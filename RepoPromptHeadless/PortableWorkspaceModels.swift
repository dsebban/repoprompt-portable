import Foundation

public struct PortableWorkspaceSummary: Equatable, Sendable {
	public let id: UUID
	public let name: String
	public let roots: [String]

	public init(id: UUID, name: String, roots: [String]) {
		self.id = id
		self.name = name
		self.roots = roots
	}
}

public struct PortableWorkspaceFile: Identifiable, Hashable, Sendable {
	public let absolutePath: String
	public let displayPath: String

	public var id: String { absolutePath }

	public init(absolutePath: String, displayPath: String) {
		self.absolutePath = absolutePath
		self.displayPath = displayPath
	}
}

public struct PortableLineRange: Equatable, Hashable, Sendable {
	public let startLine: Int
	public let endLine: Int
	public let description: String?

	public init(startLine: Int, endLine: Int? = nil, description: String? = nil) {
		self.startLine = startLine
		self.endLine = endLine ?? startLine
		self.description = description
	}
}

public struct PortableSliceSelection: Equatable, Sendable {
	public let path: String
	public let ranges: [PortableLineRange]

	public init(path: String, ranges: [PortableLineRange]) {
		self.path = path
		self.ranges = ranges
	}
}

public enum PortableSelectionMutation: Equatable, Sendable {
	case replaceWithFullFiles([String])
	case addFullFiles([String])
	case setSlices([PortableSliceSelection])
	case addSlices([PortableSliceSelection])
	case subtractSlices([PortableSliceSelection])
	case replaceWithManualCodemaps([String])
	case addManualCodemaps([String])
	case removeManualCodemaps([String])
	case promoteToFull([String])
	case demoteToManualCodemap([String])
	case removeFiles([String])
	case clear
	case setAutomaticCodemapsEnabled(Bool)
}

public struct PortableWorkspaceSelection: Equatable, Sendable {
	public let selectedFiles: [PortableWorkspaceFile]
	public let sliceFileCount: Int
	public let codemapFileCount: Int
	public let slices: [PortableSliceSelection]
	public let manualCodemapFiles: [PortableWorkspaceFile]
	public let codemapAutoEnabled: Bool

	public var selectedAbsolutePaths: Set<String> {
		Set(selectedFiles.map(\.absolutePath))
	}

	public init(
		selectedFiles: [PortableWorkspaceFile],
		sliceFileCount: Int,
		codemapFileCount: Int,
		slices: [PortableSliceSelection] = [],
		manualCodemapFiles: [PortableWorkspaceFile] = [],
		codemapAutoEnabled: Bool = true
	) {
		self.selectedFiles = selectedFiles
		self.sliceFileCount = sliceFileCount
		self.codemapFileCount = codemapFileCount
		self.slices = slices
		self.manualCodemapFiles = manualCodemapFiles
		self.codemapAutoEnabled = codemapAutoEnabled
	}
}

public struct PortableContextEntry: Equatable, Sendable {
	public enum Kind: String, Sendable {
		case full
		case slice
	}

	public let displayPath: String
	public let kind: Kind
	public let startLine: Int?
	public let endLine: Int?
	public let byteCount: Int

	public init(
		displayPath: String,
		kind: Kind,
		startLine: Int?,
		endLine: Int?,
		byteCount: Int
	) {
		self.displayPath = displayPath
		self.kind = kind
		self.startLine = startLine
		self.endLine = endLine
		self.byteCount = byteCount
	}
}

public struct PortableContextOmission: Equatable, Sendable {
	public enum Reason: String, Sendable {
		case outsideWorkspace = "outside_workspace"
		case symlinkEscape = "symlink_escape"
		case notFound = "not_found"
		case directoryUnsupported = "directory_unsupported"
		case invalidUTF8 = "invalid_utf8"
		case sourceTooLarge = "source_too_large"
		case sliceOutOfBounds = "slice_out_of_bounds"
		case budgetExceeded = "budget_exceeded"
		case readFailed = "read_failed"
		case orphanSlice = "orphan_slice"
		case invalidSlice = "invalid_slice"
		case autoCodemapUnsupported = "auto_codemap_unsupported"
	}

	public let displayPath: String
	public let reason: Reason

	public init(displayPath: String, reason: Reason) {
		self.displayPath = displayPath
		self.reason = reason
	}
}

public struct PortableContextPreview: Equatable, Sendable {
	public let entries: [PortableContextEntry]
	public let omissions: [PortableContextOmission]
	public let content: String
	public let contentByteCount: Int
	public let maximumByteCount: Int
	public let truncated: Bool
	public let omittedRootCount: Int
	public let isCompleteForProvider: Bool

	public init(
		entries: [PortableContextEntry],
		omissions: [PortableContextOmission],
		content: String,
		contentByteCount: Int,
		maximumByteCount: Int,
		truncated: Bool,
		omittedRootCount: Int,
		isCompleteForProvider: Bool
	) {
		self.entries = entries
		self.omissions = omissions
		self.content = content
		self.contentByteCount = contentByteCount
		self.maximumByteCount = maximumByteCount
		self.truncated = truncated
		self.omittedRootCount = omittedRootCount
		self.isCompleteForProvider = isCompleteForProvider
	}
}

