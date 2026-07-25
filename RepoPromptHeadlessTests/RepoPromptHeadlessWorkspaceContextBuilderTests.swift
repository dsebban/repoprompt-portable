import Foundation
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
		let firstSlice = try XCTUnwrap(context.content.range(of: "second.txt [lines 1-1]"))
		let secondSlice = try XCTUnwrap(context.content.range(of: "second.txt [lines 3-4]"))
		let fullFile = try XCTUnwrap(context.content.range(of: "first.txt [full]"))
		XCTAssertLessThan(firstSlice.lowerBound, secondSlice.lowerBound)
		XCTAssertLessThan(secondSlice.lowerBound, fullFile.lowerBound)
		XCTAssertTrue(context.content.contains("one"))
		XCTAssertTrue(context.content.contains("three\nfour"))
		XCTAssertLessThanOrEqual(context.contentByteCount, 4_096)
		XCTAssertTrue(context.isCompleteForProvider)
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
		XCTAssertTrue(empty.content.contains("No readable files are selected."))
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
		XCTAssertTrue(context.omissions.contains { $0.reason == .autoCodemapUnsupported })
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
		let included = Set(slices.prefix(HeadlessWorkspaceContextBuilder.maximumSelectionEntries).map(\.key))
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

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.standardizedFileURL
	}
}
