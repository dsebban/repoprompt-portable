import Foundation
import MCP
import RepoPromptHeadless

public protocol PortableCLIToolCatalog: Sendable {
	func tools() async -> [Tool]
	func call(name: String, arguments: [String: Value]?) async -> CallTool.Result
}

extension HeadlessToolCatalog: PortableCLIToolCatalog {}

public struct PortableCLIExecutionResult: Equatable, Sendable {
	public let exitCode: HeadlessExitCode
	public let standardOutput: String
	public let standardError: String

	public init(exitCode: HeadlessExitCode, standardOutput: String = "", standardError: String = "") {
		self.exitCode = exitCode
		self.standardOutput = standardOutput
		self.standardError = standardError
	}
}

public struct PortableCLIApplication: Sendable {
	public struct Dependencies: Sendable {
		public let resolveOracleConfiguration: @Sendable () throws -> HeadlessOracleConfiguration?
		public let makeCatalog: @Sendable (HeadlessOptions, HeadlessOracleConfiguration?) async throws -> any PortableCLIToolCatalog
		public let exportJSONL: @Sendable (Data, String) throws -> Void

		public init(
			resolveOracleConfiguration: @escaping @Sendable () throws -> HeadlessOracleConfiguration?,
			makeCatalog: @escaping @Sendable (HeadlessOptions, HeadlessOracleConfiguration?) async throws -> any PortableCLIToolCatalog,
			exportJSONL: @escaping @Sendable (Data, String) throws -> Void = { data, path in
				try PortableCLIAtomicExporter.write(data, to: path)
			}
		) {
			self.resolveOracleConfiguration = resolveOracleConfiguration
			self.makeCatalog = makeCatalog
			self.exportJSONL = exportJSONL
		}

		public static let live = Dependencies(
			resolveOracleConfiguration: { try HeadlessOracleConfiguration.resolve() },
			makeCatalog: { options, configuration in
				let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(options: options)
				return HeadlessToolCatalog(
					roots: bootstrap.roots,
					session: bootstrap.session,
					router: bootstrap.router,
					allowWrites: false,
					oracleConfiguration: configuration
				)
			}
		)
	}

	private let dependencies: Dependencies

	public init(dependencies: Dependencies = .live) {
		self.dependencies = dependencies
	}

	public func run(arguments: [String], executable: String = "repoprompt-portable-cli") async -> PortableCLIExecutionResult {
		let parsed: PortableCLIArguments
		do {
			parsed = try PortableCLIArguments.parse(arguments)
		} catch let error as PortableCLIUsageError {
			return usageFailure(error.message, executable: executable)
		} catch {
			return usageFailure(String(describing: error), executable: executable)
		}

		if parsed.help {
			return PortableCLIExecutionResult(
				exitCode: .success,
				standardOutput: PortableCLIArguments.usage(executable: executable) + "\n"
			)
		}

		let configuration: HeadlessOracleConfiguration?
		do {
			configuration = try dependencies.resolveOracleConfiguration()
		} catch let error as HeadlessRuntimeError {
			return diagnosticFailure(error.message, exitCode: error.exitCode, executable: executable)
		} catch {
			return diagnosticFailure(String(describing: error), exitCode: .runtime, executable: executable)
		}

		let catalog: any PortableCLIToolCatalog
		do {
			catalog = try await dependencies.makeCatalog(parsed.options, configuration)
		} catch let error as HeadlessRuntimeError {
			return diagnosticFailure(error.message, exitCode: error.exitCode, executable: executable)
		} catch {
			return diagnosticFailure(String(describing: error), exitCode: .runtime, executable: executable)
		}

		let advertisedNames = Set(await catalog.tools().map(\.name))
		for command in parsed.commands where !advertisedNames.contains(command.name) {
			return usageFailure("Tool is not advertised by portable: \(command.name).", executable: executable)
		}

		var standardOutput = ""
		for command in parsed.commands {
			let result = await catalog.call(name: command.name, arguments: command.arguments)
			let line: String
			do {
				line = try normalizedJSONObject(from: result)
			} catch {
				return PortableCLIExecutionResult(
					exitCode: .runtime,
					standardOutput: standardOutput,
					standardError: "\(executable): \(error)\n"
				)
			}

			if result.isError == true {
				return PortableCLIExecutionResult(
					exitCode: .toolFailure,
					standardOutput: standardOutput,
					standardError: line + "\n"
				)
			}
			standardOutput += line + "\n"
		}

		if let exportPath = parsed.exportPath {
			do {
				try dependencies.exportJSONL(Data(standardOutput.utf8), exportPath)
			} catch {
				return PortableCLIExecutionResult(
					exitCode: .cannotCreate,
					standardOutput: standardOutput,
					standardError: "\(executable): unable to create JSONL export: \(error)\n"
				)
			}
		}
		return PortableCLIExecutionResult(exitCode: .success, standardOutput: standardOutput)
	}

	private func normalizedJSONObject(from result: CallTool.Result) throws -> String {
		guard result.content.count == 1, case let .text(text, _, _) = result.content[0] else {
			throw PortableCLIResultError("Tool result must contain exactly one text item.")
		}
		let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
		guard value is [String: Any], JSONSerialization.isValidJSONObject(value) else {
			throw PortableCLIResultError("Tool result text must be one JSON object.")
		}
		let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
		guard let normalized = String(data: data, encoding: .utf8) else {
			throw PortableCLIResultError("Tool result JSON was not UTF-8.")
		}
		return normalized
	}

	private func usageFailure(_ message: String, executable: String) -> PortableCLIExecutionResult {
		PortableCLIExecutionResult(
			exitCode: .usage,
			standardError: "\(executable): \(message)\n\n\(PortableCLIArguments.usage(executable: executable))\n"
		)
	}

	private func diagnosticFailure(
		_ message: String,
		exitCode: HeadlessExitCode,
		executable: String
	) -> PortableCLIExecutionResult {
		PortableCLIExecutionResult(exitCode: exitCode, standardError: "\(executable): \(message)\n")
	}
}

private struct PortableCLIResultError: Error, CustomStringConvertible {
	let message: String

	init(_ message: String) {
		self.message = message
	}

	var description: String { message }
}
