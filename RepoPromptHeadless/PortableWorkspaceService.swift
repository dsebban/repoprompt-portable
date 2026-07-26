import Foundation
import RepoPromptCore

public actor PortableWorkspaceService {
	public static let contextByteBudget = HeadlessWorkspaceContextBuilder.defaultMaximumBytes

	private let pathIndex: HeadlessWorkspacePathIndex
	private let session: RepoPromptSession
	private let contextBuilder: HeadlessWorkspaceContextBuilder
	private let oracleWorkflow: HeadlessOracleWorkflow?

	public init(
		bootstrap: HeadlessWorkspaceBootstrapResult,
		fileManager: FileManager = .default,
		oracleConfiguration: HeadlessOracleConfiguration? = nil
	) {
		let pathIndex = HeadlessWorkspacePathIndex(roots: bootstrap.roots, fileManager: fileManager)
		self.pathIndex = pathIndex
		self.session = bootstrap.session
		self.contextBuilder = HeadlessWorkspaceContextBuilder(roots: pathIndex.roots)
		self.oracleWorkflow = oracleConfiguration.map { configuration in
			HeadlessOracleWorkflow(
				configuration: configuration,
				provider: OpenAICompatibleOracleProvider(configuration: configuration)
			)
		}
	}

	init(
		roots: [String],
		session: RepoPromptSession,
		fileManager: FileManager = .default,
		oracleWorkflow: HeadlessOracleWorkflow?
	) {
		let pathIndex = HeadlessWorkspacePathIndex(roots: roots, fileManager: fileManager)
		self.pathIndex = pathIndex
		self.session = session
		self.contextBuilder = HeadlessWorkspaceContextBuilder(roots: pathIndex.roots)
		self.oracleWorkflow = oracleWorkflow
	}

	public func workspace() async -> PortableWorkspaceSummary {
		let snapshot = await session.snapshot()
		return PortableWorkspaceSummary(id: snapshot.id, name: snapshot.name, roots: pathIndex.roots)
	}

	public func files() throws -> [PortableWorkspaceFile] {
		try pathIndex.desktopFileEntries()
	}

	public func selection() async -> PortableWorkspaceSelection {
		let snapshot = await session.selectionStore.snapshot(tabID: nil)
		return publicSelection(snapshot)
	}

	@discardableResult
	public func mutateSelection(
		_ mutation: PortableSelectionMutation,
		codemapAutoEnabledOverride: Bool? = nil
	) async throws -> PortableWorkspaceSelection {
		let coreMutation = try resolvedMutation(mutation)
		let store = await session.selectionStore
		do {
			let snapshot = try await store.mutate(for: nil, source: .headless) { selection in
				try WorkspaceSelectionReducer.apply(
					coreMutation,
					to: &selection,
					codemapAutoEnabledOverride: codemapAutoEnabledOverride
				)
			}
			return publicSelection(snapshot)
		} catch let violation as WorkspaceSelectionLimitViolation {
			throw Self.serviceError(for: violation)
		}
	}

	@discardableResult
	public func addFiles(_ paths: [String]) async throws -> PortableWorkspaceSelection {
		try await mutateSelection(.addFullFiles(paths))
	}

	@discardableResult
	public func removeFiles(_ paths: [String]) async throws -> PortableWorkspaceSelection {
		try await mutateSelection(.removeFiles(paths))
	}

	@discardableResult
	public func setSlices(_ slices: [PortableSliceSelection]) async throws -> PortableWorkspaceSelection {
		try await mutateSelection(.setSlices(slices))
	}

	@discardableResult
	public func promoteToFull(_ paths: [String]) async throws -> PortableWorkspaceSelection {
		try await mutateSelection(.promoteToFull(paths))
	}

	@discardableResult
	public func demoteToManualCodemap(_ paths: [String]) async throws -> PortableWorkspaceSelection {
		try await mutateSelection(.demoteToManualCodemap(paths))
	}

	@discardableResult
	public func setAutomaticCodemapsEnabled(_ enabled: Bool) async throws -> PortableWorkspaceSelection {
		try await mutateSelection(.setAutomaticCodemapsEnabled(enabled))
	}

	@discardableResult
	public func clearSelection() async -> PortableWorkspaceSelection {
		publicSelection(await resetSelection())
	}

	public func previewContext() async throws -> PortableContextPreview {
		try Task.checkCancellation()
		let context = await renderContext(maximumBytes: Self.contextByteBudget)
		try Task.checkCancellation()
		return PortableContextPreview(context)
	}

	public func generatePlan(instructions: String) async throws -> PortablePlanResult {
		try Task.checkCancellation()
		let request: String
		do {
			request = try HeadlessOracleWorkflow.validatedRequest(instructions)
		} catch let error as HeadlessOracleWorkflowError {
			throw PortableWorkspaceServiceError.invalidParameters(error.message)
		}
		let (context, result) = try await executeOracle(
			mode: .plan,
			request: request,
			maximumBytes: Self.contextByteBudget
		)
		return PortablePlanResult(context: context, result: result)
	}

	func applySelection(
		operation: HeadlessSelectionOperation,
		mode: HeadlessSelectionMode,
		paths: [String] = [],
		slices: [HeadlessSelectionSlice] = [],
		codemapAutoEnabledOverride: Bool? = nil
	) async throws -> WorkspaceSelectionSnapshot {
		let store = await session.selectionStore
		if case .get = operation { return await store.snapshot(tabID: nil) }

		let entries = slices.map { WorkspaceSliceEntry(path: $0.path, ranges: $0.ranges) }
		let mutation: WorkspaceSelectionMutation = switch (operation, mode) {
		case (.clear, _): .clear
		case (.set, .full): .replaceWithFullFiles(paths)
		case (.set, .slices): .setSlices(entries)
		case (.set, .codemapOnly): .replaceWithManualCodemaps(paths)
		case (.add, .full): .addFullFiles(paths)
		case (.add, .slices): .addSlices(entries)
		case (.add, .codemapOnly): .addManualCodemaps(paths)
		case (.remove, .full): .removeFiles(paths)
		case (.remove, .slices): .subtractSlices(entries)
		case (.remove, .codemapOnly): .removeManualCodemaps(paths)
		case (.get, _): .clear
		}
		do {
			return try await store.mutate(for: nil, source: .headless) { selection in
				try WorkspaceSelectionReducer.apply(
					mutation,
					to: &selection,
					codemapAutoEnabledOverride: codemapAutoEnabledOverride
				)
			}
		} catch let violation as WorkspaceSelectionLimitViolation {
			throw Self.serviceError(for: violation)
		}
	}

	func renderContext(maximumBytes: Int) async -> HeadlessWorkspaceContext {
		let selection = await session.selectionStore.snapshot(tabID: nil)
		return contextBuilder.build(selection: selection, maximumBytes: maximumBytes)
	}

	func executeOracle(
		mode: HeadlessOracleMode,
		request: String,
		maximumBytes: Int,
		reviewDiff: String? = nil,
		clarifyHandoff: String? = nil
	) async throws -> (HeadlessWorkspaceContext, HeadlessOraclePairResult) {
		guard let oracleWorkflow else {
			throw PortableWorkspaceServiceError.oracleNotConfigured
		}
		let context = await renderContext(maximumBytes: maximumBytes)
		guard context.isCompleteForProvider else {
			throw PortableWorkspaceServiceError.incompleteContext(PortableContextPreview(context))
		}
		do {
			let result = try await oracleWorkflow.execute(
				mode: mode,
				request: request,
				context: context,
				reviewDiff: reviewDiff,
				clarifyHandoff: clarifyHandoff
			)
			return (context, result)
		} catch let error as HeadlessOracleWorkflowError {
			throw PortableWorkspaceServiceError.oracleFailed(code: error.code, message: error.message)
		}
	}

	private func resetSelection() async -> WorkspaceSelectionSnapshot {
		let store = await session.selectionStore
		return await store.mutate(for: nil, source: .headless) {
			$0 = WorkspaceSelectionSnapshot()
		}
	}

	private func publicSelection(_ snapshot: WorkspaceSelectionSnapshot) -> PortableWorkspaceSelection {
		PortableWorkspaceSelection(
			selectedFiles: snapshot.selectedPaths.map {
				PortableWorkspaceFile(absolutePath: $0, displayPath: pathIndex.displayPath($0))
			},
			sliceFileCount: snapshot.slices.count,
			codemapFileCount: snapshot.manualCodemapPaths.count,
			slices: snapshot.slices.keys.sorted().map { path in
				PortableSliceSelection(
					path: path,
					ranges: (snapshot.slices[path] ?? []).map(PortableLineRange.init)
				)
			},
			manualCodemapFiles: snapshot.manualCodemapPaths.map {
				PortableWorkspaceFile(absolutePath: $0, displayPath: pathIndex.displayPath($0))
			},
			codemapAutoEnabled: snapshot.codemapAutoEnabled
		)
	}

	private func resolvedMutation(_ mutation: PortableSelectionMutation) throws -> WorkspaceSelectionMutation {
		switch mutation {
		case .replaceWithFullFiles(let paths): .replaceWithFullFiles(try resolve(paths))
		case .addFullFiles(let paths): .addFullFiles(try resolve(paths))
		case .setSlices(let slices): .setSlices(try resolve(slices))
		case .addSlices(let slices): .addSlices(try resolve(slices))
		case .subtractSlices(let slices): .subtractSlices(try resolve(slices, allowEmptyRanges: true))
		case .replaceWithManualCodemaps(let paths): .replaceWithManualCodemaps(try resolve(paths))
		case .addManualCodemaps(let paths): .addManualCodemaps(try resolve(paths))
		case .removeManualCodemaps(let paths): .removeManualCodemaps(try resolve(paths))
		case .promoteToFull(let paths): .promoteToFull(try resolve(paths))
		case .demoteToManualCodemap(let paths): .demoteToManualCodemap(try resolve(paths))
		case .removeFiles(let paths): .removeFiles(try resolve(paths))
		case .clear: .clear
		case .setAutomaticCodemapsEnabled(let enabled): .setAutomaticCodemapsEnabled(enabled)
		}
	}

	private func resolve(_ paths: [String]) throws -> [String] {
		try paths.map(pathIndex.validatedSelectionPath)
	}

	private func resolve(
		_ slices: [PortableSliceSelection],
		allowEmptyRanges: Bool = false
	) throws -> [WorkspaceSliceEntry] {
		guard slices.count <= WorkspaceSelectionReducer.maximumSelectionEntries else {
			throw PortableWorkspaceServiceError.invalidParameters("Selection accepts at most 1024 files.")
		}
		var totalRanges = 0
		return try slices.map { slice in
			guard allowEmptyRanges || !slice.ranges.isEmpty,
				slice.ranges.count <= WorkspaceSelectionReducer.maximumRangesPerFile
			else {
				throw PortableWorkspaceServiceError.invalidParameters("Each selected slice requires 1...256 ranges.")
			}
			totalRanges += slice.ranges.count
			guard totalRanges <= WorkspaceSelectionReducer.maximumTotalRanges else {
				throw PortableWorkspaceServiceError.invalidParameters("Selection accepts at most 4096 total slice ranges.")
			}
			let ranges = try slice.ranges.map { range -> LineRange in
				guard range.startLine >= 1, range.endLine >= range.startLine else {
					throw PortableWorkspaceServiceError.invalidParameters("Slice ranges require positive start lines and end lines greater than or equal to start lines.")
				}
				if let description = range.description {
					guard !description.contains("\0"), description.utf8.count <= 1_024 else {
						throw PortableWorkspaceServiceError.invalidParameters("Slice descriptions must not contain NUL and must not exceed 1024 UTF-8 bytes.")
					}
				}
				return LineRange(start: range.startLine, end: range.endLine, description: range.description)
			}
			return WorkspaceSliceEntry(path: try pathIndex.validatedSelectionPath(slice.path), ranges: ranges)
		}
	}

	private static func serviceError(for violation: WorkspaceSelectionLimitViolation) -> PortableWorkspaceServiceError {
		switch violation {
		case .tooManyPaths:
			.invalidParameters("Selection accepts at most 1024 files.")
		case .sliceRangeCountOutOfRange:
			.invalidParameters("Each selected slice requires 1...256 ranges.")
		case .totalSliceRangesExceeded:
			.invalidParameters("Selection accepts at most 4096 total slice ranges.")
		}
	}
}

