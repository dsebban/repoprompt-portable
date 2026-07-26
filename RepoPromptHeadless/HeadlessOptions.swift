import Foundation

public struct HeadlessOptions: Equatable, Sendable {
	public var roots: [String]
	public var workspaceName: String?
	public var sessionID: UUID?
	public var stateDir: String?
	public var persist: Bool
	public var allowWrites: Bool
	public var logLevel: String?
	public var help: Bool

	public init(
		roots: [String] = [],
		workspaceName: String? = nil,
		sessionID: UUID? = nil,
		stateDir: String? = nil,
		persist: Bool = true,
		allowWrites: Bool = false,
		logLevel: String? = nil,
		help: Bool = false
	) {
		self.roots = roots
		self.workspaceName = workspaceName
		self.sessionID = sessionID
		self.stateDir = stateDir
		self.persist = persist
		self.allowWrites = allowWrites
		self.logLevel = logLevel
		self.help = help
	}

	public static func parse(_ arguments: [String]) throws -> HeadlessOptions {
		var options = HeadlessOptions()
		var index = 0

		func requireValue(after flag: String) throws -> String {
			let valueIndex = index + 1
			guard valueIndex < arguments.count else {
				throw HeadlessRuntimeError("Missing value for \(flag).", exitCode: .usage)
			}
			let value = arguments[valueIndex]
			guard !value.isEmpty, !value.hasPrefix("--") else {
				throw HeadlessRuntimeError("Missing value for \(flag).", exitCode: .usage)
			}
			index = valueIndex
			return value
		}

		while index < arguments.count {
			let argument = arguments[index]
			switch argument {
			case "--help", "-h":
				options.help = true
			case "--root":
				options.roots.append(try requireValue(after: argument))
			case let value where value.hasPrefix("--root="):
				options.roots.append(String(value.dropFirst("--root=".count)))
			case "--workspace-name":
				options.workspaceName = try requireValue(after: argument)
			case let value where value.hasPrefix("--workspace-name="):
				options.workspaceName = String(value.dropFirst("--workspace-name=".count))
			case "--session-id":
				let raw = try requireValue(after: argument)
				guard let uuid = UUID(uuidString: raw) else {
					throw HeadlessRuntimeError("--session-id must be a UUID.", exitCode: .usage)
				}
				options.sessionID = uuid
			case let value where value.hasPrefix("--session-id="):
				let raw = String(value.dropFirst("--session-id=".count))
				guard let uuid = UUID(uuidString: raw) else {
					throw HeadlessRuntimeError("--session-id must be a UUID.", exitCode: .usage)
				}
				options.sessionID = uuid
			case "--state-dir":
				options.stateDir = try requireValue(after: argument)
			case let value where value.hasPrefix("--state-dir="):
				options.stateDir = String(value.dropFirst("--state-dir=".count))
			case "--no-persist":
				options.persist = false
			case "--allow-writes":
				options.allowWrites = true
			case "--log-level":
				options.logLevel = try requireValue(after: argument)
			case let value where value.hasPrefix("--log-level="):
				options.logLevel = String(value.dropFirst("--log-level=".count))
			default:
				throw HeadlessRuntimeError("Unknown option: \(argument).", exitCode: .usage)
			}
			index += 1
		}

		return options
	}

	public static func usage(executable: String) -> String {
		"""
		Usage: \(executable) [options]

		Run RepoPrompt as a direct headless stdio MCP server. Protocol frames are read from stdin and written to stdout; diagnostics go to stderr.

		context_builder clarify is local; plan/review/pro_edit and oracle_send always attach the complete current explicit selection and dispatch concurrent Primary/Secondary requests. pro_edit returns instructions only; oracle_send remains limited to chat/question/plan/review. review_diff and clarify_handoff are caller-supplied untrusted evidence sent to both lanes.

		Options:
		  --root <path>              Repeatable workspace root. Defaults to the current working directory.
		  --workspace-name <name>    Optional display name for the headless workspace.
		  --session-id <uuid>        Optional stable session/context UUID.
		  --state-dir <path>         Optional persistence directory.
		  --no-persist               Keep all headless session state in memory and do not create state directories.
		  --allow-writes             Reserved for future write-capable tools. Writes remain denied until implemented.
		  --log-level <level>        trace, debug, info, notice, warning, or error.
		  --help                     Show this help.

		Oracle environment:
		OPENCODE_API_KEY                     Enables OpenCode Go defaults using DeepSeek V4 Flash for both lanes.
		REPOPROMPT_ORACLE_ENDPOINT          Exact OpenAI-compatible chat-completions URL.
		REPOPROMPT_ORACLE_PRIMARY_MODEL     Required Primary model ID.
		REPOPROMPT_ORACLE_SECONDARY_MODEL   Required Secondary model ID; may equal Primary.
		REPOPROMPT_ORACLE_API_KEY           Optional bearer token.
		REPOPROMPT_ORACLE_REASONING_EFFORT  Optional top-level reasoning_effort value for both lanes.
		REPOPROMPT_ORACLE_TIMEOUT_SECONDS   Optional request timeout, 1...3600 (default 120).
		"""
	}
}
