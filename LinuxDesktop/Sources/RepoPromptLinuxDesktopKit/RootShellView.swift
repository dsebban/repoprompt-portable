import Foundation
import RepoPromptHeadless
import SwiftCrossUI

public struct RootShellView: View {
	private let arguments: DesktopArguments
	private let oracleConfiguration: HeadlessOracleConfiguration?

	@State private var state = DesktopState()
	@State private var service: PortableWorkspaceService?
	@State private var currentTask: Task<Void, Never>?
	@State private var bootstrapAttempted = false
	@State private var showSettings = false

	public init(arguments: DesktopArguments, oracleConfiguration: HeadlessOracleConfiguration?) {
		self.arguments = arguments
		self.oracleConfiguration = oracleConfiguration
	}

	public var body: some View {
		NavigationSplitView {
			VStack(alignment: .leading, spacing: 8) {
				Text(state.workspace?.name ?? "Workspace")
				HStack {
					Button("Workspace") { showSettings = false }
					Button("Settings") { showSettings = true }
				}
				TextField("Search files", text: $state.query)
				HStack {
					Button("Clear") { clearSelection() }
						.disabled(state.activity != nil || state.selectedPaths.isEmpty)
					Button("Reload") { reloadFiles() }
						.disabled(state.activity != nil || service == nil)
				}
				Text("Selected: \(state.selectedPaths.count) / \(state.files.count)")
				Text("Showing \(state.visibleFiles.count) of \(state.matchingFiles.count) matching files.")
				ScrollView {
					VStack(alignment: .leading, spacing: 2) {
						ForEach(state.visibleFiles) { file in
							Button((state.selectedPaths.contains(file.absolutePath) ? "✓ " : "  ") + file.displayPath) {
								toggle(file)
							}
							.disabled(state.activity != nil)
						}
					}
				}
			}
			.padding()
			.frame(minWidth: 280)
		} detail: {
			if showSettings {
				ReadOnlySettingsView(
					workspace: state.workspace,
					fileCount: state.files.count,
					selectionCount: state.selectedPaths.count,
					oracleConfiguration: oracleConfiguration
				)
			} else {
			VStack(alignment: .leading, spacing: 8) {
				Text("Instructions")
				TextEditor(text: $state.instructions)
					.frame(minHeight: 140)
					.disabled(state.activity != nil)
					.onChange(of: state.instructions) {
						state.plan = nil
					}

				HStack {
					Button("Preview Context") { previewContext() }
						.disabled(state.activity != nil || service == nil)
					Button("Generate Plan") { generatePlan() }
						.disabled(!state.canGeneratePlan || service == nil)
					if state.activity == .plan {
						Button("Cancel") { cancelCurrent() }
					}
				}

				if !state.oracleAvailable, state.workspace != nil {
					Text("Generate Plan requires Oracle environment configuration.")
						.foregroundColor(.gray)
				}
				if let activity = state.activity {
					HStack {
						ProgressView()
						Text(activity.label)
					}
				}
				if state.activity == nil, let status = state.statusMessage {
					Text(status).foregroundColor(.gray)
				}
				if let error = state.errorMessage {
					Text(error).foregroundColor(.red)
				}

				ScrollView {
					VStack(alignment: .leading, spacing: 10) {
						if let context = state.context {
							ContextPreviewView(context: context)
						}
						if let plan = state.plan {
							Divider()
							Text("Plan: \(plan.status.rawValue)")
							LaneResultView(title: "Primary", lane: plan.primary)
							LaneResultView(title: "Secondary", lane: plan.secondary)
						}
					}
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

	private func toggle(_ file: PortableWorkspaceFile) {
		guard let service, state.activity == nil else { return }
		let removing = state.selectedPaths.contains(file.absolutePath)
		let generation = state.begin(.selection)
		currentTask = Task { @MainActor in
			do {
				let selection = try await (removing
					? service.removeFiles([file.absolutePath])
					: service.addFiles([file.absolutePath]))
				guard !Task.isCancelled else { return }
				state.selectionChanged(selection, generation: generation)
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
			}
		}
	}

	private func clearSelection() {
		guard let service, state.activity == nil else { return }
		let generation = state.begin(.selection)
		currentTask = Task { @MainActor in
			let selection = await service.clearSelection()
			guard !Task.isCancelled else { return }
			state.selectionChanged(selection, generation: generation)
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

	private func generatePlan() {
		guard let service, state.canGeneratePlan else { return }
		let instructions = state.instructions
		let generation = state.begin(.plan)
		currentTask = Task { @MainActor in
			do {
				let plan = try await service.generatePlan(instructions: instructions)
				guard !Task.isCancelled else { return }
				state.planGenerated(plan, generation: generation)
			} catch is CancellationError {
				state.cancelCurrent(generation: generation)
			} catch let error as PortableWorkspaceServiceError {
				if case .incompleteContext(let context) = error {
					state.failed(error.message, context: context, generation: generation)
				} else {
					state.failed(error.message, generation: generation)
				}
			} catch {
				state.failed(desktopErrorMessage(error), generation: generation)
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
					Text("Read-only runtime configuration supplied by the launch environment.")
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
					Text("Access: Read-only")
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
						Text("Context preview remains available; Generate Plan is disabled.")
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
