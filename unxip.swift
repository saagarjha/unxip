import Compression
import Foundation

extension RandomAccessCollection {
	subscript(fromOffset fromOffset: Int = 0, toOffset toOffset: Int? = nil) -> SubSequence {
		let toOffset = toOffset ?? count
		return self[index(startIndex, offsetBy: fromOffset)..<index(startIndex, offsetBy: toOffset)]
	}

	subscript(fromOffset fromOffset: Int = 0, size size: Int) -> SubSequence {
		let base = index(startIndex, offsetBy: fromOffset)
		return self[base..<index(base, offsetBy: size)]
	}
}

struct Condition {
	var stream: AsyncStream<Void>!
	var continuation: AsyncStream<Void>.Continuation!

	init() {
		stream = .init {
			continuation = $0
		}
	}

	func signal() {
		continuation.finish()
	}

	func wait() async {
		for await _ in stream {
		}
	}
}

struct Queue<Element> {
	var buffer = [Element?.none]
	var readIndex = 0 {
		didSet {
			readIndex %= buffer.count
		}
	}
	var writeIndex = 0 {
		didSet {
			writeIndex %= buffer.count
		}
	}

	var empty: Bool {
		buffer[readIndex] == nil
	}

	mutating func push(_ element: Element) {
		if readIndex == writeIndex,
			!empty
		{
			resize()
		}
		buffer[writeIndex] = element
		writeIndex += 1
	}

	mutating func pop() -> Element {
		defer {
			buffer[readIndex] = nil
			readIndex += 1
		}
		return buffer[readIndex]!
	}

	mutating func resize() {
		var buffer = [Element?](repeating: nil, count: self.buffer.count * 2)
		let slice1 = self.buffer[readIndex..<self.buffer.endIndex]
		let slice2 = self.buffer[self.buffer.startIndex..<readIndex]
		buffer[0..<slice1.count] = slice1
		buffer[slice1.count..<slice1.count + slice2.count] = slice2
		self.buffer = buffer
		readIndex = 0
		writeIndex = slice1.count + slice2.count
	}
}

protocol BackpressureProvider {
	associatedtype Element

	var loaded: Bool { get }

	mutating func enqueue(_: Element)
	mutating func dequeue(_: Element)
}

final class CountedBackpressure<Element>: BackpressureProvider {
	var count = 0
	let max: Int

	var loaded: Bool {
		count >= max
	}

	init(max: Int) {
		self.max = max
	}

	func enqueue(_: Element) {
		count += 1
	}

	func dequeue(_: Element) {
		count -= 1
	}
}

final class FileBackpressure: BackpressureProvider {
	var size = 0
	let maxSize: Int

	var loaded: Bool {
		size >= maxSize
	}

	init(maxSize: Int) {
		self.maxSize = maxSize
	}

	func enqueue(_ file: File) {
		size += file.data.map(\.count).reduce(0, +)
	}

	func dequeue(_ file: File) {
		size -= file.data.map(\.count).reduce(0, +)
	}
}

