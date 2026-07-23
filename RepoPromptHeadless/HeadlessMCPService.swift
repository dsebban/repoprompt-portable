import Foundation
import Logging
import MCP
import RepoPromptCore

public struct HeadlessMCPService: Sendable {
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
			version: "0.1.0",
			title: "RepoPrompt Headless",
			instructions: "RepoPrompt Headless exposes read-only workspace tools, deterministic selected-file context assembly, and optional mandatory two-lane Oracle requests over stdio.",
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
