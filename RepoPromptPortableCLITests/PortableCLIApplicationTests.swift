import Foundation
import MCP
import RepoPromptHeadless
@testable import RepoPromptPortableCLI
import XCTest

final class PortableCLIApplicationTests: XCTestCase {
	func testHelpListsExactlyTheCatalogTools() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		let catalogNames = await catalog.tools().map(\.name)
		XCTAssertEqual(Set(PortableCLIArguments.helpToolNames), Set(catalogNames))
	}

	func testSuccessProducesCompactSortedJSONLinesInCommandOrder() async {
		let catalog = MockCatalog(
			names: ["first", "second"],
			results: [success("{\n  \"z\": 1, \"a\": 2\n}"), success("{\"ok\":false,\"pair_status\":\"failed\"}")]
		)
		let result = await application(catalog: catalog).run(arguments: ["-e", "first {}", "-e", "second {}"])

		XCTAssertEqual(result.exitCode, .success)
		XCTAssertEqual(result.standardOutput, "{\"a\":2,\"z\":1}\n{\"ok\":false,\"pair_status\":\"failed\"}\n")
		XCTAssertEqual(result.standardError, "")
		let calls = await catalog.recordedCalls()
		XCTAssertEqual(calls.map(\.name), ["first", "second"])
	}

	func testSuccessfulSequenceExportsExactJSONLAndPreservesStdout() async {
		let catalog = MockCatalog(
			names: ["first", "second"],
			results: [success("{\"value\":1}"), success("{\"ok\":false,\"pair_status\":\"failed\"}")]
		)
		let recorder = ExportRecorder()
		let result = await application(catalog: catalog, exportJSONL: recorder.record).run(arguments: [
			"--export-jsonl", "result.jsonl",
			"-e", "first {}",
			"-e", "second {}"
		])

		let expected = "{\"value\":1}\n{\"ok\":false,\"pair_status\":\"failed\"}\n"
		XCTAssertEqual(result.exitCode, .success)
		XCTAssertEqual(result.standardOutput, expected)
		XCTAssertEqual(recorder.value?.data, Data(expected.utf8))
		XCTAssertEqual(recorder.value?.path, "result.jsonl")
	}

	func testPartialToolFailureDoesNotExport() async {
		let catalog = MockCatalog(
			names: ["first", "second"],
			results: [success("{\"value\":1}"), failure("{\"ok\":false}")]
		)
		let recorder = ExportRecorder()
		let result = await application(catalog: catalog, exportJSONL: recorder.record).run(arguments: [
			"--export-jsonl", "result.jsonl",
			"-e", "first {}",
			"-e", "second {}"
		])

		XCTAssertEqual(result.exitCode, .toolFailure)
		XCTAssertEqual(result.standardOutput, "{\"value\":1}\n")
		XCTAssertNil(recorder.value)
	}

	func testExportFailureUsesExit73AndPreservesStdout() async {
		let catalog = MockCatalog(names: ["first"], results: [success("{\"value\":1}")])
		let result = await application(catalog: catalog, exportJSONL: { _, _ in throw StubError() }).run(arguments: [
			"--export-jsonl", "result.jsonl", "first", "{}"
		])

		XCTAssertEqual(result.exitCode, .cannotCreate)
		XCTAssertEqual(result.standardOutput, "{\"value\":1}\n")
		XCTAssertTrue(result.standardError.contains("unable to create JSONL export"))
	}

	func testToolErrorUsesStderrExitOneAndStops() async {
		let catalog = MockCatalog(
			names: ["first", "second", "third"],
			results: [success("{\"value\":1}"), failure("{\n\"message\":\"bad\",\"ok\":false\n}"), success("{\"value\":3}")]
		)
		let result = await application(catalog: catalog).run(
			arguments: ["-e", "first {}", "-e", "second {}", "-e", "third {}"]
		)

		XCTAssertEqual(result.exitCode, .toolFailure)
		XCTAssertEqual(result.standardOutput, "{\"value\":1}\n")
		XCTAssertEqual(result.standardError, "{\"message\":\"bad\",\"ok\":false}\n")
		let calls = await catalog.recordedCalls()
		XCTAssertEqual(calls.map(\.name), ["first", "second"])
	}

	func testUnadvertisedToolIsUsageErrorBeforeAnyCall() async {
		let catalog = MockCatalog(names: ["read_file"], results: [])
		let result = await application(catalog: catalog).run(arguments: ["read"])

		XCTAssertEqual(result.exitCode, .usage)
		XCTAssertTrue(result.standardError.contains("Tool is not advertised by portable: read."))
		let calls = await catalog.recordedCalls()
		XCTAssertTrue(calls.isEmpty)
	}

	func testConfigurationFailureUsesExit78() async {
		let dependencies = PortableCLIApplication.Dependencies(
			resolveOracleConfiguration: {
				throw HeadlessRuntimeError("invalid environment", exitCode: .configuration)
			},
			makeCatalog: { _, _ in throw StubError() }
		)
		let result = await PortableCLIApplication(dependencies: dependencies).run(arguments: ["read_file", "{}"])

		XCTAssertEqual(result.exitCode, .configuration)
		XCTAssertEqual(result.standardError, "repoprompt-portable-cli: invalid environment\n")
	}

	func testInvalidResultContractUsesExit70() async {
		let invalid = CallTool.Result(content: [
			.text(text: "{}", annotations: nil, _meta: nil),
			.text(text: "{}", annotations: nil, _meta: nil)
		], isError: false)
		let catalog = MockCatalog(names: ["read_file"], results: [invalid])
		let result = await application(catalog: catalog).run(arguments: ["read_file", "{}"])

		XCTAssertEqual(result.exitCode, .runtime)
		XCTAssertEqual(result.standardOutput, "")
		XCTAssertTrue(result.standardError.contains("exactly one text item"))
	}

	func testSyntaxFailureUsesExit64WithUsageOnStderr() async {
		let catalog = MockCatalog(names: [], results: [])
		let result = await application(catalog: catalog).run(arguments: ["read_file", "[]"])

		XCTAssertEqual(result.exitCode, .usage)
		XCTAssertEqual(result.standardOutput, "")
		XCTAssertTrue(result.standardError.contains("Usage:"))
		let calls = await catalog.recordedCalls()
		XCTAssertTrue(calls.isEmpty)
	}

	private func application(
		catalog: MockCatalog,
		exportJSONL: @escaping @Sendable (Data, String) throws -> Void = { _, _ in }
	) -> PortableCLIApplication {
		PortableCLIApplication(dependencies: .init(
			resolveOracleConfiguration: { nil },
			makeCatalog: { _, _ in catalog },
			exportJSONL: exportJSONL
		))
	}

	private func success(_ text: String) -> CallTool.Result {
		CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
	}

	private func failure(_ text: String) -> CallTool.Result {
		CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
	}
}