actor BackpressureStream<Element, Backpressure: BackpressureProvider>: AsyncSequence where Backpressure.Element == Element {
	struct Iterator: AsyncIteratorProtocol {
		let stream: BackpressureStream

		func next() async throws -> Element? {
			try await stream.next()
		}
	}

	// In-place mutation of an enum is not currently supported, so this avoids
	// copies of the queue when modifying the .results case on reassignment.
	// See: https://forums.swift.org/t/in-place-mutation-of-an-enum-associated-value/11747
	class QueueWrapper {
		var queue: Queue<Element> = .init()
	}

	enum Results {
		case results(QueueWrapper)
		case error(Error)
	}

	var backpressure: Backpressure
	var results = Results.results(.init())
	var finished = false
	var yieldCondition: Condition?
	var nextCondition: Condition?

	init(backpressure: Backpressure, of: Element.Type = Element.self) {
		self.backpressure = backpressure
	}

	nonisolated func makeAsyncIterator() -> Iterator {
		AsyncIterator(stream: self)
	}

	func yield(_ element: Element) async {
		assert(yieldCondition == nil)
		precondition(!backpressure.loaded)
		precondition(!finished)
		switch results {
			case .results(let results):
				results.queue.push(element)
				backpressure.enqueue(element)
				nextCondition?.signal()
				nextCondition = nil
				while backpressure.loaded {
					yieldCondition = Condition()
					await yieldCondition?.wait()
				}
			case .error(_):
				preconditionFailure()
		}
	}

	private func next() async throws -> Element? {
		switch results {
			case .results(let results):
				if results.queue.empty {
					if !finished {
						nextCondition = .init()
						await nextCondition?.wait()
						return try await next()
					} else {
						return nil
					}
				}
				let result = results.queue.pop()
				backpressure.dequeue(result)
				yieldCondition?.signal()
				yieldCondition = nil
				return result
			case .error(let error):
				throw error
		}
	}

	nonisolated func finish() {
		Task {
			await _finish()
		}
	}

	func _finish() {
		finished = true
		nextCondition?.signal()
	}

	nonisolated func finish(throwing error: Error) {
		Task {
			await _finish(throwing: error)
		}
	}

	func _finish(throwing error: Error) {
		results = .error(error)
		nextCondition?.signal()
	}
}

actor ConcurrentStream<Element> {
	class Wrapper {
		var stream: AsyncThrowingStream<Element, Error>!
		var continuation: AsyncThrowingStream<Element, Error>.Continuation!
	}

	let wrapper = Wrapper()
	let batchSize: Int
	nonisolated var results: AsyncThrowingStream<Element, Error> {
		get {
			wrapper.stream
		}
		set {
			wrapper.stream = newValue
		}
	}
	nonisolated var continuation: AsyncThrowingStream<Element, Error>.Continuation {
		get {
			wrapper.continuation
		}
		set {
			wrapper.continuation = newValue
		}
	}
	var index = -1
	var finishedIndex = Int?.none
	var completedIndex = -1
	var widthConditions = [Int: Condition]()
	var orderingConditions = [Int: Condition]()

	init(batchSize: Int = ProcessInfo.processInfo.activeProcessorCount, consumeResults: Bool = false) {
		self.batchSize = batchSize
		results = AsyncThrowingStream<Element, Error> {
			continuation = $0
		}
		if consumeResults {
			Task {
				for try await _ in results {
				}
			}
		}
	}

	@discardableResult
	func addTask(_ operation: @escaping @Sendable () async throws -> Element) async -> Task<Element, Error> {
		index += 1
		let index = index
		let widthCondition = Condition()
		widthConditions[index] = widthCondition
		let orderingCondition = Condition()
		orderingConditions[index] = orderingCondition
		await ensureWidth(index: index)
		return Task {
			let result = await Task {
				try await operation()
			}.result
			await produce(result: result, for: index)
			return try result.get()
		}
	}

	// Unsound workaround for https://github.com/apple/swift/issues/61658
	enum BrokenBy61658 {
		@_transparent
		static func ensureWidth(_ stream: isolated ConcurrentStream, index: Int) async {
			if index >= stream.batchSize {
				await stream.widthConditions[index - stream.batchSize]!.wait()
				stream.widthConditions.removeValue(forKey: index - stream.batchSize)
			}
		}

		@_transparent
		static func produce(_ stream: isolated ConcurrentStream, result: Result<Element, Error>, for index: Int) async {
			if index != 0 {
				await stream.orderingConditions[index - 1]!.wait()
				stream.orderingConditions.removeValue(forKey: index - 1)
			}
			stream.orderingConditions[index]!.signal()
			stream.continuation.yield(with: result)
			if index == stream.finishedIndex {
				stream.continuation.finish()
			}
			stream.widthConditions[index]!.signal()
			stream.completedIndex += 1
		}
	}

	#if swift(<5.8)
		@_optimize(none)
		func ensureWidth(index: Int) async {
			await BrokenBy61658.ensureWidth(self, index: index)
		}
	#else
		func ensureWidth(index: Int) async {
			await BrokenBy61658.ensureWidth(self, index: index)
		}
	#endif

	#if swift(<5.8)
		@_optimize(none)
		func produce(result: Result<Element, Error>, for index: Int) async {
			await BrokenBy61658.produce(self, result: result, for: index)
		}
	#else
		func produce(result: Result<Element, Error>, for index: Int) async {
			await BrokenBy61658.produce(self, result: result, for: index)
		}
	#endif

	func finish() {
		finishedIndex = index
		if finishedIndex == completedIndex {
			continuation.finish()
		}
	}
}

