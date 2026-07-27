import Foundation
import RepoPromptCodeMap
import RepoPromptCore

struct HeadlessWorkspaceContext: Equatable, Sendable {
	struct SourceEvidence: Equatable, Sendable {
		enum Role: String, Equatable, Sendable {
			case full
			case slice
		}

		let canonicalPath: String
		let role: Role
		let deviceID: UInt64
		let fileID: UInt64
		let byteCount: Int
		let sha256: String

		init(file: HeadlessSecureFile, role: Role) {
			canonicalPath = file.canonicalPath
			self.role = role
			deviceID = file.deviceID
			fileID = file.fileID
			byteCount = file.byteCount
			sha256 = file.sha256
		}

		func matches(_ file: HeadlessSecureFile) -> Bool {
			canonicalPath == file.canonicalPath
				&& deviceID == file.deviceID
				&& fileID == file.fileID
				&& byteCount == file.byteCount
				&& sha256 == file.sha256
		}
	}

	struct Entry: Equatable, Sendable {
		enum Kind: String, Sendable {
			case selectedFull = "selected_full"
			case selectedSlice = "selected_slice"
			case selectedCodemap = "selected_codemap"
		}

		enum CodemapSource: String, Sendable {
			case manual
			case automatic
		}

		let path: String
		let kind: Kind
		let codemapSource: CodemapSource?
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
			case codemapLanguageUnsupported = "codemap_language_unsupported"
			case codemapNoSymbols = "codemap_no_symbols"
			case codemapParseFailed = "codemap_parse_failed"
			case codemapIndexLimitExceeded = "codemap_index_limit_exceeded"
		}

