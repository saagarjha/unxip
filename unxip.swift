import Foundation

#if canImport(Compression)
	import Compression
#else
	import FoundationXML
	import GNUSource
	import getopt
	import lzma
	import zlib
#endif

#if canImport(UIKit)  // Embedded, in other words
	import libxml2
#endif

// MARK: - Internal utilities

#if PROFILING
	import os

	let readLog = { true }() ? OSLog(subsystem: "com.saagarjha.unxip.read", category: "Read") : .disabled
	let decompressionLog = { true }() ? OSLog(subsystem: "com.saagarjha.unxip.chunk", category: "Decompression") : .disabled
	let compressionLog = { true }() ? OSLog(subsystem: "com.saagarjha.unxip.compression", category: "Compression") : .disabled
	let filesystemLog = { true }() ? OSLog(subsystem: "com.saagarjha.unxip.filesystem", category: "Filesystem") : .disabled
#endif

actor Condition {
	enum State {
		case indeterminate
		case waiting(CheckedContinuation<Void, Never>)
		case signaled
	}
	var state = State.indeterminate

	nonisolated func signal() {
		Task {
			await _signal()
		}
	}

	func _signal() {
		switch state {
			case .signaled:
				preconditionFailure("Condition has already been signaled")
			case .waiting(let continuation):
				continuation.resume()
				fallthrough
			case .indeterminate:
				state = .signaled
		}
	}

	func wait() async {
		switch state {
			case .waiting(_):
				preconditionFailure("Condition is already waiting")
			case .indeterminate:
				await withCheckedContinuation {
					state = .waiting($0)
				}
			case .signaled:
				break
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

extension AsyncThrowingStream where Failure == Error {
	actor PermissiveActionLink {
		var iterator: Iterator
		let count: Int
		var queued = [CheckedContinuation<Element?, Error>]()

		init(iterator: Iterator, count: Int) {
			self.iterator = iterator
			self.count = count
		}

		func next() async throws -> Element? {
			try await withCheckedThrowingContinuation { continuation in
				queued.append(continuation)

				if queued.count == count {
					Task {
						await step()
					}
				}
			}
		}

		func step() async {
			var iterator = self.iterator
			let next: Result<Element?, Error>
			do {
				next = .success(try await iterator.next())
			} catch {
				next = .failure(error)
			}
			self.iterator = iterator
			for continuation in queued {
				continuation.resume(with: next)
			}
			queued.removeAll()
		}
	}

	init<S: AsyncSequence>(erasing sequence: S) where S.Element == Element {
		var iterator = sequence.makeAsyncIterator()
		self.init {
			try await iterator.next()
		}
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

	init(batchSize: Int = 2 * ProcessInfo.processInfo.activeProcessorCount, consumeResults: Bool = false) {
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

// MARK: - Public API

public struct DataReader<S: AsyncSequence> where S.Element: RandomAccessCollection, S.Element.Element == UInt8 {
	public var position: Int = 0 {
		didSet {
			if let cap = cap {
				precondition(position <= cap)
			}
		}
	}
	var current: (S.Element.Index, S.Element)?
	var iterator: S.AsyncIterator

	public var cap: Int?

	public init(data: S) {
		self.iterator = data.makeAsyncIterator()
	}

	mutating func read(upTo n: Int) async throws -> [UInt8]? {
		var data = [UInt8]()
		var index = 0
		while index != n {
			let current: (S.Element.Index, S.Element)
			if let _current = self.current,
				_current.0 != _current.1.endIndex
			{
				current = _current
			} else {
				let new = try await iterator.next()
				guard let new = new else {
					return data
				}
				current = (new.startIndex, new)
			}
			let count = min(n - index, current.1.distance(from: current.0, to: current.1.endIndex))
			let end = current.1.index(current.0, offsetBy: count)
			data.append(contentsOf: current.1[current.0..<end])
			self.current = (end, current.1)
			index += count
			position += count
		}
		return data
	}

	mutating func read(_ n: Int) async throws -> [UInt8] {
		let data = try await read(upTo: n)!
		precondition(data.count == n)
		return data
	}

	mutating func read<Integer: BinaryInteger>(_ type: Integer.Type) async throws -> Integer {
		try await read(MemoryLayout<Integer>.size).reduce(into: 0) { result, next in
			result <<= 8
			result |= Integer(next)
		}
	}
}

extension DataReader where S == AsyncThrowingStream<[UInt8], Error> {
	public init(descriptor: CInt) {
		self.init(data: Self.data(readingFrom: descriptor))
	}

	public static func data(readingFrom descriptor: CInt) -> S {
		let stream = BackpressureStream(backpressure: CountedBackpressure(max: 16), of: [UInt8].self)
		let io = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: .main) { _ in
		}
		#if os(macOS)
			let readSize = Int(PIPE_SIZE) * 16
		#elseif canImport(Glibc)
			let pipeSize = fcntl(descriptor, F_GETPIPE_SZ)
			let readSize = (pipeSize > 0 ? Int(pipeSize) : sysconf(CInt(_SC_PAGESIZE))) * 16
		#else
			let readSize = sysconf(CInt(_SC_PAGESIZE)) * 16
		#endif

		Task {
			while await withCheckedContinuation({ continuation in
				#if PROFILING
					let id = OSSignpostID(log: readLog)
					os_signpost(.begin, log: readLog, name: "Read", signpostID: id, "Starting read")
				#endif
				var chunk = DispatchData.empty
				io.read(offset: 0, length: readSize, queue: .main) { done, data, error in
					guard error == 0 else {
						stream.finish(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(error)))
						continuation.resume(returning: false)
						return
					}

					chunk.append(data!)

					#if PROFILING
						os_signpost(.event, log: readLog, name: "Read", signpostID: id, "Read %td bytes", data!.count)
					#endif

					if done {
						if chunk.isEmpty {
							#if PROFILING
								os_signpost(.end, log: readLog, name: "Read", signpostID: id, "Ended final read")
							#endif
							stream.finish()
							continuation.resume(returning: false)
						} else {
							#if PROFILING
								os_signpost(.end, log: readLog, name: "Read", signpostID: id, "Ended read")
							#endif
							let chunk = chunk
							Task {
								await stream.yield(
									[UInt8](unsafeUninitializedCapacity: chunk.count) { buffer, count in
										_ = chunk.copyBytes(to: buffer, from: nil)
										count = chunk.count
									})
								continuation.resume(returning: true)
							}
						}
					}
				}
			}) {
			}
		}

		return .init(erasing: stream)
	}
}

public struct Chunk: Sendable {
	public let buffer: [UInt8]
	public let decompressed: Bool

	init(data: [UInt8], decompressedSize: Int?, lzmaDecompressor: ([UInt8], Int) -> [UInt8]) {
		if let decompressedSize = decompressedSize {
			buffer = lzmaDecompressor(data, decompressedSize)
			decompressed = true
		} else {
			buffer = data
			decompressed = false
		}
	}
}

public struct File {
	public let dev: Int
	public let ino: Int
	public let mode: Int
	public let name: String
	public var data = [ArraySlice<UInt8>]()
	var looksIncompressible = false

	struct Identifier: Hashable {
		let dev: Int
		let ino: Int
	}

	var identifier: Identifier {
		Identifier(dev: dev, ino: ino)
	}

	public enum `Type` {
		case regular
		case directory
		case symlink
	}

	public var type: Type {
		// The types we care about, anyways
		let typeMask = C_ISLNK | C_ISDIR | C_ISREG
		switch CInt(mode) & typeMask {
			case C_ISLNK:
				return .symlink
			case C_ISDIR:
				return .directory
			case C_ISREG:
				return .regular
			default:
				fatalError("\(name) with \(mode) is a type that is unhandled")
		}
	}

	public var sticky: Bool {
		mode & Int(C_ISVTX) != 0
	}

	#if canImport(Darwin)
		static let blocksize = {
			var buffer = stat()
			// FIXME: This relies on a previous chdir to the output directory
			stat(".", &buffer)
			return buffer.st_blksize
		}()

		func compressedData() async -> [UInt8]? {
			guard !looksIncompressible else {
				return nil
			}

			// There is no benefit on APFS to using transparent compression if
			// the data is less than one allocation block.
			let totalSize = self.data.map(\.count).reduce(0, +)
			guard totalSize > Self.blocksize else {
				return nil
			}

			var _data = [UInt8]()
			_data.reserveCapacity(totalSize)
			let data = self.data.reduce(into: _data, +=)
			let compressionStream = ConcurrentStream<[UInt8]?>()

			#if PROFILING
				let id = OSSignpostID(log: compressionLog)
				os_signpost(.begin, log: compressionLog, name: "Data compression", signpostID: id, "Starting compression of %s (uncompressed size = %td)", name, data.count)
			#endif

			let blockSize = 64 << 10  // LZFSE with 64K block size

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
						#if PROFILING
							os_signpost(.end, log: compressionLog, name: "Data compression", signpostID: id, "Ended compression (did not compress)")
						#endif
						return nil
					}
				}
			} catch {
				fatalError()
			}

			let tableSize = (chunks.count + 1) * MemoryLayout<UInt32>.size
			let size = tableSize + chunks.map(\.count).reduce(0, +)

			#if PROFILING
				defer {
					os_signpost(.end, log: compressionLog, name: "Data compression", signpostID: id, "Ended compression (compressed size = %td)", size)
				}
			#endif

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
				#if PROFILING
					let id = OSSignpostID(log: filesystemLog)
					os_signpost(.begin, log: filesystemLog, name: "compressed pwrite", signpostID: id, "Starting compressed pwrite for %s", name)
				#endif
				// TODO: handle partial writes smarter
				written = pwrite(resourceForkDescriptor, data, data.count, 0)
				guard written >= 0 else {
					return false
				}
				#if PROFILING
					os_signpost(.end, log: filesystemLog, name: "compressed pwrite", signpostID: id, "Ended")
				#endif
			} while written != data.count

			guard fchflags(descriptor, UInt32(UF_COMPRESSED)) == 0 else {
				return false
			}

			return true
		}
	#endif
}

