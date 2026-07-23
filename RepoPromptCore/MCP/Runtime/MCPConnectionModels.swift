import Foundation
import MCP

/// Purpose of an MCP connection's run, used to route UI or headless policy.
public enum MCPRunPurpose: String, Sendable, Codable {
	case discoverRun
	case agentModeRun
	case delegateEditRun
	case unknown
}

public enum ConnectionStateSnapshot: Equatable {
	case connecting
	case ready
	case failed(Swift.Error?)
	case cancelled

	public static func == (lhs: Self, rhs: Self) -> Bool {
		switch (lhs, rhs) {
		case (.connecting, .connecting), (.ready, .ready), (.cancelled, .cancelled):
			return true
		case (.failed, .failed):
			return true
		default:
			return false
		}
	}
}

package protocol MCPServerConnection: Actor {
	func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws
	func stop() async
	func notifyToolListChanged() async
	func connectionState() -> ConnectionStateSnapshot
	func isViableForRetention() -> Bool
	func secondsSinceLastActivity() async -> TimeInterval
	nonisolated var isFilesystemBacked: Bool { get }
	nonisolated var connectionFolderURL: URL? { get }
	nonisolated var capabilityToken: String? { get }
	func terminate(reason: TerminationReason, message: String?) async
	func sendProgress(tool: String, kind: RepoPromptProgressKind, stage: String, message: String) async
}

public enum ConnectionTransport: String, Sendable, Codable {
	case network
	case filesystem
}

public enum ConnectionStateSummary: String, Sendable, Codable {
	case setup
	case waiting
	case ready
	case failed
	case cancelled
	case unknown
}

public struct ToolCallHistoryEntry: Sendable {
	public let timestamp: Date
	public let toolName: String
	public let clientName: String
	public let connectionID: UUID

	public init(timestamp: Date, toolName: String, clientName: String, connectionID: UUID) {
		self.timestamp = timestamp
		self.toolName = toolName
		self.clientName = clientName
		self.connectionID = connectionID
	}
}

public enum MCPCallActivityStatus: String, Sendable, Codable {
	case running
	case succeeded
	case failed
	case cancelled
	case timedOut

	public var isTerminal: Bool {
		self != .running
	}
}

public struct MCPMonitorConversationMessage: Sendable, Identifiable, Codable, Equatable {
	public let id: UUID
	public let role: String
	public let text: String
	public let timestamp: Date

	public init(id: UUID = UUID(), role: String, text: String, timestamp: Date = Date()) {
		self.id = id
		self.role = role
		self.text = text
		self.timestamp = timestamp
	}
}

public struct MCPMonitorFileRead: Sendable, Identifiable, Codable, Equatable {
	public let id: UUID
	public var path: String
	public var startLine: Int?
	public var endLine: Int?
	public var totalLines: Int?

	public init(id: UUID = UUID(), path: String, startLine: Int? = nil, endLine: Int? = nil, totalLines: Int? = nil) {
		self.id = id
		self.path = path
		self.startLine = startLine
		self.endLine = endLine
		self.totalLines = totalLines
	}
}

public struct MCPMonitorImageAttachment: Sendable, Identifiable, Codable, Equatable {
	public let id: UUID
	public let path: String?
	public let title: String?
	public let mimeType: String?
	public let isScreenshot: Bool

	public init(
		id: UUID = UUID(),
		path: String?,
		title: String? = nil,
		mimeType: String? = nil,
		isScreenshot: Bool = false
	) {
		self.id = id
		self.path = path
		self.title = title
		self.mimeType = mimeType
		self.isScreenshot = isScreenshot
	}
}

public struct MCPModelInvocation: Sendable, Identifiable, Codable {
	public let id: UUID
	public let source: String
	public var requestedModelID: String?
	public var resolvedModelID: String?
	public var observedModelID: String?
	public var provider: String?
	public var agentRole: String?
	public var agentName: String?
	public var workflowID: String?
	public var workflowName: String?
	public var inputTokens: Int?
	public var outputTokens: Int?
	public var totalTokens: Int?
	public var usageSource: String?
	public var reasoningEffort: String?
	public var status: MCPCallActivityStatus

