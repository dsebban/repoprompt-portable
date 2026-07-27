import Foundation
import RepoPromptCodeMap
import RepoPromptCore

public actor PortableWorkspaceService {
	public static let contextByteBudget = HeadlessWorkspaceContextBuilder.defaultMaximumBytes

	private let pathIndex: HeadlessWorkspacePathIndex
	private let session: RepoPromptSession
	private let contextBuilder: HeadlessWorkspaceContextBuilder
	private let oracleWorkflow: HeadlessOracleWorkflow?
	private let selectionIdentityResolutionHook: (@Sendable (String) throws -> Void)?
	private let proEditCandidateResolutionHook: (@Sendable () throws -> Void)?
	private let proEditTargetSnapshotHook: (@Sendable (String) throws -> Void)?

	public init(
		bootstrap: HeadlessWorkspaceBootstrapResult,
		fileManager: FileManager = .default,
		oracleConfiguration: HeadlessOracleConfiguration? = nil
	) {
		let pathIndex = HeadlessWorkspacePathIndex(roots: bootstrap.roots, fileManager: fileManager)
		self.pathIndex = pathIndex
		self.session = bootstrap.session
		self.contextBuilder = HeadlessWorkspaceContextBuilder(roots: pathIndex.roots)
		self.selectionIdentityResolutionHook = nil
		self.proEditCandidateResolutionHook = nil
		self.proEditTargetSnapshotHook = nil
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
		oracleWorkflow: HeadlessOracleWorkflow?,
		selectionIdentityResolutionHook: (@Sendable (String) throws -> Void)? = nil,
		proEditCandidateResolutionHook: (@Sendable () throws -> Void)? = nil,
		proEditTargetSnapshotHook: (@Sendable (String) throws -> Void)? = nil
	) {
		let pathIndex = HeadlessWorkspacePathIndex(roots: roots, fileManager: fileManager)
		self.pathIndex = pathIndex
		self.session = session
		self.contextBuilder = HeadlessWorkspaceContextBuilder(roots: pathIndex.roots)
		self.oracleWorkflow = oracleWorkflow
		self.selectionIdentityResolutionHook = selectionIdentityResolutionHook
		self.proEditCandidateResolutionHook = proEditCandidateResolutionHook
		self.proEditTargetSnapshotHook = proEditTargetSnapshotHook
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

	public func generatePlan(
		instructions: String,
		expectedContextContent: String? = nil
	) async throws -> PortablePlanResult {
		try await generate(.plan, instructions: instructions, expectedContextContent: expectedContextContent)
	}

	public func generateReview(
		instructions: String,
		expectedContextContent: String? = nil
	) async throws -> PortablePlanResult {
		try await generate(.review, instructions: instructions, expectedContextContent: expectedContextContent)
	}

	public func generateProEdit(
		instructions: String,
		expectedContextContent: String? = nil
	) async throws -> PortableProEditGeneration {
		try Task.checkCancellation()
		let request: String
		do {
			request = try HeadlessOracleWorkflow.validatedRequest(instructions)
		} catch let error as HeadlessOracleWorkflowError {
			throw PortableWorkspaceServiceError.invalidParameters(error.message)
		}
		guard let oracleWorkflow else {
			throw PortableWorkspaceServiceError.oracleNotConfigured
		}

		let selectionSnapshot = await session.selectionStore.snapshot(tabID: nil)
		let context = contextBuilder.build(
			selection: selectionSnapshot,
			maximumBytes: Self.contextByteBudget
		)
		try Task.checkCancellation()
		if let expectedContextContent, context.content != expectedContextContent {
			throw PortableWorkspaceServiceError.staleContextPreview(PortableContextPreview(context))
		}
		guard context.isCompleteForProvider else {
			throw PortableWorkspaceServiceError.incompleteContext(PortableContextPreview(context))
		}

		do {
			let result = try await oracleWorkflow.execute(
				mode: .proEdit,
				request: request,
				context: context
			)
			return PortableProEditGeneration(
				selection: publicSelection(selectionSnapshot),
				result: PortablePlanResult(context: context, result: result)
			)
		} catch let error as HeadlessOracleWorkflowError {
			throw PortableWorkspaceServiceError.oracleFailed(code: error.code, message: error.message)
		}
	}

	public func resolveProEditArtifact(
		_ artifact: PortableProEditArtifact,
		expectedGeneration: PortableProEditGeneration,
		lane: PortablePlanLane.Name
	) async throws -> PortableProEditPreflight {
		try Task.checkCancellation()
		let selectionSnapshot = await session.selectionStore.snapshot(tabID: nil)
		let selection = publicSelection(selectionSnapshot)
		guard selection == expectedGeneration.selection else {
			throw PortableProEditPreflightError(
				code: .staleSelection,
				message: "Workspace selection changed after Pro Edit generation."
			)
		}
		let currentContext = contextBuilder.build(
			selection: selectionSnapshot,
			maximumBytes: Self.contextByteBudget
		)
		guard currentContext.content == expectedGeneration.result.context.content,
			currentContext.sourceEvidence == expectedGeneration.sourceEvidence
		else {
			throw PortableProEditPreflightError(
				code: .staleContext,
				message: "Workspace context identity or content changed after Pro Edit generation."
			)
		}
		let laneAttribution = try Self.resolveLaneAttribution(
			artifact: artifact,
			generation: expectedGeneration,
			requestedLane: lane
		)
		try proEditCandidateResolutionHook?()
		let targets = try resolveProEditTargets(
			artifact,
			selectionSnapshot: selectionSnapshot,
			expectedEvidence: expectedGeneration.sourceEvidence
		)
		return PortableProEditPreflight(
			artifact: artifact,
			selection: selection,
			laneAttribution: laneAttribution,
			targets: targets,
			generation: expectedGeneration
		)
	}

	public func inspectProEditArtifact(
		_ artifact: PortableProEditArtifact
	) async throws -> PortableProEditInspection {
		try Task.checkCancellation()
		let selectionSnapshot = await session.selectionStore.snapshot(tabID: nil)
		let selection = publicSelection(selectionSnapshot)
		let targets = try resolveProEditTargets(
			artifact,
			selectionSnapshot: selectionSnapshot,
			expectedEvidence: nil
		)
		return PortableProEditInspection(
			artifact: artifact,
			selection: selection,
			targets: targets
		)
	}

	private func resolveProEditTargets(
		_ artifact: PortableProEditArtifact,
		selectionSnapshot: WorkspaceSelectionSnapshot,
		expectedEvidence: [HeadlessWorkspaceContext.SourceEvidence]?
	) throws -> [PortableProEditResolvedTarget] {
		let candidates = try artifact.files.map { file in
			(file: file, path: try pathIndex.canonicalProEditPath(file.path))
		}

		for firstIndex in candidates.indices {
			for secondIndex in candidates.index(after: firstIndex) ..< candidates.endIndex {
				let first = candidates[firstIndex]
				let second = candidates[secondIndex]
				if first.path.absolutePath == second.path.absolutePath {
					let code: PortableProEditPreflightError.Code =
						first.file.action == second.file.action ? .duplicateTarget : .overlappingTarget
					throw PortableProEditPreflightError(
						code: code,
						path: second.file.path,
						message: "Pro Edit targets '\(first.file.path)' and '\(second.file.path)' resolve to the same path."
					)
				}
				if Self.pathsOverlap(first.path.absolutePath, second.path.absolutePath) {
					throw PortableProEditPreflightError(
						code: .overlappingTarget,
						path: second.file.path,
						message: "Pro Edit targets '\(first.file.path)' and '\(second.file.path)' overlap."
					)
				}
			}
		}

		var selectionRoles: [String: ProEditSelectionRole] = [:]
		var evidenceByPath: [String: HeadlessWorkspaceContext.SourceEvidence] = [:]
		let currentSelectionIdentities = Set(
			selectionSnapshot.selectedPaths.map(pathIndex.canonicalSelectionIdentity)
		)
		if let expectedEvidence {
			for evidence in expectedEvidence {
				if let existing = evidenceByPath[evidence.canonicalPath] {
					guard existing.deviceID == evidence.deviceID,
						existing.fileID == evidence.fileID,
						existing.byteCount == evidence.byteCount,
						existing.sha256 == evidence.sha256
					else {
						throw PortableProEditPreflightError(
							code: .staleContext,
							message: "Pro Edit generation contains conflicting source identities."
						)
					}
					if evidence.role == .slice {
						evidenceByPath[evidence.canonicalPath] = evidence
					}
				} else {
					evidenceByPath[evidence.canonicalPath] = evidence
				}
			}
		} else {
			let slicedPaths = Set(selectionSnapshot.slices.keys)
			for selectedPath in selectionSnapshot.selectedPaths {
				let identity = pathIndex.canonicalSelectionIdentity(selectedPath)
				try selectionIdentityResolutionHook?(selectedPath)
				let role: ProEditSelectionRole = slicedPaths.contains(selectedPath) ? .slice : .full
				if selectionRoles[identity] != .slice {
					selectionRoles[identity] = role
				}
			}
		}
		var targets: [PortableProEditResolvedTarget] = []
		targets.reserveCapacity(candidates.count)
		for candidate in candidates {
			try Task.checkCancellation()
			let path = candidate.path.absolutePath
			var isDirectory = ObjCBool(false)
			let exists = pathIndex.fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
			let originalContent: String?
			switch candidate.file.action {
			case .delegateEdit:
				guard exists else {
					throw PortableProEditPreflightError(
						code: .missingExistingTarget,
						path: candidate.file.path,
						message: "Pro Edit delegate-edit target does not exist: \(candidate.file.path)"
					)
				}
				guard !isDirectory.boolValue else {
					throw PortableProEditPreflightError(
						code: .targetIsDirectory,
						path: candidate.file.path,
						message: "Pro Edit target is a directory, not a file: \(candidate.file.path)"
					)
				}
				let evidence = evidenceByPath[path]
				if expectedEvidence != nil {
					guard let evidence else {
						let retargetedSelection = currentSelectionIdentities.contains(path)
						throw PortableProEditPreflightError(
							code: retargetedSelection ? .staleContext : .targetNotSelected,
							path: candidate.file.path,
							message: retargetedSelection
								? "Pro Edit selected target identity changed after generation: \(candidate.file.path)"
								: "Pro Edit delegate-edit target was not a generated explicit selection: \(candidate.file.path)"
						)
					}
					if evidence.role == .slice {
						throw PortableProEditPreflightError(
							code: .sliceDelegateUnsupported,
							path: candidate.file.path,
							message: "Pro Edit delegate-edit does not support slice-selected targets; promote the file to full selection before generating edits."
						)
					}
				} else {
					guard let selectionRole = selectionRoles[path] else {
						throw PortableProEditPreflightError(
							code: .targetNotSelected,
							path: candidate.file.path,
							message: "Pro Edit delegate-edit target is not explicitly selected: \(candidate.file.path)"
						)
					}
					if selectionRole == .slice {
						throw PortableProEditPreflightError(
							code: .sliceDelegateUnsupported,
							path: candidate.file.path,
							message: "Pro Edit delegate-edit does not support slice-selected targets; promote the file to full selection before materializing edits."
						)
					}
				}
				try proEditTargetSnapshotHook?(candidate.file.path)
				let secureFile: HeadlessSecureFile
				do {
					secureFile = try HeadlessSecureFileReader.read(
						path: path,
						roots: pathIndex.roots,
						maximumBytes: PortableProEditArtifactParser.maximumFileContentBytes
					)
				} catch let error as HeadlessSecureFileError {
					throw Self.preflightError(for: error, path: candidate.file.path)
				} catch {
					throw PortableProEditPreflightError(
						code: .sourceReadFailed,
						path: candidate.file.path,
						message: "Could not read Pro Edit delegate-edit target: \(candidate.file.path)"
					)
				}
				if let evidence, !evidence.matches(secureFile) {
					throw PortableProEditPreflightError(
						code: .staleContext,
						path: candidate.file.path,
						message: "Pro Edit target identity or content changed after generation: \(candidate.file.path)"
					)
				}
				guard let content = String(data: secureFile.data, encoding: .utf8) else {
					throw PortableProEditPreflightError(
						code: .invalidUTF8,
						path: candidate.file.path,
						message: "Pro Edit delegate-edit target is not valid UTF-8: \(candidate.file.path)"
					)
				}
				originalContent = content

			case .create:
				if exists {
					let code: PortableProEditPreflightError.Code =
						isDirectory.boolValue ? .targetIsDirectory : .createTargetAlreadyExists
					throw PortableProEditPreflightError(
						code: code,
						path: candidate.file.path,
						message: "Pro Edit create target already exists: \(candidate.file.path)"
					)
				}
				let parent = (path as NSString).deletingLastPathComponent
				var parentIsDirectory = ObjCBool(false)
				guard pathIndex.fileManager.fileExists(atPath: parent, isDirectory: &parentIsDirectory) else {
					throw PortableProEditPreflightError(
						code: .createParentMissing,
						path: candidate.file.path,
						message: "Pro Edit create target parent does not exist: \(candidate.file.path)"
					)
				}
				guard parentIsDirectory.boolValue else {
					throw PortableProEditPreflightError(
						code: .createParentNotDirectory,
						path: candidate.file.path,
						message: "Pro Edit create target parent is not a directory: \(candidate.file.path)"
					)
				}
				originalContent = nil
			}

			targets.append(PortableProEditResolvedTarget(
				file: candidate.file,
				rootIndex: candidate.path.rootIndex,
				relativePath: candidate.path.relativePath,
				absolutePath: path,
				displayPath: candidate.path.displayPath,
				originalContent: originalContent
			))
		}
		return targets
	}

	public func materializeProEditPreview(
		_ preflight: PortableProEditPreflight
	) async throws -> PortableProEditPreview {
		try Task.checkCancellation()
		guard preflight.laneAttribution.pairID == preflight.generation.result.pairID else {
			throw PortableProEditPreflightError(
				code: .artifactLaneMismatch,
				message: "Pro Edit preflight attribution does not match its generation."
			)
		}
		let refreshed = try await resolveProEditArtifact(
			preflight.artifact,
			expectedGeneration: preflight.generation,
			lane: preflight.laneAttribution.lane
		)
		guard refreshed == preflight else {
			throw PortableProEditPreflightError(
				code: .staleContext,
				message: "Pro Edit preflight changed before materialization."
			)
		}
		return try await HeadlessProEditExecutionWorkflow(
			oracleWorkflow: oracleWorkflow
		).materialize(refreshed)
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

		let resolvedPaths = try resolve(paths)
		let entries = try slices.map {
			WorkspaceSliceEntry(path: try pathIndex.validatedSelectionPath($0.path), ranges: $0.ranges)
		}
		if mode == .codemapOnly, operation == .set || operation == .add {
			try validateCodemapPaths(resolvedPaths)
		}
		let mutation: WorkspaceSelectionMutation = switch (operation, mode) {
		case (.clear, _): .clear
		case (.set, .full): .replaceWithFullFiles(resolvedPaths)
		case (.set, .slices): .replaceWithSlices(entries)
		case (.set, .codemapOnly): .replaceWithManualCodemaps(resolvedPaths)
		case (.add, .full): .addFullFiles(resolvedPaths)
		case (.add, .slices): .addSlices(entries)
		case (.add, .codemapOnly): .addManualCodemaps(resolvedPaths)
		case (.remove, .full): .removeFiles(resolvedPaths)
		case (.remove, .slices): .subtractSlices(entries)
		case (.remove, .codemapOnly): .removeManualCodemaps(resolvedPaths)
		case (.get, _): preconditionFailure("get returns before mutation mapping")
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
		clarifyHandoff: String? = nil,
		expectedContextContent: String? = nil
	) async throws -> (HeadlessWorkspaceContext, HeadlessOraclePairResult) {
		guard let oracleWorkflow else {
			throw PortableWorkspaceServiceError.oracleNotConfigured
		}
		let context = await renderContext(maximumBytes: maximumBytes)
		try Task.checkCancellation()
		if let expectedContextContent, context.content != expectedContextContent {
			throw PortableWorkspaceServiceError.staleContextPreview(PortableContextPreview(context))
		}
		guard context.isCompleteForProvider else {
			throw PortableWorkspaceServiceError.incompleteContext(PortableContextPreview(context))
		}
		do {
			try Task.checkCancellation()
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

	private func generate(
		_ mode: HeadlessOracleMode,
		instructions: String,
		expectedContextContent: String?
	) async throws -> PortablePlanResult {
		try Task.checkCancellation()
		let request: String
		do {
			request = try HeadlessOracleWorkflow.validatedRequest(instructions)
		} catch let error as HeadlessOracleWorkflowError {
			throw PortableWorkspaceServiceError.invalidParameters(error.message)
		}
		let (context, result) = try await executeOracle(
			mode: mode,
			request: request,
			maximumBytes: Self.contextByteBudget,
			expectedContextContent: expectedContextContent
		)
		return PortablePlanResult(context: context, result: result)
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
				PortableWorkspaceFile(
					absolutePath: $0,
					displayPath: pathIndex.displayPath($0),
					codemapSupported: PortableCodeMap.supports(path: $0)
				)
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
				PortableWorkspaceFile(
					absolutePath: $0,
					displayPath: pathIndex.displayPath($0),
					codemapSupported: PortableCodeMap.supports(path: $0)
				)
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
		case .replaceWithManualCodemaps(let paths): .replaceWithManualCodemaps(try resolveCodemaps(paths))
		case .addManualCodemaps(let paths): .addManualCodemaps(try resolveCodemaps(paths))
		case .removeManualCodemaps(let paths): .removeManualCodemaps(try resolve(paths))
		case .promoteToFull(let paths): .promoteToFull(try resolve(paths))
		case .demoteToManualCodemap(let paths): .demoteToManualCodemap(try resolveCodemaps(paths))
		case .removeFiles(let paths): .removeFiles(try resolve(paths))
		case .clear: .clear
		case .setAutomaticCodemapsEnabled(let enabled): .setAutomaticCodemapsEnabled(enabled)
		}
	}

	private func resolve(_ paths: [String]) throws -> [String] {
		try paths.map(pathIndex.validatedSelectionPath)
	}

	private func resolveCodemaps(_ paths: [String]) throws -> [String] {
		let resolved = try resolve(paths)
		try validateCodemapPaths(resolved)
		return resolved
	}

	private func validateCodemapPaths(_ paths: [String]) throws {
		for path in paths where !PortableCodeMap.supports(path: path) {
			throw PortableWorkspaceServiceError.invalidParameters("Codemap generation is unavailable for: \(pathIndex.displayPath(path))")
		}
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
		case .invalidSliceDescription:
			.invalidParameters("Slice descriptions must not contain NUL and must not exceed 1024 UTF-8 bytes.")
		}
	}

	private static func pathsOverlap(_ first: String, _ second: String) -> Bool {
		first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
	}

	private static func resolveLaneAttribution(
		artifact: PortableProEditArtifact,
		generation: PortableProEditGeneration,
		requestedLane: PortablePlanLane.Name
	) throws -> PortableProEditLaneAttribution {
		let candidates = [generation.result.primary, generation.result.secondary]
		guard let selected = candidates.first(where: { $0.name == requestedLane }),
			selected.status == .completed,
			let response = selected.response,
			(try? PortableProEditArtifactParser.parse(response)) == artifact
		else {
			throw PortableProEditPreflightError(
				code: .artifactLaneMismatch,
				message: "The chosen Pro Edit artifact does not match the \(requestedLane.rawValue) generation lane."
			)
		}
		return PortableProEditLaneAttribution(
			pairID: generation.result.pairID,
			lane: selected.name,
			modelRawID: selected.modelRawID
		)
	}

	private static func preflightError(
		for error: HeadlessSecureFileError,
		path: String
	) -> PortableProEditPreflightError {
		switch error {
		case .outsideWorkspace:
			PortableProEditPreflightError(
				code: .outsideWorkspace,
				path: path,
				message: "Pro Edit target resolves outside the loaded workspace roots: \(path)"
			)
		case .notRegularFile:
			PortableProEditPreflightError(
				code: .targetIsDirectory,
				path: path,
				message: "Pro Edit target is not a regular file: \(path)"
			)
		case .tooLarge:
			PortableProEditPreflightError(
				code: .sourceTooLarge,
				path: path,
				message: "Pro Edit target exceeds \(PortableProEditArtifactParser.maximumFileContentBytes) bytes: \(path)"
			)
		case .openFailed:
			PortableProEditPreflightError(
				code: .sourceReadFailed,
				path: path,
				message: "Could not read Pro Edit target: \(path)"
			)
		case .changedDuringRead:
			PortableProEditPreflightError(
				code: .staleContext,
				path: path,
				message: "Pro Edit target changed while it was being read: \(path)"
			)
		}
	}
}

private extension PortableLineRange {
	init(_ range: LineRange) {
		self.init(startLine: range.start, endLine: range.end, description: range.description)
	}
}

private enum ProEditSelectionRole: Equatable {
	case full
	case slice
}

enum HeadlessSelectionOperation: Sendable, Equatable {
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

	func canonicalSelectionIdentity(_ absolutePath: String) -> String {
		URL(fileURLWithPath: absolutePath)
			.resolvingSymlinksInPath()
			.standardizedFileURL.path
	}

	func canonicalProEditPath(_ rawPath: String) throws -> HeadlessProEditCanonicalPath {
		guard !rawPath.isEmpty,
			rawPath.utf8.count <= Self.maximumPathBytes,
			!rawPath.contains("\0"),
			!rawPath.hasPrefix("/"),
			!rawPath.hasPrefix("~")
		else {
			throw PortableProEditPreflightError(
				code: .invalidPath,
				path: rawPath,
				message: "Pro Edit paths must be loaded-root-relative paths of 1...4096 UTF-8 bytes."
			)
		}

		let qualified = parseRootQualifiedPath(rawPath)
		if rawPath.hasPrefix("root["), qualified == nil {
			throw PortableProEditPreflightError(
				code: .invalidPath,
				path: rawPath,
				message: "Pro Edit path has an invalid root[n]: qualification: \(rawPath)"
			)
		}
		if roots.count > 1, qualified == nil {
			throw PortableProEditPreflightError(
				code: .invalidPath,
				path: rawPath,
				message: "Pro Edit paths in multi-root workspaces require root[n]: qualification: \(rawPath)"
			)
		}
		let rootIndex = qualified?.index ?? 0
		guard roots.indices.contains(rootIndex) else {
			throw PortableProEditPreflightError(
				code: .invalidPath,
				path: rawPath,
				message: "Pro Edit path uses an unavailable workspace root: \(rawPath)"
			)
		}
		let relativePath = qualified?.relativePath ?? rawPath
		let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
		guard !components.isEmpty,
			components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
		else {
			throw PortableProEditPreflightError(
				code: .invalidPath,
				path: rawPath,
				message: "Pro Edit paths must not contain empty, dot, or parent components: \(rawPath)"
			)
		}

		let root = roots[rootIndex]
		let lexicalPath = (root as NSString).appendingPathComponent(relativePath)
		let standardizedPath = (lexicalPath as NSString).standardizingPath
		guard contains(standardizedPath, root: root) else {
			throw PortableProEditPreflightError(
				code: .outsideWorkspace,
				path: rawPath,
				message: "Pro Edit path is outside the loaded workspace root: \(rawPath)"
			)
		}
		let resolvedPath = URL(fileURLWithPath: standardizedPath)
			.resolvingSymlinksInPath()
			.standardizedFileURL.path
		let parentPath = (standardizedPath as NSString).deletingLastPathComponent
		let resolvedParentPath = URL(fileURLWithPath: parentPath, isDirectory: true)
			.resolvingSymlinksInPath()
			.standardizedFileURL.path
		let parentResolvedPath = (resolvedParentPath as NSString)
			.appendingPathComponent((standardizedPath as NSString).lastPathComponent)
		let absolutePath = fileManager.fileExists(atPath: standardizedPath)
			? resolvedPath
			: (parentResolvedPath as NSString).standardizingPath
		guard contains(absolutePath, root: root) else {
			throw PortableProEditPreflightError(
				code: .outsideWorkspace,
				path: rawPath,
				message: "Pro Edit path resolves outside the loaded workspace root: \(rawPath)"
			)
		}

		let rootPrefix = root.hasSuffix("/") ? root : root + "/"
		guard absolutePath.hasPrefix(rootPrefix) else {
			throw PortableProEditPreflightError(
				code: .invalidPath,
				path: rawPath,
				message: "Pro Edit target must be a file below a loaded workspace root: \(rawPath)"
			)
		}
		let canonicalRelativePath = String(absolutePath.dropFirst(rootPrefix.count))
		let displayPath = roots.count > 1
			? "root[\(rootIndex)]:\(canonicalRelativePath)"
			: canonicalRelativePath
		return HeadlessProEditCanonicalPath(
			rootIndex: rootIndex,
			relativePath: canonicalRelativePath,
			absolutePath: absolutePath,
			displayPath: displayPath
		)
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

	func rootContainedFiles(limit: Int) throws -> (files: [String], truncated: Bool) {
		try Task.checkCancellation()
		guard limit > 0 else { return ([], true) }
		var files: [String] = []
		for root in roots {
			try Task.checkCancellation()
			guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
			for case let relative as String in enumerator {
				try Task.checkCancellation()
				let name = (relative as NSString).lastPathComponent
				if Self.shouldSkipName(name) {
					enumerator.skipDescendants()
					continue
				}
				let path = (root as NSString).appendingPathComponent(relative)
				guard isRootContainedRegularFile(path) else { continue }
				guard files.count < limit else { return (files, true) }
				files.append(path)
			}
		}
		return (files, false)
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
				guard isRootContainedRegularFile(path) else { continue }
				candidates.append((path, relative))
			}
			let ignored = try hasGitignore ? ignoredGitPaths(root: root, relativePaths: candidates.map(\.relative)) : []
			files.append(contentsOf: candidates.compactMap { candidate in
				guard !ignored.contains(candidate.relative), seen.insert(candidate.path).inserted else { return nil }
				return PortableWorkspaceFile(
					absolutePath: candidate.path,
					displayPath: displayPath(candidate.path),
					codemapSupported: PortableCodeMap.supports(path: candidate.path)
				)
			})
		}
		try Task.checkCancellation()
		return files.sorted {
			let order = $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath)
			return order == .orderedSame ? $0.displayPath < $1.displayPath : order == .orderedAscending
		}
	}

	func codemapCandidateEntries(limit: Int) throws -> [PortableWorkspaceFile] {
		guard limit > 0 else { return [] }
		let batchSize = 512
		var seen = Set<String>()
		var files: [PortableWorkspaceFile] = []

		for root in roots {
			try Task.checkCancellation()
			guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
			var batch: [(path: String, relative: String)] = []

			func flushBatch() throws -> Bool {
				guard !batch.isEmpty else { return false }
				let ignored = try ignoredGitPaths(root: root, relativePaths: batch.map(\.relative))
				for candidate in batch where !ignored.contains(candidate.relative) {
					guard seen.insert(candidate.path).inserted else { continue }
					files.append(PortableWorkspaceFile(
						absolutePath: candidate.path,
						displayPath: displayPath(candidate.path),
						codemapSupported: true
					))
					if files.count >= limit { return true }
				}
				batch.removeAll(keepingCapacity: true)
				return false
			}

			for case let relative as String in enumerator {
				try Task.checkCancellation()
				let name = (relative as NSString).lastPathComponent
				if Self.shouldSkipName(name) {
					enumerator.skipDescendants()
					continue
				}
				let path = (root as NSString).appendingPathComponent(relative)
				guard PortableCodeMap.supports(path: path), isRootContainedRegularFile(path) else { continue }
				batch.append((path, relative))
				if batch.count >= batchSize, try flushBatch() { return files }
			}
			if try flushBatch() { return files }
		}
		try Task.checkCancellation()
		return files.sorted {
			$0.displayPath.utf8.lexicographicallyPrecedes($1.displayPath.utf8)
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

	private func isRootContainedRegularFile(_ path: String) -> Bool {
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

struct HeadlessProEditCanonicalPath {
	let rootIndex: Int
	let relativePath: String
	let absolutePath: String
	let displayPath: String
}