public protocol StreamAperture {
	associatedtype Input
	associatedtype Next: StreamAperture
	associatedtype Options

	static func transform(_: Input, options: Options?) -> Next.Input
}

extension StreamAperture {
	static func async_precondition(_ condition: @autoclosure () async throws -> Bool) async rethrows {
		let result = try await condition()
		precondition(result)
	}
}

protocol Decompressor {
	static func decompress(data: [UInt8], decompressedSize: Int) -> [UInt8]
}

public enum DefaultDecompressor {
	enum Zlib: Decompressor {
		static func decompress(data: [UInt8], decompressedSize: Int) -> [UInt8] {
			return [UInt8](unsafeUninitializedCapacity: decompressedSize) { buffer, count in
				#if canImport(Compression)
					let zlibSkip = 2  // Apple's decoder doesn't want to see CMF/FLG (see RFC 1950)
					data[data.index(data.startIndex, offsetBy: zlibSkip)...].withUnsafeBufferPointer {
						precondition(compression_decode_buffer(buffer.baseAddress!, decompressedSize, $0.baseAddress!, $0.count, nil, COMPRESSION_ZLIB) == decompressedSize)
					}
				#else
					var size = decompressedSize
					precondition(uncompress(buffer.baseAddress!, &size, data, UInt(data.count)) == Z_OK)
					precondition(size == decompressedSize)
				#endif
				count = decompressedSize
			}
		}
	}

