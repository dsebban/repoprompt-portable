import Foundation
import Logging
import MCP
import RepoPromptCore

public struct HeadlessMCPService: Sendable {
	static let initializeInstructions = """
	RepoPrompt Headless exposes read-only workspace tools over stdio. manage_selection is the only selection mutation interface. context_builder renders only the current explicit in-memory file and slice selection; it never discovers or changes selection. clarify stays local and reports all omission metadata; provider-backed plan/review/pro_edit and oracle_send fail before HTTP when selected context is incomplete. pro_edit produces instructions only and never writes or executes. oracle_send remains limited to chat/question/plan/review, always snapshots and attaches the current explicit selection, and has no context-free mode. review_diff and clarify_handoff are caller-supplied untrusted evidence disclosed to both Oracle lanes. Portable tool schema version: \(PortableContract.toolSchemaVersion).
	"""

	public let options: HeadlessOptions
	private let bootstrap: HeadlessWorkspaceBootstrapResult
	private let oracleConfiguration: HeadlessOracleConfiguration?

	public init(
		options: HeadlessOptions,
		bootstrap: HeadlessWorkspaceBootstrapResult,
		oracleConfiguration: HeadlessOracleConfiguration? = nil
	) {
		self.options = options
		self.bootstrap = bootstrap
		self.oracleConfiguration = oracleConfiguration
	}

	public func run() async throws {
		let logger = Self.makeLogger(level: options.logLevel)
		let transport = StdioMCPTransport(logger: logger)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: options.allowWrites,
			oracleConfiguration: oracleConfiguration
		)
		let server = Server(
			name: "RepoPrompt Headless",
			version: PortableContract.softwareVersion,
			title: "RepoPrompt Headless",
			instructions: Self.initializeInstructions,
			capabilities: .init(tools: .init(listChanged: false)),
			configuration: .default
		)

		await server.withMethodHandler(ListTools.self) { _ in
			await ListTools.Result(tools: catalog.tools())
		}
		await server.withMethodHandler(CallTool.self) { params in
			await catalog.call(name: params.name, arguments: params.arguments)
		}

		try await server.start(transport: transport)
		await server.waitUntilCompleted()
	}

	private static func makeLogger(level: String?) -> Logger {
		Logger(label: "repoprompt.headless") { label in
			var handler = StreamLogHandler.standardError(label: label)
			if let level = level.flatMap(Logger.Level.init(rawValue:)) {
				handler.logLevel = level
			} else {
				handler.logLevel = .warning
			}
			return handler
		}
	}
}
