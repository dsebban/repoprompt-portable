import Foundation
import XCTest
@testable import RepoPromptHeadless

final class PortableProEditArtifactTests: XCTestCase {
	func testParserPreservesDelegateAndCreateInstructions() throws {
		let artifact = try PortableProEditArtifactParser.parse(Self.validArtifact)

		XCTAssertEqual(artifact.chatName, "Implement safe changes")
		XCTAssertEqual(artifact.plan.trimmingCharacters(in: .whitespacesAndNewlines), "Update one file and create one file.")
		XCTAssertEqual(artifact.files.count, 2)
		XCTAssertEqual(artifact.files[0].path, "Sources/Existing.swift")
		XCTAssertEqual(artifact.files[0].action, .delegateEdit)
		XCTAssertEqual(artifact.files[0].changes.count, 2)
		XCTAssertEqual(artifact.files[0].changes[0].complexity, 3)
		XCTAssertEqual(
			artifact.files[0].changes[1].content,
			"Keep the comparison `lhs < rhs` and preserve CRLF.\r\n"
		)
		XCTAssertEqual(artifact.files[1].path, "Sources/Created.swift")
		XCTAssertEqual(artifact.files[1].action, .create)
		XCTAssertEqual(
			artifact.files[1].changes[0].content,
			"\nstruct Created {\n\tlet value = 1\n}\n"
		)
	}

	func testParserAcceptsPlanOnlyArtifact() throws {
		let artifact = try PortableProEditArtifactParser.parse("""
		<chatName="Need more context"/>
		<Plan>The selected context is insufficient, so no file blocks are emitted.</Plan>
		""")

		XCTAssertTrue(artifact.files.isEmpty)
	}

	func testParserRejectsInvalidActionAndClassicCreateShortcut() {
		assertParseError(.invalidAction, source: """
		<chatName="Bad action"/>
		<Plan>Reject it.</Plan>
		<file path="Sources/File.swift" action="modify">
		<change><description>Change</description><content>Instruction</content><complexity>1</complexity></change>
		</file>
		""")
		assertParseError(.emptyChange, source: """
		<chatName="Incomplete create"/>
		<Plan>Reject it.</Plan>
		<file path="Sources/File.swift" action="create">
		<content>complete file</content>
		</file>
		""")
		assertParseError(.invalidFile, source: """
		<chatName="Ambiguous path"/>
		<Plan>Reject it.</Plan>
		<file path=" Sources/File.swift " action="create">
		<change><description>Create</description><content>complete file</content><complexity>1</complexity></change>
		</file>
		""")
	}

	func testParserRejectsEmptyOrMisorderedChanges() {
		assertParseError(.emptyChange, source: """
		<chatName="Empty"/>
		<Plan>Reject it.</Plan>
		<file path="Sources/File.swift" action="delegate edit"></file>
		""")
		assertParseError(.emptyDescription, source: """
		<chatName="Empty description"/>
		<Plan>Reject it.</Plan>
		<file path="Sources/File.swift" action="delegate edit">
		<change><description> </description><content>Instruction</content><complexity>1</complexity></change>
		</file>
		""")
		assertParseError(.emptyContent, source: """
		<chatName="Empty content"/>
		<Plan>Reject it.</Plan>
		<file path="Sources/File.swift" action="delegate edit">
		<change><description>Change</description><content>
		</content><complexity>1</complexity></change>
		</file>
		""")
		assertParseError(.invalidFile, source: """
		<chatName="Wrong order"/>
		<Plan>Reject it.</Plan>
		<file path="Sources/File.swift" action="delegate edit">
		<change><content>Instruction</content><description>Change</description><complexity>1</complexity></change>
		</file>
		""")
	}