	enum LZMA: Decompressor {
		static func decompress(data: [UInt8], decompressedSize: Int) -> [UInt8] {
			let magic = [0xfd] + "7zX".utf8
			precondition(data.prefix(magic.count).elementsEqual(magic))
			return [UInt8](unsafeUninitializedCapacity: decompressedSize) { buffer, count in
				#if canImport(Compression)
					precondition(compression_decode_buffer(buffer.baseAddress!, decompressedSize, data, data.count, nil, COMPRESSION_LZMA) == decompressedSize)
				#else
					var memlimit = UInt64.max
					var inIndex = 0
					var outIndex = 0
					precondition(lzma_stream_buffer_decode(&memlimit, 0, nil, data, &inIndex, data.count, buffer.baseAddress, &outIndex, decompressedSize) == LZMA_OK)
					precondition(inIndex == data.count && outIndex == decompressedSize)
				#endif
				count = decompressedSize
			}
		}
	}
}

public enum XIP<S: AsyncSequence>: StreamAperture where S.Element: RandomAccessCollection, S.Element.Element == UInt8 {
	public typealias Input = DataReader<S>
	public typealias Next = Chunks

	public struct Options {
		let zlibDecompressor: ([UInt8], Int) -> [UInt8]
		let lzmaDecompressor: ([UInt8], Int) -> [UInt8]