final class Chunk: Sendable {
	let buffer: UnsafeBufferPointer<UInt8>
	let owned: Bool

	init(buffer: UnsafeBufferPointer<UInt8>, decompressedSize: Int?) {
		if let decompressedSize = decompressedSize {
			let magic = [0xfd] + "7zX".utf8
			precondition(buffer.prefix(magic.count).elementsEqual(magic))
			let result = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(decompressedSize))
			precondition(compression_decode_buffer(result.baseAddress!, result.count, buffer.baseAddress!, buffer.count, nil, COMPRESSION_LZMA) == decompressedSize)
			self.buffer = UnsafeBufferPointer(result)
			owned = true
		} else {
			self.buffer = buffer
			owned = false
		}
	}

	deinit {
		if owned {
			buffer.deallocate()
		}
	}
}

struct File {
	let dev: Int
	let ino: Int
	let mode: Int
	let name: String
	var data = [UnsafeBufferPointer<UInt8>]()
	// For keeping the data alive
	var chunks = [Chunk]()

	struct Identifier: Hashable {
		let dev: Int
		let ino: Int
	}

	var identifier: Identifier {
		Identifier(dev: dev, ino: ino)
	}

	func compressedData() async -> [UInt8]? {
		let blockSize = 64 << 10  // LZFSE with 64K block size
		var _data = [UInt8]()
		_data.reserveCapacity(self.data.map(\.count).reduce(0, +))
		let data = self.data.reduce(into: _data, +=)
		let compressionStream = ConcurrentStream<[UInt8]?>()

		Task {
			var position = data.startIndex

			while position < data.endIndex {
				let _position = position
				await compressionStream.addTask {
					try Task.checkCancellation()
					let position = _position
					let end = min(position + blockSize, data.endIndex)
					let data = [UInt8](unsafeUninitializedCapacity: (end - position) + (end - position) / 16) { buffer, count in
						data[position..<end].withUnsafeBufferPointer { data in
							count = compression_encode_buffer(buffer.baseAddress!, buffer.count, data.baseAddress!, data.count, nil, COMPRESSION_LZFSE)
							guard count < buffer.count else {
								count = 0
								return
							}
						}
					}
					return !data.isEmpty ? data : nil
				}
				position += blockSize
			}

			await compressionStream.finish()
		}
		var chunks = [[UInt8]]()
		do {
			for try await chunk in compressionStream.results {
				if let chunk = chunk {
					chunks.append(chunk)
				} else {
					return nil
				}
			}
		} catch {
			fatalError()
		}

		let tableSize = (chunks.count + 1) * MemoryLayout<UInt32>.size
		let size = tableSize + chunks.map(\.count).reduce(0, +)
		guard size < data.count else {
			return nil
		}

		return [UInt8](unsafeUninitializedCapacity: size) { buffer, count in
			var position = tableSize

			func writePosition(toTableIndex index: Int) {
				precondition(position < UInt32.max)
				for i in 0..<MemoryLayout<UInt32>.size {
					buffer[index * MemoryLayout<UInt32>.size + i] = UInt8(position >> (i * 8) & 0xff)
				}
			}

			writePosition(toTableIndex: 0)
			for (index, chunk) in zip(1..., chunks) {
				_ = UnsafeMutableBufferPointer(rebasing: buffer.suffix(from: position)).initialize(from: chunk)
				position += chunk.count
				writePosition(toTableIndex: index)
			}
			count = size
		}
	}

