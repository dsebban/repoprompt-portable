import RepoPromptHeadless
@testable import RepoPromptLinuxDesktopKit
import XCTest

final class DesktopArgumentsTests: XCTestCase {
	func testParsesRootsAndHelp() throws {
		XCTAssertEqual(
			try DesktopArguments.parse(["--root", "/one", "-r", "/two", "--root=/three", "--help"]),
			DesktopArguments(roots: ["/one", "/two", "/three"], help: true)
		)
	}

	func testDefaultsToNoExplicitRoots() throws {
		XCTAssertEqual(try DesktopArguments.parse([]), DesktopArguments())
	}

	func testParsesMacOSQAFlag() throws {
		XCTAssertEqual(
			try DesktopArguments.parse(["--macos", "--root", "/workspace"]),
			DesktopArguments(roots: ["/workspace"], macOSQA: true)
		)
	}

	func testRejectsMissingAndUnknownArguments() {
		XCTAssertThrowsError(try DesktopArguments.parse(["--root"]))
		XCTAssertThrowsError(try DesktopArguments.parse(["--root="]))
		XCTAssertThrowsError(try DesktopArguments.parse(["--persist"]))
	}

	func testRootValueMayBeginWithDash() throws {
		XCTAssertEqual(try DesktopArguments.parse(["--root", "-workspace"]).roots, ["-workspace"])
	}
}

final class DesktopStateTests: XCTestCase {
	func testDetailRouteRoundTripPreservesWorkspaceState() {
		var state = DesktopState()
		state.query = "RootShell"
		state.focusedFilePath = "/root/RootShellView.swift"
		state.sliceDraftText = "10-20 | layout"
		state.instructions = "Keep this work."
		state.context = Self.context()
		state.plan = Self.plan()
		state.oracleMode = .plan
		let baseline = state

		state.selectDetail(.settings)
		XCTAssertEqual(state.detailRoute, .settings)
		XCTAssertEqual(state.generation, baseline.generation)
		state.selectDetail(.workspace)

		XCTAssertEqual(state, baseline)
	}

	func testOracleEndpointDisplayRemovesCredentialsAndQuery() throws {
		let endpoint = try XCTUnwrap(URL(string: "https://user:secret@example.com/v1/chat?api_key=hidden#fragment"))
		let display = desktopOracleEndpoint(endpoint)
		XCTAssertEqual(display, "https://example.com/v1/chat")
		XCTAssertFalse(display.contains("secret"))
		XCTAssertFalse(display.contains("hidden"))
	}

	func testSearchIsCaseInsensitiveAndVisibleRowsAreBounded() {
		var state = DesktopState()
		state.files = (0 ... DesktopState.maximumVisibleFiles).map { index in
			PortableWorkspaceFile(
				absolutePath: "/root/Sources/App\(index).swift",
				displayPath: "Sources/App\(index).swift"
			)
		}
		state.files.append(PortableWorkspaceFile(absolutePath: "/root/Tests/AppTests.swift", displayPath: "Tests/AppTests.swift"))
		state.query = "sources/app"
		XCTAssertEqual(state.matchingFiles.count, DesktopState.maximumVisibleFiles + 1)
		XCTAssertEqual(state.visibleFiles.count, DesktopState.maximumVisibleFiles)
		XCTAssertTrue(state.visibleFiles.allSatisfy { $0.displayPath.hasPrefix("Sources/App") })
	}

	func testSliceDraftParserSupportsDescriptionsAndReportsLineErrors() throws {
		let ranges = try DesktopSliceDraftParser.parse("12\n20-35\n40-55 | parser entry point")
		XCTAssertEqual(ranges, [
			PortableLineRange(startLine: 12),
			PortableLineRange(startLine: 20, endLine: 35),
			PortableLineRange(startLine: 40, endLine: 55, description: "parser entry point")
		])
		XCTAssertEqual(DesktopSliceDraftParser.format(ranges), "12\n20-35\n40-55 | parser entry point")
		XCTAssertThrowsError(try DesktopSliceDraftParser.parse("1\nnope")) { error in
			XCTAssertEqual((error as? DesktopSliceDraftError)?.line, 2)
		}
	}