		init<Zlib: Decompressor, LZMA: Decompressor>(zlibDecompressor: Zlib.Type, lzmaDecompressor: LZMA.Type) {
			self.zlibDecompressor = Zlib.decompress
			self.lzmaDecompressor = LZMA.decompress
		}
	}

	static var defaultOptions: Options {
		.init(zlibDecompressor: DefaultDecompressor.Zlib.self, lzmaDecompressor: DefaultDecompressor.LZMA.self)
	}

	static func locateContent(in file: inout DataReader<some AsyncSequence>, options: Options) async throws {
		let fileStart = file.position

		let magic = "xar!".utf8
		try await async_precondition(await file.read(magic.count).elementsEqual(magic))
		let headerSize = try await file.read(UInt16.self)
		try await async_precondition(await file.read(UInt16.self) == 1)  // version
		let tocCompressedSize = try await file.read(UInt64.self)
		let tocDecompressedSize = try await file.read(UInt64.self)
		_ = try await file.read(UInt32.self)  // checksum

		_ = try await file.read(fileStart + Int(headerSize) - file.position)

		let compressedTOC = try await file.read(Int(tocCompressedSize))
		let toc = options.zlibDecompressor(compressedTOC, Int(tocDecompressedSize))

		#if canImport(UIKit)
			let document = xmlReadMemory(toc, CInt(toc.count), "", nil, 0)
			defer {
				xmlFreeDoc(document)
			}
			let context = xmlXPathNewContext(document)
			defer {
				xmlXPathFreeContext(context)
			}

			func evaluateXPath(node: xmlNodePtr!, xpath: String) -> String {
				let result = xmlXPathNodeEval(node, xpath, context)!
				defer {
					xmlXPathFreeObject(result)
				}
				precondition(result.pointee.type == XPATH_NODESET && result.pointee.nodesetval.pointee.nodeNr == 1)
				let string = xmlNodeListGetString(document, result.pointee.nodesetval.pointee.nodeTab.pointee!.pointee.children, 1)!
				defer {
					xmlFree(string)
				}
				return String(cString: string)
			}

			let result = xmlXPathEvalExpression("/xar/toc/file", context)!
			defer {
				xmlXPathFreeObject(result)
			}
			precondition(result.pointee.type == XPATH_NODESET)
			let content = result.pointee.nodesetval.pointee.nodeTab[
				(0..<Int(result.pointee.nodesetval.pointee.nodeNr)).first {
					evaluateXPath(node: result.pointee.nodesetval.pointee.nodeTab[$0], xpath: "name") == "Content"
				}!]

			let contentOffset = Int(evaluateXPath(node: content, xpath: "data/offset"))!
			let contentSize = Int(evaluateXPath(node: content, xpath: "data/length"))!
		#else
			let document = try! XMLDocument(data: Data(toc))
			let content = try! document.nodes(forXPath: "/xar/toc/file").first {
				try! $0.nodes(forXPath: "name").first!.stringValue! == "Content"
			}!
			let contentOffset = Int(try! content.nodes(forXPath: "data/offset").first!.stringValue!)!
			let contentSize = Int(try! content.nodes(forXPath: "data/length").first!.stringValue!)!
		#endif

		_ = try await file.read(fileStart + Int(headerSize) + Int(tocCompressedSize) + contentOffset - file.position)
		file.cap = file.position + contentSize
	}

