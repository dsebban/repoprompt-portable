import Foundation

/// Build-flavor identity and filesystem roots for RepoPrompt Classic.
///
/// Keep user-visible/runtime identifiers centralized so the Classic app can run
/// side-by-side with original RepoPrompt without sharing LaunchServices, MCP,
/// CLI, or file-backed state.
package enum RepoPromptRuntimeIdentity {
	package static let displayName = "RepoPrompt Classic"
	package static let releaseBundleIdentifier = "com.pvncher.repoprompt.classic"
	package static let debugBundleIdentifier = "debug.pvncher.repoprompt.classic"

	package static let urlName = "com.pvncher.repoprompt.classic"
	package static let urlScheme = "repoprompt-classic"
	package static let documentTypeIdentifier = "com.pvncher.repoprompt.classic.document"
	package static let documentTypeName = "RepoPrompt Classic Document"

	package static let applicationSupportDirectoryName = "RepoPrompt Classic"
	package static let debugAppsDirectoryName = "DebugApps"
	package static let debugAppBundleName = "RepoPrompt.app"
	package static let originalApplicationSupportDirectoryName = "RepoPrompt"
	package static let originalBundleSupportDirectoryName = "com.pvncher.repoprompt"

	package static let mcpSocketDirectoryName = "repoprompt-classic-mcp"
	package static let mcpSocketBaseName = "repoprompt-classic"

	package static var stableCLILinkName: String {
		#if DEBUG
		"repoprompt_classic_cli_debug"
		#else
		"repoprompt_classic_cli"
		#endif
	}

	package static var cliCommandName: String {
		#if DEBUG
		"rp-classic-debug"
		#else
		"rp-classic"
		#endif
	}

	package static var claudeWrapperCommandName: String {
		#if DEBUG
		"claude-rp-classic-debug"
		#else
		"claude-rp-classic"
		#endif
	}

	package static var mcpServerConfigurationName: String {
		#if DEBUG
		"repoprompt-classic"
		#else
		"repoprompt-classic-mcp"
		#endif
	}

	package static var managedSkillNamePrefix: String {
		#if DEBUG
		"rp-classic-debug"
		#else
		"rp-classic"
		#endif
	}

	package static func applicationSupportRoot(fileManager: FileManager = .default) -> URL {
		fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
	}

	package static func applicationSupportURL(_ components: [String], fileManager: FileManager = .default) -> URL {
		components.reduce(applicationSupportRoot(fileManager: fileManager)) { partial, component in
			partial.appendingPathComponent(component)
		}
	}

	package static func debugAppsRoot(fileManager: FileManager = .default) -> URL {
		applicationSupportURL([debugAppsDirectoryName], fileManager: fileManager)
	}

	package static func debugAppBundleURL(fileManager: FileManager = .default) -> URL {
		debugAppsRoot(fileManager: fileManager)
			.appendingPathComponent(debugAppBundleName, isDirectory: true)
	}

	@discardableResult
	package static func ensureApplicationSupportDirectory(_ components: [String], fileManager: FileManager = .default) throws -> URL {
		let url = applicationSupportURL(components, fileManager: fileManager)
		try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	package static func originalApplicationSupportRoot(fileManager: FileManager = .default) -> URL {
		fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent(originalApplicationSupportDirectoryName, isDirectory: true)
	}

	package static func originalBundleScopedSupportRoot(fileManager: FileManager = .default) -> URL {
		fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
			.appendingPathComponent(originalBundleSupportDirectoryName, isDirectory: true)
	}
}
