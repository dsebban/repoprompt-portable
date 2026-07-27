import Foundation
import MCP
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessFileSearchSecurityTests: XCTestCase {
	func testFileSearchSchemaAdvertisesBoundedResultAndContextInputs() async throws {
		let root = try temporaryDirectory()
		let catalog = try await makeCatalog(root: root)
		let tools = await catalog.tools()
		let tool = try XCTUnwrap(tools.first { $0.name == "file_search" })
		guard
			case .object(let schema) = tool.inputSchema,
			case .object(let properties)? = schema["properties"],
			case .object(let patternSchema)? = properties["pattern"],
			case .object(let regexSchema)? = properties["regex"],
			case .object(let resultSchema)? = properties["max_results"],
			case .object(let contextSchema)? = properties["context_lines"]
		else {
			return XCTFail("Expected bounded file_search schemas")
		}

		XCTAssertEqual(
			patternSchema["maxLength"]?.intValue,
			HeadlessToolCatalog.maximumFileSearchPatternBytes
		)
		XCTAssertEqual(regexSchema["enum"]?.arrayValue?.compactMap(\.boolValue), [false])
		XCTAssertEqual(resultSchema["minimum"]?.intValue, 1)
		XCTAssertEqual(resultSchema["maximum"]?.intValue, HeadlessToolCatalog.maximumFileSearchResults)
		XCTAssertEqual(contextSchema["minimum"]?.intValue, 0)
		XCTAssertEqual(contextSchema["maximum"]?.intValue, HeadlessToolCatalog.maximumFileSearchContextLines)
	}

	func testFileSearchNeverReadsOutsideRootRegularFileSymlink() async throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		let outsideFile = outside.appendingPathComponent("secret.txt")
		try Data("OUTSIDE_SEARCH_SENTINEL".utf8).write(to: outsideFile)
		try FileManager.default.createSymbolicLink(
			at: root.appendingPathComponent("linked-secret.txt"),
			withDestinationURL: outsideFile
		)
		try Data("inside".utf8).write(to: root.appendingPathComponent("inside.txt"))
		let catalog = try await makeCatalog(root: root)

		let result = await catalog.call(name: "file_search", arguments: [
			"pattern": .string("OUTSIDE_SEARCH_SENTINEL"),
			"mode": .string("content")
		])
		let object = try json(result)

		XCTAssertEqual(result.isError, false)
		XCTAssertEqual(object["total_matches"] as? Int, 0)
		XCTAssertEqual((object["matches"] as? [[String: Any]])?.count, 0)
	}

	func testRootContainedEnumerationThenSymlinkSwapFailsClosed() throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		let insideFile = root.appendingPathComponent("inside.txt")
		let outsideFile = outside.appendingPathComponent("outside.txt")
		let link = root.appendingPathComponent("candidate.txt")
		try Data("inside".utf8).write(to: insideFile)
		try Data("outside".utf8).write(to: outsideFile)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: insideFile)
		let index = HeadlessWorkspacePathIndex(roots: [root.path])

		let enumeration = try index.rootContainedFiles(limit: 10)
		XCTAssertTrue(enumeration.files.contains(link.path))
		try FileManager.default.removeItem(at: link)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)

		XCTAssertThrowsError(
			try HeadlessSecureFileReader.read(
				path: link.path,
				roots: index.roots,
				maximumBytes: HeadlessToolCatalog.maximumFileSearchBytesPerFile
			)
		) { error in
			guard case HeadlessSecureFileError.outsideWorkspace = error else {
				return XCTFail("Expected outsideWorkspace, got \(error)")
			}
		}
	}

	func testRootContainedEnumerationBoundsFileCountAndExcludesOutsideSymlink() throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		for name in ["a.txt", "b.txt", "c.txt"] {
			try Data(name.utf8).write(to: root.appendingPathComponent(name))
		}
		let outsideFile = outside.appendingPathComponent("outside.txt")
		try Data("outside".utf8).write(to: outsideFile)
		try FileManager.default.createSymbolicLink(
			at: root.appendingPathComponent("outside-link.txt"),
			withDestinationURL: outsideFile
		)

		let enumeration = try HeadlessWorkspacePathIndex(roots: [root.path])
			.rootContainedFiles(limit: 2)

		XCTAssertEqual(enumeration.files.count, 2)
		XCTAssertTrue(enumeration.truncated)
		XCTAssertFalse(enumeration.files.contains { $0.hasSuffix("outside-link.txt") })
	}

	func testFileSearchCapsReturnedResultsWhileCountingBoundedScan() async throws {
		let root = try temporaryDirectory()
		try Data("needle\nneedle\nneedle".utf8).write(to: root.appendingPathComponent("matches.txt"))
		let catalog = try await makeCatalog(root: root)

		let result = await catalog.call(name: "file_search", arguments: [
			"pattern": .string("needle"),
			"mode": .string("content"),
			"max_results": .int(2)
		])
		let object = try json(result)

		XCTAssertEqual(result.isError, false)
		XCTAssertEqual(object["total_matches"] as? Int, 3)
		XCTAssertEqual((object["matches"] as? [[String: Any]])?.count, 2)
		XCTAssertEqual(object["truncated"] as? Bool, true)
	}

	func testFileSearchRejectsOutOfContractResultAndContextLimits() async throws {
		let root = try temporaryDirectory()
		let catalog = try await makeCatalog(root: root)

		for arguments: [String: Value] in [
			[
				"pattern": .string("x"),
				"max_results": .int(HeadlessToolCatalog.maximumFileSearchResults + 1)
			],
			[
				"pattern": .string("x"),
				"context_lines": .int(HeadlessToolCatalog.maximumFileSearchContextLines + 1)
			]
		] {
			let result = await catalog.call(name: "file_search", arguments: arguments)
			XCTAssertEqual(result.isError, true)
			XCTAssertEqual(try json(result)["code"] as? String, "invalid_params")
		}
	}

	func testFileSearchRejectsOversizedPatternAndDisabledRegex() async throws {
		let root = try temporaryDirectory()
		let catalog = try await makeCatalog(root: root)
		let oversizedPattern = String(
			repeating: "x",
			count: HeadlessToolCatalog.maximumFileSearchPatternBytes + 1
		)

		for arguments: [String: Value] in [
			["pattern": .string(oversizedPattern)],
			["pattern": .string("x"), "regex": .bool(true)],
			["pattern": .string("x"), "regex": .string("false")]
		] {
			let result = await catalog.call(name: "file_search", arguments: arguments)
			XCTAssertEqual(result.isError, true)
			XCTAssertEqual(try json(result)["code"] as? String, "invalid_params")
		}
	}

	func testFileSearchBoundsEscapedOverlappingContextAndAggregateEncodedOutput() async throws {
		let root = try temporaryDirectory()
		let escapedPrefix = String(repeating: "\u{0001}\"\\", count: 1_000)
		let line = "\(escapedPrefix) needle \(String(repeating: "x", count: 2_048))"
		try Data(Array(repeating: line, count: 200).joined(separator: "\n").utf8)
			.write(to: root.appendingPathComponent("overlap.txt"))
		let catalog = try await makeCatalog(root: root)

		let result = await catalog.call(name: "file_search", arguments: [
			"pattern": .string("needle"),
			"mode": .string("content"),
			"max_results": .int(HeadlessToolCatalog.maximumFileSearchResults),
			"context_lines": .int(HeadlessToolCatalog.maximumFileSearchContextLines)
		])
		let encoded = resultText(result)
		let object = try json(result)
		let matches = try XCTUnwrap(object["matches"] as? [[String: Any]])

		XCTAssertEqual(result.isError, false)
		XCTAssertLessThanOrEqual(
			Data(encoded.utf8).count,
			HeadlessToolCatalog.maximumFileSearchOutputBytes
		)
		XCTAssertEqual(object["truncated"] as? Bool, true)
		XCTAssertFalse(matches.isEmpty)
		XCTAssertLessThan(matches.count, 200)
		for match in matches {
			let preview = try XCTUnwrap(match["preview"] as? String)
			let previewData = try JSONSerialization.data(
				withJSONObject: preview,
				options: [.fragmentsAllowed]
			)
			XCTAssertLessThanOrEqual(
				previewData.count,
				HeadlessToolCatalog.maximumFileSearchPreviewJSONBytes
			)
		}
	}

	func testFileSearchObservesCancellationBeforeEnumeration() async throws {
		let root = try temporaryDirectory()
		try Data("needle".utf8).write(to: root.appendingPathComponent("source.txt"))
		let catalog = try await makeCatalog(root: root)

		let result = await withTaskGroup(of: CallTool.Result.self) { group in
			group.addTask {
				while !Task.isCancelled { await Task.yield() }
				return await catalog.call(name: "file_search", arguments: [
					"pattern": .string("needle")
				])
			}
			group.cancelAll()
			return await group.next()!
		}

		XCTAssertEqual(result.isError, true)
		XCTAssertEqual(try json(result)["code"] as? String, "cancelled")
	}

	func testFileSearchSkipsOversizedFileAndReportsIncompleteScan() async throws {
		let root = try temporaryDirectory()
		let file = root.appendingPathComponent("oversized.txt")
		_ = FileManager.default.createFile(atPath: file.path, contents: nil)
		let handle = try FileHandle(forWritingTo: file)
		try handle.seek(toOffset: UInt64(HeadlessToolCatalog.maximumFileSearchBytesPerFile))
		try handle.write(contentsOf: Data("x".utf8))
		try handle.close()
		let catalog = try await makeCatalog(root: root)

		let result = await catalog.call(name: "file_search", arguments: [
			"pattern": .string("x"),
			"mode": .string("content")
		])
		let object = try json(result)

		XCTAssertEqual(result.isError, false)
		XCTAssertEqual(object["total_matches"] as? Int, 0)
		XCTAssertEqual(object["truncated"] as? Bool, true)
	}

	func testFileSearchStopsAtAggregateContentByteBudget() async throws {
		let root = try temporaryDirectory()
		let fileCountAtBudget =
			HeadlessToolCatalog.maximumFileSearchAggregateBytes
			/ HeadlessToolCatalog.maximumFileSearchBytesPerFile
		for index in 0 ... fileCountAtBudget {
			let file = root.appendingPathComponent(String(format: "%02d.txt", index))
			_ = FileManager.default.createFile(atPath: file.path, contents: nil)
			let handle = try FileHandle(forWritingTo: file)
			try handle.write(contentsOf: Data("x".utf8))
			try handle.seek(
				toOffset: UInt64(HeadlessToolCatalog.maximumFileSearchBytesPerFile - 1)
			)
			try handle.write(contentsOf: Data([0]))
			try handle.close()
		}
		let catalog = try await makeCatalog(root: root)

		let result = await catalog.call(name: "file_search", arguments: [
			"pattern": .string("x"),
			"mode": .string("content")
		])
		let object = try json(result)

		XCTAssertEqual(result.isError, false)
		XCTAssertEqual(object["total_matches"] as? Int, fileCountAtBudget)
		XCTAssertEqual((object["matches"] as? [[String: Any]])?.count, fileCountAtBudget)
		XCTAssertEqual(object["truncated"] as? Bool, true)
	}

	private func makeCatalog(root: URL) async throws -> HeadlessToolCatalog {
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		return HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)
	}

	private func json(_ result: CallTool.Result) throws -> [String: Any] {
		let text = resultText(result)
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
	}

	private func resultText(_ result: CallTool.Result) -> String {
		result.content.compactMap { content in
			if case let .text(text, _, _) = content { return text }
			return nil
		}.joined(separator: "\n")
	}

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock { try? FileManager.default.removeItem(at: url) }
		return url.standardizedFileURL
	}
}
