import Foundation
import MCP
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessTests: XCTestCase {
	func testPortableInitializeInstructionsDescribeExplicitSelectionContract() {
		let instructions = HeadlessMCPService.initializeInstructions
		XCTAssertTrue(instructions.contains("manage_selection is the only selection mutation interface"))
		XCTAssertTrue(instructions.contains("context_builder renders only the current explicit"))
		XCTAssertTrue(instructions.contains("provider-backed plan/review/pro_edit"))
		XCTAssertTrue(instructions.contains("pro_edit produces instructions only and never writes or executes"))
		XCTAssertTrue(instructions.contains("oracle_send remains limited to chat/question/plan/review"))
		XCTAssertTrue(instructions.contains("always snapshots and attaches the current explicit selection"))
		XCTAssertTrue(instructions.contains("Portable tool schema version: \(PortableContract.toolSchemaVersion)."))
	}

	func testOptionsParseRootsAndNoPersist() throws {
		let id = UUID()
		let options = try HeadlessOptions.parse([
			"--root", "/tmp/one",
			"--root=/tmp/two",
			"--workspace-name", "Headless",
			"--session-id", id.uuidString,
			"--state-dir=/tmp/state",
			"--no-persist",
			"--allow-writes",
			"--log-level", "debug"
		])

		XCTAssertEqual(options.roots, ["/tmp/one", "/tmp/two"])
		XCTAssertEqual(options.workspaceName, "Headless")
		XCTAssertEqual(options.sessionID, id)
		XCTAssertEqual(options.stateDir, "/tmp/state")
		XCTAssertFalse(options.persist)
		XCTAssertTrue(options.allowWrites)
		XCTAssertEqual(options.logLevel, "debug")
	}

	func testBootstrapDefaultsRootToCurrentDirectoryAndSkipsStateDirectoryWhenNoPersist() async throws {
		let root = try temporaryDirectory()
		let options = HeadlessOptions(persist: false)
		let result = try await HeadlessWorkspaceBootstrap.bootstrap(options: options, currentDirectory: root.path)

		XCTAssertEqual(result.roots, [root.path])
		XCTAssertNil(result.stateDirectory)
		let snapshot = await result.session.snapshot()
		XCTAssertEqual(snapshot.rootPaths, [root.path])
	}

	func testBootstrapResolvesRelativeRootsAgainstCurrentDirectory() throws {
		let root = try temporaryDirectory()
		let previous = FileManager.default.currentDirectoryPath
		defer { FileManager.default.changeCurrentDirectoryPath(previous) }
		XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(root.path))

		let roots = try HeadlessWorkspaceBootstrap.validatedRoots(["."])
		XCTAssertEqual(roots, [root.path])
	}

	func testCatalogReadFileAndSelection() async throws {
		let root = try temporaryDirectory()
		let fileURL = root.appendingPathComponent("note.txt")
		try "one\ntwo\nthree".write(to: fileURL, atomically: true, encoding: .utf8)

		let options = HeadlessOptions(roots: [root.path], persist: false)
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(options: options)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		let read = await catalog.call(name: "read_file", arguments: [
			"path": .string("note.txt"),
			"start_line": .int(2),
			"limit": .int(1)
		])
		XCTAssertEqual(read.isError, false)
		XCTAssertTrue(text(read).contains("two"))
		XCTAssertTrue(text(read).contains("\"first_line\" : 2"))

		let setSelection = await catalog.call(name: "manage_selection", arguments: [
			"op": .string("set"),
			"paths": .array([.string("note.txt")])
		])
		XCTAssertEqual(setSelection.isError, false)
		XCTAssertTrue(text(setSelection).contains("note.txt"))
	}

	func testCatalogDeniesWriteToolByPolicy() async throws {
		let root = try temporaryDirectory()
		let options = HeadlessOptions(roots: [root.path], persist: false)
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(options: options)
		let catalog = HeadlessToolCatalog(
			roots: bootstrap.roots,
			session: bootstrap.session,
			router: bootstrap.router,
			allowWrites: false
		)

		let result = await catalog.call(name: "file_actions", arguments: ["action": .string("delete")])
		XCTAssertEqual(result.isError, true)
		XCTAssertTrue(text(result).contains("policy_denied"))
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
