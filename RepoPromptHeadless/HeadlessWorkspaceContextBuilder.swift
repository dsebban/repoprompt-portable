import Foundation
import RepoPromptCore

struct HeadlessWorkspaceContext: Equatable, Sendable {
	struct Entry: Equatable, Sendable {
		enum Kind: String, Sendable {
			case selectedFull = "selected_full"
			case selectedSlice = "selected_slice"
		}

		let path: String
		let kind: Kind
		let startLine: Int?
		let endLine: Int?
		let byteCount: Int
	}

	struct Omission: Equatable, Sendable {
		enum Reason: String, Sendable {
			case outsideWorkspace = "outside_workspace"
			case symlinkEscape = "symlink_escape"
			case notFound = "not_found"
			case directoryUnsupported = "directory_unsupported"
			case invalidUTF8 = "invalid_utf8"
			case sourceTooLarge = "source_too_large"
			case sliceOutOfBounds = "slice_out_of_bounds"
			case budgetExceeded = "budget_exceeded"
			case readFailed = "read_failed"
				case orphanSlice = "orphan_slice"
				case invalidSlice = "invalid_slice"
				case autoCodemapUnsupported = "auto_codemap_unsupported"
		}

		let path: String
		let reason: Reason
	}

	let roots: [String]
	let selection: WorkspaceSelectionSnapshot
	let entries: [Entry]
	let omissions: [Omission]
	let content: String
	let maximumByteCount: Int
	let truncated: Bool
	let omittedRootCount: Int

	var contentByteCount: Int { content.utf8.count }
}

struct HeadlessWorkspaceContextBuilder: Sendable {
	static let defaultMaximumBytes = 131_072
	static let minimumMaximumBytes = 1_024
	static let absoluteMaximumBytes = 1_048_576
	static let maximumSourceFileBytes = 8_388_608
	static let maximumAggregateSourceBytes = 64 * 1_024 * 1_024
	static let maximumSelectionEntries = 1_024
	static let maximumTotalRanges = 4_096

	private let resolver: HeadlessWorkspacePathResolver

	init(roots: [String]) {
		resolver = HeadlessWorkspacePathResolver(roots: roots)
	}

