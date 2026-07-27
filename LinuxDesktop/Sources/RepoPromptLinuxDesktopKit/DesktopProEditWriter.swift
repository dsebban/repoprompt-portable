import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if os(Linux)
@_silgen_name("renameat2")
private func linuxRenameAt2(
	_ oldDirectory: Int32,
	_ oldName: UnsafePointer<CChar>,
	_ newDirectory: Int32,
	_ newName: UnsafePointer<CChar>,
	_ flags: UInt32
) -> Int32
#endif

public struct DesktopProEditApplySummary: Equatable, Sendable {
	public let transactionID: UUID
	public let appliedPaths: [String]

	init(transactionID: UUID, appliedPaths: [String]) {
		self.transactionID = transactionID
		self.appliedPaths = appliedPaths
	}
}

public struct DesktopProEditApplyError: Error, Equatable, Sendable, LocalizedError {
	public enum Code: String, Equatable, Sendable {
		case invalidSession = "invalid_session"
		case staleSession = "stale_session"
		case workspaceChanged = "workspace_changed"
		case staleSelection = "stale_selection"
		case noChanges = "no_changes"
		case invalidProposal = "invalid_proposal"
		case unsafePath = "unsafe_path"
		case outsideWorkspace = "outside_workspace"
		case targetIsDirectory = "target_is_directory"
		case duplicateTarget = "duplicate_target"
		case overlappingTarget = "overlapping_target"
		case sourceChanged = "source_changed"
		case createCollision = "create_collision"
		case applyInProgress = "apply_in_progress"
		case writeFailed = "write_failed"
		case rollbackFailed = "rollback_failed"
	}

	public let code: Code
	public let path: String?
	public let message: String

	init(_ code: Code, path: String? = nil, message: String) {
		self.code = code
		self.path = path
		self.message = message
	}

	public var errorDescription: String? { message }
}

enum DesktopProEditWriterEvent: Equatable, Sendable {
	case beforeParentAcquisition(index: Int, path: String)
	case beforeBackupStaging(index: Int, path: String)
	case afterStagingFileCreated(index: Int, path: String, name: String)
	case afterRevalidation
	case beforeCommit(index: Int, path: String)
	case beforePublishMutation(index: Int, path: String)
	case beforeStagedPublish(index: Int, path: String, name: String)
	case beforeCorrectiveMutation(index: Int, path: String)
	case afterPublish(index: Int, path: String)
	case beforeRollback(index: Int, path: String)
	case beforeRollbackMutation(index: Int, path: String)
	case beforeOwnedCleanup(path: String, name: String)
	case afterQuarantineVerification(path: String, name: String, quarantineName: String)
}

protocol DesktopProEditWriting: Sendable {
	func write(_ plans: [DesktopProEditWritePlan], roots: [String]) throws -> DesktopProEditApplySummary
}

struct DesktopProEditWriter: DesktopProEditWriting, Sendable {
	private let fileManager: FileManager
	private let injectedCommitFailureIndex: Int?
	private let eventHook: (@Sendable (DesktopProEditWriterEvent) throws -> Void)?

	init(
		fileManager: FileManager = .default,
		injectedCommitFailureIndex: Int? = nil,
		eventHook: (@Sendable (DesktopProEditWriterEvent) throws -> Void)? = nil
	) {
		self.fileManager = fileManager
		self.injectedCommitFailureIndex = injectedCommitFailureIndex
		self.eventHook = eventHook
	}

