import Foundation

public struct DesktopArguments: Equatable, Sendable {
	public var roots: [String] = []
	public var help = false
	public var macOSQA = false

	public init(roots: [String] = [], help: Bool = false, macOSQA: Bool = false) {
		self.roots = roots
		self.help = help
		self.macOSQA = macOSQA
	}

	public static func parse(_ arguments: [String]) throws -> DesktopArguments {
		var parsed = DesktopArguments()
		var index = 0
		while index < arguments.count {
			let argument = arguments[index]
			switch argument {
			case "--help", "-h":
				parsed.help = true
			case "--macos":
				parsed.macOSQA = true
			case "--root", "-r":
				index += 1
				guard index < arguments.count, !arguments[index].isEmpty else {
					throw DesktopArgumentError("Missing value for \(argument).")
				}
				parsed.roots.append(arguments[index])
			case let value where value.hasPrefix("--root="):
				let root = String(value.dropFirst("--root=".count))
				guard !root.isEmpty else { throw DesktopArgumentError("Missing value for --root.") }
				parsed.roots.append(root)
			default:
				throw DesktopArgumentError("Unknown option: \(argument).")
			}
			index += 1
		}
		return parsed
	}

	public static func usage(executable: String) -> String {
		"""
		Usage: \(executable) [--root <path>]... [--macos]

		Open a read-only RepoPrompt workspace in the native desktop.

		Options:
		  --root, -r <path>  Repeatable workspace root. Defaults to the current directory.
		  --macos            Allow the Linux-first desktop to launch with AppKit for macOS QA.
		  --help, -h         Show this help.
		"""
	}
}

public struct DesktopArgumentError: Error, Equatable, LocalizedError, Sendable {
	public let message: String

	public init(_ message: String) {
		self.message = message
	}

	public var errorDescription: String? { message }
}
