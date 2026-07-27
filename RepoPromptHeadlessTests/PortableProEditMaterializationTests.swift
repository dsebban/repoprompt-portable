import Foundation
import XCTest
@testable import RepoPromptHeadless

final class PortableProEditMaterializationTests: XCTestCase {
	func testMaterializationProducesOrderedPreviewWithoutWriting() async throws {
		let root = try temporaryDirectory()
		let firstURL = root.appendingPathComponent("First.swift")
		let secondURL = root.appendingPathComponent("Second.swift")
		let createdURL = root.appendingPathComponent("Created.swift")
		let firstOriginal = "struct First { let value = 1 }\n"
		let secondOriginal = "struct Second { let value = 2 }\n"
		try firstOriginal.write(to: firstURL, atomically: true, encoding: .utf8)
		try secondOriginal.write(to: secondURL, atomically: true, encoding: .utf8)

		let provider = MaterializationProvider([
			.response("struct First { let value = 10 }\n", finishReason: "stop"),
			.response("struct Second { let value = 20 }\n", finishReason: "stop")
		])
		let service = try await service(root: root, provider: provider)
		_ = try await service.addFiles([firstURL.path, secondURL.path])
		let artifact = PortableProEditArtifact(
			chatName: "Materialize",
			plan: "Update the two selected files and add one supporting file.",
			files: [
				file(
					path: "First.swift",
					action: .delegateEdit,
					description: "Update First only",
					content: "Set First.value to 10."
				),
				file(
					path: "Created.swift",
					action: .create,
					description: "Create support",
					content: "struct Created {}\n"
				),
				file(
					path: "Second.swift",
					action: .delegateEdit,
					description: "Update Second only",
					content: "Set Second.value to 20."
				)
			]
		)
		let generation = try await generation(service: service, artifact: artifact)
		let preflight = try await service.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: .primary
		)

		let preview = try await service.materializeProEditPreview(preflight)

		XCTAssertEqual(preview.status, .completed)
		XCTAssertEqual(
			preview.laneAttribution,
			PortableProEditLaneAttribution(
				pairID: generation.result.pairID,
				lane: .primary,
				modelRawID: "primary-model"
			)
		)
		XCTAssertEqual(preview.files.map(\.target.displayPath), [
			"First.swift",
			"Created.swift",
			"Second.swift"
		])
		XCTAssertEqual(preview.files[0].status, .proposed)
		XCTAssertEqual(preview.files[1].status, .proposed)
		XCTAssertEqual(preview.files[2].status, .proposed)
		XCTAssertEqual(preview.files[1].proposedContent, "struct Created {}\n")
		XCTAssertNil(preview.files[1].modelRawID)
		XCTAssertTrue(try XCTUnwrap(preview.files[0].replacementDiff).contains("--- a/First.swift"))
		XCTAssertTrue(try XCTUnwrap(preview.files[1].replacementDiff).contains("--- /dev/null"))

