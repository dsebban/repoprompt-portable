import Foundation

public actor WorkspaceSessionStore {
	private var sessions: [UUID: RepoPromptSession] = [:]
	private var activeSessionID: UUID?

	public init() {}

	@discardableResult
	public func upsert(_ session: RepoPromptSession, activate: Bool = false) async -> UUID {
		let id = await session.id
		sessions[id] = session
		if activate || activeSessionID == nil {
			activeSessionID = id
		}
		return id
	}

	public func session(id: UUID) -> RepoPromptSession? {
		sessions[id]
	}

	public func activeSession() -> RepoPromptSession? {
		guard let activeSessionID else { return nil }
		return sessions[activeSessionID]
	}

	public func setActiveSession(id: UUID) -> Bool {
		guard sessions[id] != nil else { return false }
		activeSessionID = id
		return true
	}

	public func snapshots() async -> [RepoPromptSessionSnapshot] {
		var values: [RepoPromptSessionSnapshot] = []
		for session in sessions.values {
			values.append(await session.snapshot())
		}
		return values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
	}
}