	func build(selection: WorkspaceSelectionSnapshot, maximumBytes: Int) -> HeadlessWorkspaceContext {
		let limit = max(0, maximumBytes)
		var content = ""
		var entries: [HeadlessWorkspaceContext.Entry] = []
		var omissions: [HeadlessWorkspaceContext.Omission] = []
		var truncated = false
		var omittedRootCount = 0
		var sourceBytesRead = 0

		func append(_ text: String) -> Bool {
			guard content.utf8.count + text.utf8.count <= limit else { return false }
			content += text
			return true
		}

		_ = append("[RepoPrompt portable workspace context]\n")
		for index in resolver.roots.indices {
			if !append("root[\(index)]\n") {
				omittedRootCount += 1
				truncated = true
			}
		}
		if omittedRootCount > 0 {
			_ = append("[\(omittedRootCount) root(s) omitted by byte budget]\n")
		}

		var sliceMap: [String: [LineRange]] = [:]
		var invalidSliceKeys: [HeadlessWorkspaceContext.Omission] = []
		var acceptedRangeCount = 0
		for (rawPath, ranges) in selection.slices.prefix(Self.maximumSelectionEntries) {
			do {
				let path = try resolver.lexicalPath(rawPath)
				let available = max(0, Self.maximumTotalRanges - acceptedRangeCount)
				let accepted = Array(ranges.prefix(min(256, available)))
				sliceMap[path, default: []].append(contentsOf: accepted)
				acceptedRangeCount += accepted.count
				if accepted.count != ranges.count { truncated = true }
			} catch let error as HeadlessWorkspacePathError {
				invalidSliceKeys.append(.init(
					path: error == .outsideWorkspace ? "[outside workspace]" : resolver.displayPath(rawPath),
					reason: error.omissionReason
				))
			} catch {
				invalidSliceKeys.append(.init(path: "[invalid slice path]", reason: .invalidSlice))
			}
		}
		if selection.slices.count > Self.maximumSelectionEntries { truncated = true }

		var selectedPaths: [String] = []
		var selectedSet = Set<String>()
		for rawPath in selection.selectedPaths.prefix(Self.maximumSelectionEntries) {
			do {
				let path = try resolver.lexicalPath(rawPath)
				if selectedSet.insert(path).inserted {
					selectedPaths.append(path)
				}
			} catch {
				omissions.append(.init(path: rawPath, reason: .outsideWorkspace))
			}
		}

		for path in selectedPaths {
			do {
				let location = try resolver.location(for: path)
				var isDirectory = ObjCBool(false)
				guard FileManager.default.fileExists(atPath: location.realPath, isDirectory: &isDirectory) else {
					omissions.append(.init(path: location.displayPath, reason: .notFound))
					continue
				}
				guard !isDirectory.boolValue else {
					omissions.append(.init(path: location.displayPath, reason: .directoryUnsupported))
					continue
				}

				let hasSliceEntry = sliceMap[path] != nil
				let ranges = (sliceMap[path] ?? []).sorted {
					$0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
				}
				if hasSliceEntry, ranges.isEmpty {
					omissions.append(.init(path: location.displayPath, reason: .invalidSlice))
					continue
				}
				if ranges.isEmpty {
					let prefix = "\n===== BEGIN FILE root[\(location.rootIndex)]:\(location.relativePath) [full] =====\n"
					let suffix = "\n===== END FILE root[\(location.rootIndex)]:\(location.relativePath) =====\n"
					let overhead = prefix.utf8.count + suffix.utf8.count
					let remaining = max(0, limit - content.utf8.count - overhead)
					let data: Data
					do {
						data = try resolver.read(at: location.realPath, maximumBytes: min(remaining, Self.maximumSourceFileBytes)).data
					} catch HeadlessSecureFileError.tooLarge(let byteCount) {
						let reason: HeadlessWorkspaceContext.Omission.Reason = byteCount > Self.maximumSourceFileBytes ? .sourceTooLarge : .budgetExceeded
						omissions.append(.init(path: location.displayPath, reason: reason))
						truncated = truncated || reason == .budgetExceeded
						continue
					}
					guard let source = String(data: data, encoding: .utf8) else {
						omissions.append(.init(path: location.displayPath, reason: .invalidUTF8))
						continue
					}
					sourceBytesRead += data.count
					let rendered = prefix + source + suffix
					guard append(rendered) else {
						omissions.append(.init(path: location.displayPath, reason: .budgetExceeded))
						truncated = true
						continue
					}
					entries.append(.init(path: location.displayPath, kind: .selectedFull, startLine: nil, endLine: nil, byteCount: source.utf8.count))
					continue
				}

				let data: Data
				let remainingSourceBytes = max(0, Self.maximumAggregateSourceBytes - sourceBytesRead)
				do {
					guard remainingSourceBytes > 0 else {
						omissions.append(.init(path: location.displayPath, reason: .budgetExceeded))
						truncated = true
						continue
					}
					data = try resolver.read(
						at: location.realPath,
						maximumBytes: min(Self.maximumSourceFileBytes, remainingSourceBytes)
					).data
				} catch HeadlessSecureFileError.tooLarge {
					let reason: HeadlessWorkspaceContext.Omission.Reason =
						remainingSourceBytes < Self.maximumSourceFileBytes ? .budgetExceeded : .sourceTooLarge
					omissions.append(.init(path: location.displayPath, reason: reason))
					truncated = truncated || reason == .budgetExceeded
					continue
				}
				sourceBytesRead += data.count
				guard let source = String(data: data, encoding: .utf8) else {
					omissions.append(.init(path: location.displayPath, reason: .invalidUTF8))
					continue
				}
				let lines = source.isEmpty ? [] : source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
				for range in ranges {
					guard range.start > 0, range.end >= range.start, range.start <= lines.count else {
						omissions.append(.init(path: "\(location.displayPath):\(range.start)-\(range.end)", reason: .sliceOutOfBounds))
						continue
					}
					let end = min(range.end, lines.count)
					let slice = Array(lines[(range.start - 1) ..< end]).joined(separator: "\n")
					let prefix = "\n===== BEGIN FILE root[\(location.rootIndex)]:\(location.relativePath) [lines \(range.start)-\(end)] =====\n"
					let suffix = "\n===== END FILE root[\(location.rootIndex)]:\(location.relativePath) =====\n"
					let rendered = prefix + slice + suffix
					guard append(rendered) else {
						omissions.append(.init(path: "\(location.displayPath):\(range.start)-\(end)", reason: .budgetExceeded))
						truncated = true
						continue
					}
					entries.append(.init(path: location.displayPath, kind: .selectedSlice, startLine: range.start, endLine: end, byteCount: slice.utf8.count))
				}
			} catch let error as HeadlessWorkspacePathError {
				omissions.append(.init(path: resolver.displayPath(path), reason: error.omissionReason))
			} catch {
				omissions.append(.init(path: resolver.displayPath(path), reason: .readFailed))
			}
		}

		for path in sliceMap.keys.filter({ !selectedSet.contains($0) }).sorted() {
			omissions.append(.init(path: resolver.displayPath(path), reason: .orphanSlice))
		}
		omissions.append(contentsOf: invalidSliceKeys)

		var seenAuto = Set<String>()
		for rawPath in selection.autoCodemapPaths {
			let path = (try? resolver.lexicalPath(rawPath)) ?? rawPath
			guard !selectedSet.contains(path), seenAuto.insert(path).inserted else { continue }
			omissions.append(.init(path: resolver.displayPath(path), reason: .autoCodemapUnsupported))
		}

		if entries.isEmpty {
			_ = append("\nNo readable files are selected.\n")
		}

		return HeadlessWorkspaceContext(
			roots: resolver.roots.map(\.lexicalPath),
			selection: selection,
			entries: entries,
			omissions: omissions,
			content: content,
			maximumByteCount: limit,
			truncated: truncated,
			omittedRootCount: omittedRootCount
		)
	}
}

