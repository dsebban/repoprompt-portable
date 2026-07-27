import Foundation
import RepoPromptHeadless

public struct DesktopProEditSession: Equatable, Sendable {
	public let id: UUID
	public let changedPaths: [String]
	public let files: [PortableProEditFileProposal]

	init(
		id: UUID,
		changedPaths: [String],
		files: [PortableProEditFileProposal]
	) {
		self.id = id
		self.changedPaths = changedPaths
		self.files = files
	}
}

public actor DesktopProEditService {
	private enum ActiveOperation {
		case materialize
		case apply
	}

	private struct MaterializedSession: Sendable {
		let id: UUID
		let workspace: PortableWorkspaceSummary
		let selection: PortableWorkspaceSelection
		let plans: [DesktopProEditWritePlan]
	}

	private let workspace: PortableWorkspaceSummary
	private let workspaceService: PortableWorkspaceService
	private let writer: any DesktopProEditWriting
	private let beforeApplyValidation: (@Sendable () async -> Void)?
	private var currentSession: MaterializedSession?
	private var activeOperation: ActiveOperation?

	public init(
		workspace: PortableWorkspaceSummary,
		workspaceService: PortableWorkspaceService
	) {
		self.workspace = workspace
		self.workspaceService = workspaceService
		self.writer = DesktopProEditWriter()
		self.beforeApplyValidation = nil
	}

	init(
		workspace: PortableWorkspaceSummary,
		workspaceService: PortableWorkspaceService,
		writer: any DesktopProEditWriting,
		beforeApplyValidation: (@Sendable () async -> Void)? = nil
	) {
		self.workspace = workspace
		self.workspaceService = workspaceService
		self.writer = writer
		self.beforeApplyValidation = beforeApplyValidation
	}

	public func materialize(_ preflight: PortableProEditPreflight) async throws -> DesktopProEditSession {
		guard activeOperation == nil else {
			throw DesktopProEditApplyError(.applyInProgress, message: "Another Pro Edit operation is already in progress.")
		}
		activeOperation = .materialize
		currentSession = nil
		defer { activeOperation = nil }
		guard await workspaceService.workspace() == workspace else {
			throw DesktopProEditApplyError(.workspaceChanged, message: "Pro Edit preflight belongs to another workspace.")
		}
		guard await workspaceService.selection() == preflight.selection else {
			throw DesktopProEditApplyError(.staleSelection, message: "Workspace selection changed after Pro Edit preflight.")
		}
		let guardrail = DesktopProEditPathGuard(roots: workspace.roots)
		var preMaterializationSnapshots: [String: DesktopProEditFileSnapshot] = [:]
		for target in preflight.targets {
			if let snapshot = try guardrail.snapshot(target) {
				preMaterializationSnapshots[target.absolutePath] = snapshot
			}
		}
		let preview = try await workspaceService.materializeProEditPreview(preflight)
		return try await register(preview, preMaterializationSnapshots: preMaterializationSnapshots)
	}

	public func apply(_ sessionID: UUID) async throws -> DesktopProEditApplySummary {
		guard activeOperation == nil else {
			throw DesktopProEditApplyError(.applyInProgress, message: "Another Pro Edit operation is already in progress.")
		}
		guard let session = currentSession else {
			throw DesktopProEditApplyError(.invalidSession, message: "Pro Edit preview is no longer available.")
		}
		guard session.id == sessionID else {
			throw DesktopProEditApplyError(.staleSession, message: "A newer Pro Edit preview replaced this session.")
		}
		activeOperation = .apply
		defer { activeOperation = nil }
		await beforeApplyValidation?()
		guard await workspaceService.workspace() == session.workspace,
			session.workspace == workspace
		else {
			throw DesktopProEditApplyError(.workspaceChanged, message: "Loaded workspace changed after Pro Edit materialization.")
		}
		guard await workspaceService.selection() == session.selection else {
			throw DesktopProEditApplyError(.staleSelection, message: "Workspace selection changed after Pro Edit materialization.")
		}

		guard currentSession?.id == sessionID else {
			throw DesktopProEditApplyError(.staleSession, message: "Pro Edit session changed before apply.")
		}
		let summary = try writer.write(session.plans, roots: workspace.roots)
		currentSession = nil
		return summary
	}

	public func discard(_ sessionID: UUID) {
		guard currentSession?.id == sessionID, activeOperation == nil else { return }
		currentSession = nil
	}

	private func register(
		_ preview: PortableProEditPreview,
		preMaterializationSnapshots: [String: DesktopProEditFileSnapshot]
	) async throws -> DesktopProEditSession {
		guard preview.status == .completed else {
			currentSession = nil
			return DesktopProEditSession(id: UUID(), changedPaths: [], files: preview.files)
		}
		guard await workspaceService.workspace() == workspace else {
			throw DesktopProEditApplyError(.workspaceChanged, message: "Pro Edit preview belongs to another workspace.")
		}
		guard await workspaceService.selection() == preview.selection else {
			throw DesktopProEditApplyError(.staleSelection, message: "Workspace selection changed during Pro Edit materialization.")
		}

		let guardrail = DesktopProEditPathGuard(roots: workspace.roots)
		var plans: [DesktopProEditWritePlan] = []
		for proposal in preview.files {
			let content = proposal.proposedContent
			switch proposal.status {
			case .failed:
				throw DesktopProEditApplyError(
					.invalidProposal,
					path: proposal.target.displayPath,
					message: "A failed Pro Edit proposal cannot be applied."
				)
			case .unchanged:
				continue
			case .proposed:
				guard content != nil else {
					throw DesktopProEditApplyError(
						.invalidProposal,
						path: proposal.target.displayPath,
						message: "Materialized Pro Edit proposal omitted file content."
					)
				}
			}
			guard let content else { continue }
			let proposedBytes = Data(content.utf8)
			let current = try guardrail.snapshot(proposal.target)
			let expected: DesktopProEditFileSnapshot?
			switch proposal.target.file.action {
			case .create:
				expected = nil
			case .delegateEdit:
				guard let materializationSnapshot = preMaterializationSnapshots[proposal.target.absolutePath],
					current == materializationSnapshot
				else {
					throw DesktopProEditApplyError(
						.sourceChanged,
						path: proposal.target.displayPath,
						message: "Pro Edit target changed while its proposal was materialized."
					)
				}
				expected = materializationSnapshot
			}
			if let original = proposal.target.originalContent {
				guard expected?.bytes == Data(original.utf8) else {
					throw DesktopProEditApplyError(
						.sourceChanged,
						path: proposal.target.displayPath,
						message: "Pro Edit target changed while its preview was materialized."
					)
				}
			}
			plans.append(DesktopProEditWritePlan(
				rootIndex: proposal.target.rootIndex,
				relativePath: proposal.target.relativePath,
				absolutePath: proposal.target.absolutePath,
				displayPath: proposal.target.displayPath,
				action: proposal.target.file.action,
				expected: expected,
				proposedBytes: proposedBytes
			))
		}
		guard !plans.isEmpty else {
			currentSession = nil
			return DesktopProEditSession(id: UUID(), changedPaths: [], files: preview.files)
		}
		let boundPlans = try guardrail.bindDirectoryIdentities(plans)

		let id = UUID()
		currentSession = MaterializedSession(
			id: id,
			workspace: workspace,
			selection: preview.selection,
			plans: boundPlans
		)
		return DesktopProEditSession(
			id: id,
			changedPaths: boundPlans.map(\.displayPath),
			files: preview.files
		)
	}
}
