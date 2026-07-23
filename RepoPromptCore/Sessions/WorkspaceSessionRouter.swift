import Foundation

public struct WorkspaceSessionBindingRequest: Sendable, Equatable {
	public var sessionID: UUID?
	public var tabID: UUID?
	public var workingDirectories: [String]

	public init(sessionID: UUID? = nil, tabID: UUID? = nil, workingDirectories: [String] = []) {
		self.sessionID = sessionID
		self.tabID = tabID
		self.workingDirectories = workingDirectories
	}
}

public enum WorkspaceSessionRoutingError: Error, Sendable, Equatable {
	case sessionNotFound(UUID)
	case noMatchingWorkspace(workingDirectories: [String])
	case noActiveSession
}

public actor WorkspaceSessionRouter {
	private let store: WorkspaceSessionStore
	private var bindings: [UUID: RepoPromptSessionSnapshot] = [:]

	public init(store: WorkspaceSessionStore) {
		self.store = store
	}

	public func bind(connectionID: UUID, request: WorkspaceSessionBindingRequest) async throws -> RepoPromptSessionSnapshot {
		let session: RepoPromptSession
		if let sessionID = request.sessionID {
			guard let resolved = await store.session(id: sessionID) else {
				throw WorkspaceSessionRoutingError.sessionNotFound(sessionID)
			}
			session = resolved
		} else if !request.workingDirectories.isEmpty {
			let requested = request.workingDirectories.map(StandardizedPath.absolute)
			let snapshots = await store.snapshots()
			guard let match = snapshots.first(where: { snapshot in
				requested.allSatisfy { requestedPath in
					snapshot.rootPaths.contains { root in
						StandardizedPath.isDescendant(requestedPath, of: root)
					}
				}
			}), let resolved = await store.session(id: match.id) else {
				throw WorkspaceSessionRoutingError.noMatchingWorkspace(workingDirectories: request.workingDirectories)
			}
			session = resolved
		} else {
			guard let resolved = await store.activeSession() else {
				throw WorkspaceSessionRoutingError.noActiveSession
			}
			session = resolved
		}

		if let tabID = request.tabID {
			await session.setActiveTabID(tabID)
		}
		let snapshot = await session.snapshot()
		bindings[connectionID] = snapshot
		return snapshot
	}

	public func binding(for connectionID: UUID) -> RepoPromptSessionSnapshot? {
		bindings[connectionID]
	}

	public func clearBinding(for connectionID: UUID) {
		bindings.removeValue(forKey: connectionID)
	}
}

extension RepoPromptSession {
	package func setActiveTabID(_ tabID: UUID?) {
		activeTabID = tabID
	}
}