private enum HeadlessWorkspacePathError: Error, Equatable {
	case outsideWorkspace
	case symlinkEscape
	case notFound

	var omissionReason: HeadlessWorkspaceContext.Omission.Reason {
		switch self {
		case .outsideWorkspace: .outsideWorkspace
		case .symlinkEscape: .symlinkEscape
		case .notFound: .notFound
		}
	}
}

private struct HeadlessWorkspacePathResolver: Sendable {
	struct Root: Sendable {
		let lexicalPath: String
		let realPath: String
	}

	struct Location: Sendable {
		let rootIndex: Int
		let relativePath: String
		let displayPath: String
		let realPath: String
	}

	let roots: [Root]

	init(roots: [String]) {
		self.roots = roots.map { rawRoot in
			let lexical = (rawRoot as NSString).standardizingPath
			let real = URL(fileURLWithPath: lexical, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
			return Root(lexicalPath: lexical, realPath: real)
		}
	}

	func lexicalPath(_ rawPath: String) throws -> String {
		guard let firstRoot = roots.first else { throw HeadlessWorkspacePathError.outsideWorkspace }
		let expanded = (rawPath as NSString).expandingTildeInPath
		let absolute = expanded.hasPrefix("/") ? expanded : (firstRoot.lexicalPath as NSString).appendingPathComponent(expanded)
		let standardized = (absolute as NSString).standardizingPath
		guard roots.contains(where: { contains(standardized, root: $0.lexicalPath) }) else {
			throw HeadlessWorkspacePathError.outsideWorkspace
		}
		return standardized
	}

	func location(for rawPath: String) throws -> Location {
		let lexical = try lexicalPath(rawPath)
		let candidates = roots.indices.filter { contains(lexical, root: roots[$0].lexicalPath) }
		guard let rootIndex = candidates.max(by: { roots[$0].lexicalPath.count < roots[$1].lexicalPath.count }) else {
			throw HeadlessWorkspacePathError.outsideWorkspace
		}
		guard FileManager.default.fileExists(atPath: lexical) else {
			throw HeadlessWorkspacePathError.notFound
		}
		let root = roots[rootIndex]
		let real = URL(fileURLWithPath: lexical).resolvingSymlinksInPath().standardizedFileURL.path
		guard contains(real, root: root.realPath) else {
			throw HeadlessWorkspacePathError.symlinkEscape
		}
		let prefix = root.lexicalPath.hasSuffix("/") ? root.lexicalPath : root.lexicalPath + "/"
		let relative = lexical == root.lexicalPath ? "." : String(lexical.dropFirst(prefix.count))
		let display = roots.count > 1 ? "root[\(rootIndex)]:\(relative)" : relative
		return Location(rootIndex: rootIndex, relativePath: relative, displayPath: display, realPath: real)
	}

	func displayPath(_ rawPath: String) -> String {
		guard let lexical = try? lexicalPath(rawPath) else { return rawPath }
		for (index, root) in roots.enumerated().sorted(by: { $0.element.lexicalPath.count > $1.element.lexicalPath.count }) {
			let label = roots.count > 1 ? "root[\(index)]:" : ""
			if lexical == root.lexicalPath { return label + "." }
			let prefix = root.lexicalPath.hasSuffix("/") ? root.lexicalPath : root.lexicalPath + "/"
			if lexical.hasPrefix(prefix) { return label + String(lexical.dropFirst(prefix.count)) }
		}
		return rawPath
	}

	func read(at path: String, maximumBytes: Int) throws -> HeadlessSecureFile {
		try HeadlessSecureFileReader.read(
			path: path,
			roots: roots.map(\.realPath),
			maximumBytes: maximumBytes
		)
	}

	private func contains(_ path: String, root: String) -> Bool {
		path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
	}
}
