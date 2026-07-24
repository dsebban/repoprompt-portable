import Foundation
import MCP
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessCatalogOracleTests: XCTestCase {
	func testCatalogAdvertisesExactlyTwoNewToolsAndKeepsWorkspaceContextDenied() async throws {
		let root = try temporaryDirectory()
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		let tools = await catalog.tools()
		XCTAssertEqual(Set(tools.map(\.name)), Set([
			"bind_context", "get_file_tree", "read_file", "manage_selection", "file_search",
			"context_builder", "oracle_send"
		]))
		for name in ["context_builder", "oracle_send"] {
			let tool = try XCTUnwrap(tools.first { $0.name == name })
			guard case .object(let schema) = tool.inputSchema else {
				return XCTFail("Expected object schema")
			}
			XCTAssertEqual(schema["additionalProperties"]?.boolValue, false)
		}
		let builder = try XCTUnwrap(tools.first { $0.name == "context_builder" })
		guard
			case .object(let builderSchema) = builder.inputSchema,
			case .object(let properties)? = builderSchema["properties"],
			case .object(let responseType)? = properties["response_type"],
			case .array(let responseTypes)? = responseType["enum"]
		else {
			return XCTFail("Expected context_builder response_type enum")
		}
		XCTAssertEqual(responseTypes.compactMap(\.stringValue), ["clarify", "plan", "review"])
		let builderData = try JSONEncoder().encode(builder)
		let builderJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: builderData) as? [String: Any])
		let annotations = try XCTUnwrap(builderJSON["annotations"] as? [String: Any])
		XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
		XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
		XCTAssertEqual(annotations["idempotentHint"] as? Bool, false)
		XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)
		let denied = await catalog.call(name: "workspace_context", arguments: [:])
		XCTAssertEqual(denied.isError, true)
		XCTAssertEqual(try json(denied)["code"] as? String, "policy_denied")
	}

	func testContextBuilderClarifyIsLocalStrictAndPreservesSlicesAndCodemapOmissions() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("source.txt")
		try "one\ntwo\nthree".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		_ = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("set"),
			"mode": .string("slices"),
			"slices": .array([.object([
				"path": .string("source.txt"),
				"ranges": .array([.object([
					"start_line": .int(2),
					"end_line": .int(2)
				])])
			])])
		])
		let built = await catalog.call(name: "context_builder", arguments: [
			"instructions": .string("  inspect selection  "),
			"response_type": .string("clarify"),
			"max_context_bytes": .int(1_024)
		])
		XCTAssertEqual(built.isError, false)
		let builtJSON = try json(built)
		XCTAssertEqual(builtJSON["prompt"] as? String, "inspect selection")
		let workspace = try XCTUnwrap(builtJSON["workspace_context"] as? [String: Any])
		let content = try XCTUnwrap(workspace["content"] as? String)
		XCTAssertTrue(content.contains("two"))
		XCTAssertFalse(content.contains("one\ntwo\nthree"))
		XCTAssertLessThanOrEqual(content.utf8.count, 1_024)

		_ = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("set"),
			"mode": .string("codemap_only"),
			"paths": .array([.string("source.txt")])
		])
		let codemap = await catalog.call(name: "context_builder", arguments: ["instructions": .string("inspect")])
		let codemapWorkspace = try XCTUnwrap(try json(codemap)["workspace_context"] as? [String: Any])
		XCTAssertFalse((codemapWorkspace["content"] as? String)?.contains("one\ntwo\nthree") ?? true)
		let omissions = try XCTUnwrap(codemapWorkspace["omissions"] as? [[String: Any]])
		XCTAssertTrue(omissions.contains { $0["reason"] as? String == "auto_codemap_unsupported" })

		for arguments: [String: Value] in [
			["instructions": .string("inspect"), "response_type": .string("question")],
			["instructions": .string("inspect"), "unknown": .bool(true)],
			["instructions": .string("inspect"), "max_context_bytes": .int(100)]
		] {
			let invalid = await catalog.call(name: "context_builder", arguments: arguments)
			XCTAssertEqual(invalid.isError, true)
		}
	}

	func testContextBuilderValidationPrecedenceAndRequiresProviderOnlyForGeneratedModes() async throws {
		let root = try temporaryDirectory()
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		let cases: [([String: Value], String)] = [
			(["unknown": .bool(true)], "unknown argument"),
			(["response_type": .string("question")], "Required string argument"),
			(["instructions": .string(String(repeating: "x", count: 65_537)), "response_type": .string("question")], "exceed 65536"),
			(["instructions": .string("inspect"), "response_type": .string("question"), "max_context_bytes": .int(100)], "response_type"),
			(["instructions": .string("inspect"), "response_type": .string("plan"), "max_context_bytes": .int(100)], "max_context_bytes")
		]
		for (arguments, expectedMessage) in cases {
			let result = await catalog.call(name: "context_builder", arguments: arguments)
			XCTAssertEqual(result.isError, true)
			XCTAssertTrue((try json(result)["message"] as? String)?.contains(expectedMessage) == true)
		}

		let generated = await catalog.call(name: "context_builder", arguments: [
			"instructions": .string("inspect"),
			"response_type": .string("plan")
		])
		XCTAssertEqual(try json(generated)["code"] as? String, "oracle_not_configured")

		let clarify = await catalog.call(name: "context_builder", arguments: ["instructions": .string("inspect")])
		XCTAssertEqual(clarify.isError, false)
		let clarifyJSON = try json(clarify)
		XCTAssertEqual(clarifyJSON["response_type"] as? String, "clarify")
		for absent in ["oracle_pair_id", "oracle_results", "chat_id", "oracle_export_path"] {
			XCTAssertNil(clarifyJSON[absent])
		}
	}

	func testContextBuilderPlanAndReviewDispatchFixedLanesAndPreservePairEnvelope() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("selected.txt")
		try "BUILDER_SELECTED_SENTINEL".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		await bootstrap.session.selectionStore.persist(
			.init(selectedPaths: [file.path]),
			for: nil,
			source: .headless
		)

		for responseType in ["plan", "review"] {
			let provider = CatalogOracleProvider(
				primary: .response("primary \(responseType)"),
				secondary: .response("secondary \(responseType)"),
				autoRelease: true
			)
			let catalog = HeadlessToolCatalog(
				roots: bootstrap.roots,
				session: bootstrap.session,
				router: bootstrap.router,
				allowWrites: false,
				oracleWorkflow: try workflow(provider: provider)
			)
			let result = await catalog.call(name: "context_builder", arguments: [
				"instructions": .string("  generate \(responseType)  "),
				"response_type": .string(responseType)
			])
			XCTAssertEqual(result.isError, false)
			let object = try json(result)
			XCTAssertEqual(object["ok"] as? Bool, true)
			XCTAssertEqual(object["status"] as? String, "response_generated")
			XCTAssertEqual(object["response_type"] as? String, responseType)
			XCTAssertEqual(object["prompt"] as? String, "generate \(responseType)")
			XCTAssertEqual(object["response"] as? String, "primary \(responseType)")
			XCTAssertEqual(object["pair_status"] as? String, "completed")
			XCTAssertEqual(object["oracle_decision_policy"] as? String, "caller_decides")
			XCTAssertEqual(object["model_raw_id"] as? String, "primary-model")
			for absent in ["chat_id", "new_chat", "oracle_export_path", "winner", "synthesis"] {
				XCTAssertNil(object[absent])
			}
			let oracleResults = try XCTUnwrap(object["oracle_results"] as? [String: Any])
			XCTAssertEqual((oracleResults["primary"] as? [String: Any])?["status"] as? String, "completed")
			XCTAssertEqual((oracleResults["secondary"] as? [String: Any])?["status"] as? String, "completed")

			let requests = await provider.requests()
			XCTAssertEqual(requests.count, 2)
			XCTAssertEqual(Set(requests.map(\.lane)), Set([.primary, .secondary]))
			XCTAssertEqual(Set(requests.map(\.model)), Set(["primary-model", "secondary-model"]))
			XCTAssertEqual(Set(requests.map(\.pairID)).count, 1)
			XCTAssertEqual(requests[0].userPrompt, requests[1].userPrompt)
			for request in requests {
				XCTAssertTrue(request.userPrompt.contains("Request mode: \(responseType)"))
				XCTAssertTrue(request.userPrompt.contains("generate \(responseType)"))
				XCTAssertTrue(request.userPrompt.contains("BUILDER_SELECTED_SENTINEL"))
			}
		}
	}

	func testSelectionRejectsEmptySlicesAndReadFileRejectsEscapingSymlink() async throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		let secret = outside.appendingPathComponent("secret.txt")
		let link = root.appendingPathComponent("link.txt")
		try "SECRET_MUST_NOT_APPEAR".write(to: secret, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		let emptySlice = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("set"),
			"mode": .string("slices"),
			"slices": .array([.object([
				"path": .string("link.txt"),
				"ranges": .array([])
			])])
		])
		XCTAssertEqual(emptySlice.isError, true)
		XCTAssertEqual(try json(emptySlice)["code"] as? String, "invalid_params")

		let read = await catalog.call(name: "read_file", arguments: ["path": .string("link.txt")])
		XCTAssertEqual(read.isError, true)
		let readJSON = try json(read)
		XCTAssertEqual(readJSON["code"] as? String, "path_outside_workspace")
		XCTAssertFalse(String(describing: readJSON).contains("SECRET_MUST_NOT_APPEAR"))
	}

	func testOracleValidationPrecedesProviderAndPrimaryFailureIsNeverPromoted() async throws {
		let root = try temporaryDirectory()
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let unconfigured = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)
		let unknown = await unconfigured.call(name: "oracle_send", arguments: [
			"message": .string("hello"),
			"model": .string("forbidden")
		])
		XCTAssertEqual(try json(unknown)["code"] as? String, "invalid_params")
		let missing = await unconfigured.call(name: "oracle_send", arguments: ["message": .string("hello")])
		XCTAssertEqual(try json(missing)["code"] as? String, "oracle_not_configured")

		let provider = CatalogOracleProvider(
			primary: .failure(.init(.timeout, message: "primary timeout")),
			secondary: .response("secondary stays nested"),
			autoRelease: true
		)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false,
			oracleWorkflow: try workflow(provider: provider)
		)
		let result = await catalog.call(name: "oracle_send", arguments: [
			"message": .string("answer"),
			"mode": .string("question")
		])
		XCTAssertEqual(result.isError, false)
		let object = try json(result)
		XCTAssertEqual(object["ok"] as? Bool, false)
		XCTAssertEqual(object["pair_status"] as? String, "partial_failure")
		XCTAssertNil(object["response"])
		XCTAssertNil(object["winner"])
		XCTAssertNil(object["synthesis"])
		let error = try XCTUnwrap(object["error"] as? [String: Any])
		XCTAssertEqual(error["code"] as? String, "timeout")
		let results = try XCTUnwrap(object["oracle_results"] as? [String: Any])
		let secondary = try XCTUnwrap(results["secondary"] as? [String: Any])
		XCTAssertEqual(secondary["response"] as? String, "secondary stays nested")

		let builderResult = await catalog.call(name: "context_builder", arguments: [
			"instructions": .string("review"),
			"response_type": .string("review")
		])
		XCTAssertEqual(builderResult.isError, false)
		let builder = try json(builderResult)
		XCTAssertEqual(builder["ok"] as? Bool, false)
		XCTAssertEqual(builder["status"] as? String, "response_failed")
		XCTAssertEqual(builder["response_type"] as? String, "review")
		XCTAssertEqual(builder["pair_status"] as? String, "partial_failure")
		XCTAssertNil(builder["response"])
		XCTAssertEqual((builder["error"] as? [String: Any])?["code"] as? String, "timeout")
		let builderResults = try XCTUnwrap(builder["oracle_results"] as? [String: Any])
		XCTAssertEqual((builderResults["secondary"] as? [String: Any])?["response"] as? String, "secondary stays nested")
	}

	func testContextBuilderUsesImmutableSelectionSnapshotForBothLanes() async throws {
		let root = try temporaryDirectory()
		let original = root.appendingPathComponent("original.txt")
		let later = root.appendingPathComponent("later.txt")
		try "ORIGINAL_SELECTION_SENTINEL".write(to: original, atomically: true, encoding: .utf8)
		try "LATER_SELECTION_SENTINEL".write(to: later, atomically: true, encoding: .utf8)
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let provider = CatalogOracleProvider(
			primary: .response("primary response"),
			secondary: .response("secondary response"),
			autoRelease: false
		)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false,
			oracleWorkflow: try workflow(provider: provider)
		)
		_ = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("set"),
			"paths": .array([.string("original.txt")])
		])

		let oracleTask = Task {
			await catalog.call(name: "context_builder", arguments: [
				"instructions": .string("review"),
				"response_type": .string("plan")
			])
		}
		try await provider.waitForRequests(2)
		_ = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("set"),
			"paths": .array([.string("later.txt")])
		])
		await provider.release()
		let result = await oracleTask.value
		let requests = await provider.requests()

		XCTAssertEqual(requests.count, 2)
		XCTAssertEqual(requests[0].userPrompt, requests[1].userPrompt)
		for request in requests {
			XCTAssertTrue(request.userPrompt.contains("ORIGINAL_SELECTION_SENTINEL"))
			XCTAssertFalse(request.userPrompt.contains("LATER_SELECTION_SENTINEL"))
		}
		let object = try json(result)
		XCTAssertEqual(object["ok"] as? Bool, true)
		XCTAssertEqual(object["status"] as? String, "response_generated")
		XCTAssertEqual(object["response_type"] as? String, "plan")
		XCTAssertEqual(object["pair_status"] as? String, "completed")
		XCTAssertEqual(object["response"] as? String, "primary response")
		XCTAssertEqual(object["model_raw_id"] as? String, "primary-model")
		let workspace = try XCTUnwrap(object["workspace_context"] as? [String: Any])
		XCTAssertTrue((workspace["content"] as? String)?.contains("ORIGINAL_SELECTION_SENTINEL") == true)
		XCTAssertFalse((workspace["content"] as? String)?.contains("LATER_SELECTION_SENTINEL") == true)
	}

	private func workflow(provider: any HeadlessOracleProvider) throws -> HeadlessOracleWorkflow {
		let configuration = try HeadlessOracleConfiguration(
			endpoint: XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions")),
			primaryModel: "primary-model",
			secondaryModel: "secondary-model"
		)
		return HeadlessOracleWorkflow(configuration: configuration, provider: provider)
	}

	private func json(_ result: CallTool.Result) throws -> [String: Any] {
		let text = result.content.compactMap { content in
			if case let .text(text, _, _) = content { return text }
			return nil
		}.joined(separator: "\n")
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
	}

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.standardizedFileURL
	}
}

private actor CatalogOracleProvider: HeadlessOracleProvider {
	enum Outcome: Sendable {
		case response(String)
		case failure(HeadlessOracleProviderFailure)
	}

	private let primaryOutcome: Outcome
	private let secondaryOutcome: Outcome
	private let autoRelease: Bool
	private var recorded: [HeadlessOracleProviderRequest] = []
	private var released = false

	init(primary: Outcome, secondary: Outcome, autoRelease: Bool) {
		primaryOutcome = primary
		secondaryOutcome = secondary
		self.autoRelease = autoRelease
	}

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> String {
		recorded.append(request)
		if autoRelease, recorded.count == 2 { released = true }
		while recorded.count < 2 || !released {
			try await Task.sleep(nanoseconds: 1_000_000)
		}
		let outcome = request.lane == .primary ? primaryOutcome : secondaryOutcome
		switch outcome {
		case .response(let response): return response
		case .failure(let failure): throw failure
		}
	}

	func waitForRequests(_ expected: Int) async throws {
		while recorded.count < expected { try await Task.sleep(nanoseconds: 1_000_000) }
	}

	func release() { released = true }
	func requests() -> [HeadlessOracleProviderRequest] { recorded }
}
