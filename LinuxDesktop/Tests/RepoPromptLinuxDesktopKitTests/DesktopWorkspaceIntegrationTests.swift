import Foundation
import RepoPromptHeadless
import XCTest

final class DesktopWorkspaceIntegrationTests: XCTestCase {
	func testTypedDesktopWorkflowMovesBetweenFullSliceAndManualCodemapModes() async throws {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let source = root.appendingPathComponent("Feature.swift")
		try "struct Feature {\n\tlet value: Int\n\tfunc run() {}\n}\n".write(to: source, atomically: true, encoding: .utf8)

		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		let service = PortableWorkspaceService(bootstrap: bootstrap)
		let files = try await service.files()
		let file = try XCTUnwrap(files.first { $0.absolutePath == source.path })
		XCTAssertTrue(file.codemapSupported)

		let full = try await service.addFiles([source.path])
		XCTAssertEqual(full.selectedFiles.map(\.absolutePath), [source.path])

		let sliced = try await service.setSlices([
			PortableSliceSelection(
				path: source.path,
				ranges: [PortableLineRange(startLine: 2, endLine: 3, description: "public API")]
			)
		])
		XCTAssertEqual(sliced.slices.first?.ranges.first?.description, "public API")
		let slicePreview = try await service.previewContext()
		XCTAssertTrue(slicePreview.content.contains("(lines 2-3: public API)"))
		XCTAssertEqual(slicePreview.entries.first?.kind, .slice)

		let manual = try await service.demoteToManualCodemap([source.path])
		XCTAssertTrue(manual.selectedFiles.isEmpty)
		XCTAssertEqual(manual.manualCodemapFiles.map(\.absolutePath), [source.path])
		XCTAssertFalse(manual.codemapAutoEnabled)

		let automatic = try await service.setAutomaticCodemapsEnabled(true)
		XCTAssertTrue(automatic.codemapAutoEnabled)
		let promoted = try await service.promoteToFull([source.path])
		XCTAssertTrue(promoted.manualCodemapFiles.isEmpty)
		XCTAssertEqual(promoted.selectedFiles.map(\.absolutePath), [source.path])
		let fullPreview = try await service.previewContext()
		XCTAssertEqual(fullPreview.entries.first?.kind, .full)
		XCTAssertTrue(fullPreview.content.contains("File: Feature.swift"))
	}
}
