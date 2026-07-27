import Foundation
import RepoPromptHeadless

public enum DesktopOracleAction: String, Equatable, Sendable {
	case plan
	case review

	public var title: String { rawValue.capitalized }
}

public enum DesktopWorkspacePanel: String, Equatable, Sendable {
	case selectedFiles
	case contextBuilder
	case oracle
	case proEdit

	public var title: String {
		switch self {
		case .selectedFiles: return "Selected Files"
		case .contextBuilder: return "Context Builder"
		case .oracle: return "Oracle"
		case .proEdit: return "Pro Edit"
		}
	}
}

public enum DesktopProEditLane: String, Equatable, Sendable {
	case primary
	case secondary

	public var title: String { rawValue.capitalized }
}

public enum DesktopDetailRoute: Equatable, Sendable {
	case workspace
	case settings
}

public enum DesktopActivity: Equatable, Sendable {
	case startup
	case selection
	case automaticCodemap
	case reload
	case preview
	case plan
	case review
	case proEditGenerate
	case proEditMaterialize
	case proEditApply

	public var label: String {
		switch self {
		case .startup: return "Loading workspace…"
		case .selection: return "Updating selection…"
		case .automaticCodemap: return "Updating automatic codemaps…"
		case .reload: return "Reloading files…"
		case .preview: return "Building context…"
		case .plan: return "Generating plan…"
		case .review: return "Generating review…"
		case .proEditGenerate: return "Generating Pro Edit artifacts…"
		case .proEditMaterialize: return "Materializing Pro Edit preview…"
		case .proEditApply: return "Applying Pro Edit files…"
		}
	}
}

public struct DesktopState: Equatable, Sendable {
	public static let maximumVisibleFiles = 500

	public var workspace: PortableWorkspaceSummary?
	public var files: [PortableWorkspaceFile] = []
	public var query = ""
	public var selection = PortableWorkspaceSelection(selectedFiles: [], sliceFileCount: 0, codemapFileCount: 0)
	public var focusedFilePath: String?
	public var sliceDraftText = ""
	public var instructions = ""
	public var activePanel: DesktopWorkspacePanel = .contextBuilder
	public var detailRoute: DesktopDetailRoute = .workspace
	public var context: PortableContextPreview?
	public var plan: PortablePlanResult?
	public var oracleMode: DesktopOracleAction?
	public var proEditGeneration: PortableProEditGeneration?
	public var selectedProEditLane: DesktopProEditLane?
	public var proEditSession: DesktopProEditSession?
	public var appliedProEditPaths: [String] = []
	public var oracleAvailable = false
	public var activity: DesktopActivity?
	public var statusMessage: String?
	public var errorMessage: String?
	public private(set) var generation: UInt64 = 0

	public init() {}

	public var selectedPaths: Set<String> { selection.selectedAbsolutePaths }
	public var slicedPaths: Set<String> { Set(selection.slices.map(\.path)) }
	public var manualCodemapPaths: Set<String> { Set(selection.manualCodemapFiles.map(\.absolutePath)) }
	public var selectedRepresentationCount: Int { selection.selectedFiles.count + selection.manualCodemapFiles.count }
	public var hasSelection: Bool { selectedRepresentationCount > 0 }
	public var focusedFile: PortableWorkspaceFile? { files.first { $0.absolutePath == focusedFilePath } }

	public var matchingFiles: [PortableWorkspaceFile] {
		let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !needle.isEmpty else { return files }
		return files.filter { $0.displayPath.localizedCaseInsensitiveContains(needle) }
	}

	public var visibleFiles: [PortableWorkspaceFile] {
		Array(matchingFiles.prefix(Self.maximumVisibleFiles))
	}

