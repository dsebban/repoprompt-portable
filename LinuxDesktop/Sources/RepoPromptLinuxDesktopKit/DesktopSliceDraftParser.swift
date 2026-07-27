import Foundation
import RepoPromptHeadless

public struct DesktopSliceDraftError: Error, Equatable, Sendable {
	public let line: Int
	public let message: String

	public init(line: Int, message: String) {
		self.line = line
		self.message = message
	}
}

extension DesktopSliceDraftError: LocalizedError {
	public var errorDescription: String? { "Slice draft line \(line): \(message)" }
}

public enum DesktopSliceDraftParser {
	public static func parse(_ draft: String) throws -> [PortableLineRange] {
		var ranges: [PortableLineRange] = []
		for (offset, rawLine) in draft.components(separatedBy: .newlines).enumerated() {
			let lineNumber = offset + 1
			let line = rawLine.trimmingCharacters(in: .whitespaces)
			guard !line.isEmpty else { continue }

			let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
			let rangeText = parts[0].trimmingCharacters(in: .whitespaces)
			let bounds = rangeText.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
			guard bounds.count <= 2,
				let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
				start > 0
			else {
				throw DesktopSliceDraftError(line: lineNumber, message: "use a positive line or range such as 12 or 20-35.")
			}
			let end: Int
			if bounds.count == 2 {
				guard let parsed = Int(bounds[1].trimmingCharacters(in: .whitespaces)), parsed >= start else {
					throw DesktopSliceDraftError(line: lineNumber, message: "range end must be at least the start line.")
				}
				end = parsed
			} else {
				end = start
			}

			let description: String?
			if parts.count == 2 {
				let value = parts[1].trimmingCharacters(in: .whitespaces)
				guard !value.isEmpty else {
					throw DesktopSliceDraftError(line: lineNumber, message: "text after `|` must not be empty.")
				}
				description = unescapeDescription(value)
			} else {
				description = nil
			}
			ranges.append(PortableLineRange(startLine: start, endLine: end, description: description))
		}
		guard !ranges.isEmpty else {
			throw DesktopSliceDraftError(line: 1, message: "enter at least one line or range.")
		}
		return ranges
	}

	public static func format(_ ranges: [PortableLineRange]) -> String {
		ranges.map { range in
			var line = range.startLine == range.endLine
				? "\(range.startLine)"
				: "\(range.startLine)-\(range.endLine)"
			if let description = range.description { line += " | \(escapeDescription(description))" }
			return line
		}.joined(separator: "\n")
	}

	private static func escapeDescription(_ description: String) -> String {
		description
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\r", with: "\\r")
			.replacingOccurrences(of: "\n", with: "\\n")
	}

	private static func unescapeDescription(_ description: String) -> String {
		var unescaped = ""
		var characters = description.makeIterator()
		while let character = characters.next() {
			guard character == "\\", let escaped = characters.next() else {
				unescaped.append(character)
				continue
			}
			switch escaped {
			case "\\": unescaped.append("\\")
			case "r": unescaped.append("\r")
			case "n": unescaped.append("\n")
			default:
				unescaped.append("\\")
				unescaped.append(escaped)
			}
		}
		return unescaped
	}
}
