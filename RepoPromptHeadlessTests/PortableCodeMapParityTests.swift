import Foundation
@testable import RepoPromptCodeMap
import XCTest

final class PortableCodeMapParityTests: XCTestCase {
	private let fixtures = [
		"c/smoke.c",
		"go/smoke.go",
		"py/smoke.py",
		"swift/smoke.swift",
		"ts/smoke.ts",
		"cs/smoke.cs",
		"java/smoke.java",
		"js/smoke.js",
		"rb/smoke.rb",
		"rs/smoke.rs",
		"cpp/edge_methods.cpp",
		"php/edge_namespaces.php",
		"tsx/component.tsx"
	]

	func testLinuxSafeGeneratorMatchesCanonicalCECodemapBytesForEverySupportedLanguage() throws {
		let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
			.appendingPathComponent("CodeMapParity")
		for relativePath in fixtures {
			let sourceURL = root.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
			let source = try String(contentsOf: sourceURL, encoding: .utf8)
			guard case .ready(let artifact)? = try PortableCodeMap.artifact(source: source, path: relativePath) else {
				return XCTFail("No codemap artifact for \(relativePath)")
			}
			let rendered = PortableCodeMap.render(artifact, displayPath: "<ROOT>/\(relativePath)")
			let directory = (relativePath as NSString).deletingLastPathComponent
			let base = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
			let goldenURL = root.appendingPathComponent("Goldens/\(directory)_\(base).codemap.txt")
			let expected = try String(contentsOf: goldenURL, encoding: .utf8)
			XCTAssertEqual(Data(rendered.utf8), Data(expected.utf8), relativePath)
		}
	}

	func testFoundationRegexShimUsesPCRE2LFOnlyLineSemantics() {
		let subject = "café\u{2028}value"
		let pattern = CodeMapPCRE2Pattern("^(.+)$", multilineAnchors: true)
		XCTAssertEqual(pattern.firstCapture(in: subject), subject)
		XCTAssertTrue(pattern.wholeMatch(in: subject))
	}

	func testSupportedExtensionSetMatchesCECore() {
		XCTAssertEqual(PortableCodeMap.supportedFileExtensions, Set([
			"c", "cpp", "cs", "go", "java", "js", "php", "py", "rb", "rs", "swift", "ts", "tsx"
		]))
	}
}