	func write(_ plans: [DesktopProEditWritePlan], roots: [String]) throws -> DesktopProEditApplySummary {
		let guardrail = DesktopProEditPathGuard(roots: roots, fileManager: fileManager)
		let validated = try guardrail.validateAll(plans)
		guard validated.allSatisfy({
			$0.plan.reviewedRootIdentity == $0.rootIdentity
				&& $0.plan.reviewedParentIdentity == $0.parentIdentity
		}) else {
			throw DesktopProEditApplyError(
				.invalidProposal,
				message: "Pro Edit apply requires the reviewed workspace root and parent identities."
			)
		}
		try Task.checkCancellation()

		let transactionID = UUID()
		var entries: [StagedEntry] = []
		entries.reserveCapacity(validated.count)
		do {
			for (index, item) in validated.enumerated() {
				try eventHook?(.beforeParentAcquisition(index: index, path: item.plan.displayPath))
				let descriptors = try openParent(item)
				var owned: [String: DesktopProEditFileSnapshot] = [:]
				var stagedDescriptors: [Int32] = []
				do {
					try validateBindings(
						rootPath: item.rootPath,
						rootDescriptor: descriptors.root,
						parentComponents: item.parentComponents,
						parentDescriptor: descriptors.parent,
						expectedRootIdentity: item.rootIdentity,
						expectedParentIdentity: item.parentIdentity,
						displayPath: item.plan.displayPath
					)
					let token = transactionID.uuidString.replacingOccurrences(of: "-", with: "")
						+ "-\(index)-"
						+ UUID().uuidString.replacingOccurrences(of: "-", with: "")
					let temporaryName = ".repoprompt-pro-edit-\(token).tmp"
					let backupName = ".repoprompt-pro-edit-\(token).backup"
					let temporary = try writeStagedFile(
						parentDescriptor: descriptors.parent,
						name: temporaryName,
						bytes: item.plan.proposedBytes,
						permissions: item.plan.expected?.posixPermissions ?? 0o644,
						displayPath: item.plan.displayPath,
						index: index
					)
					owned[temporaryName] = temporary.snapshot
					stagedDescriptors.append(temporary.descriptor)
					var backup: StagedFile?
					if let expected = item.plan.expected {
						try eventHook?(.beforeBackupStaging(index: index, path: item.plan.displayPath))
						backup = try writeStagedFile(
							parentDescriptor: descriptors.parent,
							name: backupName,
							bytes: expected.bytes,
							permissions: expected.posixPermissions,
							displayPath: item.plan.displayPath,
							index: index
						)
						owned[backupName] = backup?.snapshot
						stagedDescriptors.append(backup!.descriptor)
					}
					entries.append(StagedEntry(
						validated: item,
						rootDescriptor: descriptors.root,
						parentDescriptor: descriptors.parent,
						destinationName: (item.plan.absolutePath as NSString).lastPathComponent,
						temporaryName: temporaryName,
						temporaryDescriptor: temporary.descriptor,
						backupName: item.plan.expected == nil ? nil : backupName,
						backupDescriptor: backup?.descriptor,
						publishedSnapshot: nil,
						privateOwnership: owned
					))
				} catch {
					cleanupOwned(owned, parentDescriptor: descriptors.parent)
					for descriptor in stagedDescriptors {
						_ = close(descriptor)
					}
					_ = close(descriptors.parent)
					_ = close(descriptors.root)
					throw error
				}
			}

			for entry in entries {
				try revalidate(entry)
			}
			try eventHook?(.afterRevalidation)
			try Task.checkCancellation()
		} catch {
			cleanup(entries)
			closeDescriptors(entries)
			throw normalized(error)
		}

		var committedCount = 0
		do {
			for index in entries.indices {
				try eventHook?(.beforeCommit(index: index, path: entries[index].validated.plan.displayPath))
				if injectedCommitFailureIndex == index {
					throw DesktopProEditApplyError(
						.writeFailed,
						path: entries[index].validated.plan.displayPath,
						message: "Injected Pro Edit commit failure."
					)
				}
				try revalidate(entries[index])
				try eventHook?(.beforePublishMutation(index: index, path: entries[index].validated.plan.displayPath))
				try eventHook?(.beforeStagedPublish(
					index: index,
					path: entries[index].validated.plan.displayPath,
					name: entries[index].temporaryName
				))
				switch entries[index].validated.plan.action {
				case .delegateEdit:
					try publishDelegateEdit(&entries[index], index: index)
				case .create:
					try publishCreate(&entries[index])
				}
				do {
					try eventHook?(.afterPublish(index: index, path: entries[index].validated.plan.displayPath))
					try validateBindings(entries[index])
					try verifyPublished(entries[index])
					try synchronizeDirectory(entries[index].parentDescriptor)
				} catch {
					let publishError = error
					do {
						try recoverPublishedMismatch(&entries[index])
					} catch {
						throw WriterRecoveryFailure()
					}
					throw publishError
				}
				committedCount += 1
			}
		} catch {
			let commitRecoveryFailed = error is WriterRecoveryFailure
			do {
				try rollback(&entries, committedCount: committedCount)
				if commitRecoveryFailed {
					closeDescriptors(entries)
					throw DesktopProEditApplyError(
						.rollbackFailed,
						message: "Pro Edit could not safely reverse a concurrent commit; controlled recovery files were retained."
					)
				}
				cleanup(entries)
				closeDescriptors(entries)
			} catch {
				if let applyError = error as? DesktopProEditApplyError,
					applyError.code == .rollbackFailed
				{
					throw applyError
				}
				closeDescriptors(entries)
				throw DesktopProEditApplyError(
					.rollbackFailed,
					message: "Pro Edit stopped rather than overwrite a concurrently changed target; controlled recovery files were retained."
				)
			}
			throw normalized(error)
		}

		cleanup(entries)
		closeDescriptors(entries)
		return DesktopProEditApplySummary(
			transactionID: transactionID,
			appliedPaths: entries.map(\.validated.plan.displayPath)
		)
	}

