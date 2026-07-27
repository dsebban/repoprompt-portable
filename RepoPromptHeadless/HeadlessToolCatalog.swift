import Foundation
import MCP
import RepoPromptCore

public actor HeadlessToolCatalog {
	private static let maximumReadFileBytes = 8 * 1_024 * 1_024
	static let maximumFileSearchBytesPerFile = HeadlessWorkspaceContextBuilder.maximumSourceFileBytes
	static let maximumFileSearchAggregateBytes = HeadlessWorkspaceContextBuilder.maximumAggregateSourceBytes
	static let maximumFileSearchFiles = HeadlessWorkspaceContextBuilder.maximumCodemapCandidates
	static let maximumFileSearchResults = 1_000
	static let maximumFileSearchContextLines = 20
	static let maximumFileSearchPatternBytes = 1_024
	static let maximumFileSearchPreviewJSONBytes = 16 * 1_024
	static let maximumFileSearchOutputBytes = 1_024 * 1_024
	private static let maximumSelectionEntries = HeadlessWorkspaceContextBuilder.maximumSelectionEntries
	private static let maximumRangesPerFile = HeadlessWorkspaceContextBuilder.maximumRangesPerFile
	private static let maximumTotalRanges = HeadlessWorkspaceContextBuilder.maximumTotalRanges

	private let roots: [String]
	private let session: RepoPromptSession
	private let router: WorkspaceSessionRouter
	private let allowWrites: Bool
	private let fileManager: FileManager
	private let pathIndex: HeadlessWorkspacePathIndex
	private let workspaceService: PortableWorkspaceService
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
		let pathIndex = HeadlessWorkspacePathIndex(roots: roots, fileManager: fileManager)
		let oracleWorkflow = oracleConfiguration.map { configuration in
			HeadlessOracleWorkflow(
				configuration: configuration,
				provider: OpenAICompatibleOracleProvider(configuration: configuration)
			)
		}
		self.roots = pathIndex.roots
		self.session = session
		self.router = router
		self.allowWrites = allowWrites
		self.fileManager = fileManager
		self.pathIndex = pathIndex
		self.workspaceService = PortableWorkspaceService(
			roots: pathIndex.roots,
			session: session,
			fileManager: fileManager,
			oracleWorkflow: oracleWorkflow
		)
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
		let pathIndex = HeadlessWorkspacePathIndex(roots: roots, fileManager: fileManager)
		self.roots = pathIndex.roots
		self.session = session
		self.router = router
		self.allowWrites = allowWrites
		self.fileManager = fileManager
		self.pathIndex = pathIndex
		self.workspaceService = PortableWorkspaceService(
			roots: pathIndex.roots,
			session: session,
			fileManager: fileManager,
			oracleWorkflow: oracleWorkflow
		)
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
				description: "Manage explicit full-file, described slice, and manual-codemap selection. Optionally update automatic codemap derivation atomically; returned details preserve legacy fields.",
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
												"end_line": .object(["type": .string("integer"), "minimum": .int(1)]),
												"description": Self.stringSchema(description: "Optional slice description, at most 1024 UTF-8 bytes and no NUL.")
											])
										])
									])
								])
							])
					]),
					"view": Self.stringSchema(description: "summary, files, or content."),
					"mode": Self.stringSchema(description: "full, slices, or codemap_only. Manual codemaps are explicit; automatic codemaps are derived without mutating selection."),
					"codemap_auto_enabled": .object(["type": .string("boolean"), "description": .string("Optional automatic-codemap state applied atomically with the mutation.")])
				]
			),
			Self.tool(
				name: "context_builder",
				description: "Render the current explicit in-memory file, slice, and manual-codemap selection plus derived automatic codemaps when enabled. Rendering never changes selection; use manage_selection first. clarify stays local; plan, review, and pro_edit invoke the configured Oracle provider with the same canonical context bytes. pro_edit returns instructions only and never writes, delegates, or applies.",
				properties: [
					"instructions": Self.stringSchema(description: "Required clarify, plan, review, or pro_edit request; returned unchanged after trimming. pro_edit returns instructions only and never writes, delegates, or applies."),
					"response_type": .object([
						"type": .string("string"),
						"description": .string("clarify renders the current explicit selection locally; plan, review, and pro_edit invoke the configured Oracle provider. pro_edit returns instructions only and never writes, delegates, or applies."),
						"enum": .array([.string("clarify"), .string("plan"), .string("review"), .string("pro_edit")])
					]),
					"review_diff": Self.stringSchema(description: "Optional caller-supplied review diff, accepted only with response_type review. Preserved exactly, treated as untrusted evidence, and limited to 262144 UTF-8 bytes."),
					"max_context_bytes": .object([
						"type": .string("integer"),
						"minimum": .int(HeadlessWorkspaceContextBuilder.minimumMaximumBytes),
						"maximum": .int(HeadlessWorkspaceContextBuilder.absoluteMaximumBytes)
					])
				],
				required: ["instructions"],
				additionalProperties: false,
				idempotent: false,
				openWorld: true
			),
			Self.tool(
				name: "oracle_send",
				description: "Always snapshot and attach the current explicit selection to mandatory concurrent Primary and Secondary OpenAI-compatible requests. There is no context-free mode; use manage_selection first.",
				properties: [
					"message": Self.stringSchema(description: "Required Oracle request, up to 65536 UTF-8 bytes. The current explicit selection is always attached."),
					"mode": .object([
						"type": .string("string"),
						"description": .string("chat, question, plan, or review. Defaults to chat; pro_edit is context_builder-only."),
						"enum": .array([.string("chat"), .string("question"), .string("plan"), .string("review")])
					]),
					"review_diff": Self.stringSchema(description: "Optional caller-supplied review diff, accepted only in review mode. Preserved exactly, sent to both lanes as untrusted evidence, and limited to 262144 UTF-8 bytes."),
					"clarify_handoff": Self.stringSchema(description: "Optional prior context_builder clarify output. Preserved exactly, sent to both lanes as untrusted caller-supplied evidence, and limited to 1048576 UTF-8 bytes."),
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
				description: "Search root-contained regular-file paths and bounded UTF-8 file contents using literal case-insensitive matching. Regex mode is disabled.",
				properties: [
					"pattern": .object([
						"type": .string("string"),
						"description": .string("Literal search pattern, limited to 1024 UTF-8 bytes."),
						"maxLength": .int(Self.maximumFileSearchPatternBytes)
					]),
					"regex": .object([
						"type": .string("boolean"),
						"description": .string("Regex mode is disabled; only false is accepted."),
						"enum": .array([.bool(false)])
					]),
					"mode": Self.stringSchema(description: "auto, path, content, or both."),
					"max_results": .object([
						"type": .string("integer"),
						"minimum": .int(1),
						"maximum": .int(Self.maximumFileSearchResults)
					]),
					"context_lines": .object([
						"type": .string("integer"),
						"minimum": .int(0),
						"maximum": .int(Self.maximumFileSearchContextLines)
					]),
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
		} catch let error as PortableWorkspaceServiceError {
			let details: JSONValue?
			if case .incompleteContext(let context) = error {
				details = incompleteContextDetails(context)
			} else {
				details = nil
			}
			return self.error(error.message, code: error.code, details: details)
		} catch let error as HeadlessToolError {
			return self.error(error.message, code: error.code, details: error.details)
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
			let lines = selection.selectedPaths.sorted().map { path in "- \(pathIndex.displayPath(path))" }
			return try jsonResult(["tree": .string(lines.isEmpty ? "(empty selection)" : lines.joined(separator: "\n"))])
		}

		let startPaths: [String]
		if let rawPath = args["path"]?.stringValue, !rawPath.isEmpty {
			startPaths = [try pathIndex.resolvePath(rawPath, mustExist: true)]
		} else {
			startPaths = roots
		}

		var lines: [String] = []
		for path in startPaths {
			lines.append(pathIndex.displayPath(path))
			try appendTreeLines(path: path, prefix: "", lines: &lines, maxDepth: maxDepth, currentDepth: 0, foldersOnly: mode == "folders")
		}
		return try jsonResult(["tree": .string(lines.joined(separator: "\n")), "roots": .array(roots.map { .string($0) })])
	}

	private func readFile(_ args: [String: Value]) async throws -> CallTool.Result {
		guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
			throw HeadlessToolError("read_file requires string argument `path`.", code: "invalid_params")
		}
		let path = try pathIndex.resolvePath(rawPath, mustExist: true)
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
			"display_path": .string(pathIndex.displayPath(path))
		])
	}

	private func manageSelection(_ args: [String: Value]) async throws -> CallTool.Result {
		let op = args["op"]?.stringValue ?? "get"
		let rawMode = args["mode"]?.stringValue ?? "full"
		let mode: HeadlessSelectionMode
		switch rawMode {
		case "full": mode = .full
		case "slices": mode = .slices
		case "codemap_only": mode = .codemapOnly
		default:
			throw HeadlessToolError("Unsupported manage_selection mode: \(rawMode)", code: "invalid_params")
		}

		let codemapAutoEnabledOverride: Bool?
		if let value = args["codemap_auto_enabled"] {
			guard let enabled = value.boolValue else {
				throw HeadlessToolError("manage_selection `codemap_auto_enabled` must be a boolean.", code: "invalid_params")
			}
			codemapAutoEnabledOverride = enabled
		} else {
			codemapAutoEnabledOverride = nil
		}

		let selection: WorkspaceSelectionSnapshot
		switch op {
		case "get":
			guard codemapAutoEnabledOverride == nil else {
				throw HeadlessToolError("manage_selection op `get` does not accept `codemap_auto_enabled`.", code: "invalid_params")
			}
			selection = try await workspaceService.applySelection(operation: .get, mode: mode)
		case "clear":
			selection = try await workspaceService.applySelection(
				operation: .clear,
				mode: mode,
				codemapAutoEnabledOverride: codemapAutoEnabledOverride
			)
		case "set", "add", "remove":
			let rawPaths = try stringArray(args["paths"], name: "paths")
			if mode == .slices, !rawPaths.isEmpty {
				throw HeadlessToolError("manage_selection mode `slices` does not accept `paths`.", code: "invalid_params")
			}
			let resolvedPaths = try rawPaths.map { try validatedSelectionPath($0) }
			let resolvedSlices = try selectionSlices(args["slices"]).map {
				HeadlessSelectionSlice(path: $0.path, ranges: $0.ranges)
			}
			if mode == .slices, op != "remove", resolvedSlices.isEmpty {
				throw HeadlessToolError("manage_selection mode `slices` requires non-empty `slices`.", code: "invalid_params")
			}
			if mode != .slices, !resolvedSlices.isEmpty {
				throw HeadlessToolError("manage_selection `slices` requires mode `slices`.", code: "invalid_params")
			}
			guard resolvedPaths.count + resolvedSlices.count <= Self.maximumSelectionEntries else {
				throw HeadlessToolError("manage_selection accepts at most 1024 paths or slice files.", code: "invalid_params")
			}
			let operation: HeadlessSelectionOperation = switch op {
			case "set": .set
			case "add": .add
			default: .remove
			}
			selection = try await workspaceService.applySelection(
				operation: operation,
				mode: mode,
				paths: resolvedPaths,
				slices: resolvedSlices,
				codemapAutoEnabledOverride: codemapAutoEnabledOverride
			)
		default:
			throw HeadlessToolError("Unsupported manage_selection op: \(op)", code: "invalid_params")
		}

		return try jsonResult(selectionJSON(selection))
	}

	private func buildContext(_ args: [String: Value]) async throws -> CallTool.Result {
		try validateArguments(args, allowed: ["instructions", "response_type", "review_diff", "max_context_bytes"], tool: "context_builder")
		let instructions = try requiredText(args["instructions"], name: "instructions")
		guard instructions.utf8.count <= HeadlessOracleWorkflow.maximumRequestBytes else {
			throw HeadlessToolError("context_builder instructions exceed 65536 UTF-8 bytes.", code: "invalid_params")
		}
		let responseType = try builderResponseType(args["response_type"])
		let reviewDiff = try optionalEvidence(
			args["review_diff"],
			name: "review_diff",
			maximumBytes: HeadlessOracleWorkflow.maximumReviewDiffBytes
		)
		if reviewDiff != nil, responseType != .generated(.review) {
			throw HeadlessToolError("context_builder review_diff is accepted only with response_type review.", code: "invalid_params")
		}
		let maximumBytes = try contextMaximumBytes(args["max_context_bytes"])

		switch responseType {
		case .clarify:
			let context = await workspaceService.renderContext(maximumBytes: maximumBytes)
			return try jsonResult([
				"ok": .bool(true),
				"status": .string("context_built"),
				"response_type": .string("clarify"),
				"prompt": .string(instructions),
				"workspace_context": contextJSON(context)
			])
		case .generated(let mode):
			let (context, result) = try await workspaceService.executeOracle(
				mode: mode,
				request: instructions,
				maximumBytes: maximumBytes,
				reviewDiff: reviewDiff
			)
			var object = pairJSON(result, context: context)
			object["response_type"] = .string(mode.rawValue)
			object["prompt"] = .string(instructions)
			object["status"] = .string(result.primary.status == .completed ? "response_generated" : "response_failed")
			return try jsonResult(object)
		}
	}

	private func oracleSend(_ args: [String: Value]) async throws -> CallTool.Result {
		try validateArguments(args, allowed: ["message", "mode", "review_diff", "clarify_handoff", "max_context_bytes"], tool: "oracle_send")
		let message = try requiredText(args["message"], name: "message")
		guard message.utf8.count <= HeadlessOracleWorkflow.maximumRequestBytes else {
			throw HeadlessToolError("oracle_send message exceeds 65536 UTF-8 bytes.", code: "invalid_params")
		}
		let mode: HeadlessOracleMode
		if let value = args["mode"] {
			guard let rawMode = value.stringValue else {
				throw HeadlessToolError("oracle_send mode must be chat, question, plan, or review.", code: "invalid_params")
			}
			switch rawMode {
			case "chat": mode = .chat
			case "question": mode = .question
			case "plan": mode = .plan
			case "review": mode = .review
			default:
				throw HeadlessToolError("oracle_send mode must be chat, question, plan, or review.", code: "invalid_params")
			}
		} else {
			mode = .chat
		}
		let reviewDiff = try optionalEvidence(
			args["review_diff"],
			name: "review_diff",
			maximumBytes: HeadlessOracleWorkflow.maximumReviewDiffBytes
		)
		if reviewDiff != nil, mode != .review {
			throw HeadlessToolError("oracle_send review_diff is accepted only in review mode.", code: "invalid_params")
		}
		let clarifyHandoff = try optionalEvidence(
			args["clarify_handoff"],
			name: "clarify_handoff",
			maximumBytes: HeadlessOracleWorkflow.maximumClarifyHandoffBytes
		)
		let maximumBytes = try contextMaximumBytes(args["max_context_bytes"])
		let (context, result) = try await workspaceService.executeOracle(
			mode: mode,
			request: message,
			maximumBytes: maximumBytes,
			reviewDiff: reviewDiff,
			clarifyHandoff: clarifyHandoff
		)
		return try jsonResult(pairJSON(result, context: context))
	}

	private func builderResponseType(_ value: Value?) throws -> BuilderResponseType {
		guard let value else { return .clarify }
		switch value.stringValue {
		case "clarify": return .clarify
		case "plan": return .generated(.plan)
		case "review": return .generated(.review)
		case "pro_edit": return .generated(.proEdit)
		default:
			throw HeadlessToolError("context_builder response_type must be clarify, plan, review, or pro_edit.", code: "invalid_params")
		}
	}

	private func fileSearch(_ args: [String: Value]) async throws -> CallTool.Result {
		try Task.checkCancellation()
		guard let rawPattern = args["pattern"]?.stringValue else {
			throw HeadlessToolError("file_search requires non-empty string argument `pattern`.", code: "invalid_params")
		}
		guard rawPattern.utf8.count <= Self.maximumFileSearchPatternBytes else {
			throw HeadlessToolError(
				"file_search `pattern` exceeds \(Self.maximumFileSearchPatternBytes) UTF-8 bytes.",
				code: "invalid_params"
			)
		}
		let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !pattern.isEmpty else {
			throw HeadlessToolError("file_search requires non-empty string argument `pattern`.", code: "invalid_params")
		}
		let mode = args["mode"]?.stringValue ?? "auto"
		guard ["auto", "path", "content", "both"].contains(mode) else {
			throw HeadlessToolError("file_search mode must be auto, path, content, or both.", code: "invalid_params")
		}
		if let regex = args["regex"], regex.boolValue != false {
			throw HeadlessToolError(
				"file_search regex mode is disabled; `regex` must be false.",
				code: "invalid_params"
			)
		}
		let maxResults = try boundedFileSearchInteger(
			args["max_results"],
			name: "max_results",
			defaultValue: 50,
			range: 1 ... Self.maximumFileSearchResults
		)
		let contextLines = try boundedFileSearchInteger(
			args["context_lines"],
			name: "context_lines",
			defaultValue: 0,
			range: 0 ... Self.maximumFileSearchContextLines
		)
		let countOnly = args["count_only"]?.boolValue ?? false
		let matcher = SearchMatcher(pattern: pattern)
		var matches: [JSONValue] = []
		var total = 0
		var incomplete = false
		var searchedBytes = 0
		var remainingOutputBytes = max(
			0,
			Self.maximumFileSearchOutputBytes
				- 2_048
				- Self.conservativeJSONStringBytes(pattern)
		)
		let enumeration = try pathIndex.rootContainedFiles(limit: Self.maximumFileSearchFiles)
		incomplete = enumeration.truncated

		searchLoop: for file in enumeration.files {
			try Task.checkCancellation()
			let relative = pathIndex.displayPath(file)
			if mode == "path" || mode == "both" || mode == "auto" {
				if matcher.matches(relative) {
					total += 1
					if !countOnly {
						guard matches.count < maxResults else {
							incomplete = true
							break searchLoop
						}
						let matchBytes = 256 + Self.conservativeJSONStringBytes(relative)
						guard matchBytes <= remainingOutputBytes else {
							incomplete = true
							break searchLoop
						}
						remainingOutputBytes -= matchBytes
						matches.append(.object([
							"path": .string(relative),
							"kind": .string("path")
						]))
					}
				}
			}
			if mode == "content" || mode == "both" || mode == "auto" {
				let remainingBytes = Self.maximumFileSearchAggregateBytes - searchedBytes
				guard remainingBytes > 0 else {
					incomplete = true
					continue
				}
				let secureFile: HeadlessSecureFile
				do {
					secureFile = try HeadlessSecureFileReader.read(
						path: file,
						roots: roots,
						maximumBytes: min(Self.maximumFileSearchBytesPerFile, remainingBytes)
					)
				} catch HeadlessSecureFileError.tooLarge {
					incomplete = true
					continue
				} catch {
					// Enumeration and open are separate operations. Any symlink swap,
					// non-regular replacement, or root escape fails closed here.
					incomplete = true
					continue
				}
				searchedBytes += secureFile.data.count
				guard let text = String(data: secureFile.data, encoding: .utf8) else { continue }
				let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
				for (offset, line) in lines.enumerated() {
					try Task.checkCancellation()
					guard matcher.matches(line) else { continue }
					total += 1
					if !countOnly {
						guard matches.count < maxResults else {
							incomplete = true
							break searchLoop
						}
						let start = max(0, offset - contextLines)
						let end = min(lines.count, offset + contextLines + 1)
						let preview = try Self.boundedFileSearchPreview(
							lines: lines,
							range: start ..< end
						)
						if preview.truncated { incomplete = true }
						let matchBytes =
							256
							+ Self.conservativeJSONStringBytes(relative)
							+ Self.conservativeJSONStringBytes(preview.text)
						guard matchBytes <= remainingOutputBytes else {
							incomplete = true
							break searchLoop
						}
						remainingOutputBytes -= matchBytes
						matches.append(.object([
							"path": .string(relative),
							"kind": .string("content"),
							"line": .int(offset + 1),
							"preview": .string(preview.text)
						]))
					}
				}
			}
		}

		return try fileSearchResult(
			pattern: pattern,
			total: total,
			matches: matches,
			truncated: incomplete || (!countOnly && total > matches.count)
		)
	}

	private func fileSearchResult(
		pattern: String,
		total: Int,
		matches: [JSONValue],
		truncated: Bool
	) throws -> CallTool.Result {
		var boundedMatches = matches
		var isTruncated = truncated
		while true {
			try Task.checkCancellation()
			let payload = JSONValue.object([
				"pattern": .string(pattern),
				"regex": .bool(false),
				"total_matches": .int(total),
				"matches": .array(boundedMatches),
				"truncated": .bool(isTruncated)
			])
			let data = try encoder.encode(payload)
			if data.count <= Self.maximumFileSearchOutputBytes {
				let text = String(decoding: data, as: UTF8.self)
				return CallTool.Result(
					content: [.text(text: text, annotations: nil, _meta: nil)],
					isError: false
				)
			}
			guard !boundedMatches.isEmpty else {
				throw HeadlessToolError(
					"file_search result exceeds its encoded output budget.",
					code: "internal_error"
				)
			}
			boundedMatches.removeLast()
			isTruncated = true
		}
	}

	private static func boundedFileSearchPreview(
		lines: [String],
		range: Range<Int>
	) throws -> (text: String, truncated: Bool) {
		var text = ""
		var remainingBytes = maximumFileSearchPreviewJSONBytes - 2
		for lineIndex in range {
			try Task.checkCancellation()
			if lineIndex > range.lowerBound {
				guard remainingBytes >= 2 else { return (text, true) }
				text.append("\n")
				remainingBytes -= 2
			}
			for (scalarIndex, scalar) in lines[lineIndex].unicodeScalars.enumerated() {
				if scalarIndex.isMultiple(of: 256) { try Task.checkCancellation() }
				let byteCount = conservativeJSONScalarBytes(scalar)
				guard byteCount <= remainingBytes else { return (text, true) }
				text.unicodeScalars.append(scalar)
				remainingBytes -= byteCount
			}
		}
		return (text, false)
	}

	private static func conservativeJSONStringBytes(_ value: String) -> Int {
		2 + value.unicodeScalars.reduce(into: 0) { count, scalar in
			count += conservativeJSONScalarBytes(scalar)
		}
	}

	private static func conservativeJSONScalarBytes(_ scalar: Unicode.Scalar) -> Int {
		switch scalar.value {
		case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C:
			return 2
		case 0x00 ... 0x1F, 0x2028, 0x2029:
			return 6
		default:
			return scalar.utf8.count
		}
	}

	private func boundedFileSearchInteger(
		_ value: Value?,
		name: String,
		defaultValue: Int,
		range: ClosedRange<Int>
	) throws -> Int {
		guard let value else { return defaultValue }
		guard let integer = value.intValue, range.contains(integer) else {
			throw HeadlessToolError(
				"file_search `\(name)` must be an integer in \(range.lowerBound)...\(range.upperBound).",
				code: "invalid_params"
			)
		}
		return integer
	}

	private func appendTreeLines(path: String, prefix: String, lines: inout [String], maxDepth: Int?, currentDepth: Int, foldersOnly: Bool) throws {
		if let maxDepth, currentDepth >= maxDepth { return }
		var isDirectory = ObjCBool(false)
		guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
		let children = try fileManager.contentsOfDirectory(atPath: path)
			.filter { !HeadlessWorkspacePathIndex.shouldSkipName($0) }
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
				"selected_paths": .array(selection.selectedPaths.map { .string(pathIndex.displayPath($0)) }),
				"selected_count": .int(selection.selectedPaths.count),
				"auto_codemap_paths": .array(selection.autoCodemapPaths.map { .string(pathIndex.displayPath($0)) }),
				"manual_codemap_paths": .array(selection.manualCodemapPaths.map { .string(pathIndex.displayPath($0)) }),
				"slices": .object(displaySlices(selection.slices)),
				"slice_details": .array(displaySliceDetails(selection.slices)),
				"codemap_auto_enabled": .bool(selection.codemapAutoEnabled)
			])
		]
	}

	private func contextJSON(_ context: HeadlessWorkspaceContext) -> JSONValue {
		.object([
			"roots": .array(context.roots.map { .string($0) }),
			"selection": .object([
				"selected_paths": .array(context.selection.selectedPaths.map { .string(pathIndex.displayPath($0)) }),
				"auto_codemap_paths": .array(context.selection.autoCodemapPaths.map { .string(pathIndex.displayPath($0)) }),
				"manual_codemap_paths": .array(context.selection.manualCodemapPaths.map { .string(pathIndex.displayPath($0)) }),
				"slices": .object(displaySlices(context.selection.slices)),
				"slice_details": .array(displaySliceDetails(context.selection.slices)),
				"codemap_auto_enabled": .bool(context.selection.codemapAutoEnabled)
			]),
			"automatic_codemap_paths": .array(context.automaticCodemapPaths.map { .string($0) }),
			"resolved_codemaps": .array(context.entries.compactMap { entry in
				guard let source = entry.codemapSource else { return nil }
				return .object(["path": .string(entry.path), "source": .string(source.rawValue)])
			}),
			"entries": .array(context.entries.map { entry in
				var value: [String: JSONValue] = [
					"path": .string(entry.path),
					"kind": .string(entry.kind.rawValue),
					"content_bytes": .int(entry.byteCount)
				]
				if let source = entry.codemapSource { value["codemap_source"] = .string(source.rawValue) }
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
			"omitted_root_count": .int(context.omittedRootCount),
			"complete_for_provider": .bool(context.isCompleteForProvider)
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
		if let metadata = result.primary.providerMetadata {
			object["provider_metadata"] = providerMetadataJSON(metadata)
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
		if let metadata = result.providerMetadata { object["provider_metadata"] = providerMetadataJSON(metadata) }
		if let failure = result.failure { object["error"] = failureJSON(failure) }
		return .object(object)
	}

	private func providerMetadataJSON(_ metadata: HeadlessOracleProviderMetadata) -> JSONValue {
		var object: [String: JSONValue] = [
			"http_status": .int(metadata.httpStatus),
			"latency_ms": .int(metadata.latencyMilliseconds)
		]
		if let responseID = metadata.responseID { object["id"] = .string(responseID) }
		if let requestID = metadata.requestID { object["request_id"] = .string(requestID) }
		if let observedModelID = metadata.observedModelID { object["model"] = .string(observedModelID) }
		if let finishReason = metadata.finishReason { object["finish_reason"] = .string(finishReason) }
		if let conversationID = metadata.conversationID { object["conversation_id"] = .string(conversationID) }
		if let baselineAssistantMessageID = metadata.baselineAssistantMessageID {
			object["baseline_assistant_message_id"] = .string(baselineAssistantMessageID)
		}
		if let usage = metadata.usage {
			var usageObject: [String: JSONValue] = [:]
			if let promptTokens = usage.promptTokens { usageObject["prompt_tokens"] = .int(promptTokens) }
			if let completionTokens = usage.completionTokens { usageObject["completion_tokens"] = .int(completionTokens) }
			if let totalTokens = usage.totalTokens { usageObject["total_tokens"] = .int(totalTokens) }
			object["usage"] = .object(usageObject)
		}
		if let recovery = metadata.recovery { object["recovery"] = oracleJSON(recovery) }
		return .object(object)
	}

	private func failureJSON(_ failure: HeadlessOracleFailure) -> JSONValue {
		var object: [String: JSONValue] = [
			"code": .string(failure.code),
			"message": .string(failure.message)
		]
		if let httpStatus = failure.httpStatus { object["http_status"] = .int(httpStatus) }
		if let latencyMilliseconds = failure.latencyMilliseconds { object["latency_ms"] = .int(latencyMilliseconds) }
		if let requestID = failure.requestID { object["request_id"] = .string(requestID) }
		if let providerError = failure.providerError {
			var providerObject: [String: JSONValue] = [:]
			if let message = providerError.message { providerObject["message"] = .string(message) }
			if let type = providerError.type { providerObject["type"] = .string(type) }
			if let param = providerError.param { providerObject["param"] = .string(param) }
			if let code = providerError.code { providerObject["code"] = .string(code) }
			if let failureReason = providerError.failureReason { providerObject["failure_reason"] = .string(failureReason) }
			object["provider_error"] = .object(providerObject)
		}
		if let rawErrorBody = failure.rawErrorBody { object["raw_error_body"] = .string(rawErrorBody) }
		if failure.rawErrorBodyTruncated { object["raw_error_body_truncated"] = .bool(true) }
		if let recovery = failure.recovery { object["recovery"] = oracleJSON(recovery) }
		if let retryable = failure.retryable { object["retryable"] = .bool(retryable) }
		if let retryAfterSeconds = failure.retryAfterSeconds { object["retry_after_seconds"] = .int(retryAfterSeconds) }
		return .object(object)
	}

	private func oracleJSON(_ value: HeadlessOracleJSONValue) -> JSONValue {
		switch value {
		case .null: return .null
		case .string(let value): return .string(value)
		case .int(let value): return .int(value)
		case .double(let value): return .double(value)
		case .bool(let value): return .bool(value)
		case .array(let values): return .array(values.map(oracleJSON))
		case .object(let object): return .object(object.mapValues(oracleJSON))
		}
	}

	private func incompleteContextDetails(_ context: PortableContextPreview) -> JSONValue {
		let visible = context.omissions.prefix(64).map { omission in
			JSONValue.object([
				"path": .string(omission.displayPath),
				"reason": .string(omission.reason.rawValue)
			])
		}
		return .object([
			"truncated": .bool(context.truncated),
			"omitted_root_count": .int(context.omittedRootCount),
			"omission_count": .int(context.omissions.count),
			"omissions": .array(visible),
			"additional_omission_count": .int(max(0, context.omissions.count - visible.count))
		])
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

	private func optionalEvidence(_ value: Value?, name: String, maximumBytes: Int) throws -> String? {
		guard let value else { return nil }
		guard let text = value.stringValue else {
			throw HeadlessToolError("`\(name)` must be a string.", code: "invalid_params")
		}
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw HeadlessToolError("`\(name)` must not be empty or whitespace-only.", code: "invalid_params")
		}
		guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
			throw HeadlessToolError("`\(name)` must not contain NUL.", code: "invalid_params")
		}
		guard text.utf8.count <= maximumBytes else {
			throw HeadlessToolError("`\(name)` exceeds \(maximumBytes) UTF-8 bytes.", code: "invalid_params")
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

	private func error(_ message: String, code: String, details: JSONValue? = nil) -> CallTool.Result {
		var object: [String: JSONValue] = ["ok": .bool(false), "code": .string(code), "message": .string(message)]
		if let details { object["details"] = details }
		let payload = JSONValue.object(object)
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
				let allowedKeys: Set<String> = ["start_line", "end_line", "description"]
				guard Set(range.keys).isSubset(of: allowedKeys) else {
					throw HeadlessToolError("Slice ranges contain unsupported fields.", code: "invalid_params")
				}
				let end = range["end_line"]?.intValue ?? start
				guard end >= start else {
					throw HeadlessToolError("Slice `end_line` must be greater than or equal to `start_line`.", code: "invalid_params")
				}
				let description = range["description"]?.stringValue
				if range["description"] != nil, description == nil {
					throw HeadlessToolError("Slice `description` must be a string.", code: "invalid_params")
				}
				if let description, description.contains("\0") || description.utf8.count > 1_024 {
					throw HeadlessToolError("Slice `description` must not contain NUL and must not exceed 1024 UTF-8 bytes.", code: "invalid_params")
				}
				rangesByPath[path, default: []].append(LineRange(
					start: start,
					end: end,
					description: description
				))
			}
		}
		return orderedPaths.map { ($0, rangesByPath[$0] ?? []) }
	}

	private func validatedSelectionPath(_ rawPath: String) throws -> String {
		try pathIndex.validatedSelectionPath(rawPath)
	}

	private func displaySlices(_ slices: [String: [LineRange]]) -> [String: JSONValue] {
		Dictionary(uniqueKeysWithValues: slices.map { path, ranges in
			(pathIndex.displayPath(path), .array(ranges.map { .string("\($0.start)-\($0.end)") }))
		})
	}

	private func displaySliceDetails(_ slices: [String: [LineRange]]) -> [JSONValue] {
		slices.keys.sorted().map { path in
			.object([
				"path": .string(pathIndex.displayPath(path)),
				"ranges": .array((slices[path] ?? []).map { range in
					var value: [String: JSONValue] = [
						"start_line": .int(range.start),
						"end_line": .int(range.end)
					]
					if let description = range.description { value["description"] = .string(description) }
					return .object(value)
				})
			])
		}
	}

	private static var writeToolNames: Set<String> { ["file_actions", "apply_edits", "apply_patch"] }

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
				"additionalProperties": .bool(additionalProperties),
				PortableContract.toolSchemaVersionKeyword: .string(PortableContract.toolSchemaVersion)
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

private enum BuilderResponseType: Equatable {
	case clarify
	case generated(HeadlessOracleMode)
}

private struct HeadlessToolError: Error, Sendable {
	let message: String
	let code: String
	let details: JSONValue?

	init(_ message: String, code: String, details: JSONValue? = nil) {
		self.message = message
		self.code = code
		self.details = details
	}
}

private struct SearchMatcher {
	let pattern: String

	init(pattern: String) {
		self.pattern = pattern
	}

	func matches(_ value: String) -> Bool {
		value.localizedCaseInsensitiveContains(pattern)
	}
}

private enum JSONValue: Codable, Equatable, Sendable {
	case null
	case string(String)
	case int(Int)
	case double(Double)
	case bool(Bool)
	case array([JSONValue])
	case object([String: JSONValue])

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .string(let value): try container.encode(value)
		case .int(let value): try container.encode(value)
		case .double(let value): try container.encode(value)
		case .bool(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() { self = .null }
		else if let value = try? container.decode(String.self) { self = .string(value) }
		else if let value = try? container.decode(Bool.self) { self = .bool(value) }
		else if let value = try? container.decode(Int.self) { self = .int(value) }
		else if let value = try? container.decode(Double.self) { self = .double(value) }
		else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
		else { self = .object(try container.decode([String: JSONValue].self)) }
	}
}