	public var canGeneratePlan: Bool {
		activity == nil && oracleAvailable && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	public var canGenerateProEdit: Bool { canGeneratePlan }

	public var selectedProEditArtifact: String? {
		guard let result = proEditGeneration?.result else { return nil }
		return switch selectedProEditLane {
		case .primary: result.primary.response
		case .secondary: result.secondary.response
		case nil: nil
		}
	}

	public var canMaterializeProEdit: Bool {
		activity == nil && selectedProEditArtifact != nil
	}

	public var canApplyProEdit: Bool {
		activity == nil
			&& proEditSession?.changedPaths.isEmpty == false
			&& proEditReviewIsComplete
	}

	public var proEditReviewIsComplete: Bool {
		guard let session = proEditSession, !session.files.isEmpty else { return false }
		return session.files.allSatisfy { proposal in
			let limit = DesktopContextText.maximumCharacters
			return (proposal.target.originalContent?.count ?? 0) <= limit
				&& (proposal.proposedContent?.count ?? 0) <= limit
		}
	}

	public func roleMarker(for file: PortableWorkspaceFile) -> String {
		if slicedPaths.contains(file.absolutePath) { return "[S]" }
		if selectedPaths.contains(file.absolutePath) { return "[F]" }
		if manualCodemapPaths.contains(file.absolutePath) { return "[C]" }
		if context?.automaticCodemapPaths.contains(file.displayPath) == true { return "[A]" }
		return "[ ]"
	}

	public mutating func focus(_ file: PortableWorkspaceFile) {
		focusedFilePath = file.absolutePath
		sliceDraftText = DesktopSliceDraftParser.format(
			selection.slices.first { $0.path == file.absolutePath }?.ranges ?? []
		)
	}

	public mutating func instructionsChanged() {
		plan = nil
		oracleMode = nil
		invalidateProEdit()
	}

	public mutating func selectProEditLane(_ lane: DesktopProEditLane) {
		guard activity == nil else { return }
		let response: String? = switch lane {
		case .primary: proEditGeneration?.result.primary.response
		case .secondary: proEditGeneration?.result.secondary.response
		}
		guard response != nil else { return }
		selectedProEditLane = lane
		proEditSession = nil
		appliedProEditPaths = []
		statusMessage = "\(lane.title) Pro Edit artifact selected. Materialize a preview before applying."
		errorMessage = nil
	}

	public mutating func selectDetail(_ route: DesktopDetailRoute) {
		detailRoute = route
	}

	@discardableResult
	public mutating func begin(_ activity: DesktopActivity) -> UInt64 {
		generation &+= 1
		self.activity = activity
		if activity == .plan || activity == .review {
			plan = nil
			oracleMode = nil
		}
		switch activity {
		case .proEditGenerate:
			invalidateProEdit()
		case .proEditMaterialize:
			proEditSession = nil
			appliedProEditPaths = []
		default:
			break
		}
		statusMessage = activity.label
		errorMessage = nil
		return generation
	}

	public mutating func loaded(
		workspace: PortableWorkspaceSummary,
		files: [PortableWorkspaceFile],
		selection: PortableWorkspaceSelection,
		oracleAvailable: Bool,
		generation: UInt64
	) {
		guard generation == self.generation else { return }
		self.workspace = workspace
		self.files = files
		self.selection = selection
		self.oracleAvailable = oracleAvailable
		activity = nil
		statusMessage = "Loaded \(files.count) files."
	}

	public mutating func selectionChanged(_ selection: PortableWorkspaceSelection, generation: UInt64) {
		guard generation == self.generation else { return }
		self.selection = selection
		if let focusedFilePath {
			sliceDraftText = DesktopSliceDraftParser.format(
				selection.slices.first { $0.path == focusedFilePath }?.ranges ?? []
			)
		}
		context = nil
		plan = nil
		oracleMode = nil
		invalidateProEdit()
		activity = nil
		statusMessage = "Selected \(selectedRepresentationCount) entries."
	}

	public mutating func filesReloaded(_ files: [PortableWorkspaceFile], generation: UInt64) {
		guard generation == self.generation else { return }
		self.files = files
		if let focusedFilePath, !files.contains(where: { $0.absolutePath == focusedFilePath }) {
			self.focusedFilePath = nil
			sliceDraftText = ""
		}
		context = nil
		plan = nil
		oracleMode = nil
		invalidateProEdit()
		activity = nil
		statusMessage = "Reloaded \(files.count) files."
	}

	public mutating func contextBuilt(_ context: PortableContextPreview, generation: UInt64) {
		guard generation == self.generation else { return }
		self.context = context
		plan = nil
		oracleMode = nil
		invalidateProEdit()
		activePanel = .contextBuilder
		activity = nil
		statusMessage = "Built context from \(context.entries.count) entries."
	}

	public mutating func oracleGenerated(
		_ result: PortablePlanResult,
		mode: DesktopOracleAction,
		generation: UInt64
	) {
		guard generation == self.generation else { return }
		plan = result
		oracleMode = mode
		context = result.context
		activePanel = .oracle
		activity = nil
		statusMessage = "\(mode.title) finished: \(result.status.rawValue)."
	}

	public mutating func planGenerated(_ plan: PortablePlanResult, generation: UInt64) {
		oracleGenerated(plan, mode: .plan, generation: generation)
	}

	public mutating func proEditGenerated(
		_ generationResult: PortableProEditGeneration,
		generation: UInt64
	) {
		guard generation == self.generation else { return }
		proEditGeneration = generationResult
		selectedProEditLane = nil
		proEditSession = nil
		appliedProEditPaths = []
		context = generationResult.result.context
		activePanel = .proEdit
		activity = nil
		statusMessage = "Pro Edit artifacts generated. Choose Primary or Secondary explicitly."
		errorMessage = nil
	}

	@discardableResult
	public mutating func proEditMaterialized(
		_ session: DesktopProEditSession,
		lane: DesktopProEditLane,
		artifact: String,
		generation: UInt64
	) -> Bool {
		guard generation == self.generation,
			activity == .proEditMaterialize,
			selectedProEditLane == lane,
			selectedProEditArtifact == artifact
		else { return false }
		proEditSession = session
		appliedProEditPaths = []
		activePanel = .proEdit
		activity = nil
		if session.changedPaths.isEmpty {
			statusMessage = "Preview could not be fully materialized. Review the ordered per-file status."
		} else if proEditReviewIsComplete {
			statusMessage = "Preview materialized for \(session.changedPaths.count) changed files. Review before applying."
		} else {
			statusMessage = "Preview materialized, but original or proposed content exceeds the review display limit. Apply is disabled."
		}
		errorMessage = nil
		return true
	}

	public mutating func proEditApplied(
		_ summary: DesktopProEditApplySummary,
		refreshedFiles: [PortableWorkspaceFile],
		generation: UInt64
	) {
		guard generation == self.generation else { return }
		files = refreshedFiles
		context = nil
		plan = nil
		oracleMode = nil
		proEditGeneration = nil
		selectedProEditLane = nil
		proEditSession = nil
		appliedProEditPaths = summary.appliedPaths
		activePanel = .proEdit
		activity = nil
		statusMessage = "Applied \(summary.appliedPaths.count) files: \(summary.appliedPaths.joined(separator: ", "))."
		errorMessage = nil
	}

	public mutating func failed(_ message: String, context: PortableContextPreview? = nil, generation: UInt64) {
		guard generation == self.generation else { return }
		if let context {
			self.context = context
			activePanel = .contextBuilder
		}
		if activity == .proEditApply {
			proEditSession = nil
		}
		activity = nil
		statusMessage = nil
		errorMessage = message
	}

	public mutating func cancelCurrent(generation: UInt64) {
		guard generation == self.generation, activity != nil else { return }
		self.generation &+= 1
		activity = nil
		statusMessage = "Cancelled."
		errorMessage = nil
	}

	public mutating func resetProEdit() {
		generation &+= 1
		activity = nil
		invalidateProEdit()
		activePanel = .proEdit
		statusMessage = "Pro Edit reset."
		errorMessage = nil
	}

	private mutating func invalidateProEdit() {
		proEditGeneration = nil
		selectedProEditLane = nil
		proEditSession = nil
		appliedProEditPaths = []
	}
}

struct DesktopContextText: Equatable, Sendable {
	static let maximumCharacters = 64 * 1_024
	static let chunkSize = 4 * 1_024

	let chunks: [String]
	let truncated: Bool

	init(_ content: String) {
		let end = content.index(
			content.startIndex,
			offsetBy: Self.maximumCharacters,
			limitedBy: content.endIndex
		) ?? content.endIndex
		truncated = end != content.endIndex

		var chunks: [String] = []
		var start = content.startIndex
		while start < end {
			let next = content.index(start, offsetBy: Self.chunkSize, limitedBy: end) ?? end
			chunks.append(String(content[start..<next]))
			start = next
		}
		self.chunks = chunks
	}
}

public func desktopErrorMessage(_ error: Error) -> String {
	if let error = error as? PortableWorkspaceServiceError { return error.message }
	if let error = error as? HeadlessRuntimeError { return error.message }
	if let error = error as? DesktopArgumentError { return error.message }
	if let error = error as? PortableProEditParseError { return error.message }
	if let error = error as? PortableProEditPreflightError { return error.message }
	if let error = error as? DesktopProEditApplyError { return error.message }
	return error.localizedDescription
}