private extension PortableLineRange {
	init(_ range: LineRange) {
		self.init(startLine: range.start, endLine: range.end, description: range.description)
	}
}

enum HeadlessSelectionOperation: Sendable {
	case get
	case set
	case add
	case remove
	case clear
}

enum HeadlessSelectionMode: Sendable, Equatable {
	case full
	case slices
	case codemapOnly
}

struct HeadlessSelectionSlice: Sendable {
	let path: String
	let ranges: [LineRange]
}

struct HeadlessWorkspacePathIndex {
	static let maximumPathBytes = 4_096

	let roots: [String]
	let fileManager: FileManager

	init(roots: [String], fileManager: FileManager = .default) {
		self.roots = roots.map {
			URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
		}
		self.fileManager = fileManager
	}

	func resolvePath(_ raw: String, mustExist: Bool) throws -> String {
		let expanded = (raw as NSString).expandingTildeInPath
		let absolute: String
		if let qualified = parseRootQualifiedPath(expanded) {
			guard roots.indices.contains(qualified.index) else {
				throw PortableWorkspaceServiceError.invalidParameters("Invalid workspace root index in path: \(raw)")
			}
			absolute = (roots[qualified.index] as NSString).appendingPathComponent(qualified.relativePath)
		} else {
			absolute = expanded.hasPrefix("/") ? expanded : (roots[0] as NSString).appendingPathComponent(expanded)
		}
		let standardized = (absolute as NSString).standardizingPath
		guard roots.contains(where: { contains(standardized, root: $0) }) else {
			throw PortableWorkspaceServiceError.pathOutsideWorkspace("Path is outside the headless workspace roots: \(raw)")
		}
		if mustExist, !fileManager.fileExists(atPath: standardized) {
			throw PortableWorkspaceServiceError.pathNotFound("Path does not exist: \(raw)")
		}
		return standardized
	}

