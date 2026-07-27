import Foundation

public enum PortableProEditAction: String, Equatable, Sendable {
	case delegateEdit = "delegate edit"
	case create
}

public struct PortableProEditChange: Equatable, Sendable {
	public let description: String
	public let content: String
	public let complexity: Int

	init(description: String, content: String, complexity: Int) {
		self.description = description
		self.content = content
		self.complexity = complexity
	}
}

public struct PortableProEditFile: Equatable, Sendable {
	public let path: String
	public let action: PortableProEditAction
	public let changes: [PortableProEditChange]

	init(path: String, action: PortableProEditAction, changes: [PortableProEditChange]) {
		self.path = path
		self.action = action
		self.changes = changes
	}
}

public struct PortableProEditArtifact: Equatable, Sendable {
	public let chatName: String
	public let plan: String
	public let files: [PortableProEditFile]

	init(chatName: String, plan: String, files: [PortableProEditFile]) {
		self.chatName = chatName
		self.plan = plan
		self.files = files
	}
}

public struct PortableProEditGeneration: Equatable, Sendable {
	public let selection: PortableWorkspaceSelection
	public let result: PortablePlanResult
	let sourceEvidence: [HeadlessWorkspaceContext.SourceEvidence]

	public init(selection: PortableWorkspaceSelection, result: PortablePlanResult) {
		self.selection = selection
		self.result = result
		self.sourceEvidence = result.context.proEditSourceEvidence
	}
}

public struct PortableProEditLaneAttribution: Equatable, Sendable {
	public let pairID: UUID
	public let lane: PortablePlanLane.Name
	public let modelRawID: String

	init(pairID: UUID, lane: PortablePlanLane.Name, modelRawID: String) {
		self.pairID = pairID
		self.lane = lane
		self.modelRawID = modelRawID
	}
}

public struct PortableProEditResolvedTarget: Equatable, Sendable {
	public let file: PortableProEditFile
	public let rootIndex: Int
	public let relativePath: String
	public let absolutePath: String
	public let displayPath: String
	public let originalContent: String?

	init(
		file: PortableProEditFile,
		rootIndex: Int,
		relativePath: String,
		absolutePath: String,
		displayPath: String,
		originalContent: String?
	) {
		self.file = file
		self.rootIndex = rootIndex
		self.relativePath = relativePath
		self.absolutePath = absolutePath
		self.displayPath = displayPath
		self.originalContent = originalContent
	}
}

public struct PortableProEditPreflight: Equatable, Sendable {
	public let artifact: PortableProEditArtifact
	public let selection: PortableWorkspaceSelection
	public let laneAttribution: PortableProEditLaneAttribution
	public let targets: [PortableProEditResolvedTarget]
	let generation: PortableProEditGeneration

	init(
		artifact: PortableProEditArtifact,
		selection: PortableWorkspaceSelection,
		laneAttribution: PortableProEditLaneAttribution,
		targets: [PortableProEditResolvedTarget],
		generation: PortableProEditGeneration
	) {
		self.artifact = artifact
		self.selection = selection
		self.laneAttribution = laneAttribution
		self.targets = targets
		self.generation = generation
	}
}

public struct PortableProEditInspection: Equatable, Sendable {
	public let artifact: PortableProEditArtifact
	public let selection: PortableWorkspaceSelection
	public let targets: [PortableProEditResolvedTarget]

	init(
		artifact: PortableProEditArtifact,
		selection: PortableWorkspaceSelection,
		targets: [PortableProEditResolvedTarget]
	) {
		self.artifact = artifact
		self.selection = selection
		self.targets = targets
	}
}

public enum PortableProEditPreviewStatus: String, Equatable, Sendable {
	case completed
	case partialFailure = "partial_failure"
	case failed
}

public enum PortableProEditFileMaterializationStatus: Equatable, Sendable {
	case proposed
	case unchanged
	case failed(code: String, message: String)
}

