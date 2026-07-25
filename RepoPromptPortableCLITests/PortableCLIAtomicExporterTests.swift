import Foundation
@testable import RepoPromptPortableCLI
import XCTest

final class PortableCLIAtomicExporterTests: XCTestCase {
	func testWritesExactJSONLWithFinalNewlineAndMode0600() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let destination = root.appendingPathComponent("résult.jsonl")
		let data = Data("{\"message\":\"שלום\"}\n{\"ok\":true}\n".utf8)

		try PortableCLIAtomicExporter.write(data, to: destination.path)

		XCTAssertEqual(try Data(contentsOf: destination), data)
		let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
		XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
	}

	func testExistingFileAndSymlinkAreNeverOverwritten() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let existing = root.appendingPathComponent("existing.jsonl")
		let target = root.appendingPathComponent("target.jsonl")
		let link = root.appendingPathComponent("link.jsonl")
		try Data("original".utf8).write(to: existing)
		try Data("target".utf8).write(to: target)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

		XCTAssertThrowsError(try PortableCLIAtomicExporter.write(Data("replacement".utf8), to: existing.path))
		XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
		XCTAssertThrowsError(try PortableCLIAtomicExporter.write(Data("replacement".utf8), to: link.path))
		XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target")
		XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
		XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") })
	}

	func testRejectsNonStickySharedWritableDirectory() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
		let destination = root.appendingPathComponent("result.jsonl")

		XCTAssertThrowsError(try PortableCLIAtomicExporter.write(Data("private".utf8), to: destination.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
	}

	func testValidLongDestinationNameUsesShortTemporarySibling() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let destination = root.appendingPathComponent(String(repeating: "x", count: 220) + ".jsonl")
		try PortableCLIAtomicExporter.write(Data("{}\n".utf8), to: destination.path)
		XCTAssertEqual(try Data(contentsOf: destination), Data("{}\n".utf8))
	}

	func testInvalidDestinationLeavesNoPartialFileOrTemporarySibling() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let missingParent = root.appendingPathComponent("missing", isDirectory: true)
		let destination = missingParent.appendingPathComponent("result.jsonl")

		XCTAssertThrowsError(try PortableCLIAtomicExporter.write(Data("partial".utf8), to: destination.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
		XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
		XCTAssertThrowsError(try PortableCLIAtomicExporter.write(Data(), to: root.path + "/"))
	}

	private func temporaryDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.standardizedFileURL
	}
}