	func testSliceDraftDescriptionsRoundTripLineEndingsAndBackslashes() throws {
		let description = "first\\path\r\n2-3 | not a range\nnext\rend\\n literal"
		let ranges = [PortableLineRange(startLine: 7, endLine: 9, description: description)]

		let draft = DesktopSliceDraftParser.format(ranges)
		let parsed = try DesktopSliceDraftParser.parse(draft)

		XCTAssertEqual(parsed, ranges)
		XCTAssertEqual(parsed.count, 1)
		XCTAssertFalse(draft.contains("\r"))
		XCTAssertEqual(draft.components(separatedBy: "\n").count, 1)
	}

	func testRoleMarkersAndFocusUseTypedSelectionDetails() {
		let full = PortableWorkspaceFile(absolutePath: "/root/full.swift", displayPath: "full.swift", codemapSupported: true)
		let slice = PortableWorkspaceFile(absolutePath: "/root/slice.swift", displayPath: "slice.swift", codemapSupported: true)
		let manual = PortableWorkspaceFile(absolutePath: "/root/manual.swift", displayPath: "manual.swift", codemapSupported: true)
		let automatic = PortableWorkspaceFile(absolutePath: "/root/automatic.swift", displayPath: "automatic.swift", codemapSupported: true)
		var state = DesktopState()
		state.files = [full, slice, manual, automatic]
		state.selection = PortableWorkspaceSelection(
			selectedFiles: [full, slice],
			sliceFileCount: 1,
			codemapFileCount: 1,
			slices: [PortableSliceSelection(path: slice.absolutePath, ranges: [PortableLineRange(startLine: 2, endLine: 4, description: "core")])],
			manualCodemapFiles: [manual],
			codemapAutoEnabled: true
		)
		state.context = Self.context(automaticCodemapPaths: [automatic.displayPath])

		XCTAssertEqual(state.roleMarker(for: full), "[F]")
		XCTAssertEqual(state.roleMarker(for: slice), "[S]")
		XCTAssertEqual(state.roleMarker(for: manual), "[C]")
		XCTAssertEqual(state.roleMarker(for: automatic), "[A]")
		state.focus(slice)
		XCTAssertEqual(state.focusedFilePath, slice.absolutePath)
		XCTAssertEqual(state.sliceDraftText, "2-4 | core")
	}

	func testStaleCompletionIsIgnoredAfterCancellation() {
		var state = DesktopState()
		let generation = state.begin(.plan)
		state.cancelCurrent(generation: generation)
		state.planGenerated(Self.plan(), generation: generation)
		XCTAssertNil(state.plan)
		XCTAssertNil(state.activity)
		XCTAssertEqual(state.statusMessage, "Cancelled.")
	}

	func testStaleCancellationDoesNotClobberNewerActivity() {
		var state = DesktopState()
		let staleGeneration = state.begin(.plan)
		let currentGeneration = state.begin(.selection)
		state.cancelCurrent(generation: staleGeneration)
		XCTAssertEqual(state.activity, .selection)
		XCTAssertEqual(state.generation, currentGeneration)
	}

	func testSelectionCompletionInvalidatesDerivedOutput() {
		var state = DesktopState()
		state.context = Self.context()
		state.plan = Self.plan()
		let generation = state.begin(.selection)
		state.selectionChanged(
			PortableWorkspaceSelection(
				selectedFiles: [PortableWorkspaceFile(absolutePath: "/root/a", displayPath: "a")],
				sliceFileCount: 0,
				codemapFileCount: 0
			),
			generation: generation
		)
		XCTAssertEqual(state.selectedPaths, ["/root/a"])
		XCTAssertNil(state.context)
		XCTAssertNil(state.plan)
	}