public struct PortableProEditFileProposal: Equatable, Sendable {
	public let target: PortableProEditResolvedTarget
	public let status: PortableProEditFileMaterializationStatus
	public let proposedContent: String?
	public let replacementDiff: String?
	public let modelRawID: String?

	init(
		target: PortableProEditResolvedTarget,
		status: PortableProEditFileMaterializationStatus,
		proposedContent: String?,
		replacementDiff: String?,
		modelRawID: String?
	) {
		self.target = target
		self.status = status
		self.proposedContent = proposedContent
		self.replacementDiff = replacementDiff
		self.modelRawID = modelRawID
	}
}

public struct PortableProEditPreview: Equatable, Sendable {
	public let artifact: PortableProEditArtifact
	public let selection: PortableWorkspaceSelection
	public let laneAttribution: PortableProEditLaneAttribution
	public let status: PortableProEditPreviewStatus
	public let files: [PortableProEditFileProposal]

	init(
		artifact: PortableProEditArtifact,
		selection: PortableWorkspaceSelection,
		laneAttribution: PortableProEditLaneAttribution,
		status: PortableProEditPreviewStatus,
		files: [PortableProEditFileProposal]
	) {
		self.artifact = artifact
		self.selection = selection
		self.laneAttribution = laneAttribution
		self.status = status
		self.files = files
	}
}

public struct PortableProEditParseError: Error, Equatable, Sendable, LocalizedError {
	public enum Code: String, Equatable, Sendable {
		case artifactTooLarge = "artifact_too_large"
		case invalidEnvelope = "invalid_envelope"
		case emptyChatName = "empty_chat_name"
		case emptyPlan = "empty_plan"
		case invalidFile = "invalid_file"
		case invalidAction = "invalid_action"
		case emptyPath = "empty_path"
		case emptyChange = "empty_change"
		case emptyDescription = "empty_description"
		case emptyContent = "empty_content"
		case invalidComplexity = "invalid_complexity"
		case limitExceeded = "limit_exceeded"
		case unexpectedContent = "unexpected_content"
	}

	public let code: Code
	public let characterOffset: Int
	public let message: String

	init(code: Code, characterOffset: Int, message: String) {
		self.code = code
		self.characterOffset = characterOffset
		self.message = message
	}

	public var errorDescription: String? { message }
}

public struct PortableProEditPreflightError: Error, Equatable, Sendable, LocalizedError {
	public enum Code: String, Equatable, Sendable {
		case invalidPath = "invalid_path"
		case outsideWorkspace = "outside_workspace"
		case staleSelection = "stale_selection"
		case staleContext = "stale_context"
		case targetNotSelected = "target_not_selected"
		case missingExistingTarget = "missing_existing_target"
		case targetIsDirectory = "target_is_directory"
		case createTargetAlreadyExists = "create_target_already_exists"
		case createParentMissing = "create_parent_missing"
		case createParentNotDirectory = "create_parent_not_directory"
		case duplicateTarget = "duplicate_target"
		case overlappingTarget = "overlapping_target"
		case invalidUTF8 = "invalid_utf8"
		case sourceTooLarge = "source_too_large"
		case sourceReadFailed = "source_read_failed"
		case artifactLaneMismatch = "artifact_lane_mismatch"
		case sliceDelegateUnsupported = "slice_delegate_unsupported"
	}

	public let code: Code
	public let path: String?
	public let message: String

	init(code: Code, path: String? = nil, message: String) {
		self.code = code
		self.path = path
		self.message = message
	}

	public var errorDescription: String? { message }
}

public enum PortableProEditArtifactParser {
	public static let maximumArtifactBytes = 2 * 1_024 * 1_024
	public static let maximumFiles = 64
	public static let maximumChangesPerFile = 32
	public static let maximumTotalChanges = 512
	public static let maximumPathBytes = 4_096
	public static let maximumChatNameBytes = 256
	public static let maximumPlanBytes = 64 * 1_024
	public static let maximumDescriptionBytes = 4_096
	public static let maximumFileContentBytes = 1_024 * 1_024

