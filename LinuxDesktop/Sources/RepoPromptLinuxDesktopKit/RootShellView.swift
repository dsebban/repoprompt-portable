import Foundation
import RepoPromptHeadless
import SwiftCrossUI

public struct RootShellView: View {
	private let arguments: DesktopArguments
	private let oracleConfiguration: HeadlessOracleConfiguration?

	@State private var state = DesktopState()
	@State private var service: PortableWorkspaceService?
	@State private var proEditService: DesktopProEditService?
	@State private var currentTask: Task<Void, Never>?
	@State private var bootstrapAttempted = false

	public init(arguments: DesktopArguments, oracleConfiguration: HeadlessOracleConfiguration?) {
		self.arguments = arguments
		self.oracleConfiguration = oracleConfiguration
	}

	public var body: some View {
		NavigationSplitView {
			VStack(alignment: .leading, spacing: 6) {
				Text("RepoPrompt Portable")
					.font(.system(size: 20))
				Text(state.workspace?.name ?? "Loading workspace…")
					.foregroundColor(.gray)
				HStack {
					Button("Workspace") { state.selectDetail(.workspace) }
					Button("Settings") { state.selectDetail(.settings) }
				}
				TextField("Search files", text: $state.query)
				HStack {
					Button("Clear") { mutateSelection(.clear) }
						.disabled(state.activity != nil || !state.hasSelection)
					Button("Reload") { reloadFiles() }
						.disabled(state.activity != nil || service == nil)
				}
				Text("Selected \(state.selectedRepresentationCount) of \(state.files.count) · Showing \(state.visibleFiles.count)")
					.foregroundColor(.gray)
				ScrollView {
					VStack(alignment: .leading, spacing: 2) {
						ForEach(state.visibleFiles) { file in
							Button((state.focusedFilePath == file.absolutePath ? "› " : "  ") + state.roleMarker(for: file) + " " + file.displayPath) {
								state.focus(file)
							}
							._buttonWidth(250)
							.disabled(state.activity != nil)
						}
					}
				}
				if let file = state.focusedFile {
					Divider()
					Text(file.displayPath)
						.frame(maxWidth: 250, alignment: .leading)
					HStack {
						Button("Full") { mutateSelection(.promoteToFull([file.absolutePath])) }
							.disabled(state.activity != nil)
						Button("Codemap") { mutateSelection(.demoteToManualCodemap([file.absolutePath])) }
							.disabled(state.activity != nil || !file.codemapSupported)
						Button("Remove") { mutateSelection(.removeFiles([file.absolutePath])) }
							.disabled(state.activity != nil)
					}
					Text("Slices · line, start-end, or start-end | description")
						.foregroundColor(.gray)
						.frame(maxWidth: 250, alignment: .leading)
					TextEditor(text: $state.sliceDraftText)
						.frame(minHeight: 72)
						.disabled(state.activity != nil)
					Button("Apply Slices") { applySlices(to: file) }
						.disabled(state.activity != nil)
				}
			}
			.padding()
			.frame(minWidth: 280)
			.background(Color(
				red: 0.086810246,
				green: 0.092231961,
				blue: 0.097734573
			))
		} detail: {
			if state.detailRoute == .settings {
				ReadOnlySettingsView(
					workspace: state.workspace,
					fileCount: state.files.count,
					selectionCount: state.selectedRepresentationCount,
					oracleConfiguration: oracleConfiguration
				)
			} else {
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text("Compose")
							.font(.system(size: 20))
						Text(state.workspace?.roots.joined(separator: " · ") ?? "Read-only workspace")
							.foregroundColor(.gray)
					}
					Spacer()
					Text(state.oracleAvailable ? "● Oracle configured" : "○ Oracle unavailable")
						.foregroundColor(state.oracleAvailable ? .green : .gray)
					Button("Reload") { reloadFiles() }
						.disabled(state.activity != nil || service == nil)
					Button("Settings") { state.selectDetail(.settings) }
				}
				Divider()
				HStack {
					Text("Instructions")
						.font(.system(size: 18))
					Spacer()
					Text("\(state.instructions.count) characters")
						.foregroundColor(.gray)
				}
				TextEditor(text: $state.instructions)
					.frame(minHeight: 150)
					.disabled(state.activity != nil)
					.onChange(of: state.instructions) {
						instructionsChanged()
					}
				HStack {
					ForEach(
						[DesktopWorkspacePanel.selectedFiles, .contextBuilder, .oracle, .proEdit],
						id: \.rawValue
					) { panel in
						Button((state.activePanel == panel ? "● " : "") + panel.title) {
							state.activePanel = panel
						}
						.disabled(state.activity != nil)
					}
				}
				Divider()
				if state.activePanel == .selectedFiles {
					SelectedFilesSummaryView(state: state)
				} else if state.activePanel == .contextBuilder {
					ContextBuilderWorkspaceView(
						state: state,
						previewContext: previewContext,
						setAutomaticCodemaps: { enabled in
							mutateSelection(.setAutomaticCodemapsEnabled(enabled), activity: .automaticCodemap)
						},
						generatePlan: { generateOracle(.plan) },
						generateReview: { generateOracle(.review) },
						cancel: cancelCurrent
					)
				} else if state.activePanel == .oracle {
					OracleWorkspaceView(state: state, cancel: cancelCurrent)
				} else {
					ProEditWorkspaceView(
						state: state,
						generate: generateProEdit,
						selectLane: { state.selectProEditLane($0) },
						materialize: materializeProEdit,
						apply: applyProEdit,
						cancel: cancelCurrent,
						reset: resetProEdit
					)
				}
				Divider()
				HStack {
					Text("Context")
					Text("\(state.context?.entries.count ?? 0) entries")
						.foregroundColor(.gray)
					Text("\(state.context?.contentByteCount ?? 0) bytes")
						.foregroundColor(.gray)
					Spacer()
					Text("Full \(state.selection.selectedFiles.count)")
					Text("Slices \(state.selection.slices.count)")
					Text("Codemaps \(state.selection.manualCodemapFiles.count)")
				}
			}
			.padding()
			}
		}
		.task {
			await loadWorkspace()
		}
	}

	@MainActor
	private func loadWorkspace() async {
		guard !bootstrapAttempted, service == nil else { return }
		bootstrapAttempted = true
		let generation = state.begin(.startup)
		do {
			let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
				options: HeadlessOptions(roots: arguments.roots, persist: false)
			)
			let service = PortableWorkspaceService(
				bootstrap: bootstrap,
				oracleConfiguration: oracleConfiguration
			)
			let workspace = await service.workspace()
			let files = try await service.files()
			let selection = await service.selection()
			try Task.checkCancellation()
			self.service = service
			proEditService = DesktopProEditService(workspace: workspace, workspaceService: service)
			state.loaded(
				workspace: workspace,
				files: files,
				selection: selection,
				oracleAvailable: oracleConfiguration != nil,
				generation: generation
			)
			_ = try? FileHandle.standardOutput.write(contentsOf: Data("RepoPrompt Portable ready: \(files.count) files\n".utf8))
		} catch is CancellationError {
			state.cancelCurrent(generation: generation)
		} catch {
			let message = desktopErrorMessage(error)
			state.failed(message, generation: generation)
			_ = try? FileHandle.standardError.write(contentsOf: Data("RepoPrompt Portable startup failed: \(message)\n".utf8))
		}
	}

	private func mutateSelection(
		_ mutation: PortableSelectionMutation,
		activity: DesktopActivity = .selection
	) {
		guard let service, state.activity == nil else { return }
		let generation = state.begin(activity)
		currentTask = Task { @MainActor in
			do {
				let selection = try await service.mutateSelection(mutation)
				guard !Task.isCancelled else { return }
				state.selectionChanged(selection, generation: generation)
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func applySlices(to file: PortableWorkspaceFile) {
		guard state.activity == nil else { return }
		do {
			let ranges = try DesktopSliceDraftParser.parse(state.sliceDraftText)
			mutateSelection(.setSlices([PortableSliceSelection(path: file.absolutePath, ranges: ranges)]))
		} catch {
			let generation = state.begin(.selection)
			state.failed(desktopErrorMessage(error), generation: generation)
		}
	}

	private func instructionsChanged() {
		let sessionID = state.proEditSession?.id
		state.instructionsChanged()
		if let sessionID, let proEditService {
			Task {
				await proEditService.discard(sessionID)
			}
		}
	}

	private func reloadFiles() {
		guard let service, state.activity == nil else { return }
		let generation = state.begin(.reload)
		currentTask = Task { @MainActor in
			do {
				let files = try await service.files()
				try Task.checkCancellation()
				state.filesReloaded(files, generation: generation)
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func previewContext() {
		guard let service, state.activity == nil else { return }
		let generation = state.begin(.preview)
		currentTask = Task { @MainActor in
			do {
				let context = try await service.previewContext()
				try Task.checkCancellation()
				state.contextBuilt(context, generation: generation)
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func generateOracle(_ mode: DesktopOracleAction) {
		guard let service, state.canGeneratePlan else { return }
		let instructions = state.instructions
		let expectedContextContent = state.context?.content
		let activity: DesktopActivity = mode == .plan ? .plan : .review
		let generation = state.begin(activity)
		currentTask = Task { @MainActor in
			do {
				let result = try await (mode == .plan
					? service.generatePlan(
						instructions: instructions,
						expectedContextContent: expectedContextContent
					)
					: service.generateReview(
						instructions: instructions,
						expectedContextContent: expectedContextContent
					))
				guard !Task.isCancelled else { return }
				state.oracleGenerated(result, mode: mode, generation: generation)
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch let error as PortableWorkspaceServiceError {
				switch error {
				case .incompleteContext(let context), .staleContextPreview(let context):
					state.failed(error.message, context: context, generation: generation)
				default:
					state.failed(error.message, generation: generation)
				}
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func generateProEdit() {
		guard let service, state.canGenerateProEdit else { return }
		let instructions = state.instructions
		let expectedContextContent = state.context?.content
		let generation = state.begin(.proEditGenerate)
		currentTask = Task { @MainActor in
			do {
				let result = try await service.generateProEdit(
					instructions: instructions,
					expectedContextContent: expectedContextContent
				)
				guard !Task.isCancelled else { return }
				state.proEditGenerated(result, generation: generation)
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch let error as PortableWorkspaceServiceError {
				switch error {
				case .incompleteContext(let context), .staleContextPreview(let context):
					state.failed(error.message, context: context, generation: generation)
				default:
					state.failed(error.message, generation: generation)
				}
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func materializeProEdit() {
		guard let service,
			let proEditService,
			let generationResult = state.proEditGeneration,
			let selectedLane = state.selectedProEditLane,
			let source = state.selectedProEditArtifact,
			state.canMaterializeProEdit
		else { return }
		let generation = state.begin(.proEditMaterialize)
		currentTask = Task { @MainActor in
			do {
				let artifact = try PortableProEditArtifactParser.parse(source)
				let preflight = try await service.resolveProEditArtifact(
					artifact,
					expectedGeneration: generationResult,
					lane: selectedLane == .primary ? .primary : .secondary
				)
				let session = try await proEditService.materialize(preflight)
				guard !Task.isCancelled, state.generation == generation else {
					await proEditService.discard(session.id)
					return
				}
				guard state.proEditMaterialized(
					session,
					lane: selectedLane,
					artifact: source,
					generation: generation
				) else {
					await proEditService.discard(session.id)
					return
				}
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func applyProEdit() {
		guard let service,
			let proEditService,
			let session = state.proEditSession,
			state.canApplyProEdit
		else { return }
		let generation = state.begin(.proEditApply)
		currentTask = Task { @MainActor in
			do {
				let summary = try await proEditService.apply(session.id)
				do {
					let files = try await service.files()
					state.proEditApplied(summary, refreshedFiles: files, generation: generation)
				} catch {
					state.proEditApplied(summary, refreshedFiles: state.files, generation: generation)
					state.errorMessage = "Files were applied, but refreshing the workspace failed: \(desktopErrorMessage(error))"
				}
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch {
				await proEditService.discard(session.id)
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func resetProEdit() {
		guard state.activity == nil else { return }
		let sessionID = state.proEditSession?.id
		currentTask?.cancel()
		currentTask = nil
		state.resetProEdit()
		if let sessionID, let proEditService {
			Task {
				await proEditService.discard(sessionID)
			}
		}
	}

	private func cancelCurrent() {
		let generation = state.generation
		currentTask?.cancel()
		currentTask = nil
		state.cancelCurrent(generation: generation)
	}
}

private struct SelectedFilesSummaryView: View {
	let state: DesktopState

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 6) {
				Text("Selected Files")
					.font(.system(size: 20))
				Text("Full files \(state.selection.selectedFiles.count) · Slices \(state.selection.slices.count) · Manual codemaps \(state.selection.manualCodemapFiles.count)")
					.foregroundColor(.gray)
				if !state.selection.selectedFiles.isEmpty {
					Text("Full files")
					ForEach(state.selection.selectedFiles) { file in
						Text("[F] \(file.displayPath)")
					}
				}
				if !state.selection.slices.isEmpty {
					Text("Slices")
					ForEach(Array(state.selection.slices.enumerated()), id: \.offset) { row in
						Text("[S] \(row.element.path) · \(row.element.ranges.count) ranges")
					}
				}
				if !state.selection.manualCodemapFiles.isEmpty {
					Text("Manual codemaps")
					ForEach(state.selection.manualCodemapFiles) { file in
						Text("[C] \(file.displayPath)")
					}
				}
				if !state.selection.codemapAutoEnabled {
					Text("Automatic codemaps are off.").foregroundColor(.gray)
				}
			}
		}
	}
}

private struct ContextBuilderWorkspaceView: View {
	let state: DesktopState
	let previewContext: () -> Void
	let setAutomaticCodemaps: (Bool) -> Void
	let generatePlan: () -> Void
	let generateReview: () -> Void
	let cancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				VStack(alignment: .leading, spacing: 2) {
					Text("What are you working on?")
						.font(.system(size: 20))
					Text("Build canonical context, then ask the paired Oracle for a plan or review.")
						.foregroundColor(.gray)
				}
				Spacer()
					Button("Build Context") { previewContext() }
						.disabled(state.activity != nil)
					Button("Plan") { generatePlan() }
						.disabled(!state.canGeneratePlan)
					Button("Review") { generateReview() }
						.disabled(!state.canGeneratePlan)
					if state.activity == .preview || state.activity == .plan || state.activity == .review {
						Button("Cancel") { cancel() }
					}
			}
			HStack {
				Text("Automatic codemaps: \(state.selection.codemapAutoEnabled ? "On" : "Off")")
				Button("On") { setAutomaticCodemaps(true) }
					.disabled(state.activity != nil || state.selection.codemapAutoEnabled)
				Button("Off") { setAutomaticCodemaps(false) }
					.disabled(state.activity != nil || !state.selection.codemapAutoEnabled)
				if !state.oracleAvailable {
					Text("Plan and Review require Oracle configuration.")
						.foregroundColor(.gray)
				}
			}
			ActivityStatusView(state: state)
			ScrollView {
				if let context = state.context {
					ContextPreviewView(context: context)
				} else {
					Text("No context preview yet. Select files and choose Build Context.")
						.foregroundColor(.gray)
				}
			}
		}
	}
}

private struct OracleWorkspaceView: View {
	let state: DesktopState
	let cancel: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("Paired Oracle")
					.font(.system(size: 20))
				Text(state.oracleMode?.title ?? "Plan / Review")
					.foregroundColor(.gray)
				Spacer()
					if state.activity == .plan || state.activity == .review {
						Button("Cancel") { cancel() }
					}
			}
			ActivityStatusView(state: state)
			ScrollView {
				if let plan = state.plan {
					VStack(alignment: .leading, spacing: 10) {
						Text("Overall status: \(plan.status.rawValue)")
						LaneResultView(title: "Primary", lane: plan.primary)
						Divider()
						LaneResultView(title: "Secondary", lane: plan.secondary)
					}
				} else {
					Text("No Oracle result yet. Use Context Builder to run Plan or Review.")
						.foregroundColor(.gray)
				}
			}
		}
	}
}

private struct ProEditWorkspaceView: View {
	let state: DesktopState
	let generate: () -> Void
	let selectLane: (DesktopProEditLane) -> Void
	let materialize: () -> Void
	let apply: () -> Void
	let cancel: () -> Void
	let reset: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				VStack(alignment: .leading, spacing: 2) {
					Text("Pro Edit")
						.font(.system(size: 20))
					Text("Generate attributed edit artifacts, choose one, preview every file, then apply explicitly.")
						.foregroundColor(.gray)
				}
				Spacer()
				Button("Generate Pro Edit") { generate() }
					.disabled(!state.canGenerateProEdit)
				Button("Materialize Preview") { materialize() }
					.disabled(!state.canMaterializeProEdit)
				if state.activity == .proEditGenerate || state.activity == .proEditMaterialize {
					Button("Cancel") { cancel() }
				}
				Button("Reset") { reset() }
					.disabled(state.activity != nil)
			}
			Text("Warning: Apply & Save writes the reviewed files directly inside the loaded workspace.")
				.foregroundColor(.red)
			ActivityStatusView(state: state)
			ScrollView {
				VStack(alignment: .leading, spacing: 10) {
					if let generation = state.proEditGeneration {
						Text("Choose exactly one Oracle artifact")
							.font(.system(size: 18))
						Text("Primary and Secondary remain independent. They are never merged or promoted automatically.")
							.foregroundColor(.gray)
						ProEditLaneView(
							title: "Primary",
							lane: generation.result.primary,
							selected: state.selectedProEditLane == .primary,
							disabled: state.activity != nil,
							select: { selectLane(.primary) }
						)
						Divider()
						ProEditLaneView(
							title: "Secondary",
							lane: generation.result.secondary,
							selected: state.selectedProEditLane == .secondary,
							disabled: state.activity != nil,
							select: { selectLane(.secondary) }
						)
					} else {
						Text("Task / instructions")
							.font(.system(size: 18))
						Text(state.instructions.isEmpty
							? "Enter the task in Instructions above, select its files, then generate Pro Edit."
							: state.instructions)
							.foregroundColor(.gray)
					}

					if let session = state.proEditSession {
						Divider()
						Text("Materialized file preview")
							.font(.system(size: 18))
						Text("\(session.files.count) ordered files · \(session.changedPaths.count) changes")
							.foregroundColor(.gray)
						ForEach(Array(session.files.enumerated()), id: \.offset) { row in
							ProEditFilePreviewView(index: row.offset + 1, proposal: row.element)
							Divider()
						}
						Text("Apply is transactional and revalidates paths and source snapshots before writing.")
							.foregroundColor(.red)
						if !state.proEditReviewIsComplete {
							Text("Apply is disabled because at least one full Original or Proposed pane is truncated.")
								.foregroundColor(.red)
						}
						Button("Apply & Save \(session.changedPaths.count) Files") { apply() }
							.disabled(!state.canApplyProEdit)
					}

					if !state.appliedProEditPaths.isEmpty {
						Divider()
						Text("Applied paths")
							.font(.system(size: 18))
						ForEach(Array(state.appliedProEditPaths.enumerated()), id: \.offset) { row in
							Text("✓ \(row.element)").foregroundColor(.green)
						}
					}
				}
			}
		}
	}
}

private struct ProEditLaneView: View {
	let title: String
	let lane: PortablePlanLane
	let selected: Bool
	let disabled: Bool
	let select: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text("\(selected ? "●" : "○") \(title) · \(lane.modelRawID) · \(lane.status.rawValue)")
				Spacer()
				Button(selected ? "Selected" : "Choose \(title)") { select() }
					.disabled(lane.response == nil || selected || disabled)
			}
			if let response = lane.response {
				let preview = DesktopContextText(response)
				ForEach(Array(preview.chunks.enumerated()), id: \.offset) { chunk in
					Text(chunk.element).font(.system(size: 12))
				}
				if preview.truncated {
					Text("Artifact display is truncated; parsing uses the complete generated artifact.")
						.foregroundColor(.gray)
				}
			} else {
				Text("\(lane.errorCode ?? "error"): \(lane.errorMessage ?? "No artifact returned.")")
					.foregroundColor(.red)
			}
		}
	}

}

private struct ProEditFilePreviewView: View {
	let index: Int
	let proposal: PortableProEditFileProposal

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("\(index). \(proposal.target.displayPath) · \(proposal.target.file.action.rawValue) · \(status)")
			if let modelRawID = proposal.modelRawID {
				Text("Materialized by \(modelRawID)").foregroundColor(.gray)
			}
			switch proposal.status {
			case .failed(_, let message):
				Text(message).foregroundColor(.red)
			case .unchanged:
				Text("No file-system change will be written.").foregroundColor(.gray)
			case .proposed:
				if let replacementDiff = proposal.replacementDiff {
					Text("Replacement diff")
					let diff = DesktopContextText(replacementDiff)
					ForEach(Array(diff.chunks.enumerated()), id: \.offset) { chunk in
						Text(chunk.element).font(.system(size: 12))
					}
					if diff.truncated {
						Text("Replacement diff is truncated. Review the complete Original and Proposed panes below.")
							.foregroundColor(.gray)
					}
				}
				HStack {
					VStack(alignment: .leading, spacing: 2) {
						Text("Original").foregroundColor(.gray)
						let original = DesktopContextText(proposal.target.originalContent ?? "(new file)")
						ForEach(Array(original.chunks.enumerated()), id: \.offset) { chunk in
							Text(chunk.element).font(.system(size: 12))
						}
						if original.truncated {
							Text("Original content is truncated.").foregroundColor(.red)
						}
					}
					Spacer()
					VStack(alignment: .leading, spacing: 2) {
						Text("Proposed").foregroundColor(.gray)
						let proposed = DesktopContextText(proposal.proposedContent ?? "")
						ForEach(Array(proposed.chunks.enumerated()), id: \.offset) { chunk in
							Text(chunk.element).font(.system(size: 12))
						}
						if proposed.truncated {
							Text("Proposed content is truncated.").foregroundColor(.red)
						}
					}
				}
			}
		}
	}

	private var status: String {
		switch proposal.status {
		case .proposed: return "proposed"
		case .unchanged: return "unchanged"
		case .failed(let code, _): return "failed (\(code))"
		}
	}
}

private struct ActivityStatusView: View {
	let state: DesktopState

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			if let activity = state.activity {
				HStack {
					ProgressView()
					Text(activity.label)
				}
			} else if let status = state.statusMessage {
				Text(status).foregroundColor(.gray)
			}
			if let error = state.errorMessage {
				Text(error).foregroundColor(.red)
			}
		}
	}
}

func desktopOracleEndpoint(_ endpoint: URL) -> String {
	guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
		return "Invalid endpoint"
	}
	components.user = nil
	components.password = nil
	components.query = nil
	components.fragment = nil
	return components.url?.absoluteString ?? "Invalid endpoint"
}

private struct ReadOnlySettingsView: View {
	let workspace: PortableWorkspaceSummary?
	let fileCount: Int
	let selectionCount: Int
	let oracleConfiguration: HeadlessOracleConfiguration?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 10) {
				VStack(alignment: .leading, spacing: 4) {
					Text("Settings").font(.system(size: 28))
					Text("Runtime configuration supplied by the launch environment.")
						.foregroundColor(.gray)
				}
				Divider()
				VStack(alignment: .leading, spacing: 4) {
					Text("Workspace").font(.system(size: 20))
					Text("Name: \(workspace?.name ?? "Loading…")")
					ForEach(Array((workspace?.roots ?? []).enumerated()), id: \.offset) { root in
						Text("root[\(root.offset)]: \(root.element)")
					}
					Text("Indexed files: \(fileCount)")
					Text("Selected files: \(selectionCount)")
					Text("Persistence: Disabled")
					Text("Access: Read-only browsing plus explicit reviewed Pro Edit writes")
				}
				Divider()
				VStack(alignment: .leading, spacing: 4) {
					Text("Oracle").font(.system(size: 20))
					if let configuration = oracleConfiguration {
						Text("Status: Configured")
						Text("Endpoint: \(desktopOracleEndpoint(configuration.endpoint))")
						Text("Primary model: \(configuration.primaryModel)")
						Text("Secondary model: \(configuration.secondaryModel)")
						Text("Reasoning effort: \(configuration.reasoningEffort ?? "Provider default")")
						Text("Timeout: \(configuration.timeoutSeconds) seconds")
						Text("Bearer authentication: \(configuration.bearerToken == nil ? "Not configured" : "Configured (hidden)")")
					} else {
						Text("Status: Not configured")
						Text("Context preview remains available; Generate Plan and Review are disabled.")
					}
				}
				Divider()
				VStack(alignment: .leading, spacing: 4) {
					Text("MCP and CLI").font(.system(size: 20))
					Text("Software version: \(PortableContract.softwareVersion)")
					Text("Tool schema: \(PortableContract.toolSchemaVersion)")
					Text("MCP executable: repoprompt-headless")
					Text("MCP transport: stdio, seven read-only tools")
					Text("CLI executable: repoprompt-portable-cli")
					Text("CLI protocol: JSONL over the same in-process catalog")
					Text("Desktop executable: repoprompt-linux-desktop")
					Text("Desktop Pro Edit: Materialize preview, then explicit transactional Apply & Save")
					Text("MCP and CLI remain read-only and cannot invoke desktop writes")
				}
				Divider()
				VStack(alignment: .leading, spacing: 4) {
					Text("Advanced · File System").font(.system(size: 20))
					Text("✓ Respect workspace and nested .gitignore rules")
					Text("✓ Hide dotfiles, .build, and node_modules")
					Text("✓ Allow regular-file symlinks only when their targets remain inside a workspace root")
					Text("○ Traverse directory symlinks")
					Text("○ Show empty folders")
					Text(".repo_ignore and .cursorignore: Not supported by the portable explorer")
				}
			}
			.padding()
		}
	}
}

