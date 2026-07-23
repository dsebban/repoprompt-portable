//
//  MCPControlMessages.swift
//  RepoPrompt
//
//  Shared control message definitions for app ↔ CLI communication.
//  Used for explicit termination signals and run completion notifications.
//

import Foundation

// MARK: - Control Method Names

/// Control method names for RepoPrompt-specific MCP notifications.
/// These are sent as JSON-RPC notifications (no "id" field) so no response is expected.
package enum RepoPromptControlMethod {
    /// Sent by app to CLI to request clean termination.
    /// CLI should exit gracefully without retrying.
    package static let terminate = "repoprompt/control/terminate"

    /// Sent by app to CLI when a run (context builder, discover agent) completes.
    /// CLI should exit with success status.
    package static let runCompleted = "repoprompt/control/run_completed"

    /// Sent by app to CLI during long-running operations to indicate progress.
    /// CLI can display on stderr to prevent agent timeouts.
    package static let progress = "repoprompt/control/progress"
}

// MARK: - Termination Reasons

/// Reasons why a connection was terminated.
package enum TerminationReason: String, Codable, Sendable {
    /// User clicked disconnect/boot in the MCP status dashboard
    case userBootFromDashboard = "user_boot_from_dashboard"

    /// Context builder or discover agent run completed successfully
    case runCompleted = "run_completed"

    /// Context builder or discover agent run was cancelled
    case runCancelled = "run_cancelled"

    /// Server is shutting down
    case serverShutdown = "server_shutdown"

    /// Connection was idle too long
    case idleTimeout = "idle_timeout"

    /// Approval was denied
    case approvalDenied = "approval_denied"

    /// Connection was replaced by a new connection for the same runID
    case connectionReplaced = "connection_replaced"
}

// MARK: - Control Notification Payloads

/// Parameters for the terminate control notification.
package struct RepoPromptTerminateParams: Codable, Sendable {
    /// Why the connection is being terminated
    package let reason: TerminationReason

    /// Optional human-readable message for logging
    package let message: String?

    /// When the termination was requested (ISO8601)
    package let requestedAt: Date

    package init(reason: TerminationReason, message: String? = nil, requestedAt: Date = Date()) {
        self.reason = reason
        self.message = message
        self.requestedAt = requestedAt
    }
}

/// Parameters for the run completed control notification.
package struct RepoPromptRunCompletedParams: Codable, Sendable {
    /// Type of run that completed
    package let runType: String  // "context_builder", "discover_agent", etc.

    /// Whether the run completed successfully
    package let success: Bool

    /// Optional summary message
    package let summary: String?

    /// When the run completed
    package let completedAt: Date

    package init(runType: String, success: Bool, summary: String? = nil, completedAt: Date = Date()) {
        self.runType = runType
        self.success = success
        self.summary = summary
        self.completedAt = completedAt
    }
}

/// Kind of progress update.
package enum RepoPromptProgressKind: String, Codable, Sendable, Hashable {
    /// Discrete stage transition (e.g., "discovering" → "planning")
    case stage
    /// Periodic heartbeat to indicate operation is still running
    case heartbeat
}

/// Parameters for the progress control notification.
package struct RepoPromptProgressParams: Codable, Sendable, Hashable {
    /// Tool or operation name (e.g., "context_builder", "oracle_send")
    package let tool: String

    /// Kind of progress update
    package let kind: RepoPromptProgressKind

    /// Current stage name (e.g., "discovering", "planning", "waiting_for_response")
    package let stage: String

    /// Short human-readable message
    package let message: String

    /// When this progress was emitted (ISO8601 string)
    package let emittedAt: String

    package init(tool: String, kind: RepoPromptProgressKind, stage: String, message: String, emittedAt: Date = Date()) {
        self.tool = tool
        self.kind = kind
        self.stage = stage
        self.message = message
        // Format date as ISO8601 string for cross-decoder compatibility
        let formatter = ISO8601DateFormatter()
        self.emittedAt = formatter.string(from: emittedAt)
    }
}

// MARK: - JSON-RPC Notification Structure

/// A JSON-RPC 2.0 notification (no id field, so no response expected).
package struct RepoPromptControlNotification<T: Codable & Sendable>: Codable, Sendable {
    package let jsonrpc: String
    package let method: String
    package let params: T

    package init(method: String, params: T) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }

    /// Encodes the notification as a JSON line (with trailing newline) for MCP transport.
    package func jsonLineData() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// MARK: - Convenience Factories

extension RepoPromptControlNotification where T == RepoPromptTerminateParams {
    /// Creates a terminate notification with the given reason.
    package static func terminate(reason: TerminationReason, message: String? = nil) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.terminate,
            params: RepoPromptTerminateParams(reason: reason, message: message)
        )
    }
}