	public static func transform(_ data: Input, options: Options?) -> Next.Input {
		let options = options ?? Self.defaultOptions

		let decompressionStream = ConcurrentStream<Void>(consumeResults: true)
		let chunkStream = BackpressureStream(backpressure: CountedBackpressure(max: 16), of: Chunk.self)

		Task {
			var content = data

			do {
				try await locateContent(in: &content, options: options)
			} catch {
				chunkStream.finish(throwing: error)
			}

			let magic = "pbzx".utf8
			try await async_precondition(try await content.read(magic.count).elementsEqual(magic))
			let chunkSize = try await content.read(UInt64.self)
			var decompressedSize: UInt64 = 0
			var previousYield: Task<Void, Error>?
			var chunkNumber = 0

			repeat {
				decompressedSize = try await content.read(UInt64.self)
				let compressedSize = try await content.read(UInt64.self)

				let block = try await content.read(Int(compressedSize))
				let _decompressedSize = decompressedSize
				let _previousYield = previousYield
				let _chunkNumber = chunkNumber
				previousYield = await decompressionStream.addTask {
					let decompressedSize = _decompressedSize
					let previousYield = _previousYield
					let chunkNumber = _chunkNumber
					let compressed = compressedSize != chunkSize
					#if PROFILING
						let id = OSSignpostID(log: decompressionLog)
						os_signpost(.begin, log: decompressionLog, name: "Decompress", signpostID: id, compressed ? "Starting %td (compressed size = %td)" : "Starting %td (uncompressed size = %td)", chunkNumber, compressedSize)
					#endif
					let chunk = Chunk(data: block, decompressedSize: compressed ? Int(decompressedSize) : nil, lzmaDecompressor: options.lzmaDecompressor)
					#if PROFILING
						os_signpost(.end, log: decompressionLog, name: "Decompress", signpostID: id, "Ended %td (decompressed size = %td)", chunkNumber, decompressedSize)
					#endif
					_ = await previousYield?.result
					await chunkStream.yield(chunk)
				}
				chunkNumber += 1
			} while decompressedSize == chunkSize

			_ = await previousYield?.result
			chunkStream.finish()
			await decompressionStream.finish()
		}

		return .init(erasing: chunkStream)
	}
}

public enum Chunks: StreamAperture {
	public typealias Input = AsyncThrowingStream<Chunk, Error>
	public typealias Next = Files

	public typealias Options = Never

	public static func transform(_ chunks: Input, options: Options?) -> Next.Input {
		let fileStream = BackpressureStream(backpressure: FileBackpressure(maxSize: 1_000_000_000), of: File.self)
		Task {
			var iterator = chunks.makeAsyncIterator()
			var chunk = try! await iterator.next()!
			var position = chunk.buffer.startIndex

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
						position = chunk.buffer.startIndex
					}
					let end = chunk.buffer.index(position, offsetBy: filesize, limitedBy: chunk.buffer.endIndex) ?? chunk.buffer.endIndex
					let buffer = chunk.buffer[position..<end]
					file.data.append(buffer)

					// This file appears to have a full raw chunk in it. This
					// means it's large and has substantial portions that are
					// incompressible. We probably should skip trying to do so
					// ourselves.
					if buffer.count == chunk.buffer.count, !chunk.decompressed {
						file.looksIncompressible = true
					}

					filesize -= end - position
					position = end
				}

				guard file.name != "TRAILER!!!" else {
					fileStream.finish()
					// Formally finish the stream.
					while try await iterator.next() != nil {
						assertionFailure("Found chunks after the CPIO trailer")
					}
					return
				}

				await fileStream.yield(file)
			}
		}
		return .init(erasing: fileStream)
	}
}

public enum Files: StreamAperture {
	public typealias Input = AsyncThrowingStream<File, Error>
	public typealias Next = Disk

