import Foundation

/// Tools that are hidden from normal MCP connections unless explicitly granted via `additionalTools`
/// in a connection policy. These include special-purpose tools and legacy compatibility surfaces.
public enum MCPPolicyGatedTools {
	public static let gatedCapabilities: Set<MCPToolCapability> = [
		.userInteraction,
		.agentReasoningControl,
		.agentSessionControl,

		.agentConversationSend,
		.conversationLog
	]

	/// Tool names that require explicit policy grant to be visible/callable.
	public static let names: Set<String> = MCPToolCapabilities.toolNames(for: gatedCapabilities)
}