extension RepoPromptControlNotification where T == RepoPromptRunCompletedParams {
    /// Creates a run completed notification.
    package static func runCompleted(runType: String, success: Bool, summary: String? = nil) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.runCompleted,
            params: RepoPromptRunCompletedParams(runType: runType, success: success, summary: summary)
        )
    }
}

extension RepoPromptControlNotification where T == RepoPromptProgressParams {
    /// Creates a progress notification for a stage transition.
    package static func stage(tool: String, stage: String, message: String) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.progress,
            params: RepoPromptProgressParams(tool: tool, kind: .stage, stage: stage, message: message)
        )
    }

    /// Creates a heartbeat progress notification.
    package static func heartbeat(tool: String, stage: String, message: String) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.progress,
            params: RepoPromptProgressParams(tool: tool, kind: .heartbeat, stage: stage, message: message)
        )
    }
}

// MARK: - Kill Signal Files (Filesystem Side-Channel)

/// Kill signals are written to a shared directory that the CLI watches with a DispatchSource.
/// This works for both network and filesystem transports as a reliable side-channel.
/// The CLI sets up a watcher on this directory and exits when it sees its session killed.
package enum MCPKillSignal {
    /// Directory where kill signal files are written
    package static var signalsDirectory: URL {
        RepoPromptRuntimeIdentity.applicationSupportURL(["MCPKillSignals"])
    }

    /// Kill signal file for a specific session token
    package static func signalFileURL(forSessionToken token: String) -> URL {
        signalsDirectory.appendingPathComponent("\(token).kill")
    }

    /// Content of a kill signal file
    package struct SignalContent: Codable, Sendable {
        package let reason: TerminationReason
        package let message: String?
        package let killedAt: Date
    }

    /// Writes a kill signal file for a session.
    /// CLI watches this directory with a DispatchSource and exits when it sees its session killed.
    package static func writeKillSignal(
        sessionToken: String,
        reason: TerminationReason,
        message: String? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: signalsDirectory, withIntermediateDirectories: true)

        let content = SignalContent(
            reason: reason,
            message: message,
            killedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(content)

        let url = signalFileURL(forSessionToken: sessionToken)
        try data.write(to: url, options: .atomic)
    }

    /// Reads a kill signal if it exists for this session.
    package static func readKillSignal(forSessionToken token: String) -> SignalContent? {
        let url = signalFileURL(forSessionToken: token)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SignalContent.self, from: data)
    }

    /// Removes a kill signal file (called by CLI after acknowledging).
    package static func removeKillSignal(forSessionToken token: String) {
        try? FileManager.default.removeItem(at: signalFileURL(forSessionToken: token))
    }

    /// Cleans up old kill signal files (older than 1 hour).
    package static func cleanupStaleSignals() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600) // 1 hour

        guard let contents = try? fm.contentsOfDirectory(
            at: signalsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents where url.pathExtension == "kill" {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}

// MARK: - Detection Helpers

/// Helpers for detecting control messages in incoming data.
enum RepoPromptControlDetection {
    /// Fast check if a JSON line might be a control notification (before full parse).
    /// Checks for the method prefix bytes.
    static func mightBeControlNotification(_ data: Data) -> Bool {
        // Look for "repoprompt/control/" in the data
        let marker = "repoprompt/control/".data(using: .utf8)!
        return data.range(of: marker) != nil
    }

    /// Parses a JSON line and extracts the method if it's a notification.
    /// Returns nil if not a notification or parsing fails.
    static func extractNotificationMethod(from jsonLine: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
              json["id"] == nil,  // Notifications have no id
              let method = json["method"] as? String
        else { return nil }
        return method
    }

    /// Parses terminate params from a JSON line.
    static func parseTerminateParams(from jsonLine: Data) -> RepoPromptTerminateParams? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notification = try? decoder.decode(
            RepoPromptControlNotification<RepoPromptTerminateParams>.self,
            from: jsonLine
        ) else { return nil }
        return notification.params
    }

    /// Parses run completed params from a JSON line.
    static func parseRunCompletedParams(from jsonLine: Data) -> RepoPromptRunCompletedParams? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notification = try? decoder.decode(
            RepoPromptControlNotification<RepoPromptRunCompletedParams>.self,
            from: jsonLine
        ) else { return nil }
        return notification.params
    }

    /// Parses progress params from a JSON line.
    static func parseProgressParams(from jsonLine: Data) -> RepoPromptProgressParams? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notification = try? decoder.decode(
            RepoPromptControlNotification<RepoPromptProgressParams>.self,
            from: jsonLine
        ) else { return nil }
        return notification.params
    }
}