private actor MockCatalog: PortableCLIToolCatalog {
	struct RecordedCall: Sendable {
		let name: String
		let arguments: [String: Value]
	}

	private let advertisedTools: [Tool]
	private var results: [CallTool.Result]
	private var calls: [RecordedCall] = []

	init(names: [String], results: [CallTool.Result]) {
		self.advertisedTools = names.map {
			Tool(name: $0, description: nil, inputSchema: .object(["type": .string("object")]))
		}
		self.results = results
	}

	func tools() -> [Tool] {
		advertisedTools
	}

	func call(name: String, arguments: [String: Value]?) -> CallTool.Result {
		calls.append(RecordedCall(name: name, arguments: arguments ?? [:]))
		guard !results.isEmpty else {
			return CallTool.Result(content: [.text(text: "{}", annotations: nil, _meta: nil)], isError: false)
		}
		return results.removeFirst()
	}

	func recordedCalls() -> [RecordedCall] {
		calls
	}
}

private struct StubError: Error {}

private final class ExportRecorder: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: (data: Data, path: String)?

	var record: @Sendable (Data, String) throws -> Void {
		{ [self] data, path in
			lock.lock()
			stored = (data, path)
			lock.unlock()
		}
	}

	var value: (data: Data, path: String)? {
		lock.lock()
		defer { lock.unlock() }
		return stored
	}
}