	func write(compressedData data: [UInt8], toDescriptor descriptor: CInt) -> Bool {
		let uncompressedSize = self.data.map(\.count).reduce(0, +)
		let attribute =
			"cmpf".utf8.reversed()  // magic
			+ [0x0c, 0x00, 0x00, 0x00]  // LZFSE, 64K chunks
			+ ([
				(uncompressedSize >> 0) & 0xff,
				(uncompressedSize >> 8) & 0xff,
				(uncompressedSize >> 16) & 0xff,
				(uncompressedSize >> 24) & 0xff,
				(uncompressedSize >> 32) & 0xff,
				(uncompressedSize >> 40) & 0xff,
				(uncompressedSize >> 48) & 0xff,
				(uncompressedSize >> 56) & 0xff,
			].map(UInt8.init) as [UInt8])

		guard fsetxattr(descriptor, "com.apple.decmpfs", attribute, attribute.count, 0, XATTR_SHOWCOMPRESSION) == 0 else {
			return false
		}

		let resourceForkDescriptor = open(name + _PATH_RSRCFORKSPEC, O_WRONLY | O_CREAT, 0o666)
		guard resourceForkDescriptor >= 0 else {
			return false
		}
		defer {
			close(resourceForkDescriptor)
		}

		var written: Int
		repeat {
			// TODO: handle partial writes smarter
			written = pwrite(resourceForkDescriptor, data, data.count, 0)
			guard written >= 0 else {
				return false
			}
		} while written != data.count

		guard fchflags(descriptor, UInt32(UF_COMPRESSED)) == 0 else {
			return false
		}

		return true
	}
}

extension option {
	init(name: StaticString, has_arg: CInt, flag: UnsafeMutablePointer<CInt>?, val: StringLiteralType) {
		let _option = name.withUTF8Buffer {
			$0.withMemoryRebound(to: CChar.self) {
				option(name: $0.baseAddress, has_arg: has_arg, flag: flag, val: CInt(UnicodeScalar(val)!.value))
			}
		}
		self = _option
	}
}

struct Options {
	static let options: [(flag: String, name: StaticString, description: StringLiteralType)] = [
		("V", "version", "Print the unxip version number."),
		("c", "compression-disable", "Disable APFS compression of result."),
		("h", "help", "Print this help message."),
		("n", "dry-run", "Dry run. (Often useful with -v.)"),
		("v", "verbose", "Print xip file contents."),
	]
	static let version = "1.1.3"

	var input: URL
	var output: URL?
	var compress: Bool = true
	var dryRun: Bool = false
	var verbose: Bool = false

	init() {
		let options =
			Self.options.map {
				option(name: $0.name, has_arg: no_argument, flag: nil, val: $0.flag)
			} + [option(name: nil, has_arg: 0, flag: nil, val: 0)]
		repeat {
			let result = getopt_long(CommandLine.argc, CommandLine.unsafeArgv, Self.options.map(\.flag).reduce("", +), options, nil)
			if result < 0 {
				break
			}
			switch UnicodeScalar(UInt32(result)) {
				case "c":
					compress = false
				case "n":
					dryRun = true
				case "h":
					Self.printUsage(nominally: true)
				case "V":
					Self.printVersion()
				case "v":
					verbose = true
				default:
					Self.printUsage(nominally: false)
			}
		} while true

		let arguments = UnsafeBufferPointer(start: CommandLine.unsafeArgv + Int(optind), count: Int(CommandLine.argc - optind)).map {
			String(cString: $0!)
		}

		guard let input = arguments.first else {
			Self.printUsage(nominally: false)
		}

		self.input = URL(fileURLWithPath: input)

		guard let output = arguments.dropFirst().first else {
			return
		}

		self.output = URL(fileURLWithPath: output)
	}

