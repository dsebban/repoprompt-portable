import Foundation

/// Persisted routing state for MCP client connections.
/// Allows routing to survive app restarts and connection churn.
package struct MCPRoutingState: Codable, Sendable {
	package struct ClientRecord: Codable, Sendable {
		/// MCP clientInfo.name – canonical identity string
		package var clientID: String

		/// Last known transport for this client (for debugging)
		package enum Transport: String, Codable, Sendable {
			case network
			case filesystem
		}
		package var lastTransport: Transport

		/// Optional "session key" to disambiguate multiple instances of same client.
		/// Correlates CLI sessions across reconnections.
		package var sessionKey: String?

		/// Last known RepoPrompt window ID for this client (if still valid)
		package var lastWindowID: Int?

		/// Last known workspace UUID - stable across restarts
		package var lastWorkspaceID: UUID?

		/// Last known workspace instance number - deterministic after restore
		/// Used as fallback when workspace UUID doesn't match (e.g., user didn't restore workspaces)
		package var lastWorkspaceInstanceNumber: Int?

		/// Explicit compose-tab binding for this exact client session.
		/// Restored only after validating the workspace and tab still exist.
		package var lastContextID: UUID?
		package var wasExplicitContextBinding: Bool?

		/// For debugging / dashboards
		package var lastConnectionUUID: UUID?


		/// Last time this record was confirmed by a live connection
		package var lastSeenAt: Date

		package init(
			clientID: String,
			lastTransport: Transport,
			sessionKey: String?,
			lastWindowID: Int?,
			lastWorkspaceID: UUID?,
			lastWorkspaceInstanceNumber: Int?,
			lastContextID: UUID? = nil,
			wasExplicitContextBinding: Bool? = nil,
			lastConnectionUUID: UUID?,
			lastSeenAt: Date
		) {
			self.clientID = clientID
			self.lastTransport = lastTransport
			self.sessionKey = sessionKey
			self.lastWindowID = lastWindowID
			self.lastWorkspaceID = lastWorkspaceID
			self.lastWorkspaceInstanceNumber = lastWorkspaceInstanceNumber
			self.lastContextID = lastContextID
			self.wasExplicitContextBinding = wasExplicitContextBinding
			self.lastConnectionUUID = lastConnectionUUID
			self.lastSeenAt = lastSeenAt
		}
	}

	/// Keyed by clientID (and refined by sessionKey in helpers)
	package var records: [String: [ClientRecord]] = [:]

	package init(records: [String: [ClientRecord]] = [:]) {
		self.records = records
	}
}

/// Storage helper for MCPRoutingState persistence.
package enum MCPRoutingStateStore {
	/// Set to true to enable debug logging for MCP routing state operations
	package static var debugLoggingEnabled = false
	package static var url: URL {
		RepoPromptRuntimeIdentity.applicationSupportURL(["mcp-routing.json"])
	}

	package static func load() -> MCPRoutingState {
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		guard
			let data = try? Data(contentsOf: url),
			let state = try? decoder.decode(MCPRoutingState.self, from: data)
		else {
			#if DEBUG
			if debugLoggingEnabled {
				print("[MCPRoutingStateStore] load() - no existing state or decode failed at \(url.path)")
			}
			#endif
			return MCPRoutingState()
		}
		#if DEBUG
		if debugLoggingEnabled {
			print("[MCPRoutingStateStore] load() - loaded \(state.records.count) clients from \(url.path)")
			for (clientID, records) in state.records {
				for r in records {
					print("[MCPRoutingStateStore]   client='\(clientID)' sessionKey=\(r.sessionKey?.prefix(8) ?? "nil") wsID=\(r.lastWorkspaceID?.uuidString.prefix(8) ?? "nil") inst=\(r.lastWorkspaceInstanceNumber ?? -1) window=\(r.lastWindowID ?? -1)")
				}
			}
		}
		#endif
		return state
	}

	package static func save(_ state: MCPRoutingState) {
		// Ensure directory exists
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
		encoder.dateEncodingStrategy = .iso8601
		if let data = try? encoder.encode(state) {
			try? data.write(to: url, options: .atomic)
		}
	}
}
