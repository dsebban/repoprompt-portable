import Foundation
import MCP
import RepoPromptCore

public actor HeadlessToolCatalog {
	private static let maximumReadFileBytes = 8 * 1_024 * 1_024
	private static let maximumSelectionEntries = 1_024
	private static let maximumRangesPerFile = 256
	private static let maximumTotalRanges = 4_096
	private static let maximumPathBytes = 4_096

	private let roots: [String]
	private let session: RepoPromptSession
	private let router: WorkspaceSessionRouter
	private let allowWrites: Bool
	private let fileManager: FileManager
	private let contextBuilder: HeadlessWorkspaceContextBuilder
	private let oracleWorkflow: HeadlessOracleWorkflow?
	private let encoder: JSONEncoder

	private let deniedTools: Set<String> = [
		"file_actions",
		"apply_edits",
		"apply_patch",
		"manage_workspaces",
		"workspace_context",
		"prompt",
		"get_code_structure",
		"git",
		"oracle_utils",
		"oracle_chat_log",
		"ask_oracle",
		"agent_run",
		"agent_manage",
		"agent_explore",
		"ask_user",
		"app_settings",
		"set_status",
		"share_thoughts",
		"wait_for_next_user_instruction"
	]

	public init(
		roots: [String],
		session: RepoPromptSession,
		router: WorkspaceSessionRouter,
		allowWrites: Bool,
		fileManager: FileManager = .default,
		oracleConfiguration: HeadlessOracleConfiguration? = nil
	) {
		let standardizedRoots = roots.map {
			URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
		}
		self.roots = standardizedRoots
		self.session = session
		self.router = router
		self.allowWrites = allowWrites
		self.fileManager = fileManager
		self.contextBuilder = HeadlessWorkspaceContextBuilder(roots: standardizedRoots)
		self.oracleWorkflow = oracleConfiguration.map { configuration in
			HeadlessOracleWorkflow(
				configuration: configuration,
				provider: OpenAICompatibleOracleProvider(configuration: configuration)
			)
		}
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		self.encoder = encoder
	}

	init(
		roots: [String],
		session: RepoPromptSession,
		router: WorkspaceSessionRouter,
		allowWrites: Bool,
		fileManager: FileManager = .default,
		oracleWorkflow: HeadlessOracleWorkflow?
	) {
		let standardizedRoots = roots.map {
			URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
		}
		self.roots = standardizedRoots
		self.session = session
		self.router = router
		self.allowWrites = allowWrites
		self.fileManager = fileManager
		self.contextBuilder = HeadlessWorkspaceContextBuilder(roots: standardizedRoots)
		self.oracleWorkflow = oracleWorkflow
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		self.encoder = encoder
	}

	public func tools() -> [Tool] {
		[
			Self.tool(
				name: "bind_context",
				description: "Bind this MCP connection to a headless workspace session or list available headless contexts.",
				properties: [
					"op": Self.stringSchema(description: "Operation: list, status, or bind."),
					"context_id": Self.stringSchema(description: "Headless session/context UUID to bind."),
					"working_dirs": .object([
						"type": .string("array"),
						"items": .object(["type": .string("string")])
					])
				]
			),
			Self.tool(
				name: "get_file_tree",
				description: "Return an ASCII directory tree for the headless workspace roots.",
				properties: [
					"path": Self.stringSchema(description: "Optional file or directory path under a workspace root."),
					"mode": Self.stringSchema(description: "auto, full, folders, or selected."),
					"max_depth": .object(["type": .string("integer"), "minimum": .int(0)])
				]
			),
			Self.tool(
				name: "read_file",
				description: "Read a UTF-8 text file under a headless workspace root with optional line slicing.",
				properties: [
					"path": Self.stringSchema(description: "File path. Relative paths resolve from the first workspace root."),
					"start_line": .object(["type": .string("integer"), "description": .string("1-based start line, or negative tail count.")]),
					"limit": .object(["type": .string("integer"), "minimum": .int(1)])
				],
				required: ["path"]
			),
			Self.tool(
				name: "manage_selection",
				description: "Manage the in-memory headless selection set.",
				properties: [
					"op": Self.stringSchema(description: "get, set, add, remove, or clear."),
					"paths": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
					"slices": .object([
						"type": .string("array"),
							"items": .object([
								"type": .string("object"),
								"required": .array([.string("path"), .string("ranges")]),
								"additionalProperties": .bool(false),
								"properties": .object([
									"path": Self.stringSchema(description: "File path."),
									"ranges": .object([
										"type": .string("array"),
										"minItems": .int(1),
										"maxItems": .int(Self.maximumRangesPerFile),
										"items": .object([
											"type": .string("object"),
											"required": .array([.string("start_line")]),
											"additionalProperties": .bool(false),
											"properties": .object([
												"start_line": .object(["type": .string("integer"), "minimum": .int(1)]),
												"end_line": .object(["type": .string("integer"), "minimum": .int(1)])
											])
										])
									])
								])
							])
					]),
					"view": Self.stringSchema(description: "summary, files, or content."),
					"mode": Self.stringSchema(description: "full, slices, or codemap_only. codemap_only source is never expanded in headless mode.")
				]
			),
			Self.tool(
				name: "context_builder",
				description: "Deterministically assemble the current explicit file and slice selection without provider work.",
				properties: [
					"instructions": Self.stringSchema(description: "Required local context-building instructions; returned unchanged after trimming."),
					"response_type": Self.stringSchema(description: "Optional compatibility value; only clarify is supported."),
					"max_context_bytes": .object([
						"type": .string("integer"),
						"minimum": .int(HeadlessWorkspaceContextBuilder.minimumMaximumBytes),
						"maximum": .int(HeadlessWorkspaceContextBuilder.absoluteMaximumBytes)
					])
				],
				required: ["instructions"],
				additionalProperties: false,
				idempotent: true
			),
			Self.tool(
				name: "oracle_send",
				description: "Send one immutable selected-file context to mandatory concurrent Primary and Secondary OpenAI-compatible requests.",
				properties: [
					"message": Self.stringSchema(description: "Required Oracle request, up to 65536 UTF-8 bytes."),
					"mode": Self.stringSchema(description: "chat, question, plan, or review. Defaults to chat."),
					"max_context_bytes": .object([
						"type": .string("integer"),
						"minimum": .int(HeadlessWorkspaceContextBuilder.minimumMaximumBytes),
						"maximum": .int(HeadlessWorkspaceContextBuilder.absoluteMaximumBytes)
					])
				],
				required: ["message"],
				additionalProperties: false,
				idempotent: false,
				openWorld: true
			),
			Self.tool(
				name: "file_search",
				description: "Search file paths and UTF-8 file contents under the headless workspace roots.",
				properties: [
					"pattern": Self.stringSchema(description: "Search pattern."),
					"regex": .object(["type": .string("boolean")]),
					"mode": Self.stringSchema(description: "auto, path, content, or both."),
					"max_results": .object(["type": .string("integer"), "minimum": .int(1)]),
					"context_lines": .object(["type": .string("integer"), "minimum": .int(0)]),
					"count_only": .object(["type": .string("boolean")])
				],
				required: ["pattern"]
			)
		]
	}

	public func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
		let args = arguments ?? [:]
		if deniedTools.contains(name) || (!allowWrites && Self.writeToolNames.contains(name)) {
			return error("Tool denied by headless policy: \(name)", code: "policy_denied")
		}

		do {
			switch name {
			case "bind_context":
				return try await bindContext(args)
			case "get_file_tree":
				return try await getFileTree(args)
			case "read_file":
				return try await readFile(args)
			case "manage_selection":
				return try await manageSelection(args)
			case "context_builder":
				return try await buildContext(args)
			case "oracle_send":
				return try await oracleSend(args)
			case "file_search":
				return try await fileSearch(args)
			default:
				return error("Tool not found: \(name)", code: "not_found")
			}
		} catch is CancellationError {
			return self.error("Oracle request was cancelled.", code: "cancelled")
		} catch let error as HeadlessToolError {
			return self.error(error.message, code: error.code)
		} catch {
			return self.error(String(describing: error), code: "internal_error")
		}
	}

	private func bindContext(_ args: [String: Value]) async throws -> CallTool.Result {
		let op = args["op"]?.stringValue ?? "status"
		let connectionID = UUID(uuidString: args["connection_id"]?.stringValue ?? "") ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
		switch op {
		case "list":
			let snapshot = await session.snapshot()
			return try jsonResult([
				"ok": JSONValue.bool(true),
				"contexts": .array([contextJSON(snapshot, bound: false)]),
				"windows": .array([]),
				"message": .string("Headless mode has one workspace session and no windows.")
			])
		case "status":
			let snapshot = await session.snapshot()
			return try jsonResult([
				"ok": .bool(true),
				"binding": contextJSON(snapshot, bound: true),
				"message": .string("Headless connection is bound to the active session.")
			])
		case "bind":
			if args["window_id"] != nil || args["_windowID"] != nil {
				throw HeadlessToolError("window_id selectors are unsupported in headless mode; bind by context_id or working_dirs.", code: "unsupported_selector")
			}
			let request = WorkspaceSessionBindingRequest(
				sessionID: args["context_id"].flatMap { value in value.stringValue.flatMap(UUID.init(uuidString:)) },
				workingDirectories: try stringArray(args["working_dirs"], name: "working_dirs")
			)
			let snapshot = try await router.bind(connectionID: connectionID, request: request)
			return try jsonResult([
				"ok": .bool(true),
				"binding": contextJSON(snapshot, bound: true),
				"message": .string("Bound to headless context \(snapshot.id.uuidString).")
			])
		default:
			throw HeadlessToolError("Unsupported bind_context op: \(op)", code: "invalid_params")
		}
	}

	private func getFileTree(_ args: [String: Value]) async throws -> CallTool.Result {
		let mode = args["mode"]?.stringValue ?? "auto"
		let maxDepth = args["max_depth"]?.intValue
		if mode == "selected" {
			let selection = await session.selectionStore.snapshot(tabID: nil)
			let lines = selection.selectedPaths.sorted().map { path in "- \(displayPath(path))" }
			return try jsonResult(["tree": .string(lines.isEmpty ? "(empty selection)" : lines.joined(separator: "\n"))])
		}

		let startPaths: [String]
		if let rawPath = args["path"]?.stringValue, !rawPath.isEmpty {
			startPaths = [try resolvePath(rawPath, mustExist: true)]
		} else {
			startPaths = roots
		}

		var lines: [String] = []
		for path in startPaths {
			lines.append(displayPath(path))
			try appendTreeLines(path: path, prefix: "", lines: &lines, maxDepth: maxDepth, currentDepth: 0, foldersOnly: mode == "folders")
		}
		return try jsonResult(["tree": .string(lines.joined(separator: "\n")), "roots": .array(roots.map { .string($0) })])
	}

	private func readFile(_ args: [String: Value]) async throws -> CallTool.Result {
		guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
			throw HeadlessToolError("read_file requires string argument `path`.", code: "invalid_params")
		}
		let path = try resolvePath(rawPath, mustExist: true)
		let secureFile: HeadlessSecureFile
		do {
			secureFile = try HeadlessSecureFileReader.read(
				path: path,
				roots: roots,
				maximumBytes: Self.maximumReadFileBytes
			)
		} catch HeadlessSecureFileError.outsideWorkspace {
			throw HeadlessToolError("Path resolves outside the headless workspace roots: \(rawPath)", code: "path_outside_workspace")
		} catch HeadlessSecureFileError.notRegularFile {
			throw HeadlessToolError("read_file requires a regular file: \(rawPath)", code: "invalid_params")
		} catch HeadlessSecureFileError.tooLarge {
			throw HeadlessToolError("read_file source exceeds 8 MiB: \(rawPath)", code: "source_too_large")
		} catch {
			throw HeadlessToolError("Unable to securely read file: \(rawPath)", code: "read_failed")
		}
		guard let content = String(data: secureFile.data, encoding: .utf8) else {
			throw HeadlessToolError("read_file requires UTF-8 text: \(rawPath)", code: "invalid_utf8")
		}
		let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		let totalLines = content.isEmpty ? 0 : lines.count
		let startLine = args["start_line"]?.intValue
		let limit = args["limit"]?.intValue
		if startLine == 0 {
			throw HeadlessToolError("start_line must be positive (1-based) or negative for tail reads.", code: "invalid_params")
		}
		if let startLine, startLine < 0, limit != nil {
			throw HeadlessToolError("limit is not allowed with negative start_line.", code: "invalid_params")
		}

		let range: Range<Int>
		if totalLines == 0 {
			range = 0..<0
		} else if let startLine, startLine < 0 {
			let count = min(abs(startLine), totalLines)
			range = (totalLines - count)..<totalLines
		} else {
			let start = max((startLine ?? 1) - 1, 0)
			let end = min(totalLines, start + max(limit ?? (totalLines - start), 0))
			range = min(start, totalLines)..<max(min(start, totalLines), end)
		}

		let selected = Array(lines[range]).joined(separator: "\n")
		let first = range.isEmpty ? 0 : range.lowerBound + 1
		let last = range.isEmpty ? 0 : range.upperBound
		return try jsonResult([
			"content": .string(selected),
			"total_lines": .int(totalLines),
			"first_line": .int(first),
			"last_line": .int(last),
			"display_path": .string(displayPath(path))
		])
	}

	private func manageSelection(_ args: [String: Value]) async throws -> CallTool.Result {
		let op = args["op"]?.stringValue ?? "get"
		let mode = args["mode"]?.stringValue ?? "full"
		guard ["full", "slices", "codemap_only"].contains(mode) else {
			throw HeadlessToolError("Unsupported manage_selection mode: \(mode)", code: "invalid_params")
		}
		let store = await session.selectionStore
		var selection = await store.snapshot(tabID: nil)

		switch op {
		case "get":
			break
		case "clear":
			selection = WorkspaceSelectionSnapshot()
			await store.persist(selection, for: nil, source: .headless)
		case "set", "add", "remove":
			let rawPaths = try stringArray(args["paths"], name: "paths")
			if mode == "slices", !rawPaths.isEmpty {
				throw HeadlessToolError("manage_selection mode `slices` does not accept `paths`.", code: "invalid_params")
			}
			let resolvedPaths = try rawPaths.map { try validatedSelectionPath($0) }
			let resolvedSlices = try selectionSlices(args["slices"])
			if mode == "slices", op != "remove", resolvedSlices.isEmpty {
				throw HeadlessToolError("manage_selection mode `slices` requires non-empty `slices`.", code: "invalid_params")
			}
			if mode != "slices", !resolvedSlices.isEmpty {
				throw HeadlessToolError("manage_selection `slices` requires mode `slices`.", code: "invalid_params")
			}
			guard resolvedPaths.count + resolvedSlices.count <= Self.maximumSelectionEntries else {
				throw HeadlessToolError("manage_selection accepts at most 1024 paths or slice files.", code: "invalid_params")
			}

			if op == "set" {
				switch mode {
				case "full":
					selection = WorkspaceSelectionSnapshot(selectedPaths: resolvedPaths)
				case "codemap_only":
					selection = WorkspaceSelectionSnapshot(autoCodemapPaths: resolvedPaths, codemapAutoEnabled: false)
				default:
					selection = WorkspaceSelectionSnapshot(
						selectedPaths: resolvedSlices.map(\.path),
						slices: Dictionary(uniqueKeysWithValues: resolvedSlices.map { ($0.path, $0.ranges) })
					)
				}
			} else if op == "add" {
				switch mode {
				case "full":
					appendUnique(resolvedPaths, to: &selection.selectedPaths)
					selection.autoCodemapPaths.removeAll { resolvedPaths.contains($0) }
					for path in resolvedPaths { selection.slices.removeValue(forKey: path) }
				case "codemap_only":
					appendUnique(resolvedPaths, to: &selection.autoCodemapPaths)
					selection.selectedPaths.removeAll { resolvedPaths.contains($0) }
					for path in resolvedPaths { selection.slices.removeValue(forKey: path) }
					selection.codemapAutoEnabled = false
				default:
					let paths = resolvedSlices.map(\.path)
					appendUnique(paths, to: &selection.selectedPaths)
					selection.autoCodemapPaths.removeAll { paths.contains($0) }
					for slice in resolvedSlices { selection.slices[slice.path] = slice.ranges }
				}
			} else {
				let remove = Set(resolvedPaths + resolvedSlices.map(\.path))
				selection.selectedPaths.removeAll { remove.contains($0) }
				selection.autoCodemapPaths.removeAll { remove.contains($0) }
				for path in remove { selection.slices.removeValue(forKey: path) }
			}
			try validateSelectionLimits(selection)
			await store.persist(selection, for: nil, source: .headless)
		default:
			throw HeadlessToolError("Unsupported manage_selection op: \(op)", code: "invalid_params")
		}

		return try jsonResult(selectionJSON(selection))
	}

	private func buildContext(_ args: [String: Value]) async throws -> CallTool.Result {
		try validateArguments(args, allowed: ["instructions", "response_type", "max_context_bytes"], tool: "context_builder")
		let instructions = try requiredText(args["instructions"], name: "instructions")
		guard instructions.utf8.count <= HeadlessOracleWorkflow.maximumRequestBytes else {
			throw HeadlessToolError("context_builder instructions exceed 65536 UTF-8 bytes.", code: "invalid_params")
		}
		if let value = args["response_type"] {
			guard value.stringValue == "clarify" else {
				throw HeadlessToolError("context_builder response_type must be `clarify`; provider-generating modes are unsupported.", code: "invalid_params")
			}
		}
		let maximumBytes = try contextMaximumBytes(args["max_context_bytes"])
		let selection = await session.selectionStore.snapshot(tabID: nil)
		let context = contextBuilder.build(selection: selection, maximumBytes: maximumBytes)
		return try jsonResult([
			"ok": .bool(true),
			"status": .string("context_built"),
			"response_type": .string("clarify"),
			"prompt": .string(instructions),
			"workspace_context": contextJSON(context)
		])
	}

	private func oracleSend(_ args: [String: Value]) async throws -> CallTool.Result {
		try validateArguments(args, allowed: ["message", "mode", "max_context_bytes"], tool: "oracle_send")
		let message = try requiredText(args["message"], name: "message")
		guard message.utf8.count <= HeadlessOracleWorkflow.maximumRequestBytes else {
			throw HeadlessToolError("oracle_send message exceeds 65536 UTF-8 bytes.", code: "invalid_params")
		}
		let mode: HeadlessOracleMode
		if let value = args["mode"] {
			guard let rawMode = value.stringValue, let parsed = HeadlessOracleMode(rawValue: rawMode) else {
				throw HeadlessToolError("oracle_send mode must be chat, question, plan, or review.", code: "invalid_params")
			}
			mode = parsed
		} else {
			mode = .chat
		}
		let maximumBytes = try contextMaximumBytes(args["max_context_bytes"])
		guard let oracleWorkflow else {
			throw HeadlessToolError("Oracle is not configured. Set the required REPOPROMPT_ORACLE_* environment variables.", code: "oracle_not_configured")
		}

		let selection = await session.selectionStore.snapshot(tabID: nil)
		let context = contextBuilder.build(selection: selection, maximumBytes: maximumBytes)
		let result: HeadlessOraclePairResult
		do {
			result = try await oracleWorkflow.execute(mode: mode, request: message, context: context)
		} catch let error as HeadlessOracleWorkflowError {
			throw HeadlessToolError(error.message, code: error.code)
		}
		return try jsonResult(pairJSON(result, context: context))
	}

	private func fileSearch(_ args: [String: Value]) async throws -> CallTool.Result {
		guard let pattern = args["pattern"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty else {
			throw HeadlessToolError("file_search requires non-empty string argument `pattern`.", code: "invalid_params")
		}
		let mode = args["mode"]?.stringValue ?? "auto"
		let regex = args["regex"]?.boolValue ?? false
		let maxResults = max(1, args["max_results"]?.intValue ?? 50)
		let contextLines = max(0, args["context_lines"]?.intValue ?? 0)
		let countOnly = args["count_only"]?.boolValue ?? false
		let matcher = try SearchMatcher(pattern: pattern, regex: regex)
		var matches: [JSONValue] = []
		var total = 0

		for file in try allFiles() {
			guard matches.count < maxResults || countOnly else { break }
			let relative = displayPath(file)
			if mode == "path" || mode == "both" || mode == "auto" {
				if matcher.matches(relative) {
					total += 1
					if !countOnly, matches.count < maxResults {
						matches.append(.object(["path": .string(relative), "kind": .string("path")]))
					}
				}
			}
			if mode == "content" || mode == "both" || mode == "auto" {
				guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
				let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
				for (offset, line) in lines.enumerated() where matcher.matches(line) {
					total += 1
					if !countOnly, matches.count < maxResults {
						let start = max(0, offset - contextLines)
						let end = min(lines.count, offset + contextLines + 1)
						matches.append(.object([
							"path": .string(relative),
							"kind": .string("content"),
							"line": .int(offset + 1),
							"preview": .string(Array(lines[start..<end]).joined(separator: "\n"))
						]))
					}
					if matches.count >= maxResults, !countOnly { break }
				}
			}
		}

		return try jsonResult([
			"pattern": .string(pattern),
			"regex": .bool(regex),
			"total_matches": .int(total),
			"matches": .array(matches),
			"truncated": .bool(!countOnly && total > matches.count)
		])
	}

	private func appendTreeLines(path: String, prefix: String, lines: inout [String], maxDepth: Int?, currentDepth: Int, foldersOnly: Bool) throws {
		if let maxDepth, currentDepth >= maxDepth { return }
		var isDirectory = ObjCBool(false)
		guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
		let children = try fileManager.contentsOfDirectory(atPath: path)
			.filter { !Self.shouldSkipName($0) }
			.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
		let visibleChildren = foldersOnly
			? children.filter { child in
				var childIsDirectory = ObjCBool(false)
				return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(child), isDirectory: &childIsDirectory) && childIsDirectory.boolValue
			}
			: children
		for (index, child) in visibleChildren.enumerated() {
			let childPath = (path as NSString).appendingPathComponent(child)
			let attributes = try fileManager.attributesOfItem(atPath: childPath)
			let isSymbolicLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
			let connector = index == visibleChildren.count - 1 ? "└── " : "├── "
			lines.append(prefix + connector + child)
			var childIsDirectory = ObjCBool(false)
			if !isSymbolicLink,
			   fileManager.fileExists(atPath: childPath, isDirectory: &childIsDirectory),
			   childIsDirectory.boolValue
			{
				let nextPrefix = prefix + (index == visibleChildren.count - 1 ? "    " : "│   ")
				try appendTreeLines(path: childPath, prefix: nextPrefix, lines: &lines, maxDepth: maxDepth, currentDepth: currentDepth + 1, foldersOnly: foldersOnly)
			}
		}
	}

	private func allFiles() throws -> [String] {
		var files: [String] = []
		for root in roots {
			guard let enumerator = fileManager.enumerator(atPath: root) else { continue }
			for case let relative as String in enumerator {
				let name = (relative as NSString).lastPathComponent
				if Self.shouldSkipName(name) {
					enumerator.skipDescendants()
					continue
				}
				let path = (root as NSString).appendingPathComponent(relative)
				var isDirectory = ObjCBool(false)
				guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
				files.append(path)
			}
		}
		return files
	}

	private func resolvePath(_ raw: String, mustExist: Bool) throws -> String {
		let expanded = (raw as NSString).expandingTildeInPath
		let absolute: String
		if let qualified = parseRootQualifiedPath(expanded) {
			guard roots.indices.contains(qualified.index) else {
				throw HeadlessToolError("Invalid workspace root index in path: \(raw)", code: "invalid_params")
			}
			absolute = (roots[qualified.index] as NSString).appendingPathComponent(qualified.relativePath)
		} else {
			absolute = expanded.hasPrefix("/") ? expanded : (roots[0] as NSString).appendingPathComponent(expanded)
		}
		let standardized = (absolute as NSString).standardizingPath
		guard roots.contains(where: { root in contains(standardized, root: root) }) else {
			throw HeadlessToolError("Path is outside the headless workspace roots: \(raw)", code: "path_outside_workspace")
		}
		if mustExist, !fileManager.fileExists(atPath: standardized) {
			throw HeadlessToolError("Path does not exist: \(raw)", code: "not_found")
		}
		return standardized
	}

	private func displayPath(_ path: String) -> String {
		for (index, root) in roots.enumerated().sorted(by: { $0.element.count > $1.element.count }) {
			let prefixLabel = roots.count > 1 ? "root[\(index)]:" : ""
			if path == root { return roots.count > 1 ? "root[\(index)]" : root }
			let prefix = root.hasSuffix("/") ? root : root + "/"
			if path.hasPrefix(prefix) {
				return prefixLabel + String(path.dropFirst(prefix.count))
			}
		}
		return path
	}

	private func contains(_ path: String, root: String) -> Bool {
		path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
	}

	private func parseRootQualifiedPath(_ path: String) -> (index: Int, relativePath: String)? {
		guard path.hasPrefix("root["), let close = path.firstIndex(of: "]") else { return nil }
		let indexStart = path.index(path.startIndex, offsetBy: 5)
		guard let index = Int(path[indexStart..<close]) else { return nil }
		let suffix = path[path.index(after: close)...]
		guard suffix.first == ":" else { return nil }
		let relative = suffix.dropFirst()
		guard !relative.hasPrefix("/") else { return nil }
		return (index, String(relative))
	}

	private func contextJSON(_ snapshot: RepoPromptSessionSnapshot, bound: Bool) -> JSONValue {
		.object([
			"context_id": .string(snapshot.id.uuidString),
			"session_id": .string(snapshot.id.uuidString),
			"name": .string(snapshot.name),
			"roots": .array(snapshot.rootPaths.map { .string($0) }),
			"bound": .bool(bound)
		])
	}

	private func selectionJSON(_ selection: WorkspaceSelectionSnapshot) -> [String: JSONValue] {
		[
			"ok": .bool(true),
			"selection": .object([
				"selected_paths": .array(selection.selectedPaths.map { .string(displayPath($0)) }),
				"selected_count": .int(selection.selectedPaths.count),
				"auto_codemap_paths": .array(selection.autoCodemapPaths.map { .string(displayPath($0)) }),
				"slices": .object(displaySlices(selection.slices)),
				"codemap_auto_enabled": .bool(selection.codemapAutoEnabled)
			])
		]
	}

	private func contextJSON(_ context: HeadlessWorkspaceContext) -> JSONValue {
		.object([
			"roots": .array(context.roots.map { .string($0) }),
			"selection": .object([
				"selected_paths": .array(context.selection.selectedPaths.map { .string(displayPath($0)) }),
				"auto_codemap_paths": .array(context.selection.autoCodemapPaths.map { .string(displayPath($0)) }),
				"slices": .object(displaySlices(context.selection.slices)),
				"codemap_auto_enabled": .bool(context.selection.codemapAutoEnabled)
			]),
			"entries": .array(context.entries.map { entry in
				var value: [String: JSONValue] = [
					"path": .string(entry.path),
					"kind": .string(entry.kind.rawValue),
					"content_bytes": .int(entry.byteCount)
				]
				if let start = entry.startLine { value["start_line"] = .int(start) }
				if let end = entry.endLine { value["end_line"] = .int(end) }
				return .object(value)
			}),
			"omissions": .array(context.omissions.map { omission in
				.object([
					"path": .string(omission.path),
					"reason": .string(omission.reason.rawValue)
				])
			}),
			"content": .string(context.content),
			"context_bytes": .int(context.contentByteCount),
			"max_context_bytes": .int(context.maximumByteCount),
			"truncated": .bool(context.truncated),
			"omitted_root_count": .int(context.omittedRootCount)
		])
	}

	private func pairJSON(_ result: HeadlessOraclePairResult, context: HeadlessWorkspaceContext) -> [String: JSONValue] {
		var object: [String: JSONValue] = [
			"ok": .bool(result.primary.status == .completed),
			"pair_status": .string(result.pairStatus.rawValue),
			"oracle_pair_id": .string(result.pairID.uuidString),
			"oracle_decision_policy": .string("caller_decides"),
			"model_raw_id": .string(result.primary.modelRawID),
			"workspace_context": contextJSON(context),
			"oracle_results": .object([
				"primary": laneJSON(result.primary),
				"secondary": laneJSON(result.secondary)
			])
		]
		if let response = result.primary.response {
			object["response"] = .string(response)
		}
		if let failure = result.primary.failure {
			object["error"] = failureJSON(failure)
		}
		return object
	}

	private func laneJSON(_ result: HeadlessOracleLaneResult) -> JSONValue {
		var object: [String: JSONValue] = [
			"oracle_lane": .string(result.lane.rawValue),
			"status": .string(result.status.rawValue),
			"model_raw_id": .string(result.modelRawID),
			"provider": .string("openai_compatible")
		]
		if let response = result.response { object["response"] = .string(response) }
		if let failure = result.failure { object["error"] = failureJSON(failure) }
		return .object(object)
	}

	private func failureJSON(_ failure: HeadlessOracleFailure) -> JSONValue {
		var object: [String: JSONValue] = [
			"code": .string(failure.code),
			"message": .string(failure.message)
		]
		if let httpStatus = failure.httpStatus { object["http_status"] = .int(httpStatus) }
		return .object(object)
	}

	private func validateArguments(_ args: [String: Value], allowed: Set<String>, tool: String) throws {
		let unknown = Set(args.keys).subtracting(allowed).sorted()
		guard unknown.isEmpty else {
			throw HeadlessToolError("\(tool) received unknown argument(s): \(unknown.joined(separator: ", ")).", code: "invalid_params")
		}
	}

	private func requiredText(_ value: Value?, name: String) throws -> String {
		guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
			throw HeadlessToolError("Required string argument `\(name)` must not be empty.", code: "invalid_params")
		}
		return text
	}

	private func contextMaximumBytes(_ value: Value?) throws -> Int {
		guard let value else { return HeadlessWorkspaceContextBuilder.defaultMaximumBytes }
		guard
			let maximumBytes = value.intValue,
			(HeadlessWorkspaceContextBuilder.minimumMaximumBytes ... HeadlessWorkspaceContextBuilder.absoluteMaximumBytes).contains(maximumBytes)
		else {
			throw HeadlessToolError(
				"max_context_bytes must be an integer between 1024 and 1048576.",
				code: "invalid_params"
			)
		}
		return maximumBytes
	}

	private func jsonResult(_ object: [String: JSONValue]) throws -> CallTool.Result {
		let text = try String(data: encoder.encode(JSONValue.object(object)), encoding: .utf8) ?? "{}"
		return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
	}

	private func error(_ message: String, code: String) -> CallTool.Result {
		let payload = JSONValue.object(["ok": .bool(false), "code": .string(code), "message": .string(message)])
		let data = (try? encoder.encode(payload)) ?? Data("{\"ok\":false}".utf8)
		let text = String(data: data, encoding: .utf8) ?? message
		return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: true)
	}

	private func stringArray(_ value: Value?, name: String = "value") throws -> [String] {
		switch value {
		case .array(let values):
			guard values.allSatisfy({ $0.stringValue != nil }) else {
				throw HeadlessToolError("`\(name)` must contain only strings.", code: "invalid_params")
			}
			return values.compactMap(\.stringValue)
		case .string(let string):
			return [string]
		case nil:
			return []
		default:
			throw HeadlessToolError("`\(name)` must be a string or array of strings.", code: "invalid_params")
		}
	}

	private func selectionSlices(_ value: Value?) throws -> [(path: String, ranges: [LineRange])] {
		guard let value else { return [] }
		guard case .array(let items) = value else {
			throw HeadlessToolError("manage_selection `slices` must be an array.", code: "invalid_params")
		}
		var orderedPaths: [String] = []
		var rangesByPath: [String: [LineRange]] = [:]
		var totalRangeCount = 0
		for item in items {
			guard
				case .object(let object) = item,
				let rawPath = object["path"]?.stringValue,
				!rawPath.isEmpty,
				case .array(let ranges)? = object["ranges"]
			else {
				throw HeadlessToolError("Each selection slice requires string `path` and array `ranges`.", code: "invalid_params")
			}
			guard !ranges.isEmpty else {
				throw HeadlessToolError("Each selection slice requires at least one range.", code: "invalid_params")
			}
			guard ranges.count <= Self.maximumRangesPerFile else {
				throw HeadlessToolError("Each selection slice accepts at most 256 ranges.", code: "invalid_params")
			}
			totalRangeCount += ranges.count
			guard totalRangeCount <= Self.maximumTotalRanges else {
				throw HeadlessToolError("manage_selection accepts at most 4096 total slice ranges.", code: "invalid_params")
			}
			let path = try validatedSelectionPath(rawPath)
			if rangesByPath[path] == nil { orderedPaths.append(path) }
			for value in ranges {
				guard
					case .object(let range) = value,
					let start = range["start_line"]?.intValue,
					start > 0
				else {
					throw HeadlessToolError("Each slice range requires positive integer `start_line`.", code: "invalid_params")
				}
				let allowedKeys: Set<String> = ["start_line", "end_line"]
				guard Set(range.keys).isSubset(of: allowedKeys) else {
					throw HeadlessToolError("Slice ranges contain unsupported fields.", code: "invalid_params")
				}
				let end = range["end_line"]?.intValue ?? start
				guard end >= start else {
					throw HeadlessToolError("Slice `end_line` must be greater than or equal to `start_line`.", code: "invalid_params")
				}
				rangesByPath[path, default: []].append(LineRange(
					start: start,
					end: end
				))
			}
		}
		return orderedPaths.map { ($0, rangesByPath[$0] ?? []) }
	}

	private func validatedSelectionPath(_ rawPath: String) throws -> String {
		guard !rawPath.isEmpty, rawPath.utf8.count <= Self.maximumPathBytes else {
			throw HeadlessToolError("Selection paths must contain 1...4096 UTF-8 bytes.", code: "invalid_params")
		}
		return try resolvePath(rawPath, mustExist: false)
	}

	private func appendUnique(_ paths: [String], to target: inout [String]) {
		var seen = Set(target)
		for path in paths where seen.insert(path).inserted {
			target.append(path)
		}
	}

	private func validateSelectionLimits(_ selection: WorkspaceSelectionSnapshot) throws {
		let paths = Set(selection.selectedPaths + selection.autoCodemapPaths + Array(selection.slices.keys))
		guard paths.count <= Self.maximumSelectionEntries else {
			throw HeadlessToolError("Selection accepts at most 1024 files.", code: "invalid_params")
		}
		guard selection.slices.values.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumRangesPerFile }) else {
			throw HeadlessToolError("Each selected slice requires 1...256 ranges.", code: "invalid_params")
		}
		guard selection.slices.values.reduce(0, { $0 + $1.count }) <= Self.maximumTotalRanges else {
			throw HeadlessToolError("Selection accepts at most 4096 total slice ranges.", code: "invalid_params")
		}
	}

	private func displaySlices(_ slices: [String: [LineRange]]) -> [String: JSONValue] {
		Dictionary(uniqueKeysWithValues: slices.map { path, ranges in
			(displayPath(path), .array(ranges.map { .string("\($0.start)-\($0.end)") }))
		})
	}

	private static var writeToolNames: Set<String> { ["file_actions", "apply_edits", "apply_patch"] }

	private static func shouldSkipName(_ name: String) -> Bool {
		name.hasPrefix(".") || [".git", ".build", "node_modules"].contains(name)
	}

	private static func stringSchema(description: String) -> Value {
		.object(["type": .string("string"), "description": .string(description)])
	}

	private static func tool(
		name: String,
		description: String,
		properties: [String: Value],
		required: [String] = [],
		additionalProperties: Bool = true,
		idempotent: Bool? = nil,
		openWorld: Bool = false
	) -> Tool {
		Tool(
			name: name,
			description: description,
			inputSchema: .object([
				"type": .string("object"),
				"properties": .object(properties),
				"required": .array(required.map { .string($0) }),
				"additionalProperties": .bool(additionalProperties)
			]),
			annotations: .init(
				readOnlyHint: !writeToolNames.contains(name),
				destructiveHint: false,
				idempotentHint: idempotent,
				openWorldHint: openWorld
			)
		)
	}
}

private struct HeadlessToolError: Error, Sendable {
	let message: String
	let code: String

	init(_ message: String, code: String) {
		self.message = message
		self.code = code
	}
}

private struct SearchMatcher {
	let pattern: String
	let regex: NSRegularExpression?

	init(pattern: String, regex: Bool) throws {
		self.pattern = pattern
		self.regex = regex ? try NSRegularExpression(pattern: pattern) : nil
	}

	func matches(_ value: String) -> Bool {
		if let regex {
			let range = NSRange(value.startIndex..<value.endIndex, in: value)
			return regex.firstMatch(in: value, range: range) != nil
		}
		return value.localizedCaseInsensitiveContains(pattern)
	}
}

private enum JSONValue: Codable, Equatable, Sendable {
	case string(String)
	case int(Int)
	case bool(Bool)
	case array([JSONValue])
	case object([String: JSONValue])

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .string(let value): try container.encode(value)
		case .int(let value): try container.encode(value)
		case .bool(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let value = try? container.decode(String.self) { self = .string(value) }
		else if let value = try? container.decode(Int.self) { self = .int(value) }
		else if let value = try? container.decode(Bool.self) { self = .bool(value) }
		else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
		else { self = .object(try container.decode([String: JSONValue].self)) }
	}
}