	public init(
		id: UUID = UUID(),
		source: String,
		requestedModelID: String? = nil,
		resolvedModelID: String? = nil,
		observedModelID: String? = nil,
		provider: String? = nil,
		agentRole: String? = nil,
		agentName: String? = nil,
		workflowID: String? = nil,
		workflowName: String? = nil,
		inputTokens: Int? = nil,
		outputTokens: Int? = nil,
		totalTokens: Int? = nil,
		usageSource: String? = nil,
		reasoningEffort: String? = nil,
		status: MCPCallActivityStatus = .running
	) {
		self.id = id
		self.source = source
		self.requestedModelID = requestedModelID
		self.resolvedModelID = resolvedModelID
		self.observedModelID = observedModelID
		self.provider = provider
		self.agentRole = agentRole
		self.agentName = agentName
		self.workflowID = workflowID
		self.workflowName = workflowName
		self.inputTokens = inputTokens
		self.outputTokens = outputTokens
		self.totalTokens = totalTokens
		self.usageSource = usageSource
		self.reasoningEffort = reasoningEffort
		self.status = status
	}
}

public struct MCPCallActivity: Sendable, Identifiable, Codable {
	public let id: UUID
	public let toolName: String
	public let operation: String?
	public let connectionID: UUID
	public let clientName: String
	public let windowID: Int?
	public let workspaceID: UUID?
	public let workspaceName: String?
	public let startedAt: Date
	public var endedAt: Date?
	public var durationMS: Double?
	public var status: MCPCallActivityStatus
	public var errorSummary: String?
	public var requestedRole: String?
	public var resolvedRole: String?
	public var agentName: String?
	public var requestedWorkflow: String?
	public var resolvedWorkflowID: String?
	public var resolvedWorkflowName: String?
	public var conversationID: UUID?
	public var conversationName: String?
	public var conversationMessages: [MCPMonitorConversationMessage]
	public var fileReads: [MCPMonitorFileRead]
	public var images: [MCPMonitorImageAttachment]
	public var modelInvocations: [MCPModelInvocation]

	public init(
		id: UUID,
		toolName: String,
		operation: String?,
		connectionID: UUID,
		clientName: String,
		windowID: Int?,
		workspaceID: UUID?,
		workspaceName: String?,
		startedAt: Date,
		endedAt: Date? = nil,
		durationMS: Double? = nil,
		status: MCPCallActivityStatus = .running,
		errorSummary: String? = nil,
		requestedRole: String? = nil,
		resolvedRole: String? = nil,
		agentName: String? = nil,
		requestedWorkflow: String? = nil,
		resolvedWorkflowID: String? = nil,
		resolvedWorkflowName: String? = nil,
		conversationID: UUID? = nil,
		conversationName: String? = nil,
		conversationMessages: [MCPMonitorConversationMessage] = [],
		fileReads: [MCPMonitorFileRead] = [],
		images: [MCPMonitorImageAttachment] = [],
		modelInvocations: [MCPModelInvocation] = []
	) {
		self.id = id
		self.toolName = toolName
		self.operation = operation
		self.connectionID = connectionID
		self.clientName = clientName
		self.windowID = windowID
		self.workspaceID = workspaceID
		self.workspaceName = workspaceName
		self.startedAt = startedAt
		self.endedAt = endedAt
		self.durationMS = durationMS
		self.status = status
		self.errorSummary = errorSummary
		self.requestedRole = requestedRole
		self.resolvedRole = resolvedRole
		self.agentName = agentName
		self.requestedWorkflow = requestedWorkflow
		self.resolvedWorkflowID = resolvedWorkflowID
		self.resolvedWorkflowName = resolvedWorkflowName
		self.conversationID = conversationID
		self.conversationName = conversationName
		self.conversationMessages = conversationMessages
		self.fileReads = fileReads
		self.images = images
		self.modelInvocations = modelInvocations
	}
}