		let path: String
		let reason: Reason
	}

	let roots: [String]
	let selection: WorkspaceSelectionSnapshot
	let entries: [Entry]
	let sourceEvidence: [SourceEvidence]
	let omissions: [Omission]
	let automaticCodemapPaths: [String]
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
	static let maximumCodemapCandidates = 4_096
	static let maximumAutomaticCodemaps = 1_024
	static let maximumSelectionEntries = WorkspaceSelectionReducer.maximumSelectionEntries
	static let maximumRangesPerFile = WorkspaceSelectionReducer.maximumRangesPerFile
	static let maximumTotalRanges = WorkspaceSelectionReducer.maximumTotalRanges

	private let resolver: HeadlessWorkspacePathResolver

	init(roots: [String]) {
		resolver = HeadlessWorkspacePathResolver(roots: roots)
	}

	static func automaticCodemapOmissionReason(
		for outcome: CodeMapSyntaxArtifactOutcome
	) -> HeadlessWorkspaceContext.Omission.Reason? {
		switch outcome {
		case .oversize: .sourceTooLarge
		case .decodeFailed: .invalidUTF8
		case .parseFailed: .codemapParseFailed
		case .ready, .readyNoSymbols: nil
		}
	}

	func build(selection: WorkspaceSelectionSnapshot, maximumBytes: Int) -> HeadlessWorkspaceContext {
		let limit = max(0, maximumBytes)
		var contentBlocks: [String] = []
		var codemapBlocks: [String] = []
		var entries: [HeadlessWorkspaceContext.Entry] = []
		var sourceEvidence: [HeadlessWorkspaceContext.SourceEvidence] = []
		var omissions: [HeadlessWorkspaceContext.Omission] = []
		var automaticCodemapPaths: [String] = []
		var truncated = false
		var sourceBytesRead = 0
		var artifacts: [String: CodeMapSyntaxArtifact] = [:]
		var acceptedExplicitPaths = Set<String>()

		func acceptExplicitPath(_ path: String) -> Bool {
			if acceptedExplicitPaths.contains(path) { return true }
			guard acceptedExplicitPaths.count < Self.maximumSelectionEntries else {
				truncated = true
				return false
			}
			acceptedExplicitPaths.insert(path)
			return true
		}

		func packaged(_ map: [String] = codemapBlocks, _ contents: [String] = contentBlocks) -> String {
			CanonicalPromptPackaging.package(fileMapBlocks: map, fileContentBlocks: contents)
		}

		func appendContentBlock(_ block: String) -> Bool {
			guard packaged(codemapBlocks, contentBlocks + [block]).utf8.count <= limit else { return false }
			contentBlocks.append(block)
			return true
		}

		func appendCodemapBlock(
			_ block: String,
			displayPath: String,
			source: HeadlessWorkspaceContext.Entry.CodemapSource
		) -> Bool {
			guard packaged(codemapBlocks + [block], contentBlocks).utf8.count <= limit else { return false }
			codemapBlocks.append(block)
			entries.append(.init(
				path: displayPath,
				kind: .selectedCodemap,
				codemapSource: source,
				startLine: nil,
				endLine: nil,
				byteCount: block.utf8.count
			))
			if source == .automatic { automaticCodemapPaths.append(displayPath) }
			return true
		}

		func loadSource(
			_ location: HeadlessWorkspacePathResolver.Location,
			contextBudget: Int? = nil
		) throws -> (source: String, file: HeadlessSecureFile) {
			let aggregateRemaining = max(0, Self.maximumAggregateSourceBytes - sourceBytesRead)
			guard aggregateRemaining > 0 else { throw HeadlessContextSourceError.aggregateLimit }
			if let contextBudget, contextBudget <= 0 { throw HeadlessContextSourceError.contextBudget }
			let readLimit = min(
				Self.maximumSourceFileBytes,
				aggregateRemaining,
				contextBudget ?? Self.maximumSourceFileBytes
			)
			let file: HeadlessSecureFile
			do {
				file = try resolver.read(at: location.realPath, maximumBytes: readLimit)
			} catch HeadlessSecureFileError.tooLarge(let byteCount) {
				if byteCount <= Self.maximumSourceFileBytes, byteCount > aggregateRemaining {
					throw HeadlessContextSourceError.aggregateLimit
				}
				if let contextBudget, byteCount <= Self.maximumSourceFileBytes, byteCount > contextBudget {
					throw HeadlessContextSourceError.contextBudget
				}
				throw HeadlessSecureFileError.tooLarge(byteCount)
			}
			sourceBytesRead += file.data.count
			guard let source = String(data: file.data, encoding: .utf8) else {
				throw HeadlessContextSourceError.invalidUTF8
			}
			return (source, file)
		}

		func makeArtifact(source: String, path: String) -> CodeMapSyntaxArtifactOutcome? {
			do { return try PortableCodeMap.artifact(source: source, path: path) }
			catch { return .parseFailed(.parserReturnedNilTree) }
		}

		var sliceMap: [String: [LineRange]] = [:]
		var sliceIntentPaths = Set<String>()
		let sliceIntentOverflow = selection.slices.count > Self.maximumSelectionEntries
		var invalidSliceKeys: [HeadlessWorkspaceContext.Omission] = []
		var acceptedRangeCount = 0
		for rawPath in selection.slices.keys.sorted().prefix(Self.maximumSelectionEntries) {
			let ranges = selection.slices[rawPath] ?? []
			do {
				let path = try resolver.lexicalPath(rawPath)
				sliceIntentPaths.insert(path)
				guard acceptExplicitPath(path) else { continue }
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
				guard acceptExplicitPath(path) else {
					omissions.append(.init(
						path: resolver.displayPath(path),
						reason: sliceIntentOverflow ? .invalidSlice : .budgetExceeded
					))
					continue
				}
				if selectedSet.insert(path).inserted { selectedPaths.append(path) }
			} catch {
				omissions.append(.init(path: "[outside workspace]", reason: .outsideWorkspace))
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
				if sliceIntentOverflow, !hasSliceEntry {
					omissions.append(.init(path: location.displayPath, reason: .invalidSlice))
					continue
				}
				let ranges = sliceMap[path] ?? []
				if hasSliceEntry, ranges.isEmpty {
					omissions.append(.init(path: location.displayPath, reason: .invalidSlice))
					continue
				}
				let remainingContextBudget = max(0, limit - packaged().utf8.count)
				let loaded = try loadSource(
					location,
					contextBudget: ranges.isEmpty ? remainingContextBudget : nil
				)
				if selection.codemapAutoEnabled,
					PortableCodeMap.supports(path: path),
					let outcome = makeArtifact(source: loaded.source, path: path)
				{
					if case .ready(let artifact) = outcome {
						artifacts[path] = artifact
					} else if let reason = Self.automaticCodemapOmissionReason(for: outcome) {
						omissions.append(.init(path: location.displayPath, reason: reason))
					}
				}

				if ranges.isEmpty {
					let block = CanonicalPromptPackaging.fullFileBlock(
						displayPath: location.displayPath,
						fileName: location.relativePath,
						content: loaded.source
					)
					guard appendContentBlock(block) else {
						omissions.append(.init(path: location.displayPath, reason: .budgetExceeded))
						truncated = true
						continue
					}
					entries.append(.init(
						path: location.displayPath,
						kind: .selectedFull,
						codemapSource: nil,
						startLine: nil,
						endLine: nil,
						byteCount: loaded.source.utf8.count
					))
					sourceEvidence.append(.init(file: loaded.file, role: .full))
					continue
				}

				let invalidRanges = ranges.filter { $0.start < 1 || $0.end < $0.start }
				for range in invalidRanges {
					omissions.append(.init(path: "\(location.displayPath):\(range.start)-\(range.end)", reason: .invalidSlice))
				}
				let validRanges = ranges.filter { $0.start >= 1 && $0.end >= $0.start }
				let assembly = WorkspaceSliceAssemblyBuilder.build(from: loaded.source, ranges: validRanges)
				for range in validRanges where range.start > assembly.totalLines {
					omissions.append(.init(path: "\(location.displayPath):\(range.start)-\(range.end)", reason: .sliceOutOfBounds))
				}
				guard !assembly.isInvalidSlice, !assembly.isFullFile else {
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
						codemapSource: nil,
						startLine: segment.range.start,
						endLine: segment.range.end,
						byteCount: segment.text.utf8.count
					)
				})
				sourceEvidence.append(.init(file: loaded.file, role: .slice))
			} catch let error as HeadlessWorkspacePathError {
				omissions.append(.init(path: resolver.displayPath(path), reason: error.omissionReason))
			} catch HeadlessContextSourceError.invalidUTF8 {
				omissions.append(.init(path: resolver.displayPath(path), reason: .invalidUTF8))
			} catch HeadlessContextSourceError.aggregateLimit,
				HeadlessContextSourceError.contextBudget
			{
				omissions.append(.init(path: resolver.displayPath(path), reason: .budgetExceeded))
				truncated = true
			} catch HeadlessSecureFileError.tooLarge {
				omissions.append(.init(path: resolver.displayPath(path), reason: .sourceTooLarge))
			} catch {
				omissions.append(.init(path: resolver.displayPath(path), reason: .readFailed))
			}
		}

		for path in sliceMap.keys.filter({ !selectedSet.contains($0) }).sorted() {
			omissions.append(.init(path: resolver.displayPath(path), reason: .orphanSlice))
		}
		omissions.append(contentsOf: invalidSliceKeys)

		var manualPaths: [String] = []
		var manualSet = Set<String>()
		for rawPath in selection.manualCodemapPaths.prefix(Self.maximumSelectionEntries) {
			do {
				let path = try resolver.lexicalPath(rawPath)
				guard acceptExplicitPath(path),
					!selectedSet.contains(path),
					manualSet.insert(path).inserted
				else { continue }
				manualPaths.append(path)
			} catch {
				omissions.append(.init(path: "[outside workspace]", reason: .outsideWorkspace))
			}
		}
		if selection.manualCodemapPaths.count > Self.maximumSelectionEntries { truncated = true }

		for path in manualPaths {
			do {
				let location = try resolver.location(for: path)
				guard PortableCodeMap.supports(path: path) else {
					omissions.append(.init(path: location.displayPath, reason: .codemapLanguageUnsupported))
					continue
				}
				let source = try loadSource(location).source
				guard let outcome = makeArtifact(source: source, path: path) else {
					omissions.append(.init(path: location.displayPath, reason: .codemapLanguageUnsupported))
					continue
				}
				switch outcome {
				case .ready(let artifact):
					artifacts[path] = artifact
					let block = PortableCodeMap.render(artifact, displayPath: location.displayPath)
					guard appendCodemapBlock(block, displayPath: location.displayPath, source: .manual) else {
						omissions.append(.init(path: location.displayPath, reason: .budgetExceeded))
						truncated = true
						continue
					}
				case .readyNoSymbols:
					omissions.append(.init(path: location.displayPath, reason: .codemapNoSymbols))
				case .oversize:
					omissions.append(.init(path: location.displayPath, reason: .sourceTooLarge))
				case .decodeFailed:
					omissions.append(.init(path: location.displayPath, reason: .invalidUTF8))
				case .parseFailed:
					omissions.append(.init(path: location.displayPath, reason: .codemapParseFailed))
				}
			} catch let error as HeadlessWorkspacePathError {
				omissions.append(.init(path: resolver.displayPath(path), reason: error.omissionReason))
			} catch HeadlessContextSourceError.invalidUTF8 {
				omissions.append(.init(path: resolver.displayPath(path), reason: .invalidUTF8))
			} catch HeadlessContextSourceError.aggregateLimit,
				HeadlessContextSourceError.contextBudget
			{
				omissions.append(.init(path: resolver.displayPath(path), reason: .budgetExceeded))
				truncated = true
			} catch HeadlessSecureFileError.tooLarge {
				omissions.append(.init(path: resolver.displayPath(path), reason: .sourceTooLarge))
			} catch {
				omissions.append(.init(path: resolver.displayPath(path), reason: .codemapParseFailed))
			}
		}

		let selectedReferences = Set(selectedPaths.flatMap { artifacts[$0]?.referencedTypes ?? [] })
		if selection.codemapAutoEnabled, !selectedReferences.isEmpty {
			let candidates: [String]
			do {
				candidates = try resolver.codemapCandidatePaths(limit: Self.maximumCodemapCandidates + 1)
			} catch {
				omissions.append(.init(path: "[automatic codemap index]", reason: .readFailed))
				candidates = []
			}
			if candidates.count > Self.maximumCodemapCandidates {
				omissions.append(.init(path: "[automatic codemap index]", reason: .codemapIndexLimitExceeded))
			} else {
				var matches: [(path: String, displayPath: String, artifact: CodeMapSyntaxArtifact)] = []
				for path in candidates where !selectedSet.contains(path) && !manualSet.contains(path) {
					do {
						let location = try resolver.location(for: path)
						let artifact: CodeMapSyntaxArtifact
						if let cached = artifacts[path] {
							artifact = cached
						} else {
							let source = try loadSource(location).source
							guard let outcome = makeArtifact(source: source, path: path), case .ready(let generated) = outcome else {
								continue
							}
							artifact = generated
							artifacts[path] = generated
						}
						guard !artifact.definedTypeNames.isDisjoint(with: selectedReferences) else { continue }
						matches.append((path, location.displayPath, artifact))
					} catch HeadlessContextSourceError.aggregateLimit {
						omissions.append(.init(path: "[automatic codemap index]", reason: .budgetExceeded))
						truncated = true
						break
					} catch {
						continue
					}
				}
				matches.sort { $0.displayPath.utf8.lexicographicallyPrecedes($1.displayPath.utf8) }
				if matches.count > Self.maximumAutomaticCodemaps {
					omissions.append(.init(path: "[automatic codemap index]", reason: .codemapIndexLimitExceeded))
					truncated = true
				}
				for match in matches.prefix(Self.maximumAutomaticCodemaps) {
					let block = PortableCodeMap.render(match.artifact, displayPath: match.displayPath)
					guard appendCodemapBlock(block, displayPath: match.displayPath, source: .automatic) else {
						omissions.append(.init(path: match.displayPath, reason: .budgetExceeded))
						truncated = true
						continue
					}
				}
			}
		}

		let content = packaged()
		return HeadlessWorkspaceContext(
			roots: resolver.roots.map(\.lexicalPath),
			selection: selection,
			entries: entries,
			sourceEvidence: sourceEvidence,
			omissions: omissions,
			automaticCodemapPaths: automaticCodemapPaths,
			content: content,
			maximumByteCount: limit,
			truncated: truncated,
			omittedRootCount: 0
		)
	}
}

private enum HeadlessContextSourceError: Error {
	case invalidUTF8
	case aggregateLimit
	case contextBudget
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

	func codemapCandidatePaths(limit: Int) throws -> [String] {
		try HeadlessWorkspacePathIndex(roots: roots.map(\.lexicalPath))
			.codemapCandidateEntries(limit: limit)
			.map(\.absolutePath)
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