	func testReloadAndPreviewInvalidateOlderDerivedOutput() {
		var state = DesktopState()
		state.selection = PortableWorkspaceSelection(
			selectedFiles: [PortableWorkspaceFile(absolutePath: "/root/selected.swift", displayPath: "selected.swift")],
			sliceFileCount: 0,
			codemapFileCount: 0
		)
		state.context = Self.context()
		state.plan = Self.plan()
		let reloadGeneration = state.begin(.reload)
		state.filesReloaded([], generation: reloadGeneration)
		XCTAssertEqual(state.selectedPaths, ["/root/selected.swift"])
		XCTAssertNil(state.context)
		XCTAssertNil(state.plan)

		state.plan = Self.plan()
		let previewGeneration = state.begin(.preview)
		state.contextBuilt(Self.context(), generation: previewGeneration)
		XCTAssertNil(state.plan)
		XCTAssertEqual(state.activePanel, .contextBuilder)
	}

	func testContextTextIsChunkedAndBounded() {
		let text = DesktopContextText(String(repeating: "x", count: DesktopContextText.maximumCharacters + 1))
		XCTAssertTrue(text.truncated)
		XCTAssertEqual(text.chunks.count, DesktopContextText.maximumCharacters / DesktopContextText.chunkSize)
		XCTAssertEqual(text.chunks.reduce(0) { $0 + $1.count }, DesktopContextText.maximumCharacters)
		XCTAssertTrue(text.chunks.allSatisfy { $0.count <= DesktopContextText.chunkSize })
	}

	func testErrorMessagesPreserveHeadlessRuntimeMessage() {
		let error = HeadlessRuntimeError("Workspace root does not exist.", exitCode: .usage)
		XCTAssertEqual(desktopErrorMessage(error), "Workspace root does not exist.")
	}

	func testReviewCompletionRecordsModeAndAutomaticToggleInvalidatesDerivedOutput() {
		var state = DesktopState()
		state.context = Self.context(automaticCodemapPaths: ["dependency.swift"])
		state.plan = Self.plan()
		let toggleGeneration = state.begin(.automaticCodemap)
		state.selectionChanged(
			PortableWorkspaceSelection(
				selectedFiles: [],
				sliceFileCount: 0,
				codemapFileCount: 0,
				codemapAutoEnabled: false
			),
			generation: toggleGeneration
		)
		XCTAssertFalse(state.selection.codemapAutoEnabled)
		XCTAssertNil(state.context)
		XCTAssertNil(state.plan)

		let reviewGeneration = state.begin(.review)
		state.oracleGenerated(Self.plan(), mode: .review, generation: reviewGeneration)
		XCTAssertEqual(state.oracleMode, .review)
		XCTAssertEqual(state.activePanel, .oracle)
		XCTAssertTrue(state.statusMessage?.hasPrefix("Review finished:") == true)
	}

	func testGeneratePlanGateRequiresProviderAndInstructions() {
		var state = DesktopState()
		state.oracleAvailable = true
		state.instructions = "  plan this  "
		state.plan = Self.plan()
		XCTAssertTrue(state.canGeneratePlan)
		_ = state.begin(.plan)
		XCTAssertNil(state.plan)
		XCTAssertFalse(state.canGeneratePlan)
	}

	func testProEditRequiresExplicitLaneChoiceBeforeMaterialization() {
		var state = DesktopState()
		state.oracleAvailable = true
		state.instructions = "Apply the requested change."
		let token = state.begin(.proEditGenerate)

		state.proEditGenerated(
			PortableProEditGeneration(
				selection: state.selection,
				result: Self.plan()
			),
			generation: token
		)

		XCTAssertEqual(state.activePanel, .proEdit)
		XCTAssertNil(state.selectedProEditLane)
		XCTAssertNil(state.selectedProEditArtifact)
		XCTAssertFalse(state.canMaterializeProEdit)
		state.selectProEditLane(.secondary)
		XCTAssertEqual(state.selectedProEditLane, .secondary)
		XCTAssertEqual(state.selectedProEditArtifact, "two")
		XCTAssertTrue(state.canMaterializeProEdit)
	}