	public struct Options {
		public let compress: Bool
		public let dryRun: Bool

		public init(compress: Bool, dryRun: Bool) {
			self.compress = compress
			self.dryRun = dryRun
		}
	}

	static var defaultOptions: Options {
		.init(compress: true, dryRun: false)
	}

	public static func transform(_ files: Input, options: Options?) -> Next.Input {
		let options = options ?? Self.defaultOptions
		let taskStream = ConcurrentStream<Void>()

		actor Completion {
			var queued = Queue<File>()
			let completionStream = BackpressureStream(backpressure: FileBackpressure(maxSize: 1_000_000_000), of: File.self)

			func complete(_ file: File) {
				queued.push(file)
			}

			func waitForCompletions() async {
				while !queued.empty {
					await completionStream.yield(queued.pop())
				}
			}
		}
		let completion = Completion()

		Task {
			let compressionStream = ConcurrentStream<[UInt8]?>(consumeResults: true)

			var hardlinks = [File.Identifier: (String, Task<Void, Error>)]()
			var directories = [Substring: Task<Void, Error>]()

			for try await file in files {
				await completion.waitForCompletions()

				@Sendable
				func measureFilesystemOperation<T>(named name: StaticString, _ operation: () -> T) -> T {
					#if PROFILING
						let id = OSSignpostID(log: filesystemLog)
						os_signpost(.begin, log: filesystemLog, name: name, signpostID: id, "Starting %s for %s", name.description, file.name)
						defer {
							os_signpost(.end, log: filesystemLog, name: name, signpostID: id, "Completed")
						}
					#endif
					return operation()
				}

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
					if file.sticky {
						measureFilesystemOperation(named: "chmod") {
							warn(chmod(file.name, mode_t(file.mode)), "Setting sticky bit on")
						}
					}
				}

				@Sendable @discardableResult
				func addTask(_ operation: @escaping @Sendable () async throws -> Void) async -> Task<Void, Error> {
					await taskStream.addTask {
						try await operation()
						await completion.complete(file)
					}
				}

				if file.name == "." {
					continue
				}

				if let (original, originalTask) = hardlinks[file.identifier] {
					let task = parentDirectoryTask(for: file)
					assert(task != nil, file.name)
					await addTask {
						_ = try await (originalTask.value, task?.value)
						guard !options.dryRun else {
							return
						}

						measureFilesystemOperation(named: "link") {
							warn(link(original, file.name), "linking")
						}
					}
					continue
				}

				switch file.type {
					case .symlink:
						let task = parentDirectoryTask(for: file)
						assert(task != nil, file.name)
						await addTask {
							try await task?.value
							guard !options.dryRun else {
								return
							}

							measureFilesystemOperation(named: "symlink") {
								warn(symlink(String(data: Data(file.data.map(Array.init).reduce([], +)), encoding: .utf8)!, file.name), "symlinking")
							}
							setStickyBit(on: file)
						}
					case .directory:
						let task = parentDirectoryTask(for: file)
						assert(task != nil || parentDirectory(of: file.name) == ".", file.name)
						directories[file.name[...]] = await addTask {
							try await task?.value
							guard !options.dryRun else {
								return
							}

							measureFilesystemOperation(named: "mkdir") {
								warn(mkdir(file.name, mode_t(file.mode & 0o777)), "creating directory at")
							}
							setStickyBit(on: file)
						}
					case .regular:
						let task = parentDirectoryTask(for: file)
						assert(task != nil, file.name)
						hardlinks[file.identifier] = (
							file.name,
							await addTask {
								try await task?.value

								#if canImport(Darwin)
									let compressedData =
										options.compress
										? try! await compressionStream.addTask {
											await file.compressedData()
										}.result.get() : nil
								#endif

								guard !options.dryRun else {
									return
								}

								let fd = measureFilesystemOperation(named: "open") {
									open(file.name, O_CREAT | O_WRONLY, mode_t(file.mode & 0o777))
								}
								if fd < 0 {
									warn(fd, "creating file at")
									return
								}
								defer {
									measureFilesystemOperation(named: "close") {
										warn(close(fd), "closing")
									}
									setStickyBit(on: file)
								}

								#if canImport(Darwin)
									if let compressedData = compressedData,
										file.write(compressedData: compressedData, toDescriptor: fd)
									{
										return
									}
								#endif

								var position = 0
								outer: for data in file.data {
									var written = 0
									// TODO: handle partial writes smarter
									repeat {
										written = data.withUnsafeBytes { data in
											measureFilesystemOperation(named: "pwrite") {
												pwrite(fd, data.baseAddress, data.count, off_t(position))
											}
										}
										if written < 0 {
											warn(-1, "writing chunk to")
											break outer
										}
									} while written != data.count
									position += written
								}
							}
						)
				}
			}

			await taskStream.finish()

			// Run through any stragglers
			for try await _ in taskStream.results {
			}

			await completion.waitForCompletions()
			completion.completionStream.finish()
		}

