import Foundation
import RepoPromptCore

public struct HeadlessWorkspaceBootstrapResult: Sendable {
	public let roots: [String]
	public let stateDirectory: String?
	public let session: RepoPromptSession
	public let sessionStore: WorkspaceSessionStore
	public let router: WorkspaceSessionRouter
}

public enum HeadlessWorkspaceBootstrap {
	public static func bootstrap(
		options: HeadlessOptions,
		fileManager: FileManager = .default,
		currentDirectory: String = FileManager.default.currentDirectoryPath
	) async throws -> HeadlessWorkspaceBootstrapResult {
		let roots = try validatedRoots(
			options.roots.isEmpty ? [currentDirectory] : options.roots,
			fileManager: fileManager
		)
		let stateDirectory = try prepareStateDirectory(
			configuredPath: options.stateDir,
			persist: options.persist,
			fileManager: fileManager
		)

		let session = RepoPromptSession(
			id: options.sessionID ?? UUID(),
			name: options.workspaceName ?? defaultWorkspaceName(for: roots),
			rootPaths: roots
		)
		let store = WorkspaceSessionStore()
		await store.upsert(session, activate: true)
		let router = WorkspaceSessionRouter(store: store)

		return HeadlessWorkspaceBootstrapResult(
			roots: roots,
			stateDirectory: stateDirectory,
			session: session,
			sessionStore: store,
			router: router
		)
	}

	public static func validatedRoots(_ rawRoots: [String], fileManager: FileManager = .default) throws -> [String] {
		var roots: [String] = []
		var seen = Set<String>()
		for rawRoot in rawRoots {
			let expanded = (rawRoot as NSString).expandingTildeInPath
			let absolute = expanded.hasPrefix("/") ? expanded : (fileManager.currentDirectoryPath as NSString).appendingPathComponent(expanded)
			let standardized = (absolute as NSString).standardizingPath
			var isDirectory = ObjCBool(false)
			guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory), isDirectory.boolValue else {
				throw HeadlessRuntimeError("Workspace root does not exist or is not a directory: \(rawRoot)", exitCode: .configuration)
			}
			if seen.insert(standardized).inserted {
				roots.append(standardized)
			}
		}
		guard !roots.isEmpty else {
			throw HeadlessRuntimeError("At least one workspace root is required.", exitCode: .configuration)
		}
		return roots
	}

	public static func defaultStateDirectory(homeDirectory: String = NSHomeDirectory()) -> String {
		#if os(macOS)
		return (homeDirectory as NSString).appendingPathComponent("Library/Application Support/RepoPrompt CE/Headless")
		#else
		if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdg.isEmpty {
			return (xdg as NSString).appendingPathComponent("repoprompt-ce/headless")
		}
		return (homeDirectory as NSString).appendingPathComponent(".local/state/repoprompt-ce/headless")
		#endif
	}

	private static func prepareStateDirectory(
		configuredPath: String?,
		persist: Bool,
		fileManager: FileManager
	) throws -> String? {
		guard persist else { return nil }
		let raw = configuredPath ?? defaultStateDirectory()
		let standardized = ((raw as NSString).expandingTildeInPath as NSString).standardizingPath
		try fileManager.createDirectory(
			at: URL(fileURLWithPath: standardized, isDirectory: true),
			withIntermediateDirectories: true
		)
		return standardized
	}

	private static func defaultWorkspaceName(for roots: [String]) -> String {
		guard roots.count == 1, let root = roots.first else {
			return "Headless Workspace"
		}
		let last = URL(fileURLWithPath: root, isDirectory: true).lastPathComponent
		return last.isEmpty ? root : last
	}
}