	func testParserRejectsInvalidComplexityEnvelopeAndLimits() {
		for complexity in ["0", "11", "hard"] {
			assertParseError(.invalidComplexity, source: """
			<chatName="Bad complexity"/>
			<Plan>Reject it.</Plan>
			<file path="Sources/File.swift" action="delegate edit">
			<change><description>Change</description><content>Instruction</content><complexity>\(complexity)</complexity></change>
			</file>
			""")
		}
		assertParseError(.invalidEnvelope, source: "<file path=\"File.swift\" action=\"create\"></file>")
		assertParseError(.unexpectedContent, source: """
		<chatName="Trailing"/>
		<Plan>Reject it.</Plan>
		surrounding prose
		""")
		assertParseError(
			.artifactTooLarge,
			source: String(repeating: "x", count: PortableProEditArtifactParser.maximumArtifactBytes + 1)
		)
	}

	func testGenerateProEditUsesFixedModeAndReturnsImmutableSelection() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("Selected.swift")
		try "struct Selected {}".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let provider = ProEditRecordingProvider()
		let service = PortableWorkspaceService(
			roots: bootstrap.roots,
			session: bootstrap.session,
			oracleWorkflow: try workflow(provider: provider)
		)
		_ = try await service.addFiles([file.path])
		let preview = try await service.previewContext()

		let generation = try await service.generateProEdit(
			instructions: "Implement the selected change",
			expectedContextContent: preview.content
		)

