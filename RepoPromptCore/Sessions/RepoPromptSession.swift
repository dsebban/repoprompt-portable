import Foundation

public actor RepoPromptSession {
	public let id: UUID
	public var name: String
	public var rootPaths: [String]
	public var activeTabID: UUID?
	public let selectionStore: WorkspaceSelectionStateStore

	public init(
		id: UUID = UUID(),
		name: String,
		rootPaths: [String],
		activeTabID: UUID? = nil,
		selectionStore: WorkspaceSelectionStateStore = WorkspaceSelectionStateStore()
	) {
		self.id = id
		self.name = name
		self.rootPaths = rootPaths.map(StandardizedPath.absolute)
		self.activeTabID = activeTabID
		self.selectionStore = selectionStore
	}

	public func snapshot() -> RepoPromptSessionSnapshot {
		RepoPromptSessionSnapshot(id: id, name: name, rootPaths: rootPaths, activeTabID: activeTabID)
	}
}

public struct RepoPromptSessionSnapshot: Codable, Equatable, Sendable, Identifiable {
	public let id: UUID
	public let name: String
	public let rootPaths: [String]
	public let activeTabID: UUID?

	public init(id: UUID, name: String, rootPaths: [String], activeTabID: UUID?) {
		self.id = id
		self.name = name
		self.rootPaths = rootPaths
		self.activeTabID = activeTabID
	}
}
