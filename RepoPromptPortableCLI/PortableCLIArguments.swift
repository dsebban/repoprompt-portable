import Foundation
import MCP
import RepoPromptHeadless

public struct PortableCLICommand: Equatable, Sendable {
	public let name: String
	public let arguments: [String: Value]

	public init(name: String, arguments: [String: Value]) {
		self.name = name
		self.arguments = arguments
	}
}

public struct PortableCLIArguments: Equatable, Sendable {
	public static let helpToolNames = [
		"bind_context",
		"get_file_tree",
		"read_file",
		"manage_selection",
		"file_search",
		"context_builder",
		"oracle_send"
	]

	public let options: HeadlessOptions
	public let commands: [PortableCLICommand]
	public let exportPath: String?
	public let help: Bool

	public static func parse(_ arguments: [String]) throws -> PortableCLIArguments {
		var options = HeadlessOptions(persist: false, allowWrites: false)
		var expressions: [String] = []
		var implicitArguments: [String] = []
		var exportPath: String?
		var help = false
		var index = 0

		func setExportPath(_ path: String) throws {
			guard exportPath == nil else { throw PortableCLIUsageError("--export-jsonl may be specified only once.") }
			guard !path.isEmpty else { throw PortableCLIUsageError("Missing value for --export-jsonl.") }
			exportPath = path
		}

		func requireValue(for option: String) throws -> String {
			let valueIndex = index + 1
			guard valueIndex < arguments.count, !arguments[valueIndex].isEmpty else {
				throw PortableCLIUsageError("Missing value for \(option).")
			}
			index = valueIndex
			return arguments[valueIndex]
		}

		while index < arguments.count {
			let argument = arguments[index]
			switch argument {
			case "-h", "--help":
				help = true
			case "--root":
				options.roots.append(try requireValue(for: argument))
			case let value where value.hasPrefix("--root="):
				options.roots.append(String(value.dropFirst("--root=".count)))
			case "--workspace-name":
				options.workspaceName = try requireValue(for: argument)
			case let value where value.hasPrefix("--workspace-name="):
				options.workspaceName = String(value.dropFirst("--workspace-name=".count))
			case "--session-id":
				options.sessionID = try parseSessionID(try requireValue(for: argument))
			case let value where value.hasPrefix("--session-id="):
				options.sessionID = try parseSessionID(String(value.dropFirst("--session-id=".count)))
			case "--export-jsonl":
				try setExportPath(try requireValue(for: argument))
			case let value where value.hasPrefix("--export-jsonl="):
				try setExportPath(String(value.dropFirst("--export-jsonl=".count)))
			case "-e", "--exec":
				expressions.append(try requireValue(for: argument))
			case let value where value.hasPrefix("--exec="):
				expressions.append(String(value.dropFirst("--exec=".count)))
			default:
				implicitArguments = Array(arguments[index...])
				index = arguments.count
				continue
			}
			index += 1
		}

		if help {
			return PortableCLIArguments(options: options, commands: [], exportPath: exportPath, help: true)
		}
		guard expressions.isEmpty || implicitArguments.isEmpty else {
			throw PortableCLIUsageError("Do not mix an implicit command with -e/--exec commands.")
		}

		let commands: [PortableCLICommand]
		if !expressions.isEmpty {
			commands = try expressions.map(parseExpression)
		} else {
			guard !implicitArguments.isEmpty else {
				throw PortableCLIUsageError("A tool command is required.")
			}
			guard implicitArguments.count <= 2 else {
				throw PortableCLIUsageError("Tool arguments must be one shell-quoted JSON object.")
			}
			commands = [try parseCommand(name: implicitArguments[0], json: implicitArguments.count == 2 ? implicitArguments[1] : nil)]
		}

		return PortableCLIArguments(options: options, commands: commands, exportPath: exportPath, help: false)
	}

	public static func usage(executable: String) -> String {
		"""
		Usage:
			\(executable) [global options] <exact-tool-name> ['<JSON object>']
			\(executable) [global options] -e '<exact-tool-name> [JSON object]' [-e ...]

		Contract:
			context_builder accepts clarify|plan|review|pro_edit; clarify is local and pro_edit returns instructions only.
			Provider-backed builder modes and oracle_send always attach the complete current explicit selection and run Primary/Secondary concurrently.
			oracle_send remains limited to chat|question|plan|review; review_diff and clarify_handoff are caller-supplied untrusted evidence sent to both lanes.

		Global options:
			--root <path>              Repeatable workspace root; defaults to the current directory.
			--workspace-name <name>    Optional workspace display name.
			--session-id <uuid>        Optional in-process session/context UUID.
			--export-jsonl <path>      Atomically create a new mode-0600 JSONL file; never overwrites.
			-e, --exec <command>       Execute a tool command; repeat to share in-process selection state.
			-h, --help                 Show this help.

		Tools:
			\(helpToolNames.joined(separator: "\n  "))
		"""
	}

	private static func parseExpression(_ expression: String) throws -> PortableCLICommand {
		let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			throw PortableCLIUsageError("An -e/--exec command cannot be empty.")
		}
		guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else {
			return try parseCommand(name: trimmed, json: nil)
		}
		let name = String(trimmed[..<separator])
		let json = String(trimmed[separator...]).trimmingCharacters(in: .whitespacesAndNewlines)
		return try parseCommand(name: name, json: json.isEmpty ? nil : json)
	}

	private static func parseCommand(name: String, json: String?) throws -> PortableCLICommand {
		guard !name.isEmpty else {
			throw PortableCLIUsageError("A tool name is required.")
		}
		guard let json else {
			return PortableCLICommand(name: name, arguments: [:])
		}
		do {
			let arguments = try JSONDecoder().decode([String: Value].self, from: Data(json.utf8))
			return PortableCLICommand(name: name, arguments: arguments)
		} catch {
			throw PortableCLIUsageError("Arguments for \(name) must be exactly one valid JSON object.")
		}
	}

	private static func parseSessionID(_ raw: String) throws -> UUID {
		guard let id = UUID(uuidString: raw) else {
			throw PortableCLIUsageError("--session-id must be a UUID.")
		}
		return id
	}
}

public struct PortableCLIUsageError: Error, CustomStringConvertible, Equatable, Sendable {
	public let message: String

	public init(_ message: String) {
		self.message = message
	}

	public var description: String { message }
}
