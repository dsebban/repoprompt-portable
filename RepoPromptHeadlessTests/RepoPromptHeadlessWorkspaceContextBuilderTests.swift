import Foundation
import RepoPromptCodeMap
import RepoPromptCore
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessWorkspaceContextBuilderTests: XCTestCase {
	func testDeterministicSelectionAndSliceOrdering() throws {
		let root = try temporaryDirectory()
		let first = root.appendingPathComponent("first.txt")
		let second = root.appendingPathComponent("second.txt")
		try "first-file".write(to: first, atomically: true, encoding: .utf8)
		try "one\ntwo\nthree\nfour".write(to: second, atomically: true, encoding: .utf8)
		let selection = WorkspaceSelectionSnapshot(
			selectedPaths: [second.path, first.path, second.path],
			slices: [second.path: [LineRange(start: 3, end: 4), LineRange(start: 1, end: 1)]]
		)

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: selection,
			maximumBytes: 4_096
		)

		XCTAssertEqual(context.entries.map(\.kind), [.selectedSlice, .selectedSlice, .selectedFull])
		XCTAssertEqual(context.entries.compactMap(\.startLine), [1, 3])
		let firstSlice = try XCTUnwrap(context.content.range(of: "(lines 1)"))
		let secondSlice = try XCTUnwrap(context.content.range(of: "(lines 3-4)"))
		let fullFile = try XCTUnwrap(context.content.range(of: "File: first.txt"))
		XCTAssertLessThan(firstSlice.lowerBound, secondSlice.lowerBound)
		XCTAssertLessThan(secondSlice.lowerBound, fullFile.lowerBound)
		XCTAssertTrue(context.content.contains("one"))
		XCTAssertTrue(context.content.contains("three\nfour"))
		XCTAssertLessThanOrEqual(context.contentByteCount, 4_096)
		XCTAssertTrue(context.isCompleteForProvider)
	}

	func testCanonicalFullFilePackagingIsByteExact() throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("Main.swift")
		let source = "let value = 1\n"
		try Data(source.utf8).write(to: file)

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(selectedPaths: [file.path]),
			maximumBytes: 4_096
		)
		let expected = "<file_contents>\nFile: Main.swift\n```swift\nlet value = 1\n\n```\n</file_contents>"

		XCTAssertEqual(Data(context.content.utf8), Data(expected.utf8))
		XCTAssertFalse(context.content.contains("===== BEGIN FILE"))
		XCTAssertTrue(context.isCompleteForProvider)
	}

	func testCanonicalSlicePackagingPreservesCRLFAndCRBytes() throws {
		let root = try temporaryDirectory()
		let crlf = root.appendingPathComponent("crlf.swift")
		let cr = root.appendingPathComponent("legacy.txt")
		try Data("one\r\ntwo\r\nthree\r\nfour".utf8).write(to: crlf)
		try Data("alpha\rbeta\rgamma\rdelta".utf8).write(to: cr)

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(
				selectedPaths: [crlf.path, cr.path],
				slices: [
					crlf.path: [
						LineRange(start: 1, end: 2, description: "first"),
						LineRange(start: 3, end: 3, description: "next")
					],
					cr.path: [LineRange(start: 2, end: 3, description: "legacy")]
				]
			),
			maximumBytes: 8_192
		)
		let expected = "<file_contents>\n"
			+ "File: crlf.swift\n(lines 1-3: first; next)\n```swift\none\r\ntwo\r\nthree\r\n\n```\n\n"
			+ "File: legacy.txt\n(lines 2-3: legacy)\n```txt\nbeta\rgamma\r\n```\n"
			+ "</file_contents>"

		XCTAssertEqual(Data(context.content.utf8), Data(expected.utf8))
		XCTAssertEqual(context.entries.compactMap(\.startLine), [1, 2])
		XCTAssertEqual(context.entries.compactMap(\.endLine), [3, 3])
		XCTAssertTrue(context.isCompleteForProvider)
	}

	func testCanonicalPackagerComposesMapBeforeContents() {
		let packaged = CanonicalPromptPackaging.package(
			fileMapBlocks: ["File: API.swift\nImports:\n  - Foundation"],
			fileContentBlocks: ["File: Main.swift\n```swift\nmain()\n```"]
		)
		let expected = "<file_map>\nFile: API.swift\nImports:\n  - Foundation\n</file_map>\n\n"
			+ "<file_contents>\nFile: Main.swift\n```swift\nmain()\n```\n</file_contents>"
		XCTAssertEqual(Data(packaged.utf8), Data(expected.utf8))
	}

	func testBudgetSkipsOversizedEntriesAndContinuesWithoutReadingSparseFile() throws {
		let root = try temporaryDirectory()
		let budgetFile = root.appendingPathComponent("budget.txt")
		let sparseFile = root.appendingPathComponent("sparse.txt")
		let smallFile = root.appendingPathComponent("small.txt")
		try String(repeating: "x", count: 2_000).write(to: budgetFile, atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: sparseFile.path, contents: Data()))
		let handle = try FileHandle(forWritingTo: sparseFile)
		try handle.truncate(atOffset: UInt64(HeadlessWorkspaceContextBuilder.maximumSourceFileBytes + 1))
		try handle.close()
		try "small sentinel".write(to: smallFile, atomically: true, encoding: .utf8)

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(selectedPaths: [budgetFile.path, sparseFile.path, smallFile.path]),
			maximumBytes: 1_024
		)

		XCTAssertLessThanOrEqual(context.contentByteCount, 1_024)
		XCTAssertTrue(context.truncated, "omissions: \(context.omissions)")
		XCTAssertTrue(context.content.contains("small sentinel"))
		XCTAssertTrue(context.omissions.contains { $0.path == "budget.txt" && $0.reason == .budgetExceeded })
		XCTAssertTrue(context.omissions.contains { $0.path == "sparse.txt" && $0.reason == .sourceTooLarge })
		XCTAssertFalse(context.isCompleteForProvider)
	}

	func testEmptySelectionAndDeterministicOmissions() throws {
		let root = try temporaryDirectory()
		let empty = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(),
			maximumBytes: 1_024
		)
		XCTAssertTrue(empty.entries.isEmpty)
		XCTAssertEqual(empty.content, "")
		XCTAssertLessThanOrEqual(empty.contentByteCount, 1_024)
		XCTAssertTrue(empty.isCompleteForProvider)

		let directory = root.appendingPathComponent("directory", isDirectory: true)
		let invalid = root.appendingPathComponent("invalid.bin")
		let sliced = root.appendingPathComponent("sliced.txt")
		let orphan = root.appendingPathComponent("orphan.txt")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try Data([0xFF, 0xFE]).write(to: invalid)
		try "line".write(to: sliced, atomically: true, encoding: .utf8)
		try "orphan".write(to: orphan, atomically: true, encoding: .utf8)
		let missing = root.appendingPathComponent("missing.txt")
		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(
				selectedPaths: [missing.path, directory.path, invalid.path, sliced.path],
				autoCodemapPaths: [orphan.path],
				slices: [
					sliced.path: [LineRange(start: 9, end: 10)],
					orphan.path: [LineRange(start: 1, end: 1)]
				]
			),
			maximumBytes: 4_096
		)

		XCTAssertTrue(context.omissions.contains { $0.reason == .notFound })
		XCTAssertTrue(context.omissions.contains { $0.reason == .directoryUnsupported })
		XCTAssertTrue(context.omissions.contains { $0.reason == .invalidUTF8 })
		XCTAssertTrue(context.omissions.contains { $0.reason == .sliceOutOfBounds })
		XCTAssertTrue(context.omissions.contains { $0.reason == .orphanSlice })
		XCTAssertTrue(context.omissions.contains { $0.reason == .codemapLanguageUnsupported })
		XCTAssertFalse(context.content.contains("orphan"))
		XCTAssertFalse(context.isCompleteForProvider)
	}

	func testOverLimitPersistedSnapshotIsIncompleteAndNeverDropsSliceIntentToFullFile() throws {
		let root = try temporaryDirectory()
		var slices: [String: [LineRange]] = [:]
		for index in 0 ... HeadlessWorkspaceContextBuilder.maximumSelectionEntries {
			let path = root.appendingPathComponent("slice-\(index).txt").path
			slices[path] = [LineRange(start: 2, end: 2)]
		}
		let included = Set(slices.keys.sorted().prefix(HeadlessWorkspaceContextBuilder.maximumSelectionEntries))
		let droppedPath = try XCTUnwrap(slices.keys.first { !included.contains($0) })
		try "FULL_FILE_MUST_NOT_APPEAR".write(toFile: droppedPath, atomically: true, encoding: .utf8)

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(selectedPaths: [droppedPath], slices: slices),
			maximumBytes: 4_096
		)
		XCTAssertTrue(context.truncated)
		XCTAssertFalse(context.isCompleteForProvider)
		XCTAssertFalse(context.content.contains("FULL_FILE_MUST_NOT_APPEAR"))
		XCTAssertTrue(context.omissions.contains { $0.path.contains((droppedPath as NSString).lastPathComponent) && $0.reason == .invalidSlice })

		let oversizedSelection = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(
				selectedPaths: Array(repeating: droppedPath, count: HeadlessWorkspaceContextBuilder.maximumSelectionEntries + 1)
			),
			maximumBytes: 4_096
		)
		XCTAssertTrue(oversizedSelection.truncated)
		XCTAssertFalse(oversizedSelection.isCompleteForProvider)
	}

	func testPersistedManualCodemapPathsAreCappedFailClosed() throws {
		let root = try temporaryDirectory()
		let paths = (0 ... HeadlessWorkspaceContextBuilder.maximumSelectionEntries).map {
			root.appendingPathComponent("missing-\($0).swift").path
		}

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(
				autoCodemapPaths: paths,
				codemapAutoEnabled: false
			),
			maximumBytes: 4_096
		)

		XCTAssertTrue(context.truncated)
		XCTAssertFalse(context.isCompleteForProvider)
		XCTAssertEqual(context.omissions.count, HeadlessWorkspaceContextBuilder.maximumSelectionEntries)
		XCTAssertFalse(context.omissions.contains { $0.path == "missing-\(HeadlessWorkspaceContextBuilder.maximumSelectionEntries).swift" })
	}

	func testPersistedMixedRepresentationsShareOneGlobalPathCap() throws {
		let root = try temporaryDirectory()
		let selected = (0 ..< HeadlessWorkspaceContextBuilder.maximumSelectionEntries).map {
			root.appendingPathComponent("selected-\($0).txt").path
		}
		let manual = root.appendingPathComponent("manual.swift").path

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(
				selectedPaths: selected,
				autoCodemapPaths: [manual],
				codemapAutoEnabled: false
			),
			maximumBytes: 4_096
		)

		XCTAssertTrue(context.truncated)
		XCTAssertFalse(context.isCompleteForProvider)
		XCTAssertEqual(context.omissions.count, HeadlessWorkspaceContextBuilder.maximumSelectionEntries)
		XCTAssertFalse(context.omissions.contains { $0.path == "manual.swift" })
	}

	func testInRootSymlinkEscapingRootIsNeverRead() throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		let secret = outside.appendingPathComponent("secret.txt")
		let link = root.appendingPathComponent("selected.txt")
		try "OUTSIDE_SECRET_SENTINEL".write(to: secret, atomically: true, encoding: .utf8)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(selectedPaths: [link.path]),
			maximumBytes: 4_096
		)

		XCTAssertTrue(context.entries.isEmpty)
		XCTAssertFalse(context.omissions.isEmpty)
		XCTAssertFalse(context.content.contains("OUTSIDE_SECRET_SENTINEL"))
		XCTAssertFalse(context.isCompleteForProvider)
	}

	func testEmptyAndInvalidPersistedSlicesNeverExpandToFullFile() throws {
		let root = try temporaryDirectory()
		let source = root.appendingPathComponent("source.txt")
		try "FULL_FILE_MUST_NOT_APPEAR".write(to: source, atomically: true, encoding: .utf8)

		let invalidRange = try JSONDecoder().decode(
			LineRange.self,
			from: Data(#"{"start":3,"end":1}"#.utf8)
		)
		for ranges: [LineRange] in [[], [invalidRange]] {
			let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
				selection: WorkspaceSelectionSnapshot(
					selectedPaths: [source.path],
					slices: [source.path: ranges]
				),
				maximumBytes: 4_096
			)

			XCTAssertTrue(context.entries.isEmpty)
			XCTAssertFalse(context.content.contains("FULL_FILE_MUST_NOT_APPEAR"))
			XCTAssertTrue(context.omissions.contains {
				$0.reason == .invalidSlice || $0.reason == .sliceOutOfBounds
			})
		}
	}

	func testSliceAssemblerReportsInvalidIntentInsteadOfReturningFullContent() {
		let source = "one\r\ntwo\r\nthree"
		let assembly = WorkspaceSliceAssemblyBuilder.build(
			from: source,
			ranges: [LineRange(start: 9, end: 10)]
		)

		XCTAssertTrue(assembly.isInvalidSlice)
		XCTAssertFalse(assembly.isFullFile)
		XCTAssertTrue(assembly.segments.isEmpty)
		XCTAssertEqual(assembly.combinedText, "")
		XCTAssertEqual(assembly.detectedLineEnding, "\r\n")
	}

	func testSelectedAutomaticCodemapParseAndOversizeFailuresAreFailClosedOmissions() throws {
		XCTAssertEqual(
			HeadlessWorkspaceContextBuilder.automaticCodemapOmissionReason(
				for: .parseFailed(.parserReturnedNilTree)
			),
			.codemapParseFailed
		)
		XCTAssertEqual(
			HeadlessWorkspaceContextBuilder.automaticCodemapOmissionReason(
				for: .oversize(.lines(actual: 2, limit: 1))
			),
			.sourceTooLarge
		)
		let root = try temporaryDirectory()
		let consumer = root.appendingPathComponent("Consumer.swift")
		let source = String(repeating: "struct Consumer { let dependency: Dependency }\n", count: 25_001)
		try source.write(to: consumer, atomically: true, encoding: .utf8)

		let context = HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(selectedPaths: [consumer.path], codemapAutoEnabled: true),
			maximumBytes: 2_000_000
		)

		XCTAssertTrue(context.content.contains("struct Consumer"))
		XCTAssertTrue(context.omissions.contains { $0.path == "Consumer.swift" && $0.reason == .sourceTooLarge })
		XCTAssertFalse(context.isCompleteForProvider)
	}

	func testAutomaticCodemapCandidatesRespectIgnoreRulesAndDeduplicateNestedRoots() throws {
		let parent = try temporaryDirectory()
		let nested = parent.appendingPathComponent("nested", isDirectory: true)
		try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
		let consumer = parent.appendingPathComponent("Consumer.swift")
		let ignored = parent.appendingPathComponent("Ignored.swift")
		let dependency = nested.appendingPathComponent("Dependency.swift")
		try "nested/\nIgnored.swift\n".write(to: parent.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		try "struct Consumer {\n    let dependency: Dependency\n    let other: Other\n}\n".write(
			to: consumer,
			atomically: true,
			encoding: .utf8
		)
		try "struct Other {}\n".write(to: ignored, atomically: true, encoding: .utf8)
		try "struct Dependency {\n    let value: String\n    func run() -> String { value }\n}\n".write(
			to: dependency,
			atomically: true,
			encoding: .utf8
		)
		let inventory = try HeadlessWorkspacePathIndex(roots: [parent.path, nested.path]).desktopFileEntries()
		XCTAssertEqual(inventory.map(\.displayPath), ["root[0]:Consumer.swift", "root[1]:Dependency.swift"])

		let context = HeadlessWorkspaceContextBuilder(roots: [parent.path, nested.path]).build(
			selection: WorkspaceSelectionSnapshot(selectedPaths: [consumer.path], codemapAutoEnabled: true),
			maximumBytes: 64_000
		)

		XCTAssertTrue(context.omissions.isEmpty, "omissions: \(context.omissions)")
		XCTAssertEqual(context.automaticCodemapPaths, ["root[1]:Dependency.swift"])
		XCTAssertEqual(context.content.components(separatedBy: "File: root[1]:Dependency.swift").count - 1, 1)
		XCTAssertFalse(context.content.contains("File: root[0]:Ignored.swift"))
	}

	func testCodemapCandidateInventoryAppliesItsLimitAfterIgnoreAndNestedRootDedupe() throws {
		let parent = try temporaryDirectory()
		let nested = parent.appendingPathComponent("nested", isDirectory: true)
		try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
		try "nested/\nIgnored.swift\n".write(to: parent.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		try "struct Ignored {}\n".write(to: parent.appendingPathComponent("Ignored.swift"), atomically: true, encoding: .utf8)
		for index in 0 ..< 4 {
			try "struct Candidate\(index) {}\n".write(
				to: nested.appendingPathComponent("Candidate\(index).swift"),
				atomically: true,
				encoding: .utf8
			)
		}

		let candidates = try HeadlessWorkspacePathIndex(roots: [parent.path, nested.path])
			.codemapCandidateEntries(limit: 2)

		XCTAssertEqual(candidates.count, 2)
		XCTAssertEqual(Set(candidates.map(\.absolutePath)).count, 2)
		XCTAssertFalse(candidates.contains { $0.displayPath.contains("Ignored.swift") })
	}

	func testManualAndAutomaticCodemapsUseOneHopGraphAndRenderEachPathExactlyOnce() throws {
		let root = try temporaryDirectory()
		let consumer = root.appendingPathComponent("Consumer.swift")
		let dependency = root.appendingPathComponent("Dependency.swift")
		try "struct Consumer { let dependency: Dependency }\n".write(
			to: consumer,
			atomically: true,
			encoding: .utf8
		)
		try "struct Dependency {\n    let value: String\n    func run() -> String { value }\n}\n".write(
			to: dependency,
			atomically: true,
			encoding: .utf8
		)
		let builder = HeadlessWorkspaceContextBuilder(roots: [root.path])

		let automatic = builder.build(
			selection: WorkspaceSelectionSnapshot(selectedPaths: [consumer.path], codemapAutoEnabled: true),
			maximumBytes: 32_768
		)
		XCTAssertTrue(automatic.omissions.isEmpty)
		XCTAssertEqual(automatic.automaticCodemapPaths, ["Dependency.swift"])
		XCTAssertEqual(automatic.entries.filter { $0.codemapSource == .automatic }.map(\.path), ["Dependency.swift"])
		XCTAssertEqual(automatic.content.components(separatedBy: "File: Dependency.swift").count - 1, 1)
		XCTAssertTrue(automatic.content.hasPrefix("<file_map>\nFile: Dependency.swift\nImports:\n---"))
		XCTAssertTrue(automatic.content.contains("<file_contents>\nFile: Consumer.swift\n```swift"))

		let manualWins = builder.build(
			selection: WorkspaceSelectionSnapshot(
				selectedPaths: [consumer.path],
				autoCodemapPaths: [dependency.path],
				codemapAutoEnabled: true
			),
			maximumBytes: 32_768
		)
		XCTAssertTrue(manualWins.omissions.isEmpty)
		XCTAssertTrue(manualWins.automaticCodemapPaths.isEmpty)
		XCTAssertEqual(manualWins.entries.filter { $0.codemapSource == .manual }.map(\.path), ["Dependency.swift"])
		XCTAssertEqual(manualWins.content.components(separatedBy: "File: Dependency.swift").count - 1, 1)
	}

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.standardizedFileURL
	}
}
