import Foundation

// MARK: - MCP Debug Logging

#if DEBUG
private var mcpFilesystemConstantsDebugLoggingEnabled = false
private func mcpFilesystemConstantsDebugLog(_ message: @autoclosure () -> String) {
	guard mcpFilesystemConstantsDebugLoggingEnabled else { return }
	print("[MCPFilesystemConstants] \(message())")
}
#else
private func mcpFilesystemConstantsDebugLog(_ message: @autoclosure () -> String) {}
#endif

/// Centralized debug logging control for MCP transport layer.
/// Set flags to false to reduce console spam.
package enum MCPDebugLogging {
	/// Log transport-level details (send/receive byte counts, message previews)
	package static var transportVerbose = false

	/// Log connection lifecycle events (connect, disconnect, EOF)
	package static var connectionLifecycle = false

	/// Log routing decisions and tab context binding
	package static var routing = false

	/// Log all debug messages (master switch - overrides individual flags when false)
	package static var enabled = false
}

/// Logs MCP transport-level debug messages when enabled.
@inline(__always)
package func mcpTransportLog(_ message: @autoclosure () -> String) {
	#if DEBUG
	if MCPDebugLogging.enabled && MCPDebugLogging.transportVerbose {
		print("[MCPTransport] \(message())")
	}
	#endif
}

/// Logs MCP connection lifecycle debug messages when enabled.
@inline(__always)
package func mcpConnectionLog(_ message: @autoclosure () -> String) {
	#if DEBUG
	if MCPDebugLogging.enabled && MCPDebugLogging.connectionLifecycle {
		print("[MCPConnection] \(message())")
	}
	#endif
}

/// Logs MCP routing debug messages when enabled.
@inline(__always)
package func mcpRoutingDebugLog(_ message: @autoclosure () -> String) {
	#if DEBUG
	if MCPDebugLogging.enabled && MCPDebugLogging.routing {
		print("[MCPRouting] \(message())")
	}
	#endif
}

