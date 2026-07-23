import Foundation

public struct WorkspaceSelectionSnapshot: Codable, Equatable, Sendable {
	public var selectedPaths: [String]
	public var autoCodemapPaths: [String]
	public var slices: [String: [LineRange]]
	public var codemapAutoEnabled: Bool

	public init(
		selectedPaths: [String] = [],
		autoCodemapPaths: [String] = [],
		slices: [String: [LineRange]] = [:],
		codemapAutoEnabled: Bool = true
	) {
		self.selectedPaths = selectedPaths
		self.autoCodemapPaths = autoCodemapPaths
		self.slices = slices
		self.codemapAutoEnabled = codemapAutoEnabled
	}
}

public actor WorkspaceSelectionStateStore {
	public enum Source: Sendable, Equatable {
		case appAdapter
		case mcpRuntime
		case headless
	}

	public struct Change: Sendable, Equatable {
		public let tabID: UUID?
		public let selection: WorkspaceSelectionSnapshot
		public let source: Source

		public init(tabID: UUID?, selection: WorkspaceSelectionSnapshot, source: Source) {
			self.tabID = tabID
			self.selection = selection
			self.source = source
		}
	}

	private var selections: [UUID?: WorkspaceSelectionSnapshot] = [:]
	private var continuations: [UUID: AsyncStream<Change>.Continuation] = [:]

	public init(defaultSelection: WorkspaceSelectionSnapshot = WorkspaceSelectionSnapshot()) {
		selections[nil] = defaultSelection
	}

	public func snapshot(tabID: UUID?) -> WorkspaceSelectionSnapshot {
		selections[tabID] ?? selections[nil] ?? WorkspaceSelectionSnapshot()
	}

	public func persist(_ selection: WorkspaceSelectionSnapshot, for tabID: UUID?, source: Source) {
		selections[tabID] = selection
		let change = Change(tabID: tabID, selection: selection, source: source)
		for continuation in continuations.values {
			continuation.yield(change)
		}
	}

	public func changes() -> AsyncStream<Change> {
		let id = UUID()
		return AsyncStream { continuation in
			continuations[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { await self?.removeContinuation(id) }
			}
		}
	}

	private func removeContinuation(_ id: UUID) {
		continuations.removeValue(forKey: id)
	}
}