	func validatedSelectionPath(_ rawPath: String) throws -> String {
		guard !rawPath.isEmpty, rawPath.utf8.count <= Self.maximumPathBytes else {
			throw PortableWorkspaceServiceError.invalidParameters("Selection paths must contain 1...4096 UTF-8 bytes.")
		}
		return try resolvePath(rawPath, mustExist: false)
	}

	func displayPath(_ path: String) -> String {
		for (index, root) in roots.enumerated().sorted(by: { $0.element.count > $1.element.count }) {
			let prefixLabel = roots.count > 1 ? "root[\(index)]:" : ""
			if path == root { return roots.count > 1 ? "root[\(index)]" : root }
			let prefix = root.hasSuffix("/") ? root : root + "/"
			if path.hasPrefix(prefix) {
				return prefixLabel + String(path.dropFirst(prefix.count))
			}
		}
		return path
	}

	func allFiles() -> [String] {
		var files: [String] = []
		for root in roots {
			guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
			for case let relative as String in enumerator {
				let name = (relative as NSString).lastPathComponent
				if Self.shouldSkipName(name) {
					enumerator.skipDescendants()
					continue
				}
				let path = (root as NSString).appendingPathComponent(relative)
				var isDirectory = ObjCBool(false)
				guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
				files.append(path)
			}
		}
		return files
	}

