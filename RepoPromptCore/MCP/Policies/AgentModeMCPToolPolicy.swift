import Foundation

/// MCP tool policy for agent mode runs.
/// Controls which tools are restricted and which special tools are granted.
public enum AgentModeMCPToolPolicy {
	/// Agent mode is tab-scoped, so advanced routing and the live oracle helper surface stay blocked.
	public static let restrictedCapabilities: Set<MCPToolCapability> = [
		.contextBinding,
		.workspaceManagement,
		.conversationHelper,
		.conversationSend
	]

	public static let restrictedTools: Set<String> = MCPToolCapabilities.toolNames(for: restrictedCapabilities)

	/// Tools granted to legacy/generic agent mode runs (from MCPPolicyGatedTools).
	/// These enable user interaction, agent workflow control, and agent-only oracle recovery.
	public static let grantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction,
		.agentReasoningControl,
		.agentSessionControl,
		.agentConversationSend,
		.conversationLog
	]

	public static let grantedTools: Set<String> = MCPToolCapabilities.toolNames(for: grantedCapabilities)

	/// Tools granted to Claude native-style agent runs.
	/// Claude no longer relies on share_thoughts or wait_for_next_user_instruction,
	/// but it does use set_status to rename the active session.
	static let claudeNativeGrantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction,
		.agentSessionControl,
		.agentConversationSend,
		.conversationLog
	]

	public static let claudeNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: claudeNativeGrantedCapabilities)

	/// Tools granted to Codex native agent runs.
	/// Codex native still needs ask_user + set_status even though it doesn't use
	/// share_thoughts or wait_for_next_user_instruction.
	/// set_status is title-only; running status now comes from native reasoning summaries.
	static let codexNativeGrantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction,
		.agentSessionControl,
		.agentConversationSend,
		.conversationLog
	]

	public static let codexNativeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: codexNativeGrantedCapabilities)

	/// Gemini ACP should keep ask_user/set_status/oracle recovery, but no longer relies on
	/// share_thoughts or wait_for_next_user_instruction.
	static let geminiGrantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction,
		.agentSessionControl,
		.agentConversationSend,
		.conversationLog
	]

	public static let geminiGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: geminiGrantedCapabilities)

	/// OpenCode ACP uses the same Agent Mode app/session control surface as Gemini.
	static let openCodeGrantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction,
		.agentSessionControl,
		.agentConversationSend,
		.conversationLog
	]

	public static let openCodeGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: openCodeGrantedCapabilities)

	/// Cursor ACP uses the same Agent Mode app/session control surface as Gemini/OpenCode.
	static let cursorGrantedCapabilities: Set<MCPToolCapability> = [
		.userInteraction,
		.agentSessionControl,
		.agentConversationSend,
		.conversationLog
	]

	public static let cursorGrantedTools: Set<String> = MCPToolCapabilities.toolNames(for: cursorGrantedCapabilities)

	public static func grantedTools(forAgentKind agentKind: MCPAgentKind) -> Set<String> {
		switch agentKind {
		case .codexExec:
			return codexNativeGrantedTools
		case .claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible:
			return claudeNativeGrantedTools
		case .gemini:
			return geminiGrantedTools
		case .openCode:
			return openCodeGrantedTools
		case .cursor:
			return cursorGrantedTools
		}
	}
}
