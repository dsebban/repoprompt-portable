import Foundation

package enum CanonicalPromptPackaging {
	package static func fullFileBlock(displayPath: String, fileName: String, content: String) -> String {
		"File: \(displayPath)\n\(codeFenceStart(for: fileName))\n\(content)\n```"
	}

	package static func sliceFileBlock(
		displayPath: String,
		fileName: String,
		segments: [WorkspaceSliceSegment]
	) -> String {
		var lines = ["File: \(displayPath)"]
		let fence = codeFenceStart(for: fileName)
		for (index, segment) in segments.enumerated() {
			let range = segment.range.start == segment.range.end
				? "\(segment.range.start)"
				: "\(segment.range.start)-\(segment.range.end)"
			if let description = segment.range.description, !description.isEmpty {
				lines.append("(lines \(range): \(description))")
			} else {
				lines.append("(lines \(range))")
			}
			lines.append(fence)
			lines.append(segment.text)
			lines.append("```")
			if index != segments.count - 1 { lines.append("") }
		}
		return lines.joined(separator: "\n")
	}

	package static func package(fileMapBlocks: [String] = [], fileContentBlocks: [String]) -> String {
		var sections: [String] = []
		let map = fileMapBlocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
		if !map.isEmpty {
			sections.append("<file_map>\n\(map)\n</file_map>")
		}
		let contents = fileContentBlocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
		if !contents.isEmpty {
			sections.append("<file_contents>\n\(contents)\n</file_contents>")
		}
		return sections.joined(separator: "\n\n")
	}

	private static func codeFenceStart(for fileName: String) -> String {
		let pathExtension = URL(fileURLWithPath: fileName).pathExtension
		return pathExtension.isEmpty ? "```" : "```\(pathExtension)"
	}
}
