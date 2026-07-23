import Foundation

/// Capability-level grouping for MCP tool policy decisions.
/// Policies should express intent in terms of capabilities and derive tool names from this map.
public enum MCPToolCapability: CaseIterable, Hashable, Sendable {
	case conversationSend
	case conversationHelper
	case conversationLog
	case contextMutate
	case contextRender
	case contextBinding
	case workspaceManagement
	case discovery
	case userInteraction
	case agentExternalControl
	case agentExploreControl
	case agentReasoningControl
	case agentSessionControl
	case fileContentEdit
	case fileManagement
	case structuralExplore
	case agentConversationSend
	case gitRead
	case appSettings

	/// Stable snake_case name for MCP discovery serialization.
	public var externalName: String {
		switch self {
		case .conversationSend: return "conversation_send"
		case .conversationHelper: return "conversation_helper"
		case .conversationLog: return "conversation_log"
		case .contextMutate: return "context_mutate"
		case .contextRender: return "context_render"
		case .contextBinding: return "context_binding"
		case .workspaceManagement: return "workspace_management"
		case .discovery: return "discovery"
		case .userInteraction: return "user_interaction"
		case .agentExternalControl: return "agent_external_control"
		case .agentExploreControl: return "agent_explore_control"
		case .agentReasoningControl: return "agent_reasoning_control"
		case .agentConversationSend: return "agent_conversation_send"
		case .agentSessionControl: return "agent_session_control"
		case .fileContentEdit: return "file_content_edit"
		case .fileManagement: return "file_management"
		case .structuralExplore: return "structural_explore"
		case .gitRead: return "git_read"
		case .appSettings: return "app_settings"
		}
	}
}

public enum MCPToolCapabilities {
	private static let capabilityToTools: [MCPToolCapability: Set<String>] = [
		.conversationSend: [
			"oracle_send"
		],
		.agentConversationSend: [
			"ask_oracle"
		],
		.conversationHelper: [
			"oracle_utils"
		],
		.conversationLog: [
			"oracle_chat_log"
		],
		.contextMutate: [
			"manage_selection",
			"prompt"
		],
		.contextRender: [
			"workspace_context"
		],
		.contextBinding: [
			"bind_context"
		],
		.workspaceManagement: [
			"manage_workspaces"
		],
		.discovery: [
			"context_builder"
		],
		.userInteraction: [
			"ask_user"
		],
		.agentExternalControl: [
			"agent_run",
			"agent_manage"
		],
		.agentExploreControl: [
			"agent_explore"
		],
		.agentReasoningControl: [
			"share_thoughts",
			"wait_for_next_user_instruction"
		],
		.agentSessionControl: [
			"set_status"
		],
		.fileContentEdit: [
			"apply_edits",
			"pro_edit"
		],
		.fileManagement: [
			"file_actions"
		],
		.structuralExplore: [
			"get_file_tree",
			"get_code_structure"
		],
		.gitRead: [
			"git"
		],
		.appSettings: [
			"app_settings"
		]
	]

	public static func toolNames(for capabilities: Set<MCPToolCapability>) -> Set<String> {
		capabilities.reduce(into: Set<String>()) { partialResult, capability in
			partialResult.formUnion(capabilityToTools[capability] ?? [])
		}
	}

	public static func capabilities(for toolName: String) -> Set<MCPToolCapability> {
		Set(capabilityToTools.compactMap { capability, tools in
			tools.contains(toolName) ? capability : nil
		})
	}
}
