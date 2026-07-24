import Foundation
import MCP
@testable import RepoPromptPortableCLI
import XCTest

final class PortableCLIArgumentsTests: XCTestCase {
	func testParsesImplicitCommandAndForcesEphemeralReadOnlyOptions() throws {
		let sessionID = UUID()
		let parsed = try PortableCLIArguments.parse([
			"--root", "/tmp/one",
			"--root=/tmp/two",
			"--workspace-name", "Workspace",
			"--session-id", sessionID.uuidString,
			"read_file", "{\"path\":\"README.md\"}"
		])

		XCTAssertEqual(parsed.options.roots, ["/tmp/one", "/tmp/two"])
		XCTAssertEqual(parsed.options.workspaceName, "Workspace")
		XCTAssertEqual(parsed.options.sessionID, sessionID)
		XCTAssertFalse(parsed.options.persist)
		XCTAssertFalse(parsed.options.allowWrites)
		XCTAssertEqual(parsed.commands, [
			PortableCLICommand(name: "read_file", arguments: ["path": .string("README.md")])
		])
	}

	func testParsesExecCommandsInOrderWithWholeJSONObject() throws {
		let parsed = try PortableCLIArguments.parse([
			"-e", "manage_selection {\"op\":\"set\",\"paths\":[\"a b.txt\"]}",
			"--exec", "context_builder {\"instructions\":\"Build this.\"}"
		])

		XCTAssertEqual(parsed.commands.map(\.name), ["manage_selection", "context_builder"])
		XCTAssertEqual(parsed.commands[0].arguments["paths"], .array([.string("a b.txt")]))
		XCTAssertEqual(parsed.commands[1].arguments["instructions"], .string("Build this."))
	}

	func testRejectsMixedImplicitAndExecCommands() {
		XCTAssertThrowsError(try PortableCLIArguments.parse(["-e", "read_file {}", "get_file_tree"]))
	}

	func testRejectsMalformedOrNonObjectJSON() {
		for json in ["[]", "1", "{", "{\"path\":\"a\"} trailing"] {
			XCTAssertThrowsError(try PortableCLIArguments.parse(["read_file", json]), "Accepted \(json)")
		}
	}

	func testRejectsExtraUnquotedArguments() {
		XCTAssertThrowsError(try PortableCLIArguments.parse(["read_file", "{\"path\":", "\"a\"}"]))
	}

	func testHelpDoesNotRequireACommand() throws {
		let parsed = try PortableCLIArguments.parse(["--help"])
		XCTAssertTrue(parsed.help)
		XCTAssertTrue(parsed.commands.isEmpty)
	}
}
