import Foundation

package struct WorkspaceSliceSegment: Equatable, Sendable {
	package let range: LineRange
	package let text: String
}

package struct WorkspaceSliceAssembly: Equatable, Sendable {
	package enum Kind: Equatable, Sendable {
		case fullFile
		case sliced
		case invalidSlice
	}

	package let segments: [WorkspaceSliceSegment]
	package let combinedText: String
	package let totalLines: Int
	package let detectedLineEnding: String
	package let usedRanges: [LineRange]
	package let kind: Kind

	package var isFullFile: Bool { kind == .fullFile }
	package var isInvalidSlice: Bool { kind == .invalidSlice }
}

package enum WorkspaceSliceAssemblyBuilder {
	package static func build(from content: String, ranges: [LineRange]?) -> WorkspaceSliceAssembly {
		let pairs = splitContentPreservingAllLineEndings(content)
		let totalLines = pairs.count
		let detectedEnding = detectedLineEnding(in: pairs)

		func fullFileAssembly() -> WorkspaceSliceAssembly {
			let segment: WorkspaceSliceSegment? = {
				guard totalLines > 0 || !content.isEmpty else { return nil }
				return WorkspaceSliceSegment(
					range: LineRange(start: 1, end: totalLines > 0 ? totalLines : 1),
					text: content
				)
			}()
			return WorkspaceSliceAssembly(
				segments: segment.map { [$0] } ?? [],
				combinedText: content,
				totalLines: totalLines,
				detectedLineEnding: detectedEnding,
				usedRanges: [],
				kind: .fullFile
			)
		}

		func invalidSliceAssembly() -> WorkspaceSliceAssembly {
			WorkspaceSliceAssembly(
				segments: [],
				combinedText: "",
				totalLines: totalLines,
				detectedLineEnding: detectedEnding,
				usedRanges: [],
				kind: .invalidSlice
			)
		}

		guard let ranges, !ranges.isEmpty else { return fullFileAssembly() }
		let normalized = normalize(ranges, maximumLine: totalLines)
		guard !normalized.isEmpty else { return invalidSliceAssembly() }

		var segments: [WorkspaceSliceSegment] = []
		var combined = ""
		for range in normalized {
			let startIndex = range.start - 1
			let endIndex = min(range.end, totalLines)
			guard startIndex < endIndex else { continue }
			let text = pairs[startIndex ..< endIndex].map { $0.line + $0.ending }.joined()
			let effectiveRange = LineRange(start: startIndex + 1, end: endIndex, description: range.description)
			segments.append(WorkspaceSliceSegment(range: effectiveRange, text: text))
			combined += text
		}

		guard !segments.isEmpty else { return invalidSliceAssembly() }
		return WorkspaceSliceAssembly(
			segments: segments,
			combinedText: combined,
			totalLines: totalLines,
			detectedLineEnding: detectedEnding,
			usedRanges: segments.map(\.range),
			kind: .sliced
		)
	}

	private static func normalize(_ ranges: [LineRange], maximumLine: Int) -> [LineRange] {
		guard maximumLine > 0 else { return [] }
		let clamped = ranges.compactMap { range -> LineRange? in
			guard range.start >= 1, range.end >= range.start, range.start <= maximumLine else { return nil }
			return LineRange(
				start: range.start,
				end: min(range.end, maximumLine),
				description: range.description
			)
		}
		return SliceRangeMath.normalize(clamped)
	}

	private static func splitContentPreservingAllLineEndings(_ content: String) -> [(line: String, ending: String)] {
		guard !content.isEmpty else { return [] }
		var result: [(String, String)] = []
		let scalars = content.unicodeScalars
		var lineStart = scalars.startIndex
		var index = scalars.startIndex

		while index < scalars.endIndex {
			switch scalars[index] {
			case "\r":
				let line = String(scalars[lineStart ..< index])
				let next = scalars.index(after: index)
				if next < scalars.endIndex, scalars[next] == "\n" {
					result.append((line, "\r\n"))
					index = scalars.index(after: next)
				} else {
					result.append((line, "\r"))
					index = next
				}
				lineStart = index
			case "\n":
				result.append((String(scalars[lineStart ..< index]), "\n"))
				index = scalars.index(after: index)
				lineStart = index
			default:
				index = scalars.index(after: index)
			}
		}
		if lineStart < scalars.endIndex {
			result.append((String(scalars[lineStart ..< scalars.endIndex]), ""))
		}
		return result
	}

	private static func detectedLineEnding(in pairs: [(line: String, ending: String)]) -> String {
		var counts = ["\r\n": 0, "\r": 0, "\n": 0]
		var last = "\n"
		for pair in pairs where !pair.ending.isEmpty {
			counts[pair.ending, default: 0] += 1
			last = pair.ending
		}
		let maximum = counts.values.max() ?? 0
		let winners = counts.filter { $0.value == maximum && maximum > 0 }.map(\.key)
		return winners.count == 1 ? winners[0] : last
	}
}