	public static func parse(_ source: String) throws -> PortableProEditArtifact {
		guard source.utf8.count <= maximumArtifactBytes else {
			throw PortableProEditParseError(
				code: .artifactTooLarge,
				characterOffset: 0,
				message: "Pro Edit artifact exceeds \(maximumArtifactBytes) UTF-8 bytes."
			)
		}
		guard !source.contains("\0") else {
			throw PortableProEditParseError(
				code: .invalidEnvelope,
				characterOffset: 0,
				message: "Pro Edit artifact must not contain NUL."
			)
		}

		var cursor = Cursor(source)
		cursor.skipWhitespace()
		try cursor.expect(
			"<chatName=\"",
			code: .invalidEnvelope,
			message: "Pro Edit artifact must begin with exactly one <chatName=\"...\"/> element."
		)
		let chatName = try cursor.read(
			until: "\"/>",
			code: .invalidEnvelope,
			message: "Pro Edit chatName element is unterminated."
		).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !chatName.isEmpty else {
			throw cursor.error(.emptyChatName, "Pro Edit chatName must not be empty.")
		}
		guard chatName.utf8.count <= maximumChatNameBytes else {
			throw cursor.error(.limitExceeded, "Pro Edit chatName exceeds \(maximumChatNameBytes) UTF-8 bytes.")
		}

		cursor.skipWhitespace()
		try cursor.expect(
			"<Plan>",
			code: .invalidEnvelope,
			message: "Pro Edit artifact must contain one <Plan> immediately after chatName."
		)
		let plan = try cursor.read(
			until: "</Plan>",
			code: .invalidEnvelope,
			message: "Pro Edit Plan element is unterminated."
		)
		guard !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw cursor.error(.emptyPlan, "Pro Edit Plan must not be empty.")
		}
		guard plan.utf8.count <= maximumPlanBytes else {
			throw cursor.error(.limitExceeded, "Pro Edit Plan exceeds \(maximumPlanBytes) UTF-8 bytes.")
		}