public struct ConnectionDashboardEntry: Sendable, Identifiable, Codable {
	public let id: UUID
	public let clientName: String
	public let windowID: Int?
	public let transport: ConnectionTransport
	public let state: ConnectionStateSummary
	public let createdAt: Date
	public let lastToolCallAt: Date?
	public let totalToolCalls: Int
	public let idleSeconds: TimeInterval?
	public let hasInFlightCalls: Bool
	public let activeToolName: String?
	public let sessionKey: String?

	public init(
		id: UUID,
		clientName: String,
		windowID: Int?,
		transport: ConnectionTransport,
		state: ConnectionStateSummary,
		createdAt: Date,
		lastToolCallAt: Date?,
		totalToolCalls: Int,
		idleSeconds: TimeInterval?,
		hasInFlightCalls: Bool,
		activeToolName: String?,
		sessionKey: String?
	) {
		self.id = id
		self.clientName = clientName
		self.windowID = windowID
		self.transport = transport
		self.state = state
		self.createdAt = createdAt
		self.lastToolCallAt = lastToolCallAt
		self.totalToolCalls = totalToolCalls
		self.idleSeconds = idleSeconds
		self.hasInFlightCalls = hasInFlightCalls
		self.activeToolName = activeToolName
		self.sessionKey = sessionKey
	}
}

public struct NetworkDashboardSnapshot: Sendable {
	public let isRunning: Bool
	public let connections: [ConnectionDashboardEntry]
	public let recentToolCalls: [ToolCallHistoryEntry]
	public let activeToolCalls: [MCPCallActivity]
	public let recentToolActivity: [MCPCallActivity]
	public let totalToolCallsSinceLaunch: Int
	public let errorToolCallsSinceLaunch: Int
	public let providerReportedInputTokensSinceLaunch: Int?
	public let providerReportedOutputTokensSinceLaunch: Int?

	public init(
		isRunning: Bool,
		connections: [ConnectionDashboardEntry],
		recentToolCalls: [ToolCallHistoryEntry],
		activeToolCalls: [MCPCallActivity] = [],
		recentToolActivity: [MCPCallActivity] = [],
		totalToolCallsSinceLaunch: Int = 0,
		errorToolCallsSinceLaunch: Int = 0,
		providerReportedInputTokensSinceLaunch: Int? = nil,
		providerReportedOutputTokensSinceLaunch: Int? = nil
	) {
		self.isRunning = isRunning
		self.connections = connections
		self.recentToolCalls = recentToolCalls
		self.activeToolCalls = activeToolCalls
		self.recentToolActivity = recentToolActivity
		self.totalToolCallsSinceLaunch = totalToolCallsSinceLaunch
		self.errorToolCallsSinceLaunch = errorToolCallsSinceLaunch
		self.providerReportedInputTokensSinceLaunch = providerReportedInputTokensSinceLaunch
		self.providerReportedOutputTokensSinceLaunch = providerReportedOutputTokensSinceLaunch
	}
}

public struct IdentityContextSnapshot: Sendable {
	public enum Source: String, Sendable {
		case unknown
		case filesystemMeta
		case handshake
	}

	public let connectionID: UUID
	public let clientName: String?
	public let capabilityToken: String?
	public let source: Source
	public let hasHandshake: Bool
	public let lastUpdated: Date

	public init(
		connectionID: UUID,
		clientName: String?,
		capabilityToken: String?,
		source: Source,
		hasHandshake: Bool,
		lastUpdated: Date
	) {
		self.connectionID = connectionID
		self.clientName = clientName
		self.capabilityToken = capabilityToken
		self.source = source
		self.hasHandshake = hasHandshake
		self.lastUpdated = lastUpdated
	}
}