		XCTAssertEqual(generation.selection.selectedFiles.map(\.absolutePath), [file.path])
		XCTAssertEqual(generation.result.context.content, preview.content)
		XCTAssertEqual(generation.result.primary.response, Self.validArtifact)
		XCTAssertEqual(generation.result.secondary.response, Self.validArtifact)
		let requests = await provider.requests()
		XCTAssertEqual(requests.count, 2)
		XCTAssertTrue(requests.allSatisfy { $0.userPrompt.contains("request_mode: pro_edit") })
		XCTAssertTrue(requests.allSatisfy { $0.systemPrompt.contains("Pro Edit v1") })
		XCTAssertTrue(requests.allSatisfy { $0.userPrompt.contains("struct Selected {}") })
	}

	func testResolvePreflightsSelectedDelegateAndAbsentCreateWithoutWriting() async throws {
		let root = try temporaryDirectory()
		let sources = root.appendingPathComponent("Sources", isDirectory: true)
		try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
		let existing = sources.appendingPathComponent("Existing.swift")
		let created = sources.appendingPathComponent("Created.swift")
		let original = "struct Existing {}\n"
		try original.write(to: existing, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		_ = try await service.addFiles([existing.path])
		let before = try Data(contentsOf: existing)

		let artifact = try PortableProEditArtifactParser.parse(Self.validArtifact)
		let preflight = try await service.inspectProEditArtifact(artifact)

		XCTAssertEqual(preflight.targets.map(\.displayPath), ["Sources/Existing.swift", "Sources/Created.swift"])
		XCTAssertEqual(preflight.targets[0].absolutePath, existing.path)
		XCTAssertEqual(preflight.targets[0].originalContent, original)
		XCTAssertNil(preflight.targets[1].originalContent)
		XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
		XCTAssertEqual(try Data(contentsOf: existing), before)
	}

	func testResolveRejectsMissingUnselectedExistingAndExistingCreate() async throws {
		let root = try temporaryDirectory()
		let existing = root.appendingPathComponent("Existing.swift")
		try "existing".write(to: existing, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		await assertPreflightError(.targetNotSelected) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "Existing.swift",
				action: .delegateEdit
			))
		}
		await assertPreflightError(.missingExistingTarget) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "Missing.swift",
				action: .delegateEdit
			))
		}
		await assertPreflightError(.createTargetAlreadyExists) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "Existing.swift",
				action: .create
			))
		}
	}

	func testResolveRejectsFoldersMissingCreateParentsAndInvalidUTF8() async throws {
		let root = try temporaryDirectory()
		let folder = root.appendingPathComponent("Folder", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let invalidUTF8 = root.appendingPathComponent("Invalid.txt")
		try Data([0xFF]).write(to: invalidUTF8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		_ = try await service.addFiles([folder.path])
		await assertPreflightError(.targetIsDirectory) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "Folder",
				action: .delegateEdit
			))
		}
		await assertPreflightError(.createParentMissing) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "Missing/Created.swift",
				action: .create
			))
		}
		_ = try await service.addFiles([invalidUTF8.path])
		await assertPreflightError(.invalidUTF8) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "Invalid.txt",
				action: .delegateEdit
			))
		}
	}

	func testResolveRejectsOutsideDuplicateAndOverlappingTargets() async throws {
		let root = try temporaryDirectory()
		let existing = root.appendingPathComponent("Existing.swift")
		try "existing".write(to: existing, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		_ = try await service.addFiles([existing.path])

		await assertPreflightError(.invalidPath) {
			try await service.inspectProEditArtifact(Self.artifact(path: "../Outside.swift", action: .create))
		}
		await assertPreflightError(.duplicateTarget) {
			try await service.inspectProEditArtifact(PortableProEditArtifact(
				chatName: "Duplicate",
				plan: "Reject aliases.",
				files: [
					Self.file(path: "Existing.swift", action: .delegateEdit),
					Self.file(path: "root[0]:Existing.swift", action: .delegateEdit)
				]
			))
		}
		await assertPreflightError(.overlappingTarget) {
			try await service.inspectProEditArtifact(PortableProEditArtifact(
				chatName: "Overlap",
				plan: "Reject overlapping destinations.",
				files: [
					Self.file(path: "Generated", action: .create),
					Self.file(path: "Generated/Nested.swift", action: .create)
				]
			))
		}
	}

	func testResolveRequiresAndPreservesMultiRootQualification() async throws {
		let first = try temporaryDirectory()
		let second = try temporaryDirectory()
		let file = second.appendingPathComponent("Selected.swift")
		try "selected".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [first.path, second.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		_ = try await service.addFiles(["root[1]:Selected.swift"])

		let preflight = try await service.inspectProEditArtifact(Self.artifact(
			path: "root[1]:Selected.swift",
			action: .delegateEdit
		))

		XCTAssertEqual(preflight.targets[0].rootIndex, 1)
		XCTAssertEqual(preflight.targets[0].relativePath, "Selected.swift")
		XCTAssertEqual(preflight.targets[0].displayPath, "root[1]:Selected.swift")
		XCTAssertEqual(preflight.targets[0].absolutePath, file.path)
		await assertPreflightError(.invalidPath) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "Selected.swift",
				action: .delegateEdit
			))
		}
	}

	func testResolveRejectsSelectionAndContextChangedAfterGeneration() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("Selected.swift")
		try "before".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		let selected = try await service.addFiles([file.path])
		let preview = try await service.previewContext()
		let generation = Self.generation(selection: selected, context: preview)
		let artifact = Self.artifact(path: "Selected.swift", action: .delegateEdit)

		_ = await service.clearSelection()
		await assertPreflightError(.staleSelection) {
			try await service.resolveProEditArtifact(
				artifact,
				expectedGeneration: generation,
				lane: .primary
			)
		}

		let reselected = try await service.addFiles([file.path])
		let refreshed = try await service.previewContext()
		let refreshedGeneration = Self.generation(selection: reselected, context: refreshed)
		try "after".write(to: file, atomically: true, encoding: .utf8)
		await assertPreflightError(.staleContext) {
			try await service.resolveProEditArtifact(
				artifact,
				expectedGeneration: refreshedGeneration,
				lane: .primary
			)
		}
	}

	func testResolveRejectsSymlinkEscape() async throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		let link = root.appendingPathComponent("escape", isDirectory: true)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		await assertPreflightError(.outsideWorkspace) {
			try await service.inspectProEditArtifact(Self.artifact(
				path: "escape/New.swift",
				action: .create
			))
		}
	}

	private func assertParseError(
		_ expected: PortableProEditParseError.Code,
		source: String,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		XCTAssertThrowsError(
			try PortableProEditArtifactParser.parse(source),
			file: file,
			line: line
		) { error in
			XCTAssertEqual((error as? PortableProEditParseError)?.code, expected, file: file, line: line)
		}
	}

	private func assertPreflightError<Result>(
		_ expected: PortableProEditPreflightError.Code,
		operation: () async throws -> Result,
		file: StaticString = #filePath,
		line: UInt = #line
	) async {
		do {
			_ = try await operation()
			XCTFail("Expected Pro Edit preflight error.", file: file, line: line)
		} catch let error as PortableProEditPreflightError {
			XCTAssertEqual(error.code, expected, file: file, line: line)
		} catch {
			XCTFail("Unexpected error: \(error)", file: file, line: line)
		}
	}

	private static func artifact(
		path: String,
		action: PortableProEditAction
	) -> PortableProEditArtifact {
		PortableProEditArtifact(
			chatName: "Test",
			plan: "Test preflight.",
			files: [file(path: path, action: action)]
		)
	}

	private static func file(
		path: String,
		action: PortableProEditAction
	) -> PortableProEditFile {
		PortableProEditFile(
			path: path,
			action: action,
			changes: [
				PortableProEditChange(
					description: action == .create ? "Create the file" : "Edit the file",
					content: action == .create ? "struct Created {}" : "Update the selected symbol.",
					complexity: 1
				)
			]
		)
	}

	private static func generation(
		selection: PortableWorkspaceSelection,
		context: PortableContextPreview
	) -> PortableProEditGeneration {
		let lane = PortablePlanLane(
			name: .primary,
			modelRawID: "model",
			status: .completed,
			response: validArtifact,
			errorCode: nil,
			errorMessage: nil
		)
		return PortableProEditGeneration(
			selection: selection,
			result: PortablePlanResult(
				pairID: UUID(),
				status: .completed,
				primary: lane,
				secondary: PortablePlanLane(
					name: .secondary,
					modelRawID: "secondary",
					status: .completed,
					response: validArtifact,
					errorCode: nil,
					errorMessage: nil
				),
				context: context
			)
		)
	}

	private func bootstrap(roots: [String]) async throws -> HeadlessWorkspaceBootstrapResult {
		try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: roots, persist: false)
		)
	}

	private func workflow(provider: any HeadlessOracleProvider) throws -> HeadlessOracleWorkflow {
		let configuration = try HeadlessOracleConfiguration(
			endpoint: XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions")),
			primaryModel: "primary-model",
			secondaryModel: "secondary-model"
		)
		return HeadlessOracleWorkflow(configuration: configuration, provider: provider)
	}

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.standardizedFileURL
	}

	fileprivate static let validArtifact = """
	<chatName="Implement safe changes"/>
	<Plan>
	Update one file and create one file.
	</Plan>
	<file path="Sources/Existing.swift" action="delegate edit">
	<change>
	<description>Update the existing implementation</description>
	<content>Change the existing symbol without replacing the whole file.</content>
	<complexity>3</complexity>
	</change>
	<change>
	<description>Preserve comparison behavior</description>
	<content>Keep the comparison `lhs < rhs` and preserve CRLF.\r
	</content>
	<complexity>2</complexity>
	</change>
	</file>
	<file path="Sources/Created.swift" action="create">
	<change>
	<description>Create the supporting type</description>
	<content>
	struct Created {
		let value = 1
	}
	</content>
	<complexity>1</complexity>
	</change>
	</file>
	"""
}

private actor ProEditRecordingProvider: HeadlessOracleProvider {
	private var recorded: [HeadlessOracleProviderRequest] = []

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> HeadlessOracleProviderCompletion {
		recorded.append(request)
		return HeadlessOracleProviderCompletion(
			content: PortableProEditArtifactTests.validArtifact,
			metadata: HeadlessOracleProviderMetadata(
				httpStatus: 200,
				latencyMilliseconds: 1,
				responseID: nil,
				requestID: nil,
				observedModelID: request.model,
				finishReason: "stop",
				usage: nil,
				conversationID: nil,
				baselineAssistantMessageID: nil,
				recovery: nil
			)
		)
	}

	func requests() -> [HeadlessOracleProviderRequest] { recorded }
}
