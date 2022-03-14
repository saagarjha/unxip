import Foundation
import UnxipFramework

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

extension Unxip.Options {
	static func fromCommandLine() -> Self {
		let options = [
			option(name: "compression-disable", has_arg: no_argument, flag: nil, val: "c"),
			option(name: "help", has_arg: no_argument, flag: nil, val: "h"),
			option(name: nil, has_arg: 0, flag: nil, val: 0),
		]

		var compress: Bool = true
		var result: CInt
		repeat {
			result = getopt_long(CommandLine.argc, CommandLine.unsafeArgv, "ch", options, nil)
			if result < 0 {
				break
			}
			switch UnicodeScalar(UInt32(result)) {
				case "c":
					compress = false
				case "h":
					Self.printUsage(nominally: true)
				default:
					Self.printUsage(nominally: false)
			}
		} while true

		let arguments = UnsafeBufferPointer(start: CommandLine.unsafeArgv + Int(optind), count: Int(CommandLine.argc - optind)).map {
			String(cString: $0!)
		}

		guard let inputArgument = arguments.first else {
			Self.printUsage(nominally: false)
		}
		let input = URL(fileURLWithPath: inputArgument)

		let output: URL?
		if let outputArgument = arguments.dropFirst().first {
			output = URL(fileURLWithPath: outputArgument)
		} else {
			output = nil
		}

		return Self(input: input, output: output, compress: compress)
	}

	static func printUsage(nominally: Bool) -> Never {
		fputs(
			"""
			A fast Xcode unarchiver

			USAGE: unxip [options] <input> [output]

			OPTIONS:
			    -c, --compression-disable  Disable APFS compression of result.
			    -h, --help                 Print this help message.
			""", nominally ? stdout : stderr)
		exit(nominally ? EXIT_SUCCESS : EXIT_FAILURE)
	}
}

@main
struct Main {
	static func main() async throws {
		try await Unxip.unxip(options: .fromCommandLine())
	}
}