		return .init(erasing: completion.completionStream)
	}
}

public enum Disk: StreamAperture {
	public typealias Input = AsyncThrowingStream<File, Error>
	public typealias Next = Disk  // Irrelevant because this is never used

	public typealias Options = Never

	public static func transform(_ files: Input, options: Options?) -> Next.Input {
		fatalError()
	}
}

public struct UnxipStream<T: StreamAperture> {
	public static func xip<S: AsyncSequence>(wrapping: S) -> UnxipStream<XIP<S>> where S.Element: RandomAccessCollection, S.Element.Element == UInt8 {
		return .init()
	}

	public static func xip<S: AsyncSequence>(input: DataReader<S>) -> UnxipStream<XIP<S>> where S.Element: RandomAccessCollection, S.Element.Element == UInt8 {
		return .init()
	}

	public static var chunks: UnxipStream<Chunks> {
		.init()
	}

	public static var files: UnxipStream<Files> {
		.init()
	}

	public static var disk: UnxipStream<Disk> {
		.init()
	}
}

public struct Unxip {
	public static func makeStream<Start: StreamAperture, End: StreamAperture>(from start: UnxipStream<Start>, to end: UnxipStream<End>, input: Start.Input, _ option1: Start.Options? = nil, _ option2: Start.Next.Options? = nil, _ option3: Start.Next.Next.Options? = nil) -> End.Input where Start.Next.Next.Next == End {
		Start.Next.Next.transform(Start.Next.transform(Start.transform(input, options: option1), options: option2), options: option3)
	}

	public static func makeStream<Start: StreamAperture, End: StreamAperture>(from start: UnxipStream<Start>, to end: UnxipStream<End>, input: Start.Input, _ option1: Start.Options? = nil, _ option2: Start.Next.Options? = nil) -> End.Input where Start.Next.Next == End {
		Start.Next.transform(Start.transform(input, options: option1), options: option2)
	}

	public static func makeStream<Start: StreamAperture, End: StreamAperture>(from start: UnxipStream<Start>, to end: UnxipStream<End>, input: Start.Input, _ option1: Start.Options? = nil) -> End.Input where Start.Next == End {
		Start.transform(input, options: option1)
	}

	// For completeness, really
	public static func makeStream<StartEnd: StreamAperture>(from start: UnxipStream<StartEnd>, to end: UnxipStream<StartEnd>, input: StartEnd.Input) -> StartEnd.Input {
		input
	}
}

extension AsyncThrowingStream where Failure == Error {
	public func lockstepSplit() -> (Self, Self) {
		let pal = PermissiveActionLink(iterator: makeAsyncIterator(), count: 2)

		return (
			Self {
				try await pal.next()
			},
			Self {
				try await pal.next()
			}
		)
	}
}

// MARK: - unxip