	static func printVersion() -> Never {
		print("unxip \(version)")
		exit(EXIT_SUCCESS)
	}

	static func printUsage(nominally: Bool) -> Never {
		fputs(
			"""
			A fast Xcode unarchiver

			USAGE: unxip [options] <input> [output]

			OPTIONS:
			
			""", nominally ? stdout : stderr)

		assert(options.map(\.flag) == options.map(\.flag).sorted())
		let maxWidth = options.map(\.name.utf8CodeUnitCount).max()!
		for option in options {
			let line = "    -\(option.flag), --\(option.name.description.padding(toLength: maxWidth, withPad: " ", startingAt: 0))  \(option.description)\n"
			assert(line.count <= 80)
			fputs(line, nominally ? stdout : stderr)
		}

		exit(nominally ? EXIT_SUCCESS : EXIT_FAILURE)
	}
}

@main
struct Main {
	static let options = Options()

	static func read<Integer: BinaryInteger, Buffer: RandomAccessCollection>(_ type: Integer.Type, from buffer: inout Buffer) -> Integer where Buffer.Element == UInt8, Buffer.SubSequence == Buffer {
		defer {
			buffer = buffer[fromOffset: MemoryLayout<Integer>.size]
		}
		var result: Integer = 0
		var iterator = buffer.makeIterator()
		for _ in 0..<MemoryLayout<Integer>.size {
			result <<= 8
			result |= Integer(iterator.next()!)
		}
		return result
	}

	static func chunks(from content: UnsafeBufferPointer<UInt8>) -> BackpressureStream<Chunk, CountedBackpressure<Chunk>> {
		let decompressionStream = ConcurrentStream<Void>(consumeResults: true)
		let chunkStream = BackpressureStream(backpressure: CountedBackpressure(max: 16), of: Chunk.self)

		Task {
			var remaining = content[fromOffset: 4]
			let chunkSize = read(UInt64.self, from: &remaining)
			var decompressedSize: UInt64 = 0
			var previousYield: Task<Void, Error>?

			repeat {
				decompressedSize = read(UInt64.self, from: &remaining)
				let compressedSize = read(UInt64.self, from: &remaining)

				let _remaining = remaining
				let _decompressedSize = decompressedSize
				let _previousYield = previousYield
				previousYield = await decompressionStream.addTask {
					let remaining = _remaining
					let decompressedSize = _decompressedSize
					let previousYield = _previousYield
					let chunk = Chunk(buffer: UnsafeBufferPointer(rebasing: remaining[fromOffset: 0, size: Int(compressedSize)]), decompressedSize: compressedSize == chunkSize ? nil : Int(decompressedSize))
					_ = await previousYield?.result
					await chunkStream.yield(chunk)
				}

				remaining = remaining[fromOffset: Int(compressedSize)]
			} while decompressedSize == chunkSize
			await decompressionStream.finish()
		}

		return chunkStream
	}

