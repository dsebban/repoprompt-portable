import Foundation

/// MCP tool policy for discovery agent runs.
/// Controls which tools are restricted and which special tools are granted.
public enum DiscoverMCPToolPolicy {
	/// Discovery agents should explore and plan, not make changes or manage state.
	public static let restrictedCapabilities: Set<MCPToolCapability> = [
		.conversationSend,
		.agentConversationSend,
		.conversationHelper,
		.fileContentEdit,
		.fileManagement,
		.contextBinding,
		.workspaceManagement,
		.discovery,
		.appSettings,

		.agentExternalControl,
		.agentExploreControl,
		.agentReasoningControl,
		.agentSessionControl
	]

	public static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

	/// Tools granted to discovery runs (from MCPPolicyGatedTools).
	/// These are conditionally granted based on user settings (allowClarifyingQuestions).
	public static let grantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction
	]

	public static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)
}