package enum MCPFilesystemConstants {
	// UNIX domain socket transport
	// Socket placed in user's temp directory (via FileManager.temporaryDirectory)
	// This uses /var/folders/... which may be treated differently by firewalls than /tmp
	// sun_path limit is 104 bytes - typical path is ~70 bytes, well under limit
	static let socketDirName = RepoPromptRuntimeIdentity.mcpSocketDirectoryName

	/// Internal override for testing. Never set this in production code.
	/// Tests use this to compute paths under a temp directory instead of /tmp.
	package static var _testSocketDirectoryBase: URL? = nil

	/// Returns the primary socket directory URL in /tmp.
	/// Uses /tmp/repoprompt-classic-mcp-{uid}/ which:
	/// - Is accessible by external sandboxed apps (Claude Desktop, Cursor, etc.)
	/// - Per-user suffix prevents conflicts between users
	/// - Is a well-known, stable path (not containerized per-app)
	static func socketDirectoryURL() -> URL {
		if let testBase = _testSocketDirectoryBase {
			return testBase.appendingPathComponent("\(socketDirName)-\(POSIXCompat.getUID())", isDirectory: true)
		}
		let uid = POSIXCompat.getUID()
		return URL(fileURLWithPath: "/tmp/\(socketDirName)-\(uid)", isDirectory: true)
	}

	/// Returns the legacy socket directory URL (FileManager.temporaryDirectory).
	/// Used for symlink creation to maintain backwards compatibility with old CLIs.
	static func legacySocketDirectoryURL() -> URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent(socketDirName, isDirectory: true)
	}

	/// Creates the socket directory with secure permissions (0700)
	/// - Returns: true if directory exists or was created successfully
	@discardableResult
	package static func ensureSocketDirectoryExists() -> Bool {
		let url = socketDirectoryURL()
		let fm = FileManager.default

		if fm.fileExists(atPath: url.path) {
			return true
		}

		do {
			// Create with owner-only permissions for security
			try fm.createDirectory(
				at: url,
				withIntermediateDirectories: true,
				attributes: [.posixPermissions: 0o700]
			)
			return true
		} catch {
			mcpFilesystemConstantsDebugLog("Failed to create socket directory: \(error)")
			return false
		}
	}

	// MARK: - Bootstrap Socket (Single App-Owned Socket)

	/// Name of the single bootstrap socket owned by the app.
	/// CLI connects to this socket for all MCP communication.
	///
	/// Socket naming scheme (includes version to force old CLIs to disconnect on upgrade):
	/// - Debug builds: `repoprompt-classic-D-{version}.sock`
	/// - Release builds: `repoprompt-classic-{version}.sock`
	///
	/// Version history:
	/// - v6: Moved socket from /tmp to FileManager.temporaryDirectory, added version suffix
	///
	/// Keep path short due to sun_path 104-byte limit.
	static let socketVersion = 6

	static var bootstrapSocketName: String {
		#if DEBUG
		"\(RepoPromptRuntimeIdentity.mcpSocketBaseName)-D-\(socketVersion).sock"
		#else
		"\(RepoPromptRuntimeIdentity.mcpSocketBaseName)-\(socketVersion).sock"
		#endif
	}

	/// Returns the bootstrap socket URL.
	/// This is a single well-known socket that the app listens on.
	/// CLI connects to this socket to initiate MCP sessions.
	package static func bootstrapSocketURL() -> URL {
		socketDirectoryURL().appendingPathComponent(bootstrapSocketName, isDirectory: false)
	}

	/// Returns the legacy bootstrap socket URL (in FileManager.temporaryDirectory).
	/// Used for symlink creation to maintain backwards compatibility with old CLIs.
	static func legacyBootstrapSocketURL() -> URL {
		legacySocketDirectoryURL().appendingPathComponent(bootstrapSocketName, isDirectory: false)
	}

	/// Creates a symlink from the legacy socket path to the new socket path.
	/// This allows old CLIs (looking at /var/folders/...) to connect via symlink.
	/// Call this after the real socket is created at bootstrapSocketURL().
	package static func createLegacySymlink() {
		let fm = FileManager.default
		let legacyURL = legacyBootstrapSocketURL()
		let actualURL = bootstrapSocketURL()

		// Ensure legacy directory exists
		let legacyDir = legacySocketDirectoryURL()
		if !fm.fileExists(atPath: legacyDir.path) {
			try? fm.createDirectory(at: legacyDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		}

		// Remove old symlink/file if exists
		try? fm.removeItem(at: legacyURL)

		// Create symlink: legacy -> actual
		do {
			try fm.createSymbolicLink(at: legacyURL, withDestinationURL: actualURL)
			mcpFilesystemConstantsDebugLog("Created legacy symlink: \(legacyURL.path) -> \(actualURL.path)")
		} catch {
			mcpFilesystemConstantsDebugLog("Failed to create legacy symlink: \(error)")
		}
	}

	/// Removes the legacy symlink when the server stops.
	package static func removeLegacySymlink() {
		try? FileManager.default.removeItem(at: legacyBootstrapSocketURL())
	}

	// MARK: - Migration

	/// UserDefaults key for tracking MCP migration version
	private static let migrationVersionKey = "MCPFilesystemMigrationVersion"

	/// Current migration version - bump this when a deep clean is needed
	private static let currentMigrationVersion = 7  // MCP7: Classic namespace isolation

	/// Performs a one-time deep clean when upgrading to a new MCP version.
	/// Only runs once per migration version.
	package static func performMigrationCleanupIfNeeded() {
		let defaults = UserDefaults.standard
		let lastMigration = defaults.integer(forKey: migrationVersionKey)

		guard lastMigration < currentMigrationVersion else {
			return  // Already migrated
		}

		let fm = FileManager.default
		let log: (String) -> Void = { msg in
			mcpFilesystemConstantsDebugLog(msg)
		}

		log("Running MCP migration cleanup (v\(lastMigration) -> v\(currentMigrationVersion))")

		// 1. Remove legacy MCPFS root directory (old filesystem transport)
		let fsRoot = RepoPromptRuntimeIdentity.applicationSupportURL(["MCPFS"], fileManager: fm)
		if fm.fileExists(atPath: fsRoot.path) {
			try? fm.removeItem(at: fsRoot)
			log("Removed legacy MCPFS directory")
		}

		// 2. Remove old shared socket directory (pre per-user migration)
		let oldSocketDir = URL(fileURLWithPath: "/tmp/\(socketDirName)", isDirectory: true)
		if fm.fileExists(atPath: oldSocketDir.path) {
			try? fm.removeItem(at: oldSocketDir)
			log("Removed old shared socket directory")
		}

		// 2b. Remove old Classic /tmp per-user socket directory.
		let uid = POSIXCompat.getUID()
		let oldPerUserSocketDir = URL(fileURLWithPath: "/tmp/\(socketDirName)-\(uid)", isDirectory: true)
		if fm.fileExists(atPath: oldPerUserSocketDir.path) {
			try? fm.removeItem(at: oldPerUserSocketDir)
			log("Removed old /tmp per-user socket directory")
		}

		// 3. Clean up stale sockets in current per-user directory
		let socketDir = socketDirectoryURL()
		if fm.fileExists(atPath: socketDir.path) {
			do {
				let contents = try fm.contentsOfDirectory(at: socketDir, includingPropertiesForKeys: nil)
				for url in contents where url.pathExtension == "sock" {
					try? fm.removeItem(at: url)
					log("Removed stale socket: \(url.lastPathComponent)")
				}
			} catch {
				log("Failed to enumerate socket dir: \(error)")
			}
		}

		// 4. Remove all TCP client cache files created by older CLI versions.
		// These were used by the deprecated TCP transport to recover client identity.
		let cacheDir = RepoPromptRuntimeIdentity.applicationSupportRoot(fileManager: fm)
		if fm.fileExists(atPath: cacheDir.path) {
			do {
				let contents = try fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
				for url in contents where url.lastPathComponent.hasPrefix("tcp-client-cache-") && url.pathExtension == "json" {
					try? fm.removeItem(at: url)
					log("Removed stale TCP cache: \(url.lastPathComponent)")
				}
			} catch {
				log("Failed to enumerate cache dir: \(error)")
			}
		}

		// Mark migration complete
		defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
		log("MCP migration cleanup completed")
	}

	// MARK: - External Client Events Directory

	/// Directory for external client error events.
	/// Gated by build flavor and socket version so different app versions don't cross-pollinate.
	/// e.g. "MCPEvents-6" for release, "MCPEvents-D-6" for debug
	package static func eventsDirectoryURL() -> URL {
		#if DEBUG
		let dirname = "MCPEvents-D-\(socketVersion)"
		#else
		let dirname = "MCPEvents-\(socketVersion)"
		#endif
		return RepoPromptRuntimeIdentity.applicationSupportURL([dirname])
	}
}