	static func files<ChunkStream: AsyncSequence>(in chunkStream: ChunkStream) -> BackpressureStream<File, FileBackpressure> where ChunkStream.Element == Chunk {
		let fileStream = BackpressureStream(backpressure: FileBackpressure(maxSize: 1_000_000_000), of: File.self)
		Task {
			var iterator = chunkStream.makeAsyncIterator()
			var chunk = try! await iterator.next()!
			var position = 0

			func read(size: Int) async -> [UInt8] {
				var result = [UInt8]()
				while result.count < size {
					if position >= chunk.buffer.endIndex {
						chunk = try! await iterator.next()!
						position = 0
					}
					result.append(chunk.buffer[chunk.buffer.startIndex + position])
					position += 1
				}
				return result
			}

			func readOctal(from bytes: [UInt8]) -> Int {
				Int(String(data: Data(bytes), encoding: .utf8)!, radix: 8)!
			}

			while true {
				let magic = await read(size: 6)
				// Yes, cpio.h really defines this global macro
				precondition(magic.elementsEqual(MAGIC.utf8))
				let dev = readOctal(from: await read(size: 6))
				let ino = readOctal(from: await read(size: 6))
				let mode = readOctal(from: await read(size: 6))
				let _ = await read(size: 6)  // uid
				let _ = await read(size: 6)  // gid
				let _ = await read(size: 6)  // nlink
				let _ = await read(size: 6)  // rdev
				let _ = await read(size: 11)  // mtime
				let namesize = readOctal(from: await read(size: 6))
				var filesize = readOctal(from: await read(size: 11))
				let name = String(cString: await read(size: namesize))
				var file = File(dev: dev, ino: ino, mode: mode, name: name)

				while filesize > 0 {
					if position >= chunk.buffer.endIndex {
						chunk = try! await iterator.next()!
						position = 0
					}
					let size = min(filesize, chunk.buffer.endIndex - position)
					file.chunks.append(chunk)
					file.data.append(UnsafeBufferPointer(rebasing: chunk.buffer[fromOffset: position, size: size]))
					filesize -= size
					position += size
				}

				guard file.name != "TRAILER!!!" else {
					fileStream.finish()
					return
				}

				await fileStream.yield(file)
			}
		}
		return fileStream
	}

	static func parseContent(_ content: UnsafeBufferPointer<UInt8>) async throws {
		let taskStream = ConcurrentStream<Void>()
		let compressionStream = ConcurrentStream<[UInt8]?>(consumeResults: true)

		var hardlinks = [File.Identifier: (String, Task<Void, Error>)]()
		var directories = [Substring: Task<Void, Error>]()

		for try await file in files(in: chunks(from: content)) {
			@Sendable
			func warn(_ result: CInt, _ operation: String) {
				if result != 0 {
					perror("\(operation) \(file.name) failed")
				}
			}

			// The assumption is that all directories are provided without trailing slashes
			func parentDirectory<S: StringProtocol>(of path: S) -> S.SubSequence {
				path[..<path.lastIndex(of: "/")!]
			}

			// https://bugs.swift.org/browse/SR-15816
			func parentDirectoryTask(for: File) -> Task<Void, Error>? {
				directories[parentDirectory(of: file.name)] ?? directories[String(parentDirectory(of: file.name))[...]]
			}

			@Sendable
			func setStickyBit(on file: File) {
				if file.mode & Int(C_ISVTX) != 0 {
					warn(chmod(file.name, mode_t(file.mode)), "Setting sticky bit on")
				}
			}

			if file.name == "." {
				continue
			}

			if options.verbose {
				print(file.name)
			}

			if let (original, originalTask) = hardlinks[file.identifier] {
				let task = parentDirectoryTask(for: file)
				assert(task != nil, file.name)
				await taskStream.addTask {
					_ = try await (originalTask.value, task?.value)
					guard !options.dryRun else {
						return
					}

					warn(link(original, file.name), "linking")
				}
				continue
			}

			// The types we care about, anyways
			let typeMask = Int(C_ISLNK | C_ISDIR | C_ISREG)
			switch CInt(file.mode & typeMask) {
				case C_ISLNK:
					let task = parentDirectoryTask(for: file)
					assert(task != nil, file.name)
					await taskStream.addTask {
						try await task?.value
						guard !options.dryRun else {
							return
						}

						warn(symlink(String(data: Data(file.data.map(Array.init).reduce([], +)), encoding: .utf8), file.name), "symlinking")
						setStickyBit(on: file)
					}
				case C_ISDIR:
					let task = parentDirectoryTask(for: file)
					assert(task != nil || parentDirectory(of: file.name) == ".", file.name)
					directories[file.name[...]] = await taskStream.addTask {
						try await task?.value
						guard !options.dryRun else {
							return
						}

						warn(mkdir(file.name, mode_t(file.mode & 0o777)), "creating directory at")
						setStickyBit(on: file)
					}
				case C_ISREG:
					let task = parentDirectoryTask(for: file)
					assert(task != nil, file.name)
					hardlinks[file.identifier] = (
						file.name,
						await taskStream.addTask {
							try await task?.value

							let compressedData =
								options.compress
								? try! await compressionStream.addTask {
									await file.compressedData()
								}.result.get() : nil

							guard !options.dryRun else {
								return
							}

							let fd = open(file.name, O_CREAT | O_WRONLY, mode_t(file.mode & 0o777))
							if fd < 0 {
								warn(fd, "creating file at")
								return
							}
							defer {
								warn(close(fd), "closing")
								setStickyBit(on: file)
							}

							if let compressedData = compressedData,
								file.write(compressedData: compressedData, toDescriptor: fd)
							{
								return
							}

							// pwritev requires the vector count to be positive
							if file.data.count == 0 {
								return
							}

							var vector = file.data.map {
								iovec(iov_base: UnsafeMutableRawPointer(mutating: $0.baseAddress), iov_len: $0.count)
							}
							let total = file.data.map(\.count).reduce(0, +)
							var written = 0

							repeat {
								// TODO: handle partial writes smarter
								written = pwritev(fd, &vector, CInt(vector.count), 0)
								if written < 0 {
									warn(-1, "writing chunk to")
									break
								}
							} while written != total
						}
					)
				default:
					fatalError("\(file.name) with \(file.mode) is a type that is unhandled")
			}
		}

		await taskStream.finish()

		// Run through any stragglers
		for try await _ in taskStream.results {
		}
	}

