import Crypto
import Foundation

package enum PortableCodeMap {
	package static let supportedFileExtensions = Set(CodeMapSyntaxEngine.extensionToLanguage.keys)

	package static func supports(path: String) -> Bool {
		CodeMapSyntaxEngine.isSupportedFileExtension(URL(fileURLWithPath: path).pathExtension)
	}

	package static func artifact(source: String, path: String) throws -> CodeMapSyntaxArtifactOutcome? {
		let fileExtension = URL(fileURLWithPath: path).pathExtension
		guard let language = CodeMapSyntaxEngine.shared.language(forFileExtension: fileExtension) else {
			return nil
		}
		let data = Data(source.utf8)
		let snapshot = CodeMapCoreSourceSnapshot(
			rawByteCount: data.count,
			rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
			decoderPolicy: .workspaceAutomaticV1,
			decodeResult: .decoded(CodeMapDecodedSource(
				text: source,
				detectedEncodingRawValue: String.Encoding.utf8.rawValue
			))
		)
		return try CodeMapSyntaxArtifactBuilder.build(source: snapshot, language: language)
	}

	package static func render(_ artifact: CodeMapSyntaxArtifact, displayPath: String) -> String {
		(["File: \(displayPath)", "Imports:"] + artifact.imports.map { "  - \($0)" })
			.joined(separator: "\n") + artifact.apiDescription
	}
}