		let requests = await provider.requests()
		XCTAssertEqual(requests.count, 2, "Create content must not trigger a provider request.")
		XCTAssertEqual(requests.map(\.model), ["primary-model", "primary-model"])
		XCTAssertTrue(requests[0].userPrompt.contains(
			"target_identity_base64: \(Data("First.swift".utf8).base64EncodedString())"
		))
		XCTAssertTrue(requests[0].userPrompt.contains(firstOriginal))
		XCTAssertTrue(requests[0].userPrompt.contains("Set First.value to 10."))
		XCTAssertFalse(requests[0].userPrompt.contains(secondOriginal))
		XCTAssertFalse(requests[0].userPrompt.contains("Set Second.value to 20."))
		XCTAssertTrue(requests[1].userPrompt.contains(
			"target_identity_base64: \(Data("Second.swift".utf8).base64EncodedString())"
		))
		XCTAssertTrue(requests[1].userPrompt.contains(secondOriginal))
		XCTAssertTrue(requests[1].userPrompt.contains("Set Second.value to 20."))
		XCTAssertFalse(requests[1].userPrompt.contains(firstOriginal))
		XCTAssertFalse(requests[1].userPrompt.contains("Set First.value to 10."))
		XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), firstOriginal)
		XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), secondOriginal)
		XCTAssertFalse(FileManager.default.fileExists(atPath: createdURL.path))
	}

	func testMaterializationReportsStablePartialFailuresAndContinues() async throws {
		let root = try temporaryDirectory()
		let paths = ["One.swift", "Two.swift", "Three.swift"]
		for path in paths {
			try "original \(path)\n".write(
				to: root.appendingPathComponent(path),
				atomically: true,
				encoding: .utf8
			)
		}
		let provider = MaterializationProvider([
			.response("updated one\n", finishReason: "stop"),
			.failure(HeadlessOracleProviderFailure(
				.httpError,
				message: "Provider rejected Two.swift."
			)),
			.response("updated three\n", finishReason: "stop")
		])
		let service = try await service(root: root, provider: provider)
		_ = try await service.addFiles(paths)
		let artifact = PortableProEditArtifact(
			chatName: "Partial",
			plan: "Update every selected file.",
			files: paths.map {
				file(path: $0, action: .delegateEdit, description: "Update \($0)", content: "Make the requested update.")
			}
		)
		let generation = try await generation(service: service, artifact: artifact)
		let preflight = try await service.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: .primary
		)

		let preview = try await service.materializeProEditPreview(preflight)

		XCTAssertEqual(preview.status, .partialFailure)
		XCTAssertEqual(preview.files.map(\.target.displayPath), paths)
		XCTAssertEqual(preview.files[0].status, .proposed)
		XCTAssertEqual(
			preview.files[1].status,
			.failed(code: "http_error", message: "Provider rejected Two.swift.")
		)
		XCTAssertEqual(preview.files[2].status, .proposed)
		XCTAssertNil(preview.files[1].proposedContent)
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 3)
		for path in paths {
			XCTAssertEqual(
				try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8),
				"original \(path)\n"
			)
		}
	}

	func testMaterializationRejectsEmptyFencedNULOversizedAndTruncatedResponses() async throws {
		let root = try temporaryDirectory()
		let paths = ["Empty.swift", "Fenced.swift", "NUL.swift", "Large.swift", "Truncated.swift"]
		for path in paths {
			try "original\n".write(
				to: root.appendingPathComponent(path),
				atomically: true,
				encoding: .utf8
			)
		}
		let provider = MaterializationProvider([
			.response(" \n", finishReason: "stop"),
			.response("```swift\nchanged\n```", finishReason: "stop"),
			.response("changed\0content", finishReason: "stop"),
			.response(
				String(repeating: "x", count: HeadlessProEditExecutionWorkflow.maximumProposedContentBytes + 1),
				finishReason: "stop"
			),
			.response("prefix only", finishReason: "length")
		])
		let service = try await service(root: root, provider: provider)
		_ = try await service.addFiles(paths)
		let artifact = PortableProEditArtifact(
			chatName: "Invalid",
			plan: "Reject malformed provider outputs.",
			files: paths.map {
				file(path: $0, action: .delegateEdit, description: "Update", content: "Update safely.")
			}
		)
		let generation = try await generation(service: service, artifact: artifact)
		let preflight = try await service.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: .primary
		)

		let preview = try await service.materializeProEditPreview(preflight)

		XCTAssertEqual(preview.status, .failed)
		XCTAssertEqual(preview.files.count, paths.count)
		for proposal in preview.files.dropLast() {
			guard case .failed(let code, _) = proposal.status else {
				return XCTFail("Expected invalid materialization failure.")
			}
			XCTAssertEqual(code, "pro_edit_materialization_invalid")
		}
		XCTAssertEqual(
			preview.files.last?.status,
			.failed(
				code: "pro_edit_materialization_truncated",
				message: "Pro Edit provider response was truncated."
			)
		)
	}

	func testMaterializationRequiresSuccessfulStopReasonAndRejectsWhitespacePrefixedFences() async throws {
		let root = try temporaryDirectory()
		let paths = [
			"MissingReason.swift",
			"MaxOutput.swift",
			"Filtered.swift",
			"Unknown.swift",
			"NormalizedStop.swift",
			"LeadingFence.swift"
		]
		for path in paths {
			try "original\n".write(
				to: root.appendingPathComponent(path),
				atomically: true,
				encoding: .utf8
			)
		}
		let provider = MaterializationProvider([
			.response("updated\n", finishReason: nil),
			.response("updated\n", finishReason: "max_output_tokens"),
			.response("updated\n", finishReason: "content_filter"),
			.response("updated\n", finishReason: "future_reason"),
			.response("updated\n", finishReason: " STOP "),
			.response(" \n```swift\nupdated\n```", finishReason: "stop")
		])
		let service = try await service(root: root, provider: provider)
		_ = try await service.addFiles(paths)
		let artifact = PortableProEditArtifact(
			chatName: "Finish reasons",
			plan: "Accept only a complete raw-file response.",
			files: paths.map {
				file(path: $0, action: .delegateEdit, description: "Update", content: "Update safely.")
			}
		)
		let generation = try await generation(service: service, artifact: artifact)
		let preflight = try await service.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: .primary
		)

		let preview = try await service.materializeProEditPreview(preflight)

		XCTAssertEqual(preview.status, .partialFailure)
		XCTAssertEqual(
			preview.files.map(\.status),
			[
				.failed(
					code: "pro_edit_materialization_incomplete",
					message: "Pro Edit provider did not report a successful stop reason."
				),
				.failed(
					code: "pro_edit_materialization_truncated",
					message: "Pro Edit provider response was truncated."
				),
				.failed(
					code: "pro_edit_materialization_incomplete",
					message: "Pro Edit provider did not report a successful stop reason."
				),
				.failed(
					code: "pro_edit_materialization_incomplete",
					message: "Pro Edit provider did not report a successful stop reason."
				),
				.proposed,
				.failed(
					code: "pro_edit_materialization_invalid",
					message: "Pro Edit provider returned fenced content instead of raw file content."
				)
			]
		)
	}

	func testMaterializationRevalidatesTargetsBeforeProviderExecution() async throws {
		let root = try temporaryDirectory()
		let fileURL = root.appendingPathComponent("Selected.swift")
		try "before\n".write(to: fileURL, atomically: true, encoding: .utf8)
		let provider = MaterializationProvider([
			.response("proposed\n", finishReason: "stop")
		])
		let service = try await service(root: root, provider: provider)
		_ = try await service.addFiles([fileURL.path])
		let artifact = PortableProEditArtifact(
			chatName: "Stale",
			plan: "Update selected file.",
			files: [
				file(
					path: "Selected.swift",
					action: .delegateEdit,
					description: "Update",
					content: "Make the update."
				)
			]
		)
		let generation = try await generation(service: service, artifact: artifact)
		let preflight = try await service.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: .primary
		)
		try "changed after preflight\n".write(to: fileURL, atomically: true, encoding: .utf8)

		do {
			_ = try await service.materializeProEditPreview(preflight)
			XCTFail("Expected stale target rejection.")
		} catch let error as PortableProEditPreflightError {
			XCTAssertEqual(error.code, .staleContext)
		}
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 0)
		XCTAssertEqual(
			try String(contentsOf: fileURL, encoding: .utf8),
			"changed after preflight\n"
		)
	}

	func testAmbiguousCreateFailsWithoutProviderOrFilesystemMutation() async throws {
		let root = try temporaryDirectory()
		let createdURL = root.appendingPathComponent("Created.swift")
		let provider = MaterializationProvider([])
		let service = try await service(root: root, provider: provider)
		let artifact = PortableProEditArtifact(
			chatName: "Ambiguous create",
			plan: "Reject multiple complete contents.",
			files: [
				PortableProEditFile(
					path: "Created.swift",
					action: .create,
					changes: [
						PortableProEditChange(description: "First", content: "first\n", complexity: 1),
						PortableProEditChange(description: "Second", content: "second\n", complexity: 1)
					]
				)
			]
		)
		let generation = try await generation(service: service, artifact: artifact)
		let preflight = try await service.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: .primary
		)

		let preview = try await service.materializeProEditPreview(preflight)

		XCTAssertEqual(preview.status, .failed)
		XCTAssertEqual(
			preview.files[0].status,
			.failed(
				code: "ambiguous_create_content",
				message: "Pro Edit create targets require exactly one complete-content change."
			)
		)
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 0)
		XCTAssertFalse(FileManager.default.fileExists(atPath: createdURL.path))
	}

	func testSecondaryArtifactMaterializesThroughSecondaryModelAndPreservesAttribution() async throws {
		let root = try temporaryDirectory()
		let fileURL = root.appendingPathComponent("Selected.swift")
		try "before\n".write(to: fileURL, atomically: true, encoding: .utf8)
		let provider = MaterializationProvider([
			.response("after\n", finishReason: "stop")
		])
		let service = try await service(root: root, provider: provider)
		_ = try await service.addFiles([fileURL.path])
		let primaryArtifact = PortableProEditArtifact(
			chatName: "Primary",
			plan: "Primary plan.",
			files: [file(
				path: "Selected.swift",
				action: .delegateEdit,
				description: "Primary edit",
				content: "Make the primary change."
			)]
		)
		let secondaryArtifact = PortableProEditArtifact(
			chatName: "Secondary",
			plan: "Secondary plan.",
			files: [file(
				path: "Selected.swift",
				action: .delegateEdit,
				description: "Secondary edit",
				content: "Make the secondary change."
			)]
		)
		let generation = try await generation(
			service: service,
			artifact: primaryArtifact,
			secondaryArtifact: secondaryArtifact
		)
		let preflight = try await service.resolveProEditArtifact(
			secondaryArtifact,
			expectedGeneration: generation,
			lane: .secondary
		)

		let preview = try await service.materializeProEditPreview(preflight)

		XCTAssertEqual(preflight.laneAttribution.lane, .secondary)
		XCTAssertEqual(preflight.laneAttribution.modelRawID, "secondary-model")
		XCTAssertEqual(preview.laneAttribution, preflight.laneAttribution)
		XCTAssertEqual(preview.files.first?.modelRawID, "secondary-model")
		let requests = await provider.requests()
		XCTAssertEqual(requests.map(\.lane), [.secondary])
		XCTAssertEqual(requests.map(\.model), ["secondary-model"])
		XCTAssertTrue(requests[0].userPrompt.contains("Secondary edit"))
		XCTAssertFalse(requests[0].userPrompt.contains("Primary edit"))
	}

	func testIdenticalGeneratedArtifactsHonorExplicitSecondaryLane() async throws {
		let root = try temporaryDirectory()
		let fileURL = root.appendingPathComponent("Selected.swift")
		try "before\n".write(to: fileURL, atomically: true, encoding: .utf8)
		let provider = MaterializationProvider([])
		let service = try await service(root: root, provider: provider)
		_ = try await service.addFiles([fileURL.path])
		let artifact = PortableProEditArtifact(
			chatName: "Same",
			plan: "Both lanes returned the same artifact.",
			files: [file(
				path: "Selected.swift",
				action: .delegateEdit,
				description: "Edit",
				content: "Make the update."
			)]
		)
		let generation = try await generation(service: service, artifact: artifact)

		let preflight = try await service.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: .secondary
		)
		XCTAssertEqual(preflight.laneAttribution.lane, .secondary)
		XCTAssertEqual(preflight.laneAttribution.modelRawID, "secondary-model")
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 0)
	}

	func testSliceSelectedDelegateIsRejectedBeforeFullFileReadOrProviderExecution() async throws {
		let root = try temporaryDirectory()
		let fileURL = root.appendingPathComponent("Selected.swift")
		try "selected-line\nprivate-secret\n".write(to: fileURL, atomically: true, encoding: .utf8)
		let provider = MaterializationProvider([])
		let service = try await service(root: root, provider: provider)
		_ = try await service.setSlices([
			PortableSliceSelection(
				path: fileURL.path,
				ranges: [PortableLineRange(startLine: 1)]
			)
		])
		let artifact = PortableProEditArtifact(
			chatName: "Slice",
			plan: "Edit only the selected slice.",
			files: [file(
				path: "Selected.swift",
				action: .delegateEdit,
				description: "Edit slice",
				content: "Update the selected line."
			)]
		)
		let generation = try await generation(service: service, artifact: artifact)

		do {
			_ = try await service.resolveProEditArtifact(
				artifact,
				expectedGeneration: generation,
				lane: .primary
			)
			XCTFail("Expected slice-selected delegate rejection.")
		} catch let error as PortableProEditPreflightError {
			XCTAssertEqual(error.code, .sliceDelegateUnsupported)
		}
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 0)
	}

	func testSameBytesSymlinkRetargetAfterContextRefreshIsRejected() async throws {
		let root = try temporaryDirectory()
		let firstTarget = root.appendingPathComponent("First.swift")
		let secondTarget = root.appendingPathComponent("Second.swift")
		let aliasURL = root.appendingPathComponent("Alias.swift")
		try "same bytes\n".write(to: firstTarget, atomically: true, encoding: .utf8)
		try "same bytes\n".write(to: secondTarget, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: firstTarget)
		let provider = MaterializationProvider([])
		let service = try await service(
			root: root,
			provider: provider,
			proEditCandidateResolutionHook: {
				try FileManager.default.removeItem(at: aliasURL)
				try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: secondTarget)
			}
		)
		_ = try await service.addFiles([aliasURL.path])
		let artifact = PortableProEditArtifact(
			chatName: "Retarget",
			plan: "Reject a same-bytes symlink retarget.",
			files: [file(
				path: "Alias.swift",
				action: .delegateEdit,
				description: "Edit alias",
				content: "Update the selected file."
			)]
		)
		let generation = try await generation(service: service, artifact: artifact)

		do {
			_ = try await service.resolveProEditArtifact(
				artifact,
				expectedGeneration: generation,
				lane: .primary
			)
			XCTFail("Expected same-bytes symlink retarget rejection.")
		} catch let error as PortableProEditPreflightError {
			XCTAssertEqual(error.code, .staleContext)
		}
		XCTAssertEqual(aliasURL.resolvingSymlinksInPath().standardizedFileURL, secondTarget.standardizedFileURL)
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 0)
	}

	func testSameBytesAtomicReplacementAfterContextRefreshIsRejected() async throws {
		let root = try temporaryDirectory()
		let target = root.appendingPathComponent("Selected.swift")
		try "same bytes\n".write(to: target, atomically: true, encoding: .utf8)
		let provider = MaterializationProvider([])
		let service = try await service(
			root: root,
			provider: provider,
			proEditTargetSnapshotHook: { _ in
				try Data("same bytes\n".utf8).write(to: target, options: .atomic)
			}
		)
		_ = try await service.addFiles([target.path])
		let artifact = PortableProEditArtifact(
			chatName: "Replacement",
			plan: "Reject an atomic replacement after context refresh.",
			files: [file(
				path: "Selected.swift",
				action: .delegateEdit,
				description: "Edit selected file",
				content: "Update the selected file."
			)]
		)
		let generation = try await generation(service: service, artifact: artifact)

		do {
			_ = try await service.resolveProEditArtifact(
				artifact,
				expectedGeneration: generation,
				lane: .primary
			)
			XCTFail("Expected same-bytes atomic replacement rejection.")
		} catch let error as PortableProEditPreflightError {
			XCTAssertEqual(error.code, .staleContext)
		}
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 0)
	}

	private func service(
		root: URL,
		provider: any HeadlessOracleProvider,
		selectionIdentityResolutionHook: (@Sendable (String) throws -> Void)? = nil,
		proEditCandidateResolutionHook: (@Sendable () throws -> Void)? = nil,
		proEditTargetSnapshotHook: (@Sendable (String) throws -> Void)? = nil
	) async throws -> PortableWorkspaceService {
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let configuration = try HeadlessOracleConfiguration(
			endpoint: XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions")),
			primaryModel: "primary-model",
			secondaryModel: "secondary-model"
		)
		return PortableWorkspaceService(
			roots: bootstrap.roots,
			session: bootstrap.session,
			oracleWorkflow: HeadlessOracleWorkflow(configuration: configuration, provider: provider),
			selectionIdentityResolutionHook: selectionIdentityResolutionHook,
			proEditCandidateResolutionHook: proEditCandidateResolutionHook,
			proEditTargetSnapshotHook: proEditTargetSnapshotHook
		)
	}

	private func generation(
		service: PortableWorkspaceService,
		artifact: PortableProEditArtifact,
		secondaryArtifact: PortableProEditArtifact? = nil
	) async throws -> PortableProEditGeneration {
		let context = try await service.previewContext()
		let selection = await service.selection()
		let pairID = UUID()
		return PortableProEditGeneration(
			selection: selection,
			result: PortablePlanResult(
				pairID: pairID,
				status: .completed,
				primary: PortablePlanLane(
					name: .primary,
					modelRawID: "primary-model",
					status: .completed,
					response: artifactSource(artifact),
					errorCode: nil,
					errorMessage: nil
				),
				secondary: PortablePlanLane(
					name: .secondary,
					modelRawID: "secondary-model",
					status: .completed,
					response: artifactSource(secondaryArtifact ?? artifact),
					errorCode: nil,
					errorMessage: nil
				),
				context: context
			)
		)
	}

	private func artifactSource(_ artifact: PortableProEditArtifact) -> String {
		var source = """
		<chatName="\(artifact.chatName)"/>
		<Plan>\(artifact.plan)</Plan>

		"""
		for file in artifact.files {
			source += "<file path=\"\(file.path)\" action=\"\(file.action.rawValue)\">\n"
			for change in file.changes {
				source += """
				<change>
				<description>\(change.description)</description>
				<content>\(change.content)</content>
				<complexity>\(change.complexity)</complexity>
				</change>

				"""
			}
			source += "</file>\n"
		}
		return source
	}

	private func file(
		path: String,
		action: PortableProEditAction,
		description: String,
		content: String
	) -> PortableProEditFile {
		PortableProEditFile(
			path: path,
			action: action,
			changes: [
				PortableProEditChange(
					description: description,
					content: content,
					complexity: 2
				)
			]
		)
	}

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.standardizedFileURL
	}
}

