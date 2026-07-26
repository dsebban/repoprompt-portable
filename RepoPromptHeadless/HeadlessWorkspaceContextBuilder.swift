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
	var isCompleteForProvider: Bool { !truncated && omittedRootCount == 0 && omissions.isEmpty }
}

struct HeadlessWorkspaceContextBuilder: Sendable {
	static let defaultMaximumBytes = 131_072
	static let minimumMaximumBytes = 1_024
	static let absoluteMaximumBytes = 1_048_576
	static let maximumSourceFileBytes = 8_388_608
	static let maximumAggregateSourceBytes = 64 * 1_024 * 1_024
	static let maximumSelectionEntries = WorkspaceSelectionReducer.maximumSelectionEntries
	static let maximumRangesPerFile = WorkspaceSelectionReducer.maximumRangesPerFile
	static let maximumTotalRanges = WorkspaceSelectionReducer.maximumTotalRanges

	private let resolver: HeadlessWorkspacePathResolver

	init(roots: [String]) {
		resolver = HeadlessWorkspacePathResolver(roots: roots)
	}

	func build(selection: WorkspaceSelectionSnapshot, maximumBytes: Int) -> HeadlessWorkspaceContext {
		let limit = max(0, maximumBytes)
		var contentBlocks: [String] = []
		var entries: [HeadlessWorkspaceContext.Entry] = []
		var omissions: [HeadlessWorkspaceContext.Omission] = []
		var truncated = false
		var sourceBytesRead = 0

		func appendContentBlock(_ block: String) -> Bool {
			let candidate = CanonicalPromptPackaging.package(
				fileContentBlocks: contentBlocks + [block]
			)
			guard candidate.utf8.count <= limit else { return false }
			contentBlocks.append(block)
			return true
		}

		var sliceMap: [String: [LineRange]] = [:]
		let sliceIntentPaths = Set(selection.slices.keys.compactMap { try? resolver.lexicalPath($0) })
		var invalidSliceKeys: [HeadlessWorkspaceContext.Omission] = []
		var acceptedRangeCount = 0
		for (rawPath, ranges) in selection.slices.prefix(Self.maximumSelectionEntries) {
			do {
				let path = try resolver.lexicalPath(rawPath)
				let available = max(0, Self.maximumTotalRanges - acceptedRangeCount)
				let accepted = Array(ranges.prefix(min(Self.maximumRangesPerFile, available)))
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
				if selectedSet.insert(path).inserted { selectedPaths.append(path) }
			} catch {
				omissions.append(.init(path: rawPath, reason: .outsideWorkspace))
			}
		}
		if selection.selectedPaths.count > Self.maximumSelectionEntries { truncated = true }

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

				let hasSliceEntry = sliceIntentPaths.contains(path)
				let ranges = sliceMap[path] ?? []
				if hasSliceEntry, ranges.isEmpty {
					omissions.append(.init(path: location.displayPath, reason: .invalidSlice))
					continue
				}

				let remainingAggregateBytes = max(0, Self.maximumAggregateSourceBytes - sourceBytesRead)
				guard remainingAggregateBytes > 0 else {
					omissions.append(.init(path: location.displayPath, reason: .budgetExceeded))
					truncated = true
					continue
				}
				let readLimit = ranges.isEmpty
					? min(min(Self.maximumSourceFileBytes, remainingAggregateBytes), limit)
					: min(Self.maximumSourceFileBytes, remainingAggregateBytes)
				let data: Data
				do {
					data = try resolver.read(at: location.realPath, maximumBytes: readLimit).data
				} catch HeadlessSecureFileError.tooLarge(let byteCount) {
					let reason: HeadlessWorkspaceContext.Omission.Reason = byteCount > Self.maximumSourceFileBytes
						? .sourceTooLarge
						: .budgetExceeded
					omissions.append(.init(path: location.displayPath, reason: reason))
					truncated = truncated || reason == .budgetExceeded
					continue
				}
				sourceBytesRead += data.count
				guard let source = String(data: data, encoding: .utf8) else {
					omissions.append(.init(path: location.displayPath, reason: .invalidUTF8))
					continue
				}

				if ranges.isEmpty {
					let block = CanonicalPromptPackaging.fullFileBlock(
						displayPath: location.displayPath,
						fileName: location.relativePath,
						content: source
					)
					guard appendContentBlock(block) else {
						omissions.append(.init(path: location.displayPath, reason: .budgetExceeded))
						truncated = true
						continue
					}
					entries.append(.init(
						path: location.displayPath,
						kind: .selectedFull,
						startLine: nil,
						endLine: nil,
						byteCount: source.utf8.count
					))
					continue
				}

				let invalidRanges = ranges.filter { $0.start < 1 || $0.end < $0.start }
				for range in invalidRanges {
					omissions.append(.init(
						path: "\(location.displayPath):\(range.start)-\(range.end)",
						reason: .invalidSlice
					))
				}
				let validRanges = ranges.filter { $0.start >= 1 && $0.end >= $0.start }
				let assembly = WorkspaceSliceAssemblyBuilder.build(from: source, ranges: validRanges)
				for range in validRanges where range.start > assembly.totalLines {
					omissions.append(.init(
						path: "\(location.displayPath):\(range.start)-\(range.end)",
						reason: .sliceOutOfBounds
					))
				}
				guard !assembly.isFullFile else {
					if invalidRanges.isEmpty, !validRanges.contains(where: { $0.start > assembly.totalLines }) {
						omissions.append(.init(path: location.displayPath, reason: .invalidSlice))
					}
					continue
				}
				let block = CanonicalPromptPackaging.sliceFileBlock(
					displayPath: location.displayPath,
					fileName: location.relativePath,
					segments: assembly.segments
				)
				guard appendContentBlock(block) else {
					omissions.append(.init(path: location.displayPath, reason: .budgetExceeded))
					truncated = true
					continue
				}
				entries.append(contentsOf: assembly.segments.map { segment in
					.init(
						path: location.displayPath,
						kind: .selectedSlice,
						startLine: segment.range.start,
						endLine: segment.range.end,
						byteCount: segment.text.utf8.count
					)
				})
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

		var seenManualCodemaps = Set<String>()
		for rawPath in selection.manualCodemapPaths {
			let path = (try? resolver.lexicalPath(rawPath)) ?? rawPath
			guard !selectedSet.contains(path), seenManualCodemaps.insert(path).inserted else { continue }
			omissions.append(.init(path: resolver.displayPath(path), reason: .autoCodemapUnsupported))
		}

		let content = CanonicalPromptPackaging.package(fileContentBlocks: contentBlocks)
		return HeadlessWorkspaceContext(
			roots: resolver.roots.map(\.lexicalPath),
			selection: selection,
			entries: entries,
			omissions: omissions,
			content: content,
			maximumByteCount: limit,
			truncated: truncated,
			omittedRootCount: 0
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