public struct PortablePlanLane: Equatable, Sendable {
	public enum Name: String, Sendable {
		case primary
		case secondary
	}

	public enum Status: String, Sendable {
		case completed
		case failed
	}

	public let name: Name
	public let modelRawID: String
	public let status: Status
	public let response: String?
	public let errorCode: String?
	public let errorMessage: String?

	public init(
		name: Name,
		modelRawID: String,
		status: Status,
		response: String?,
		errorCode: String?,
		errorMessage: String?
	) {
		self.name = name
		self.modelRawID = modelRawID
		self.status = status
		self.response = response
		self.errorCode = errorCode
		self.errorMessage = errorMessage
	}
}

public struct PortablePlanResult: Equatable, Sendable {
	public enum Status: String, Sendable {
		case completed
		case partialFailure = "partial_failure"
		case failed
	}

	public let pairID: UUID
	public let status: Status
	public let primary: PortablePlanLane
	public let secondary: PortablePlanLane
	public let context: PortableContextPreview

	public init(
		pairID: UUID,
		status: Status,
		primary: PortablePlanLane,
		secondary: PortablePlanLane,
		context: PortableContextPreview
	) {
		self.pairID = pairID
		self.status = status
		self.primary = primary
		self.secondary = secondary
		self.context = context
	}
}

public enum PortableWorkspaceServiceError: Error, Equatable, Sendable {
	case invalidParameters(String)
	case pathOutsideWorkspace(String)
	case pathNotFound(String)
	case oracleNotConfigured
	case incompleteContext(PortableContextPreview)
	case oracleFailed(code: String, message: String)

	public var code: String {
		switch self {
		case .invalidParameters: return "invalid_params"
		case .pathOutsideWorkspace: return "path_outside_workspace"
		case .pathNotFound: return "not_found"
		case .oracleNotConfigured: return "oracle_not_configured"
		case .incompleteContext: return "incomplete_workspace_context"
		case .oracleFailed(let code, _): return code
		}
	}

	public var message: String {
		switch self {
		case .invalidParameters(let message),
		     .pathOutsideWorkspace(let message),
		     .pathNotFound(let message):
			return message
		case .oracleNotConfigured:
			return "Oracle is not configured. Set the required REPOPROMPT_ORACLE_* environment variables."
		case .incompleteContext:
			return "Selected workspace context is incomplete; inspect context_builder clarify omission metadata before retrying."
		case .oracleFailed(_, let message):
			return message
		}
	}
}

extension PortableWorkspaceServiceError: LocalizedError {
	public var errorDescription: String? { message }
}

extension PortableContextPreview {
	init(_ context: HeadlessWorkspaceContext) {
		entries = context.entries.map { entry in
			PortableContextEntry(
				displayPath: entry.path,
				kind: PortableContextEntry.Kind(entry.kind),
				startLine: entry.startLine,
				endLine: entry.endLine,
				byteCount: entry.byteCount
			)
		}
		omissions = context.omissions.map { omission in
			PortableContextOmission(
				displayPath: omission.path,
				reason: PortableContextOmission.Reason(omission.reason)
			)
		}
		content = context.content
		contentByteCount = context.contentByteCount
		maximumByteCount = context.maximumByteCount
		truncated = context.truncated
		omittedRootCount = context.omittedRootCount
		isCompleteForProvider = context.isCompleteForProvider
	}
}

extension PortablePlanResult {
	init(context: HeadlessWorkspaceContext, result: HeadlessOraclePairResult) {
		pairID = result.pairID
		status = switch result.pairStatus {
		case .completed: .completed
		case .partialFailure: .partialFailure
		case .failed: .failed
		}
		primary = PortablePlanLane(result.primary)
		secondary = PortablePlanLane(result.secondary)
		self.context = PortableContextPreview(context)
	}
}

private extension PortableContextEntry.Kind {
	init(_ kind: HeadlessWorkspaceContext.Entry.Kind) {
		self = switch kind {
		case .selectedFull: .full
		case .selectedSlice: .slice
		}
	}
}

private extension PortableContextOmission.Reason {
	init(_ reason: HeadlessWorkspaceContext.Omission.Reason) {
		self = switch reason {
		case .outsideWorkspace: .outsideWorkspace
		case .symlinkEscape: .symlinkEscape
		case .notFound: .notFound
		case .directoryUnsupported: .directoryUnsupported
		case .invalidUTF8: .invalidUTF8
		case .sourceTooLarge: .sourceTooLarge
		case .sliceOutOfBounds: .sliceOutOfBounds
		case .budgetExceeded: .budgetExceeded
		case .readFailed: .readFailed
		case .orphanSlice: .orphanSlice
		case .invalidSlice: .invalidSlice
		case .autoCodemapUnsupported: .autoCodemapUnsupported
		}
	}
}

private extension PortablePlanLane {
	init(_ result: HeadlessOracleLaneResult) {
		name = result.lane == .primary ? .primary : .secondary
		status = result.status == .completed ? .completed : .failed
		modelRawID = result.modelRawID
		response = result.response
		errorCode = result.failure?.code
		errorMessage = result.failure?.message
	}
}
