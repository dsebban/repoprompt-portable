import Foundation
import RepoPromptHeadless

public enum DesktopActivity: Equatable, Sendable {
	case startup
	case selection
	case reload
	case preview
	case plan

	public var label: String {
		switch self {
		case .startup: return "Loading workspace…"
		case .selection: return "Updating selection…"
		case .reload: return "Reloading files…"
		case .preview: return "Building context…"
		case .plan: return "Generating plan…"
		}
	}
}

public struct DesktopState: Equatable, Sendable {
	public static let maximumVisibleFiles = 500

	public var workspace: PortableWorkspaceSummary?
	public var files: [PortableWorkspaceFile] = []
	public var query = ""
	public var selectedPaths: Set<String> = []
	public var instructions = ""
	public var context: PortableContextPreview?
	public var plan: PortablePlanResult?
	public var oracleAvailable = false
	public var activity: DesktopActivity?
	public var statusMessage: String?
	public var errorMessage: String?
	public private(set) var generation: UInt64 = 0

	public init() {}

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

	@discardableResult
	public mutating func begin(_ activity: DesktopActivity) -> UInt64 {
		generation &+= 1
		self.activity = activity
		if activity == .plan { plan = nil }
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
		selectedPaths = selection.selectedAbsolutePaths
		self.oracleAvailable = oracleAvailable
		activity = nil
		statusMessage = "Loaded \(files.count) files."
	}

	public mutating func selectionChanged(_ selection: PortableWorkspaceSelection, generation: UInt64) {
		guard generation == self.generation else { return }
		selectedPaths = selection.selectedAbsolutePaths
		context = nil
		plan = nil
		activity = nil
		statusMessage = "Selected \(selectedPaths.count) files."
	}

	public mutating func filesReloaded(_ files: [PortableWorkspaceFile], generation: UInt64) {
		guard generation == self.generation else { return }
		self.files = files
		context = nil
		plan = nil
		activity = nil
		statusMessage = "Reloaded \(files.count) files."
	}

	public mutating func contextBuilt(_ context: PortableContextPreview, generation: UInt64) {
		guard generation == self.generation else { return }
		self.context = context
		plan = nil
		activity = nil
		statusMessage = "Built context from \(context.entries.count) entries."
	}

	public mutating func planGenerated(_ plan: PortablePlanResult, generation: UInt64) {
		guard generation == self.generation else { return }
		self.plan = plan
		context = plan.context
		activity = nil
		statusMessage = "Plan finished: \(plan.status.rawValue)."
	}

	public mutating func failed(_ message: String, context: PortableContextPreview? = nil, generation: UInt64) {
		guard generation == self.generation else { return }
		if let context { self.context = context }
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
	return error.localizedDescription
}