private actor MaterializationProvider: HeadlessOracleProvider {
	enum Outcome: @unchecked Sendable {
		case response(String, finishReason: String?)
		case failure(HeadlessOracleProviderFailure)
	}

	private var outcomes: [Outcome]
	private var recorded: [HeadlessOracleProviderRequest] = []

	init(_ outcomes: [Outcome]) {
		self.outcomes = outcomes
	}

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> HeadlessOracleProviderCompletion {
		recorded.append(request)
		guard !outcomes.isEmpty else {
			throw HeadlessOracleProviderFailure(
				.invalidResponse,
				message: "No fake materialization outcome remains."
			)
		}
		let outcome = outcomes.removeFirst()
		switch outcome {
		case .response(let content, let finishReason):
			return HeadlessOracleProviderCompletion(
				content: content,
				metadata: HeadlessOracleProviderMetadata(
					httpStatus: 200,
					latencyMilliseconds: 1,
					responseID: "response-\(recorded.count)",
					requestID: "request-\(recorded.count)",
					observedModelID: request.model,
					finishReason: finishReason,
					usage: nil,
					conversationID: nil,
					baselineAssistantMessageID: nil,
					recovery: nil
				)
			)
		case .failure(let failure):
			throw failure
		}
	}

	func requests() -> [HeadlessOracleProviderRequest] { recorded }
	func requestCount() -> Int { recorded.count }
}