	func desktopFileEntries() throws -> [PortableWorkspaceFile] {
		var seen = Set<String>()
		var files: [PortableWorkspaceFile] = []
		for root in roots {
			try Task.checkCancellation()
			guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
			var candidates: [(path: String, relative: String)] = []
			var hasGitignore = false
			for case let relative as String in enumerator {
				try Task.checkCancellation()
				let name = (relative as NSString).lastPathComponent
				if name == ".gitignore" { hasGitignore = true }
				if Self.shouldSkipName(name) {
					enumerator.skipDescendants()
					continue
				}
				let path = (root as NSString).appendingPathComponent(relative)
				guard isDesktopRegularFile(path), seen.insert(path).inserted else { continue }
				candidates.append((path, relative))
			}
			let ignored = try hasGitignore ? ignoredGitPaths(root: root, relativePaths: candidates.map(\.relative)) : []
			files.append(contentsOf: candidates.compactMap { candidate in
				guard !ignored.contains(candidate.relative) else { return nil }
				return PortableWorkspaceFile(absolutePath: candidate.path, displayPath: displayPath(candidate.path))
			})
		}
		try Task.checkCancellation()
		return files.sorted {
			let order = $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath)
			return order == .orderedSame ? $0.displayPath < $1.displayPath : order == .orderedAscending
		}
	}

	private func ignoredGitPaths(root: String, relativePaths: [String]) throws -> Set<String> {
		guard !relativePaths.isEmpty else { return [] }
		let directory = fileManager.temporaryDirectory.appendingPathComponent("repoprompt-ignore-\(UUID().uuidString)", isDirectory: true)
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? fileManager.removeItem(at: directory) }

		let gitDirectory = directory.appendingPathComponent("repository.git", isDirectory: true)
		let initialize = Process()
		initialize.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		initialize.arguments = ["git", "init", "--bare", "--quiet", gitDirectory.path]
		initialize.standardOutput = FileHandle.nullDevice
		initialize.standardError = FileHandle.nullDevice
		try initialize.run()
		initialize.waitUntilExit()
		guard initialize.terminationStatus == 0 else {
			throw PortableWorkspaceServiceError.invalidParameters("Could not initialize .gitignore evaluation for \(root).")
		}

		let inputURL = directory.appendingPathComponent("input")
		let outputURL = directory.appendingPathComponent("output")
		let errorURL = directory.appendingPathComponent("error")
		try Data((relativePaths.joined(separator: "\0") + "\0").utf8).write(to: inputURL)
		_ = fileManager.createFile(atPath: outputURL.path, contents: nil)
		_ = fileManager.createFile(atPath: errorURL.path, contents: nil)
		let input = try FileHandle(forReadingFrom: inputURL)
		let output = try FileHandle(forWritingTo: outputURL)
		let error = try FileHandle(forWritingTo: errorURL)
		defer {
			try? input.close()
			try? output.close()
			try? error.close()
		}

		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = [
			"git", "-c", "core.excludesFile=/dev/null",
			"--git-dir=\(gitDirectory.path)", "--work-tree=\(root)",
			"check-ignore", "--no-index", "-z", "--stdin"
		]
		process.standardInput = input
		process.standardOutput = output
		process.standardError = error
		try process.run()
		process.waitUntilExit()
		guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
			let errorData = try Data(contentsOf: errorURL)
			let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
			let message = detail.flatMap { $0.isEmpty ? nil : $0 } ?? "git check-ignore failed"
			throw PortableWorkspaceServiceError.invalidParameters("Could not evaluate .gitignore rules for \(root): \(message)")
		}
		let data = try Data(contentsOf: outputURL)
		return Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
	}

	private func isDesktopRegularFile(_ path: String) -> Bool {
		let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
		guard roots.contains(where: { contains(resolved, root: $0) }),
			let attributes = try? fileManager.attributesOfItem(atPath: resolved),
			attributes[.type] as? FileAttributeType == .typeRegular
		else { return false }
		return true
	}

	static func shouldSkipName(_ name: String) -> Bool {
		name.hasPrefix(".") || [".git", ".build", "node_modules"].contains(name)
	}

	private func contains(_ path: String, root: String) -> Bool {
		path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
	}

	private func parseRootQualifiedPath(_ path: String) -> (index: Int, relativePath: String)? {
		guard path.hasPrefix("root["), let close = path.firstIndex(of: "]") else { return nil }
		let indexStart = path.index(path.startIndex, offsetBy: 5)
		guard let index = Int(path[indexStart..<close]) else { return nil }
		let suffix = path[path.index(after: close)...]
		guard suffix.first == ":" else { return nil }
		let relative = suffix.dropFirst()
		guard !relative.hasPrefix("/") else { return nil }
		return (index, String(relative))
	}
}