	static func locateContent(in file: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
		precondition(file.starts(with: "xar!".utf8))  // magic
		var header = file[4...]
		let headerSize = read(UInt16.self, from: &header)
		precondition(read(UInt16.self, from: &header) == 1)  // version
		let tocCompressedSize = read(UInt64.self, from: &header)
		let tocDecompressedSize = read(UInt64.self, from: &header)
		_ = read(UInt32.self, from: &header)  // checksum

		let toc = [UInt8](unsafeUninitializedCapacity: Int(tocDecompressedSize)) { buffer, count in
			let zlibSkip = 2  // Apple's decoder doesn't want to see CMF/FLG (see RFC 1950)
			count = compression_decode_buffer(buffer.baseAddress!, Int(tocDecompressedSize), file.baseAddress! + Int(headerSize) + zlibSkip, Int(tocCompressedSize) - zlibSkip, nil, COMPRESSION_ZLIB)
			precondition(count == Int(tocDecompressedSize))
		}

		let document = try! XMLDocument(data: Data(toc))
		let content = try! document.nodes(forXPath: "xar/toc/file").first {
			try! $0.nodes(forXPath: "name").first!.stringValue! == "Content"
		}!
		let contentOffset = Int(try! content.nodes(forXPath: "data/offset").first!.stringValue!)!
		let contentSize = Int(try! content.nodes(forXPath: "data/length").first!.stringValue!)!
		let contentBase = Int(headerSize) + Int(tocCompressedSize) + contentOffset

		let slice = file[fromOffset: contentBase, size: contentSize]
		precondition(slice.starts(with: "pbzx".utf8))
		return UnsafeBufferPointer(rebasing: slice)
	}

	static func main() async throws {
		let handle = try FileHandle(forReadingFrom: options.input)
		try handle.seekToEnd()
		let length = Int(try handle.offset())
		let file = UnsafeBufferPointer(start: mmap(nil, length, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0).bindMemory(to: UInt8.self, capacity: length), count: length)
		precondition(UnsafeMutableRawPointer(mutating: file.baseAddress) != MAP_FAILED)
		defer {
			munmap(UnsafeMutableRawPointer(mutating: file.baseAddress), length)
		}

		if let output = options.output {
			guard chdir(output.path) == 0 else {
				fputs("Failed to access output directory at \(output.path): \(String(cString: strerror(errno)))", stderr)
				exit(EXIT_FAILURE)
			}
		}

		try await parseContent(locateContent(in: file))
	}
}
