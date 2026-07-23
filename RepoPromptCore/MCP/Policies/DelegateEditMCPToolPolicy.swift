import Foundation

/// MCP tool policy for delegate-edit agent runs.
/// Only the safe sandbox-edit surface, file_search, and read_file are exposed.
/// The live apply_edits file-content-edit capability is restricted.
/// Delegate edit is a focused single-file operation with sandboxed file access.
public enum DelegateEditMCPToolPolicy {
	/// Delegate edit is a focused operation that only needs file reading and sandboxed editing.
	public static let restrictedCapabilities: Set<MCPToolCapability> = [
		.conversationSend,
		.agentConversationSend,
		.conversationHelper,
		.fileManagement,
		.contextBinding,
		.workspaceManagement,
		.discovery,
		.userInteraction,
		.contextRender,
		.structuralExplore,
		.contextMutate,
		.fileContentEdit,

		.gitRead,
		.agentExternalControl,
		.agentExploreControl,
		.agentReasoningControl,
		.agentSessionControl
	]

	public static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

	/// Delegate edit does not grant any additional policy-gated tools.
	public static let grantedCapabilities: Set<MCPToolCapability> = []
	public static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)
}