#if !LIBUNXIP
	@main
	struct Main {
		struct Options {
			static let options: [(flag: String, name: StaticString, description: StringLiteralType)] = [
				("V", "version", "Print the unxip version number."),
				("c", "compression-disable", "Disable APFS compression of result."),
				("h", "help", "Print this help message."),
				("n", "dry-run", "Dry run. (Often useful with -v.)"),
				("s", "statistics", "Print statistics on completion."),
				("v", "verbose", "Print xip file contents."),
			]
			static let version = "2.2"

			var input: String?
			var output: String?
			var compress = true
			var dryRun = false
			var printStatistics = false
			var verbose = false

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
						case "V":
							Self.printVersion()
						case "c":
							compress = false
						case "n":
							dryRun = true
						case "h":
							Self.printUsage(nominally: true)
						case "s":
							printStatistics = true
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

				self.input = input == "-" ? nil : input
				self.output = arguments.dropFirst().first
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

		actor Statistics {
			static let byteCountFormatter: ByteCountFormatter = {
				let byteCountFormatter = ByteCountFormatter()
				byteCountFormatter.allowsNonnumericFormatting = false
				return byteCountFormatter
			}()

			// There seems to be a compiler bug where this needs to be outside of init
			static func start() -> Any? {
				if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
					return ContinuousClock.now
				} else {
					return nil
				}
			}

			var start: Any?
			var files = 0
			var directories = 0
			var symlinks = 0
			var hardlinks = 0
			var read = 0
			var total: Int?
			var identifiers = Set<File.Identifier>()

			let source: DispatchSourceSignal

			init() {
				start = Self.start()

				let watchedSignal: CInt
				#if canImport(Darwin)
					watchedSignal = SIGINFO
				#else
					watchedSignal = SIGUSR1
					signal(watchedSignal, SIG_IGN)
				#endif

				let source = DispatchSource.makeSignalSource(signal: watchedSignal)
				self.source = source
				source.setEventHandler {
					Task {
						await self.printStatistics()
					}
				}
				source.resume()

			}

			func note(_ file: File) {
				switch file.type {
					case .regular:
						if identifiers.contains(file.identifier) {
							hardlinks += 1
						} else {
							files += 1
							identifiers.insert(file.identifier)
						}
					case .directory:
						directories += 1
					case .symlink:
						symlinks += 1
				}
			}

			func noteRead(size bytes: Int) {
				read += bytes
			}

			func setTotal(_ total: Int) {
				self.total = total
			}

			func printStatistics() {
				print("Read \(Self.byteCountFormatter.string(fromByteCount: Int64(read)))", terminator: "")
				if let total = total {
					print(" (out of \(Self.byteCountFormatter.string(fromByteCount: Int64(total))))", terminator: "")
				}
				if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *),
					let start = start as? ContinuousClock.Instant
				{
					#if canImport(Darwin)
						let duration = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2)))
					#else
						let duration = ContinuousClock.now - start
					#endif
					print(" in \(duration)")
				} else {
					print()
				}
				print("Created \(files) files, \(directories) directories, \(symlinks) symlinks, and \(hardlinks) hardlinks")
			}
		}

		static func main() async throws {
			let options = Options()
			let statistics = Statistics()

			let handle: FileHandle
			if let input = options.input {
				handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: input))
				try handle.seekToEnd()
				await statistics.setTotal(Int(try handle.offset()))
				try handle.seek(toOffset: 0)
			} else {
				handle = FileHandle.standardInput
			}

			if let output = options.output {
				guard chdir(output) == 0 else {
					fputs("Failed to access output directory at \(output): \(String(cString: strerror(errno)))", stderr)
					exit(EXIT_FAILURE)
				}
			}

			let file = AsyncThrowingStream(erasing: DataReader.data(readingFrom: handle.fileDescriptor))
			let (data, input) = file.lockstepSplit()

			Task {
				for try await data in data {
					await statistics.noteRead(size: data.count)
				}
			}

			for try await file in Unxip.makeStream(from: .xip(wrapping: input), to: .disk, input: DataReader(data: input), nil, nil, .init(compress: options.compress, dryRun: options.dryRun)) {
				await statistics.note(file)
				if options.verbose {
					print(file.name)
				}
			}

			if options.printStatistics {
				await statistics.printStatistics()
			}
		}
	}
#endif
