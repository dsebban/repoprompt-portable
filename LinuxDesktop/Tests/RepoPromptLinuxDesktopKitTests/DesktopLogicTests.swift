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
		state.selectedPaths = ["/root/selected.swift"]
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

	private static func context() -> PortableContextPreview {
		PortableContextPreview(
			entries: [],
			omissions: [],
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
