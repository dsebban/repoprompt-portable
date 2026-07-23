import Foundation

public enum MCPAgentKind: String, Sendable, Hashable {
	case codexExec
	case claudeCode
	case claudeCodeGLM
	case kimiCode
	case customClaudeCompatible
	case gemini
	case openCode
	case cursor
}

public enum MCPTaskLabelKind: String, CaseIterable, Sendable, Hashable {
	case explore
	case engineer
	case pair
	case design
	case proEdit = "pro_edit"
}