private struct ContextPreviewView: View {
	let context: PortableContextPreview

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("Context: \(context.entries.count) entries, \(context.contentByteCount) / \(context.maximumByteCount) bytes")
			if !context.entries.isEmpty {
				Text("Canonical preview entries")
				ForEach(Array(context.entries.prefix(128).enumerated()), id: \.offset) { row in
					Text(contextEntryLabel(row.element)).foregroundColor(.gray)
				}
			}
			if !context.automaticCodemapPaths.isEmpty {
				Text("Derived automatic codemaps (\(context.automaticCodemapPaths.count))")
				ForEach(Array(context.automaticCodemapPaths.prefix(64).enumerated()), id: \.offset) { row in
					Text("[A] \(row.element)").foregroundColor(.gray)
				}
			}
			if context.truncated {
				Text("Context is truncated.").foregroundColor(.red)
			}
			if context.omittedRootCount > 0 {
				Text("Omitted roots: \(context.omittedRootCount)").foregroundColor(.red)
			}
			if !context.omissions.isEmpty {
				Text("Omissions (\(context.omissions.count))")
				ForEach(Array(context.omissions.prefix(64).enumerated()), id: \.offset) { row in
					Text("\(row.element.displayPath): \(row.element.reason.rawValue)")
						.foregroundColor(.red)
				}
				if context.omissions.count > 64 {
					Text("Showing 64 of \(context.omissions.count) omissions.").foregroundColor(.red)
				}
			}
			let preview = DesktopContextText(context.content)
			ForEach(Array(preview.chunks.enumerated()), id: \.offset) { chunk in
				Text(chunk.element).font(.system(size: 12))
			}
			if preview.truncated {
				Text("Preview shows the first \(DesktopContextText.maximumCharacters) characters.")
					.foregroundColor(.gray)
			}
		}
	}
}

private func contextEntryLabel(_ entry: PortableContextEntry) -> String {
	var metadata = entry.kind.rawValue
	if let source = entry.codemapSource { metadata += ":\(source.rawValue)" }
	if let start = entry.startLine {
		metadata += entry.endLine == start ? ":L\(start)" : ":L\(start)-\(entry.endLine ?? start)"
	}
	return "[\(metadata)] \(entry.displayPath) · \(entry.byteCount) bytes"
}

private struct LaneResultView: View {
	let title: String
	let lane: PortablePlanLane

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text("\(title) — \(lane.modelRawID) — \(lane.status.rawValue)")
			if let response = lane.response {
				Text(response)
			} else {
				Text("\(lane.errorCode ?? "error"): \(lane.errorMessage ?? "No response")")
					.foregroundColor(.red)
			}
		}
	}
}