	private func publishDelegateEdit(_ entry: inout StagedEntry, index: Int) throws {
		guard let proposed = entry.privateOwnership[entry.temporaryName] else {
			throw DesktopProEditApplyError(.writeFailed, message: "Missing proposed Pro Edit staging identity.")
		}
		try exchange(
			parentDescriptor: entry.parentDescriptor,
			entry.temporaryName,
			entry.destinationName
		)
		entry.privateOwnership.removeValue(forKey: entry.temporaryName)
		entry.publishedSnapshot = proposed
		do {
			let published = try snapshot(
				parentDescriptor: entry.parentDescriptor,
				name: entry.destinationName,
				displayPath: entry.validated.plan.displayPath
			)
			let staged = try snapshot(
				descriptor: entry.temporaryDescriptor,
				displayPath: entry.validated.plan.displayPath
			)
			let displaced = try snapshot(
				parentDescriptor: entry.parentDescriptor,
				name: entry.temporaryName,
				displayPath: entry.validated.plan.displayPath
			)
			guard let expected = entry.validated.plan.expected,
				snapshotsMatch(published, proposed),
				snapshotsMatch(staged, proposed),
				snapshotsMatch(displaced, expected)
			else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: entry.validated.plan.displayPath,
					message: "Pro Edit staging or target identity changed during commit."
				)
			}
			entry.privateOwnership[entry.temporaryName] = displaced
		} catch {
			do {
				try eventHook?(.beforeCorrectiveMutation(index: index, path: entry.validated.plan.displayPath))
				try recoverPublishedMismatch(&entry)
			} catch {
				throw WriterRecoveryFailure()
			}
			throw error
		}
	}

	private func publishCreate(_ entry: inout StagedEntry) throws {
		guard let proposed = entry.privateOwnership[entry.temporaryName] else {
			throw DesktopProEditApplyError(.writeFailed, message: "Missing proposed Pro Edit staging identity.")
		}
		let result = renameNoReplace(
			parentDescriptor: entry.parentDescriptor,
			entry.temporaryName,
			entry.destinationName
		)
		guard result == 0 else {
			throw DesktopProEditApplyError(
				errno == EEXIST ? .createCollision : .writeFailed,
				path: entry.validated.plan.displayPath,
				message: errno == EEXIST
					? "Pro Edit create target appeared during commit."
					: "Could not publish a Pro Edit create target."
			)
		}
		entry.privateOwnership.removeValue(forKey: entry.temporaryName)
		entry.publishedSnapshot = proposed
		do {
			let published = try snapshot(
				parentDescriptor: entry.parentDescriptor,
				name: entry.destinationName,
				displayPath: entry.validated.plan.displayPath
			)
			let staged = try snapshot(
				descriptor: entry.temporaryDescriptor,
				displayPath: entry.validated.plan.displayPath
			)
			guard snapshotsMatch(published, proposed), snapshotsMatch(staged, proposed) else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: entry.validated.plan.displayPath,
					message: "Pro Edit create staging identity changed during commit."
				)
			}
		} catch {
			do {
				try recoverPublishedMismatch(&entry)
			} catch {
				throw WriterRecoveryFailure()
			}
			throw error
		}
	}

	private func recoverPublishedMismatch(_ entry: inout StagedEntry) throws {
		let publishedRecoveryName = uniqueRecoveryName()
		let expectedPublished = entry.publishedSnapshot
		guard renameNoReplace(
			parentDescriptor: entry.parentDescriptor,
			entry.destinationName,
			publishedRecoveryName
		) == 0 else {
			throw WriterRecoveryFailure()
		}

		switch entry.validated.plan.action {
		case .create:
			break
		case .delegateEdit:
			try restoreDelegateSource(&entry)
		}
		entry.publishedSnapshot = nil
		if let moved = try? snapshot(
			parentDescriptor: entry.parentDescriptor,
			name: publishedRecoveryName,
			displayPath: entry.validated.plan.displayPath
		), let published = expectedPublished,
			snapshotsMatch(moved, published)
		{
			entry.privateOwnership[publishedRecoveryName] = moved
		}
	}

	private func restoreDelegateSource(_ entry: inout StagedEntry) throws {
		guard let expected = entry.validated.plan.expected else {
			throw WriterRecoveryFailure()
		}
		let restoredIdentity: DesktopProEditFileSnapshot
		if let displaced = try? snapshot(
			parentDescriptor: entry.parentDescriptor,
			name: entry.temporaryName,
			displayPath: entry.validated.plan.displayPath
		), snapshotsMatch(displaced, expected) {
			guard renameNoReplace(
				parentDescriptor: entry.parentDescriptor,
				entry.temporaryName,
				entry.destinationName
			) == 0 else {
				throw WriterRecoveryFailure()
			}
			entry.privateOwnership.removeValue(forKey: entry.temporaryName)
			restoredIdentity = expected
		} else {
			let displacedRecoveryName = uniqueRecoveryName()
			guard renameNoReplace(
				parentDescriptor: entry.parentDescriptor,
				entry.temporaryName,
				displacedRecoveryName
			) == 0 else {
				throw WriterRecoveryFailure()
			}
			if let displaced = try? snapshot(
				parentDescriptor: entry.parentDescriptor,
				name: displacedRecoveryName,
				displayPath: entry.validated.plan.displayPath
			), snapshotsMatch(displaced, expected) {
				entry.privateOwnership[displacedRecoveryName] = displaced
			}
			restoredIdentity = try restoreDelegateBackup(&entry, expected: expected)
		}

		let restored = try snapshot(
			parentDescriptor: entry.parentDescriptor,
			name: entry.destinationName,
			displayPath: entry.validated.plan.displayPath
		)
		guard snapshotsMatch(restored, restoredIdentity),
			sourceContentsMatch(restored, expected)
		else {
			let recoveryName = uniqueRecoveryName()
			_ = renameNoReplace(
				parentDescriptor: entry.parentDescriptor,
				entry.destinationName,
				recoveryName
			)
			throw WriterRecoveryFailure()
		}
	}

	private func restoreDelegateBackup(
		_ entry: inout StagedEntry,
		expected: DesktopProEditFileSnapshot
	) throws -> DesktopProEditFileSnapshot {
		guard let backupName = entry.backupName,
			let backupDescriptor = entry.backupDescriptor,
			let namedBackup = try? snapshot(
				parentDescriptor: entry.parentDescriptor,
				name: backupName,
				displayPath: entry.validated.plan.displayPath
			),
			let stagedBackup = try? snapshot(
				descriptor: backupDescriptor,
				displayPath: entry.validated.plan.displayPath
			),
			snapshotsMatch(namedBackup, stagedBackup),
			sourceContentsMatch(stagedBackup, expected),
			renameNoReplace(
				parentDescriptor: entry.parentDescriptor,
				backupName,
				entry.destinationName
			) == 0
		else {
			throw WriterRecoveryFailure()
		}
		entry.privateOwnership.removeValue(forKey: backupName)
		return stagedBackup
	}

	private func rollback(_ entries: inout [StagedEntry], committedCount: Int) throws {
		guard committedCount > 0 else { return }
		for index in (0..<committedCount).reversed() {
			try eventHook?(.beforeRollback(index: index, path: entries[index].validated.plan.displayPath))
			try validateBindings(entries[index])
			try verifyPublished(entries[index])
			try eventHook?(.beforeRollbackMutation(index: index, path: entries[index].validated.plan.displayPath))
			try rollbackEntry(&entries[index])
			try synchronizeDirectory(entries[index].parentDescriptor)
		}
	}

	private func rollbackEntry(_ entry: inout StagedEntry) throws {
		let recoveryName = uniqueRecoveryName()
		guard renameNoReplace(
			parentDescriptor: entry.parentDescriptor,
			entry.destinationName,
			recoveryName
		) == 0 else {
			throw WriterRecoveryFailure()
		}
		let moved = try snapshot(
			parentDescriptor: entry.parentDescriptor,
			name: recoveryName,
			displayPath: entry.validated.plan.displayPath
		)
		guard let published = entry.publishedSnapshot, snapshotsMatch(moved, published) else {
			_ = renameNoReplace(
				parentDescriptor: entry.parentDescriptor,
				recoveryName,
				entry.destinationName
			)
			throw WriterRecoveryFailure()
		}
		entry.privateOwnership[recoveryName] = moved

		switch entry.validated.plan.action {
		case .create:
			break
		case .delegateEdit:
			guard let expected = entry.validated.plan.expected,
				let original = entry.privateOwnership[entry.temporaryName],
				snapshotsMatch(original, expected),
				renameNoReplace(
					parentDescriptor: entry.parentDescriptor,
					entry.temporaryName,
					entry.destinationName
				) == 0
			else {
				throw WriterRecoveryFailure()
			}
			entry.privateOwnership.removeValue(forKey: entry.temporaryName)
			let restored = try snapshot(
				parentDescriptor: entry.parentDescriptor,
				name: entry.destinationName,
				displayPath: entry.validated.plan.displayPath
			)
			guard snapshotsMatch(restored, expected) else {
				throw WriterRecoveryFailure()
			}
		}
		entry.publishedSnapshot = nil
	}

	private func openParent(_ item: DesktopProEditValidatedPlan) throws -> (root: Int32, parent: Int32) {
		let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
		let root = item.rootPath.withCString { open($0, flags) }
		guard root >= 0 else {
			throw DesktopProEditApplyError(
				.unsafePath,
				path: item.plan.displayPath,
				message: "Could not open the exact Pro Edit workspace root."
			)
		}
		do {
			let parent = try walkParent(
				rootDescriptor: root,
				components: item.parentComponents,
				displayPath: item.plan.displayPath
			)
			return (root, parent)
		} catch {
			_ = close(root)
			throw error
		}
	}

	private func walkParent(
		rootDescriptor: Int32,
		components: [String],
		displayPath: String
	) throws -> Int32 {
		var current = dup(rootDescriptor)
		guard current >= 0 else {
			throw DesktopProEditApplyError(.unsafePath, path: displayPath, message: "Could not retain the workspace root.")
		}
		for component in components {
			let next = component.withCString {
				openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			}
			_ = close(current)
			guard next >= 0 else {
				throw DesktopProEditApplyError(
					.unsafePath,
					path: displayPath,
					message: "A Pro Edit target parent changed or became a symbolic link."
				)
			}
			current = next
		}
		return current
	}

	private func validateBindings(_ entry: StagedEntry) throws {
		try validateBindings(
			rootPath: entry.validated.rootPath,
				rootDescriptor: entry.rootDescriptor,
				parentComponents: entry.validated.parentComponents,
				parentDescriptor: entry.parentDescriptor,
				expectedRootIdentity: entry.validated.rootIdentity,
				expectedParentIdentity: entry.validated.parentIdentity,
				displayPath: entry.validated.plan.displayPath
		)
	}

	private func validateBindings(
		rootPath: String,
		rootDescriptor: Int32,
		parentComponents: [String],
		parentDescriptor: Int32,
		expectedRootIdentity: DesktopProEditDirectoryIdentity,
		expectedParentIdentity: DesktopProEditDirectoryIdentity,
		displayPath: String
	) throws {
		let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
		let currentRoot = rootPath.withCString { open($0, flags) }
		guard currentRoot >= 0 else {
			throw DesktopProEditApplyError(.sourceChanged, path: displayPath, message: "Workspace root changed.")
		}
		defer { _ = close(currentRoot) }
		guard try sameIdentity(rootDescriptor, currentRoot) else {
			throw DesktopProEditApplyError(.sourceChanged, path: displayPath, message: "Workspace root was replaced.")
		}
		let rootIdentity = try directoryIdentity(rootDescriptor)
		let currentParent = try walkParent(
			rootDescriptor: rootDescriptor,
			components: parentComponents,
			displayPath: displayPath
		)
		defer { _ = close(currentParent) }
		guard try sameIdentity(parentDescriptor, currentParent) else {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: displayPath,
				message: "Pro Edit target parent was concurrently replaced."
			)
		}
		let parentIdentity = try directoryIdentity(parentDescriptor)
		guard rootIdentity == expectedRootIdentity,
			parentIdentity == expectedParentIdentity
		else {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: displayPath,
				message: "Reviewed Pro Edit directory identity changed before apply."
			)
		}
	}

	private func sameIdentity(_ lhs: Int32, _ rhs: Int32) throws -> Bool {
		var left = stat()
		var right = stat()
		guard fstat(lhs, &left) == 0, fstat(rhs, &right) == 0 else {
			throw DesktopProEditApplyError(.sourceChanged, message: "Could not verify Pro Edit directory identity.")
		}
		return left.st_dev == right.st_dev && left.st_ino == right.st_ino
	}

	private func directoryIdentity(_ descriptor: Int32) throws -> DesktopProEditDirectoryIdentity {
		var info = stat()
		guard fstat(descriptor, &info) == 0,
			(info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
		else {
			throw DesktopProEditApplyError(.sourceChanged, message: "Could not verify Pro Edit directory identity.")
		}
		return DesktopProEditDirectoryIdentity(
			fileSystemNumber: UInt64(info.st_dev),
			fileSystemFileNumber: UInt64(info.st_ino)
		)
	}

	private func revalidate(_ entry: StagedEntry) throws {
		try validateBindings(entry)
		switch entry.validated.plan.action {
		case .create:
			var info = stat()
			let result = entry.destinationName.withCString {
				fstatat(entry.parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
			}
			guard result != 0, errno == ENOENT else {
				throw DesktopProEditApplyError(
					.createCollision,
					path: entry.validated.plan.displayPath,
					message: "Pro Edit create target appeared before commit."
				)
			}
		case .delegateEdit:
			guard let expected = entry.validated.plan.expected else {
				throw DesktopProEditApplyError(
					.invalidProposal,
					path: entry.validated.plan.displayPath,
					message: "Delegate-edit proposal omitted its exact source snapshot."
				)
			}
			let current = try snapshot(
				parentDescriptor: entry.parentDescriptor,
				name: entry.destinationName,
				displayPath: entry.validated.plan.displayPath
			)
			guard snapshotsMatch(current, expected) else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: entry.validated.plan.displayPath,
					message: "Pro Edit target changed before commit."
				)
			}
		}
	}

	private func writeStagedFile(
		parentDescriptor: Int32,
		name: String,
		bytes: Data,
		permissions: Int,
		displayPath: String,
		index: Int
	) throws -> StagedFile {
		let descriptor = name.withCString {
			openat(parentDescriptor, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
		}
		guard descriptor >= 0 else {
			throw DesktopProEditApplyError(.writeFailed, message: "Could not create a Pro Edit staging file.")
		}
		var retainDescriptor = false
		defer {
			if !retainDescriptor {
				_ = close(descriptor)
			}
		}
		var owned = try snapshot(descriptor: descriptor, displayPath: displayPath)
		do {
			try eventHook?(.afterStagingFileCreated(index: index, path: displayPath, name: name))
			try bytes.withUnsafeBytes { rawBuffer in
				var offset = 0
				while offset < rawBuffer.count {
					let result = posixWrite(
						descriptor,
						rawBuffer.baseAddress!.advanced(by: offset),
						rawBuffer.count - offset
					)
					guard result > 0 else {
						throw DesktopProEditApplyError(.writeFailed, message: "Could not write a Pro Edit staging file.")
					}
					offset += result
				}
			}
			guard fchmod(descriptor, mode_t(permissions)) == 0, fsync(descriptor) == 0 else {
				throw DesktopProEditApplyError(.writeFailed, message: "Could not synchronize a Pro Edit staging file.")
			}
			owned = try snapshot(descriptor: descriptor, displayPath: displayPath)
			retainDescriptor = true
			return StagedFile(descriptor: descriptor, snapshot: owned)
		} catch {
			if let currentOwned = try? snapshot(descriptor: descriptor, displayPath: displayPath) {
				owned = currentOwned
			}
			quarantineOwned(
				name: name,
				expected: owned,
				parentDescriptor: parentDescriptor,
				displayPath: displayPath
			)
			throw normalized(error)
		}
	}

	private func verifyPublished(_ entry: StagedEntry) throws {
		guard let expected = entry.publishedSnapshot else {
			throw DesktopProEditApplyError(.writeFailed, message: "Missing published Pro Edit snapshot.")
		}
		let current = try snapshot(
			parentDescriptor: entry.parentDescriptor,
			name: entry.destinationName,
			displayPath: entry.validated.plan.displayPath
		)
		guard snapshotsMatch(current, expected) else {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: entry.validated.plan.displayPath,
				message: "Published Pro Edit target was concurrently changed."
			)
		}
	}

	private func snapshot(
		parentDescriptor: Int32,
		name: String,
		displayPath: String
	) throws -> DesktopProEditFileSnapshot {
		var pathInfo = stat()
		let metadataResult = name.withCString {
			fstatat(parentDescriptor, $0, &pathInfo, AT_SYMLINK_NOFOLLOW)
		}
		guard metadataResult == 0,
			(pathInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
		else {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: displayPath,
				message: "Pro Edit target is no longer a regular file."
			)
		}
		let descriptor = name.withCString {
			openat(parentDescriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
		}
		guard descriptor >= 0 else {
			throw DesktopProEditApplyError(.sourceChanged, path: displayPath, message: "Could not open the exact Pro Edit target.")
		}
		defer { _ = close(descriptor) }
		return try snapshot(descriptor: descriptor, displayPath: displayPath)
	}

	private func snapshot(descriptor: Int32, displayPath: String) throws -> DesktopProEditFileSnapshot {
		var info = stat()
		guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
			throw DesktopProEditApplyError(.sourceChanged, path: displayPath, message: "Pro Edit target is no longer a regular file.")
		}
		let bytes = try readAll(descriptor, maximumBytes: DesktopProEditPathGuard.maximumContentBytes)
		let modificationDate: Date
		#if os(Linux)
		modificationDate = Date(
			timeIntervalSince1970: TimeInterval(info.st_mtim.tv_sec)
				+ TimeInterval(info.st_mtim.tv_nsec) / 1_000_000_000
		)
		#else
		modificationDate = Date(
			timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
				+ TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
		)
		#endif
		return DesktopProEditFileSnapshot(
			bytes: bytes,
			posixPermissions: Int(info.st_mode & 0o7777),
			fileSystemNumber: UInt64(info.st_dev),
			fileSystemFileNumber: UInt64(info.st_ino),
			fileSize: UInt64(info.st_size),
			modificationDate: modificationDate
		)
	}

	private func snapshotsMatch(
		_ lhs: DesktopProEditFileSnapshot,
		_ rhs: DesktopProEditFileSnapshot
	) -> Bool {
		lhs.bytes == rhs.bytes
			&& lhs.posixPermissions == rhs.posixPermissions
			&& lhs.fileSystemNumber == rhs.fileSystemNumber
			&& lhs.fileSystemFileNumber == rhs.fileSystemFileNumber
			&& lhs.fileSize == rhs.fileSize
	}

	private func sourceContentsMatch(
		_ lhs: DesktopProEditFileSnapshot,
		_ rhs: DesktopProEditFileSnapshot
	) -> Bool {
		lhs.bytes == rhs.bytes
			&& lhs.posixPermissions == rhs.posixPermissions
			&& lhs.fileSize == rhs.fileSize
	}

	private func readAll(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
		guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
			throw DesktopProEditApplyError(.sourceChanged, message: "Could not seek a Pro Edit target.")
		}
		var output = Data()
		var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
		while true {
			let count = buffer.withUnsafeMutableBytes {
				posixRead(descriptor, $0.baseAddress!, $0.count)
			}
			guard count >= 0 else {
				throw DesktopProEditApplyError(.sourceChanged, message: "Could not read a Pro Edit target.")
			}
			if count == 0 { break }
			guard output.count + count <= maximumBytes else {
				throw DesktopProEditApplyError(.sourceChanged, message: "Pro Edit target became oversized.")
			}
			output.append(contentsOf: buffer.prefix(count))
		}
		return output
	}

	private func exchange(parentDescriptor: Int32, _ lhs: String, _ rhs: String) throws {
		let result = lhs.withCString { lhsPointer in
			rhs.withCString { rhsPointer in
				#if os(Linux)
				linuxRenameAt2(parentDescriptor, lhsPointer, parentDescriptor, rhsPointer, 2)
				#else
				renameatx_np(parentDescriptor, lhsPointer, parentDescriptor, rhsPointer, UInt32(RENAME_SWAP))
				#endif
			}
		}
		guard result == 0 else {
			throw DesktopProEditApplyError(.writeFailed, message: "Could not atomically exchange a Pro Edit target.")
		}
	}

	private func renameNoReplace(parentDescriptor: Int32, _ source: String, _ destination: String) -> Int32 {
		source.withCString { sourcePointer in
			destination.withCString { destinationPointer in
				#if os(Linux)
				linuxRenameAt2(parentDescriptor, sourcePointer, parentDescriptor, destinationPointer, 1)
				#else
				renameatx_np(parentDescriptor, sourcePointer, parentDescriptor, destinationPointer, UInt32(RENAME_EXCL))
				#endif
			}
		}
	}

	private func uniqueRecoveryName() -> String {
		".repoprompt-pro-edit-\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).recovery"
	}

	private func synchronizeDirectory(_ descriptor: Int32) throws {
		guard fsync(descriptor) == 0 else {
			throw DesktopProEditApplyError(.writeFailed, message: "Could not synchronize a Pro Edit parent directory.")
		}
	}

	private func cleanup(_ entries: [StagedEntry]) {
		for entry in entries {
			cleanupOwned(
				entry.privateOwnership,
				parentDescriptor: entry.parentDescriptor,
				displayPath: entry.validated.plan.displayPath
			)
		}
	}

	private func cleanupOwned(
		_ owned: [String: DesktopProEditFileSnapshot],
		parentDescriptor: Int32,
		displayPath: String? = nil
	) {
		for (name, expected) in owned {
			if let displayPath {
				try? eventHook?(.beforeOwnedCleanup(path: displayPath, name: name))
			}
			quarantineOwned(
				name: name,
				expected: expected,
				parentDescriptor: parentDescriptor,
				displayPath: displayPath
			)
		}
	}

	private func quarantineOwned(
		name: String,
		expected: DesktopProEditFileSnapshot,
		parentDescriptor: Int32,
		displayPath: String? = nil
	) {
		let quarantineName = uniqueQuarantineName()
		guard renameNoReplace(
			parentDescriptor: parentDescriptor,
			name,
			quarantineName
		) == 0 else {
			return
		}
		guard let quarantined = try? snapshot(
			parentDescriptor: parentDescriptor,
			name: quarantineName,
			displayPath: name
		), snapshotsMatch(quarantined, expected)
		else {
			_ = renameNoReplace(
				parentDescriptor: parentDescriptor,
				quarantineName,
				name
			)
			return
		}
		if let displayPath {
			try? eventHook?(.afterQuarantineVerification(
				path: displayPath,
				name: name,
				quarantineName: quarantineName
			))
		}
	}

	private func uniqueQuarantineName() -> String {
		".repoprompt-pro-edit-\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).quarantine"
	}

	private func closeDescriptors(_ entries: [StagedEntry]) {
		for entry in entries {
			_ = close(entry.temporaryDescriptor)
			if let backupDescriptor = entry.backupDescriptor {
				_ = close(backupDescriptor)
			}
			_ = close(entry.parentDescriptor)
			_ = close(entry.rootDescriptor)
		}
	}

	private func normalized(_ error: Error) -> DesktopProEditApplyError {
		if let error = error as? DesktopProEditApplyError { return error }
		if error is CancellationError {
			return DesktopProEditApplyError(.writeFailed, message: "Pro Edit apply was cancelled before commit.")
		}
		return DesktopProEditApplyError(.writeFailed, message: "Pro Edit apply failed.")
	}

	private func posixWrite(
		_ descriptor: Int32,
		_ buffer: UnsafeRawPointer,
		_ count: Int
	) -> Int {
		#if canImport(Darwin)
		return Darwin.write(descriptor, buffer, count)
		#else
		return Glibc.write(descriptor, buffer, count)
		#endif
	}

	private func posixRead(
		_ descriptor: Int32,
		_ buffer: UnsafeMutableRawPointer,
		_ count: Int
	) -> Int {
		#if canImport(Darwin)
		return Darwin.read(descriptor, buffer, count)
		#else
		return Glibc.read(descriptor, buffer, count)
		#endif
	}
}

private struct StagedEntry: Sendable {
	let validated: DesktopProEditValidatedPlan
	let rootDescriptor: Int32
	let parentDescriptor: Int32
	let destinationName: String
	let temporaryName: String
	let temporaryDescriptor: Int32
	let backupName: String?
	let backupDescriptor: Int32?
	var publishedSnapshot: DesktopProEditFileSnapshot?
	var privateOwnership: [String: DesktopProEditFileSnapshot]
}

private struct StagedFile: Sendable {
	let descriptor: Int32
	let snapshot: DesktopProEditFileSnapshot
}

private struct WriterRecoveryFailure: Error {}