	func testResetInvalidatesCurrentMaterialization() {
		var state = DesktopState()
		state.proEditGeneration = PortableProEditGeneration(
			selection: state.selection,
			result: Self.plan()
		)
		state.selectProEditLane(.primary)
		let token = state.begin(.proEditMaterialize)
		let session = DesktopProEditSession(
			id: UUID(),
			changedPaths: ["Sources/Feature.swift"],
			files: []
		)

		XCTAssertTrue(state.proEditMaterialized(
			session,
			lane: .primary,
			artifact: "one",
			generation: token
		))

		XCTAssertEqual(state.proEditSession?.id, session.id)
		state.resetProEdit()
		XCTAssertFalse(state.canApplyProEdit)
		XCTAssertNil(state.proEditSession)
		XCTAssertEqual(state.statusMessage, "Pro Edit reset.")
	}

	func testStaleProEditMaterializationCannotReenableApplyAfterCancellation() {
		var state = DesktopState()
		state.proEditGeneration = PortableProEditGeneration(
			selection: state.selection,
			result: Self.plan()
		)
		state.selectProEditLane(.primary)
		let staleToken = state.begin(.proEditMaterialize)
		state.cancelCurrent(generation: staleToken)
		XCTAssertFalse(state.proEditMaterialized(
			DesktopProEditSession(id: UUID(), changedPaths: ["Stale.swift"], files: []),
			lane: .primary,
			artifact: "one",
			generation: staleToken
		))

		XCTAssertFalse(state.canApplyProEdit)
		XCTAssertNil(state.proEditSession)
		XCTAssertEqual(state.statusMessage, "Cancelled.")
	}

	func testLaneChoiceCannotChangeDuringMaterialization() {
		var state = DesktopState()
		state.proEditGeneration = PortableProEditGeneration(
			selection: state.selection,
			result: Self.plan()
		)
		state.selectProEditLane(.primary)
		_ = state.begin(.proEditMaterialize)

		state.selectProEditLane(.secondary)

		XCTAssertEqual(state.selectedProEditLane, .primary)
		XCTAssertEqual(state.selectedProEditArtifact, "one")
	}

	func testProEditApplyRefreshesInventoryAndReportsExactPaths() {
		var state = DesktopState()
		let token = state.begin(.proEditApply)
		let files = [
			PortableWorkspaceFile(
				absolutePath: "/root/Created.swift",
				displayPath: "Created.swift"
			)
		]
		let summary = DesktopProEditApplySummary(
			transactionID: UUID(),
			appliedPaths: ["Created.swift", "Sources/Changed.swift"]
		)

		state.proEditApplied(summary, refreshedFiles: files, generation: token)

		XCTAssertEqual(state.files, files)
		XCTAssertEqual(state.appliedProEditPaths, summary.appliedPaths)
		XCTAssertNil(state.proEditSession)
		XCTAssertFalse(state.canApplyProEdit)
		XCTAssertEqual(state.activePanel, .proEdit)
		XCTAssertTrue(state.statusMessage?.contains("Created.swift, Sources/Changed.swift") == true)
	}

	private static func context(automaticCodemapPaths: [String] = []) -> PortableContextPreview {
		PortableContextPreview(
			entries: [],
			omissions: [],
			automaticCodemapPaths: automaticCodemapPaths,
			content: "context",
			contentByteCount: 7,
			maximumByteCount: 128,
			truncated: false,
			omittedRootCount: 0,
			isCompleteForProvider: true
		)
	}

	private static func plan() -> PortablePlanResult {
		let primary = PortablePlanLane(
			name: .primary,
			modelRawID: "primary",
			status: .completed,
			response: "one",
			errorCode: nil,
			errorMessage: nil
		)
		let secondary = PortablePlanLane(
			name: .secondary,
			modelRawID: "secondary",
			status: .completed,
			response: "two",
			errorCode: nil,
			errorMessage: nil
		)
		return PortablePlanResult(
			pairID: UUID(),
			status: .completed,
			primary: primary,
			secondary: secondary,
			context: context()
		)
	}
}