		var files: [PortableProEditFile] = []
		var totalChanges = 0
		while true {
			cursor.skipWhitespace()
			if cursor.isAtEnd { break }
			guard files.count < maximumFiles else {
				throw cursor.error(.limitExceeded, "Pro Edit artifact exceeds \(maximumFiles) file blocks.")
			}
			try cursor.expect(
				"<file path=\"",
				code: .unexpectedContent,
				message: "Only file blocks may follow the Pro Edit Plan."
			)
			let path = try cursor.read(
				until: "\" action=\"",
				code: .invalidFile,
				message: "Pro Edit file path or action is malformed."
			)
			guard !path.isEmpty else {
				throw cursor.error(.emptyPath, "Pro Edit file path must not be empty.")
			}
			guard path == path.trimmingCharacters(in: .whitespacesAndNewlines) else {
				throw cursor.error(.invalidFile, "Pro Edit file path must not contain surrounding whitespace.")
			}
			guard path.utf8.count <= maximumPathBytes else {
				throw cursor.error(.limitExceeded, "Pro Edit file path exceeds \(maximumPathBytes) UTF-8 bytes.")
			}
			let rawAction = try cursor.read(
				until: "\">",
				code: .invalidFile,
				message: "Pro Edit file action is malformed."
			)
			guard let action = PortableProEditAction(rawValue: rawAction) else {
				throw cursor.error(
					.invalidAction,
					"Pro Edit file action must be \"delegate edit\" or \"create\"."
				)
			}

			var changes: [PortableProEditChange] = []
			var fileContentBytes = 0
			while true {
				cursor.skipWhitespace()
				if cursor.consume("</file>") { break }
				guard changes.count < maximumChangesPerFile, totalChanges < maximumTotalChanges else {
					throw cursor.error(.limitExceeded, "Pro Edit artifact exceeds its change-count limit.")
				}
				try cursor.expect(
					"<change>",
					code: .emptyChange,
					message: "Each Pro Edit file must contain one or more complete change blocks."
				)
				cursor.skipWhitespace()
				try cursor.expect(
					"<description>",
					code: .invalidFile,
					message: "Each Pro Edit change must contain description, content, then complexity."
				)
				let description = try cursor.read(
					until: "</description>",
					code: .invalidFile,
					message: "Pro Edit change description is unterminated."
				).trimmingCharacters(in: .whitespacesAndNewlines)
				guard !description.isEmpty else {
					throw cursor.error(.emptyDescription, "Pro Edit change description must not be empty.")
				}
				guard description.utf8.count <= maximumDescriptionBytes else {
					throw cursor.error(
						.limitExceeded,
						"Pro Edit change description exceeds \(maximumDescriptionBytes) UTF-8 bytes."
					)
				}

				cursor.skipWhitespace()
				try cursor.expect(
					"<content>",
					code: .invalidFile,
					message: "Each Pro Edit change must contain description, content, then complexity."
				)
				let content = try cursor.read(
					until: "</content>",
					code: .invalidFile,
					message: "Pro Edit change content is unterminated."
				)
				guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
					throw cursor.error(.emptyContent, "Pro Edit change content must not be empty.")
				}
				fileContentBytes += content.utf8.count
				guard fileContentBytes <= maximumFileContentBytes else {
					throw cursor.error(
						.limitExceeded,
						"Pro Edit file content exceeds \(maximumFileContentBytes) UTF-8 bytes."
					)
				}

				cursor.skipWhitespace()
				try cursor.expect(
					"<complexity>",
					code: .invalidFile,
					message: "Each Pro Edit change must contain description, content, then complexity."
				)
				let rawComplexity = try cursor.read(
					until: "</complexity>",
					code: .invalidFile,
					message: "Pro Edit change complexity is unterminated."
				).trimmingCharacters(in: .whitespacesAndNewlines)
				guard let complexity = Int(rawComplexity), (1 ... 10).contains(complexity) else {
					throw cursor.error(.invalidComplexity, "Pro Edit change complexity must be an integer from 1 through 10.")
				}
				cursor.skipWhitespace()
				try cursor.expect(
					"</change>",
					code: .invalidFile,
					message: "Pro Edit change must end immediately after complexity."
				)

				changes.append(PortableProEditChange(
					description: description,
					content: content,
					complexity: complexity
				))
				totalChanges += 1
			}
			guard !changes.isEmpty else {
				throw cursor.error(.emptyChange, "Each Pro Edit file must contain at least one change.")
			}
			files.append(PortableProEditFile(path: path, action: action, changes: changes))
		}

		return PortableProEditArtifact(chatName: chatName, plan: plan, files: files)
	}
}

private struct Cursor {
	let source: String
	var index: String.Index

	init(_ source: String) {
		self.source = source
		self.index = source.startIndex
	}

	var isAtEnd: Bool { index == source.endIndex }

	mutating func skipWhitespace() {
		while index < source.endIndex, source[index].isWhitespace {
			index = source.index(after: index)
		}
	}

	mutating func consume(_ literal: String) -> Bool {
		guard source[index...].hasPrefix(literal) else { return false }
		index = source.index(index, offsetBy: literal.count)
		return true
	}

	mutating func expect(
		_ literal: String,
		code: PortableProEditParseError.Code,
		message: String
	) throws {
		guard consume(literal) else { throw error(code, message) }
	}

	mutating func read(
		until literal: String,
		code: PortableProEditParseError.Code,
		message: String
	) throws -> String {
		guard let range = source.range(of: literal, range: index ..< source.endIndex) else {
			throw error(code, message)
		}
		let value = String(source[index ..< range.lowerBound])
		index = range.upperBound
		return value
	}

	func error(_ code: PortableProEditParseError.Code, _ message: String) -> PortableProEditParseError {
		PortableProEditParseError(
			code: code,
			characterOffset: source.distance(from: source.startIndex, to: index),
			message: message
		)
	}
}
