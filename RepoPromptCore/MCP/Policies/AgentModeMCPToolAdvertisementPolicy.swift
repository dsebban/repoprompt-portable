import Foundation

/// Advertisement-only tool filtering for MCP-started agent runs based on task label role.
///
/// This policy controls which tools are **hidden from `ListTools`** responses based on the
/// agent's role. It is intentionally separate from execution-time restrictions (`restrictedTools`)
/// — hidden tools are not advertised but remain technically callable if invoked by name.
///
/// Related:
/// - MCPToolCapabilities.swift (capability → tool name mapping)
/// - DiscoverMCPToolPolicy.swift (discover agent restrictions — reused for explore role)
/// - AgentModeMCPToolPolicy.swift (agent mode execution-time restrictions)
/// - MCPConnectionManager.swift (ListTools handler — consumer of this policy)
public enum AgentModeMCPToolAdvertisementPolicy {

	// MARK: - Precomputed hidden tool sets

	/// Tools hidden from `explore` role agents.
	/// Explore agents get a minimal read-only toolset: file_search, get_file_tree,
	/// get_code_structure, read_file, git, ask_user, set_status.
	/// Everything else is hidden: editing, oracle, context_builder, agent delegation,
	/// manage_selection, workspace_context, prompt.
	private static let exploreHiddenTools: Set<String> = {
		// Start from discover agent restrictions (which already block edits, oracle, context_builder, agent control)
		var capabilities = DiscoverMCPToolPolicy.restrictedCapabilities
		// Remove reasoning/session control — explore agents can use set_status and share_thoughts
		capabilities.remove(.agentReasoningControl)
		capabilities.remove(.agentSessionControl)
		// App settings are safe allowlisted preferences and should be visible to agent-mode subagents;
		// discovery/context-builder runs remain restricted by DiscoverMCPToolPolicy itself.
		capabilities.remove(.appSettings)
		// Add conversation log hiding — explore agents don't need oracle_chat_log
		capabilities.insert(.conversationLog)
		// Hide context mutation tools (manage_selection, prompt) and context render (workspace_context)
		// Explore agents should use read_file and file_search directly, not curate selections
		capabilities.insert(.contextMutate)
		capabilities.insert(.contextRender)

		return MCPToolCapabilities.toolNames(for: capabilities)
	}()

	/// Tools hidden from non-explore role agents (engineer, pair, design, pro_edit) by default.
	/// The run policy can opt back into agent_run/agent_manage for allowed orchestrator sessions.
	private static let nonExploreRoleHiddenTools: Set<String> = {
		MCPToolCapabilities.toolNames(for: [.agentExternalControl])
	}()

	// MARK: - Public API

	/// Returns the set of tool names that should be hidden from `ListTools` for the given role.
	///
	/// - Parameter taskLabelKind: The resolved task label role, or `nil` for direct/non-role connections.
	/// - Returns: Tool names to hide. Empty set means no role-based hiding.
	public static func hiddenToolNames(for taskLabelKind: MCPTaskLabelKind?) -> Set<String> {
		let exploreControlTools = MCPToolCapabilities.toolNames(for: [.agentExploreControl])
		guard let taskLabelKind else { return exploreControlTools }
		switch taskLabelKind {
		case .explore:
			return exploreHiddenTools.union(exploreControlTools)
		case .engineer, .pair, .design, .proEdit:
			return nonExploreRoleHiddenTools
		}
	}

	/// Whether a tool should be advertised for the given role.
	///
	/// - Parameters:
	///   - toolName: The MCP tool name to check.
	///   - taskLabelKind: The resolved task label role, or `nil` for direct/non-role connections.
	/// - Returns: `true` if the tool should be included in `ListTools` results.
	public static func shouldAdvertise(toolName: String, taskLabelKind: MCPTaskLabelKind?) -> Bool {
		if MCPToolCapabilities.capabilities(for: toolName).contains(.agentExploreControl) {
			guard let taskLabelKind else { return false }
			switch taskLabelKind {
			case .explore:
				return false
			case .engineer, .pair, .design, .proEdit:
				return true
			}
		}

		guard let taskLabelKind else { return true }
		switch taskLabelKind {
		case .explore:
			return !exploreHiddenTools.contains(toolName)
		case .engineer, .pair, .design, .proEdit:
			return !nonExploreRoleHiddenTools.contains(toolName)
		}
	}

	/// Whether a tool should be advertised for the given role, optionally allowing
	/// agent control tools when the current run policy permits orchestration.
	public static func shouldAdvertise(
		toolName: String,
		taskLabelKind: MCPTaskLabelKind?,
		allowsAgentExternalControlTools: Bool
	) -> Bool {
		if taskLabelKind != .explore,
			allowsAgentExternalControlTools,
			MCPToolCapabilities.capabilities(for: toolName).contains(.agentExternalControl) {
			return true
		}
		return shouldAdvertise(toolName: toolName, taskLabelKind: taskLabelKind)
	}
}
