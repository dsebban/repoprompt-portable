import Foundation
import MCP
@testable import RepoPromptHeadless
import XCTest

final class PortableWorkspaceServiceTests: XCTestCase {
	func testListsFlattenedFilesWithStableMultiRootDisplayPaths() async throws {
		let first = try temporaryDirectory()
		let second = try temporaryDirectory()
		try "a".write(to: first.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
		try "b".write(to: first.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
		try "hidden".write(to: first.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
		try FileManager.default.createDirectory(at: first.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
		try "ignored".write(to: first.appendingPathComponent("node_modules/ignored.js"), atomically: true, encoding: .utf8)
		try "z".write(to: second.appendingPathComponent("z.md"), atomically: true, encoding: .utf8)

		let bootstrap = try await bootstrap(roots: [first.path, second.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		let summary = await service.workspace()
		XCTAssertEqual(summary.roots, [
			first.resolvingSymlinksInPath().path,
			second.resolvingSymlinksInPath().path
		])
		let files = try await service.files()
		XCTAssertEqual(files.map(\.displayPath), [
			"root[0]:A.swift",
			"root[0]:b.txt",
			"root[1]:z.md"
		])
	}

	func testDesktopInventoryRespectsGitignoreRules() async throws {
		let root = try temporaryDirectory()
		try "*.pyc\nignored.txt\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		try "keep".write(to: root.appendingPathComponent("keep.swift"), atomically: true, encoding: .utf8)
		try "ignored".write(to: root.appendingPathComponent("cache.pyc"), atomically: true, encoding: .utf8)
		try "ignored".write(to: root.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		let files = try await service.files()
		XCTAssertEqual(files.map(\.displayPath), ["keep.swift"])
	}

	func testDesktopInventoryHandlesIgnorePayloadLargerThanPipeBuffers() async throws {
		let root = try temporaryDirectory()
		let generated = root.appendingPathComponent("generated", isDirectory: true)
		try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
		try "generated/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		for index in 0 ..< 1_500 {
			let name = "generated-file-with-a-long-name-\(index).txt"
			try "ignored".write(to: generated.appendingPathComponent(name), atomically: true, encoding: .utf8)
		}
		try "keep".write(to: root.appendingPathComponent("keep.swift"), atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		let files = try await service.files()
		XCTAssertEqual(files.map(\.displayPath), ["keep.swift"])
	}

	func testSymlinkedRootUsesOneCanonicalPublicPathNamespace() async throws {
		let parent = try temporaryDirectory()
		let realRoot = parent.appendingPathComponent("real", isDirectory: true)
		let linkedRoot = parent.appendingPathComponent("linked", isDirectory: true)
		try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
		try "linked".write(to: realRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [linkedRoot.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		let summary = await service.workspace()
		let files = try await service.files()
		XCTAssertEqual(summary.roots, [realRoot.resolvingSymlinksInPath().path])
		XCTAssertEqual(files.count, 1)
		XCTAssertTrue(files[0].absolutePath.hasPrefix(summary.roots[0] + "/"))
		let selection = try await service.addFiles([files[0].absolutePath])
		XCTAssertEqual(selection.selectedAbsolutePaths, [files[0].absolutePath])
	}

	func testDesktopInventoryFiltersEscapingAndNonRegularSymlinks() async throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		let regular = root.appendingPathComponent("regular.txt")
		let outsideFile = outside.appendingPathComponent("outside.txt")
		let directory = root.appendingPathComponent("directory", isDirectory: true)
		try "inside".write(to: regular, atomically: true, encoding: .utf8)
		try "outside".write(to: outsideFile, atomically: true, encoding: .utf8)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try "child".write(to: directory.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inside-link.txt"), withDestinationURL: regular)
		try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside-link.txt"), withDestinationURL: outsideFile)
		try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("directory-link"), withDestinationURL: directory)
		try FileManager.default.createSymbolicLink(
			at: root.appendingPathComponent("broken-link.txt"),
			withDestinationURL: root.appendingPathComponent("missing.txt")
		)

		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		let files = try await service.files()
		XCTAssertEqual(files.map(\.displayPath), ["directory/child.txt", "inside-link.txt", "regular.txt"])
	}

	func testDesktopInventoryAndPreviewObserveCancellation() async throws {
		let root = try temporaryDirectory()
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		let inventory = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await service.files()
		}
		do {
			_ = try await inventory.value
			XCTFail("Expected inventory cancellation")
		} catch is CancellationError {}

		let preview = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await service.previewContext()
		}
		do {
			_ = try await preview.value
			XCTFail("Expected preview cancellation")
		} catch is CancellationError {}
	}

	func testPublicFullFileSelectionSharesCatalogStateAndCatalogKeepsSliceAndCodemapModes() async throws {
		let root = try temporaryDirectory()
		let full = root.appendingPathComponent("full.swift")
		let sliced = root.appendingPathComponent("sliced.swift")
		try "full".write(to: full, atomically: true, encoding: .utf8)
		try "one\ntwo".write(to: sliced, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		let added = try await service.addFiles([full.path])
		XCTAssertEqual(added.selectedAbsolutePaths, [full.path])
		let catalogSelection = await catalog.call(name: "manage_selection", arguments: ["op": .string("get")])
		XCTAssertEqual(catalogSelection.isError, false)
		XCTAssertTrue(text(catalogSelection).contains("full.swift"))

		let sliceResult = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("add"),
			"mode": .string("slices"),
			"slices": .array([.object([
				"path": .string(sliced.path),
				"ranges": .array([.object([
					"start_line": .int(1),
					"end_line": .int(1)
				])])
			])])
		])
		XCTAssertEqual(sliceResult.isError, false)

		let codemapResult = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("add"),
			"mode": .string("codemap_only"),
			"paths": .array([.string(full.path)])
		])
		XCTAssertEqual(codemapResult.isError, false)
		let mixed = await bootstrap.session.selectionStore.snapshot(tabID: nil)
		XCTAssertEqual(mixed.selectedPaths, [sliced.path])
		XCTAssertEqual(mixed.slices[sliced.path], [.init(start: 1, end: 1)])
		XCTAssertEqual(mixed.autoCodemapPaths, [full.path])
		XCTAssertFalse(mixed.codemapAutoEnabled)

		let removed = try await service.removeFiles([full.path])
		XCTAssertEqual(removed.codemapFileCount, 0)
		let cleared = await service.clearSelection()
		XCTAssertTrue(cleared.selectedFiles.isEmpty)
		let final = await bootstrap.session.selectionStore.snapshot(tabID: nil)
		XCTAssertEqual(final, .init())
	}

	func testTypedSelectionReducerNormalizesSlicesAndPreservesCompatibilityState() async throws {
		let root = try temporaryDirectory()
		let full = root.appendingPathComponent("full.swift")
		let sliced = root.appendingPathComponent("sliced.swift")
		try "full".write(to: full, atomically: true, encoding: .utf8)
		try "one\ntwo\nthree\nfour".write(to: sliced, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		_ = try await service.setAutomaticCodemapsEnabled(false)
		_ = try await service.addFiles([full.path])
		let slicedSelection = try await service.setSlices([
			PortableSliceSelection(path: sliced.path, ranges: [
				PortableLineRange(startLine: 1, endLine: 2, description: "first"),
				PortableLineRange(startLine: 3, endLine: 3, description: "next")
			])
		])
		XCTAssertEqual(slicedSelection.selectedFiles.map(\.absolutePath), [full.path, sliced.path])
		XCTAssertEqual(slicedSelection.slices, [
			PortableSliceSelection(
				path: sliced.path,
				ranges: [PortableLineRange(startLine: 1, endLine: 3, description: "first; next")]
			)
		])
		XCTAssertFalse(slicedSelection.codemapAutoEnabled)

		let demoted = try await service.demoteToManualCodemap([full.path])
		XCTAssertEqual(demoted.manualCodemapFiles.map(\.absolutePath), [full.path])
		XCTAssertEqual(demoted.codemapFileCount, 1)
		XCTAssertFalse(demoted.selectedAbsolutePaths.contains(full.path))

		let promoted = try await service.promoteToFull([sliced.path])
		XCTAssertNil(promoted.slices.first { $0.path == sliced.path })
		XCTAssertTrue(promoted.selectedAbsolutePaths.contains(sliced.path))

		let replaced = try await service.mutateSelection(.replaceWithFullFiles([full.path]))
		XCTAssertEqual(replaced.selectedFiles.map(\.absolutePath), [full.path])
		XCTAssertTrue(replaced.manualCodemapFiles.isEmpty)
		XCTAssertTrue(replaced.slices.isEmpty)
		XCTAssertFalse(replaced.codemapAutoEnabled)

		let cleared = await service.clearSelection()
		XCTAssertTrue(cleared.selectedFiles.isEmpty)
		XCTAssertTrue(cleared.codemapAutoEnabled)
	}

	func testTypedSelectionMutationRejectsInvalidDescriptionAtomically() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("file.swift")
		try "line".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		_ = try await service.addFiles([file.path])
		let before = await bootstrap.session.selectionStore.snapshot(tabID: nil)

		do {
			_ = try await service.setSlices([
				PortableSliceSelection(
					path: file.path,
					ranges: [PortableLineRange(startLine: 1, description: "bad\0description")]
				)
			])
			XCTFail("Expected invalid description")
		} catch let error as PortableWorkspaceServiceError {
			XCTAssertEqual(error.code, "invalid_params")
		}
		let after = await bootstrap.session.selectionStore.snapshot(tabID: nil)
		XCTAssertEqual(after, before)
	}

	func testConcurrentServiceAndCatalogAddsAreAtomic() async throws {
		let root = try temporaryDirectory()
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		try await withThrowingTaskGroup(of: Void.self) { group in
			for index in 0 ..< 40 {
				group.addTask {
					_ = try await service.addFiles(["service-\(index).swift"])
				}
				group.addTask {
					let result = await catalog.call(name: "manage_selection", arguments: [
						"op": .string("add"),
						"paths": .array([.string("catalog-\(index).swift")])
					])
					if result.isError == true { throw ConcurrentSelectionError() }
				}
			}
			try await group.waitForAll()
		}

		let selection = await bootstrap.session.selectionStore.snapshot(tabID: nil)
		XCTAssertEqual(Set(selection.selectedPaths).count, 80)
	}

	func testPreviewProjectsSelectedContext() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("selected.txt")
		try "PREVIEW_SENTINEL".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		try await service.addFiles([file.path])

		let preview = try await service.previewContext()

		XCTAssertEqual(preview.entries, [
			PortableContextEntry(
				displayPath: "selected.txt",
				kind: .full,
				startLine: nil,
				endLine: nil,
				byteCount: "PREVIEW_SENTINEL".utf8.count
			)
		])
		XCTAssertTrue(preview.content.contains("PREVIEW_SENTINEL"))
		XCTAssertEqual(preview.maximumByteCount, PortableWorkspaceService.contextByteBudget)
		XCTAssertTrue(preview.isCompleteForProvider)
	}

	func testGeneratePlanValidatesInstructionsBeforeConfigurationOrContext() async throws {
		let root = try temporaryDirectory()
		let bootstrap = try await bootstrap(roots: [root.path])
		let service = PortableWorkspaceService(bootstrap: bootstrap)

		for instructions in [" \n ", String(repeating: "x", count: 65_537)] {
			do {
				_ = try await service.generatePlan(instructions: instructions)
				XCTFail("Expected invalid instructions")
			} catch let error as PortableWorkspaceServiceError {
				XCTAssertEqual(error.code, "invalid_params")
				XCTAssertEqual(error.localizedDescription, error.message)
			} catch {
				XCTFail("Unexpected error: \(error)")
			}
		}
	}

	func testGeneratePlanUsesFixedPlanModeAndReturnsBothLanes() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("selected.txt")
		try "PLAN_SENTINEL".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let provider = PortableWorkspaceProvider()
		let service = PortableWorkspaceService(
			roots: bootstrap.roots,
			session: bootstrap.session,
			oracleWorkflow: try workflow(provider: provider)
		)
		try await service.addFiles([file.path])

		let result = try await service.generatePlan(instructions: "Plan the change")

		XCTAssertEqual(result.status, .completed)
		XCTAssertEqual(result.primary.response, "primary plan")
		XCTAssertEqual(result.secondary.response, "secondary plan")
		let expectedContext = "<file_contents>\nFile: selected.txt\n```txt\nPLAN_SENTINEL\n```\n</file_contents>"
		XCTAssertEqual(Data(result.context.content.utf8), Data(expectedContext.utf8))
		let requests = await provider.requests()
		XCTAssertEqual(requests.count, 2)
		XCTAssertTrue(requests.allSatisfy { $0.userPrompt.contains("request_mode: plan") })
		XCTAssertTrue(requests.allSatisfy { $0.userPrompt.contains(expectedContext) })
	}

	func testGeneratePlanFailsClosedBeforeProviderWhenSelectionBecomesUnreadable() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("selected.txt")
		try "soon gone".write(to: file, atomically: true, encoding: .utf8)
		let bootstrap = try await bootstrap(roots: [root.path])
		let provider = PortableWorkspaceProvider()
		let service = PortableWorkspaceService(
			roots: bootstrap.roots,
			session: bootstrap.session,
			oracleWorkflow: try workflow(provider: provider)
		)
		try await service.addFiles([file.path])
		try FileManager.default.removeItem(at: file)

		do {
			_ = try await service.generatePlan(instructions: "Plan the change")
			XCTFail("Expected incomplete context")
		} catch PortableWorkspaceServiceError.incompleteContext(let preview) {
			XCTAssertEqual(preview.omissions.first?.reason, .notFound)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
		let requestCount = await provider.requestCount()
		XCTAssertEqual(requestCount, 0)
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

	private func text(_ result: CallTool.Result) -> String {
		result.content.compactMap { content in
			if case let .text(text, _, _) = content { return text }
			return nil
		}.joined(separator: "\n")
	}
}

private struct ConcurrentSelectionError: Error {}

private actor PortableWorkspaceProvider: HeadlessOracleProvider {
	private var recorded: [HeadlessOracleProviderRequest] = []

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> HeadlessOracleProviderCompletion {
		recorded.append(request)
		return HeadlessOracleProviderCompletion(
			content: request.lane == .primary ? "primary plan" : "secondary plan",
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
	func requestCount() -> Int { recorded.count }
}
