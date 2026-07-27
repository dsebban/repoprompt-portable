import Foundation
import RepoPromptHeadless

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct DesktopProEditFileSnapshot: Equatable, Sendable {
	public let bytes: Data
	public let posixPermissions: Int
	public let fileSystemNumber: UInt64
	public let fileSystemFileNumber: UInt64
	public let fileSize: UInt64
	public let modificationDate: Date

	init(
		bytes: Data,
		posixPermissions: Int,
		fileSystemNumber: UInt64,
		fileSystemFileNumber: UInt64,
		fileSize: UInt64,
		modificationDate: Date
	) {
		self.bytes = bytes
		self.posixPermissions = posixPermissions
		self.fileSystemNumber = fileSystemNumber
		self.fileSystemFileNumber = fileSystemFileNumber
		self.fileSize = fileSize
		self.modificationDate = modificationDate
	}
}

struct DesktopProEditDirectoryIdentity: Equatable, Sendable {
	let fileSystemNumber: UInt64
	let fileSystemFileNumber: UInt64
}

struct DesktopProEditWritePlan: Equatable, Sendable {
	let rootIndex: Int
	let relativePath: String
	let absolutePath: String
	let displayPath: String
	let action: PortableProEditAction
	let expected: DesktopProEditFileSnapshot?
	let proposedBytes: Data
	let reviewedRootIdentity: DesktopProEditDirectoryIdentity?
	let reviewedParentIdentity: DesktopProEditDirectoryIdentity?

	init(
		rootIndex: Int,
		relativePath: String,
		absolutePath: String,
		displayPath: String,
		action: PortableProEditAction,
		expected: DesktopProEditFileSnapshot?,
		proposedBytes: Data,
		reviewedRootIdentity: DesktopProEditDirectoryIdentity? = nil,
		reviewedParentIdentity: DesktopProEditDirectoryIdentity? = nil
	) {
		self.rootIndex = rootIndex
		self.relativePath = relativePath
		self.absolutePath = absolutePath
		self.displayPath = displayPath
		self.action = action
		self.expected = expected
		self.proposedBytes = proposedBytes
		self.reviewedRootIdentity = reviewedRootIdentity
		self.reviewedParentIdentity = reviewedParentIdentity
	}
}

struct DesktopProEditValidatedPlan: Equatable, Sendable {
	let plan: DesktopProEditWritePlan
	let rootPath: String
	let parentPath: String
	let parentComponents: [String]
	let rootIdentity: DesktopProEditDirectoryIdentity
	let parentIdentity: DesktopProEditDirectoryIdentity
}

struct DesktopProEditPathGuard: Sendable {
	static let maximumContentBytes = PortableProEditArtifactParser.maximumFileContentBytes

	private let roots: [String]
	private let fileManager: FileManager

	init(roots: [String], fileManager: FileManager = .default) {
		self.roots = roots.map {
			URL(fileURLWithPath: $0, isDirectory: true)
				.resolvingSymlinksInPath()
				.standardizedFileURL.path
		}
		self.fileManager = fileManager
	}

	func validateAll(_ plans: [DesktopProEditWritePlan]) throws -> [DesktopProEditValidatedPlan] {
		guard !plans.isEmpty else {
			throw DesktopProEditApplyError(.noChanges, message: "Pro Edit preview has no changed files to apply.")
		}

		let ordered = plans.sorted {
			($0.rootIndex, $0.relativePath) < ($1.rootIndex, $1.relativePath)
		}
		for firstIndex in ordered.indices {
			for secondIndex in ordered.index(after: firstIndex) ..< ordered.endIndex {
				let first = ordered[firstIndex]
				let second = ordered[secondIndex]
				if first.absolutePath == second.absolutePath {
					throw DesktopProEditApplyError(
						.duplicateTarget,
						path: second.displayPath,
						message: "Pro Edit apply contains a duplicate target: \(second.displayPath)"
					)
				}
				if pathsOverlap(first.absolutePath, second.absolutePath) {
					throw DesktopProEditApplyError(
						.overlappingTarget,
						path: second.displayPath,
						message: "Pro Edit apply targets overlap: \(first.displayPath) and \(second.displayPath)"
					)
				}
			}
		}
		return try ordered.map(validate)
	}

	func bindDirectoryIdentities(_ plans: [DesktopProEditWritePlan]) throws -> [DesktopProEditWritePlan] {
		try validateAll(plans).map { validated in
			DesktopProEditWritePlan(
				rootIndex: validated.plan.rootIndex,
				relativePath: validated.plan.relativePath,
				absolutePath: validated.plan.absolutePath,
				displayPath: validated.plan.displayPath,
				action: validated.plan.action,
				expected: validated.plan.expected,
				proposedBytes: validated.plan.proposedBytes,
				reviewedRootIdentity: validated.rootIdentity,
				reviewedParentIdentity: validated.parentIdentity
			)
		}
	}

	func snapshot(_ target: PortableProEditResolvedTarget) throws -> DesktopProEditFileSnapshot? {
		let provisional = DesktopProEditWritePlan(
			rootIndex: target.rootIndex,
			relativePath: target.relativePath,
			absolutePath: target.absolutePath,
			displayPath: target.displayPath,
			action: target.file.action,
			expected: nil,
			proposedBytes: Data(),
			reviewedRootIdentity: nil,
			reviewedParentIdentity: nil
		)
		let validated = try validate(provisional)
		switch target.file.action {
		case .create:
			return nil
		case .delegateEdit:
			return try currentSnapshot(validated)
		}
	}

	func revalidate(_ validated: DesktopProEditValidatedPlan) throws {
		_ = try validate(validated.plan)
		switch validated.plan.action {
		case .create:
			break
		case .delegateEdit:
			guard let expected = validated.plan.expected else {
				throw DesktopProEditApplyError(
					.invalidProposal,
					path: validated.plan.displayPath,
					message: "Delegate-edit proposal is missing its materialized source snapshot."
				)
			}
			let current = try currentSnapshot(validated)
			guard current == expected else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: validated.plan.displayPath,
					message: "Pro Edit target changed after materialization: \(validated.plan.displayPath)"
				)
			}
		}
	}

	private func validate(_ plan: DesktopProEditWritePlan) throws -> DesktopProEditValidatedPlan {
		guard roots.indices.contains(plan.rootIndex) else {
			throw DesktopProEditApplyError(
				.outsideWorkspace,
				path: plan.displayPath,
				message: "Pro Edit target uses an unavailable workspace root."
			)
		}
		guard !plan.relativePath.isEmpty, !plan.relativePath.hasPrefix("/") else {
			throw unsafePath(plan, "Pro Edit targets must be root-relative.")
		}
		let components = plan.relativePath.split(separator: "/", omittingEmptySubsequences: false)
		guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
			throw unsafePath(plan, "Pro Edit targets must not contain empty, dot, or parent components.")
		}
		guard !components.contains(where: { [".git", ".build", "node_modules"].contains(String($0)) }) else {
			throw unsafePath(plan, "Pro Edit targets must not enter protected workspace directories.")
		}
		guard plan.proposedBytes.count <= Self.maximumContentBytes,
			!plan.proposedBytes.contains(0)
		else {
			throw DesktopProEditApplyError(
				.invalidProposal,
				path: plan.displayPath,
				message: "Pro Edit proposed content is oversized or contains NUL."
			)
		}

		let root = roots[plan.rootIndex]
		let rootIdentity = try directoryIdentity(at: root, displayPath: plan.displayPath)
		if let reviewed = plan.reviewedRootIdentity, reviewed != rootIdentity {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: plan.displayPath,
				message: "Pro Edit workspace root changed after materialization."
			)
		}
		let lexicalPath = (root as NSString).appendingPathComponent(plan.relativePath)
		let standardizedPath = URL(fileURLWithPath: lexicalPath).standardizedFileURL.path
		guard contains(standardizedPath, root: root), standardizedPath == plan.absolutePath else {
			throw DesktopProEditApplyError(
				.outsideWorkspace,
				path: plan.displayPath,
				message: "Pro Edit target identity no longer matches the loaded workspace."
			)
		}

		var current = root
		for component in components.dropLast() {
			current = (current as NSString).appendingPathComponent(String(component))
			let attributes = try attributes(at: current, displayPath: plan.displayPath)
			guard attributes[.type] as? FileAttributeType == .typeDirectory else {
				throw unsafePath(plan, "A Pro Edit target parent is not a real directory.")
			}
			guard !isSymbolicLink(attributes) else {
				throw unsafePath(plan, "A Pro Edit target parent is a symbolic link.")
			}
		}
		let parentPath = (standardizedPath as NSString).deletingLastPathComponent
		let resolvedParent = URL(fileURLWithPath: parentPath, isDirectory: true)
			.resolvingSymlinksInPath()
			.standardizedFileURL.path
		guard contains(resolvedParent, root: root), resolvedParent == parentPath else {
			throw unsafePath(plan, "A Pro Edit target parent resolves outside the loaded workspace.")
		}
		let parentIdentity = try directoryIdentity(at: parentPath, displayPath: plan.displayPath)
		if let reviewed = plan.reviewedParentIdentity, reviewed != parentIdentity {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: plan.displayPath,
				message: "Pro Edit target parent changed after materialization."
			)
		}

		var isDirectory = ObjCBool(false)
		let exists = fileManager.fileExists(atPath: standardizedPath, isDirectory: &isDirectory)
		switch plan.action {
		case .create:
			guard !exists else {
				throw DesktopProEditApplyError(
					.createCollision,
					path: plan.displayPath,
					message: "Pro Edit create target now exists: \(plan.displayPath)"
				)
			}
		case .delegateEdit:
			guard exists else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: plan.displayPath,
					message: "Pro Edit delegate-edit target no longer exists: \(plan.displayPath)"
				)
			}
			guard !isDirectory.boolValue else {
				throw DesktopProEditApplyError(
					.targetIsDirectory,
					path: plan.displayPath,
					message: "Pro Edit target is a directory: \(plan.displayPath)"
				)
			}
			let attributes = try attributes(at: standardizedPath, displayPath: plan.displayPath)
			guard !isSymbolicLink(attributes),
				attributes[.type] as? FileAttributeType == .typeRegular
			else {
				throw unsafePath(plan, "Pro Edit delegate-edit targets must be regular non-symlink files.")
			}
			let canonical = URL(fileURLWithPath: standardizedPath)
				.resolvingSymlinksInPath()
				.standardizedFileURL.path
			guard canonical == standardizedPath else {
				throw unsafePath(plan, "Pro Edit delegate-edit target resolves through a symbolic link.")
			}
		}
		return DesktopProEditValidatedPlan(
			plan: plan,
			rootPath: root,
			parentPath: parentPath,
			parentComponents: components.dropLast().map(String.init),
			rootIdentity: rootIdentity,
			parentIdentity: parentIdentity
		)
	}

	private func directoryIdentity(
		at path: String,
		displayPath: String
	) throws -> DesktopProEditDirectoryIdentity {
		let attributes = try attributes(at: path, displayPath: displayPath)
		guard attributes[.type] as? FileAttributeType == .typeDirectory else {
			throw DesktopProEditApplyError(
				.unsafePath,
				path: displayPath,
				message: "A reviewed Pro Edit directory is no longer a directory."
			)
		}
		return DesktopProEditDirectoryIdentity(
			fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
			fileSystemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
		)
	}

	private func currentSnapshot(_ validated: DesktopProEditValidatedPlan) throws -> DesktopProEditFileSnapshot {
		let displayPath = validated.plan.displayPath
		do {
			let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
			let rootDescriptor = validated.rootPath.withCString { open($0, flags) }
			guard rootDescriptor >= 0 else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Workspace root changed before Pro Edit snapshot."
				)
			}
			defer { _ = close(rootDescriptor) }
			guard try directoryIdentity(
				descriptor: rootDescriptor,
				displayPath: displayPath
			) == validated.rootIdentity else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Workspace root changed before Pro Edit snapshot."
				)
			}

			let parentDescriptor = try openParent(
				rootDescriptor: rootDescriptor,
				components: validated.parentComponents,
				displayPath: displayPath
			)
			defer { _ = close(parentDescriptor) }
			guard try directoryIdentity(
				descriptor: parentDescriptor,
				displayPath: displayPath
			) == validated.parentIdentity else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Pro Edit target parent changed before snapshot: \(displayPath)"
				)
			}

			let name = (validated.plan.relativePath as NSString).lastPathComponent
			let descriptor = name.withCString {
				openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
			}
			guard descriptor >= 0 else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Could not open the exact Pro Edit target: \(displayPath)"
				)
			}
			defer { _ = close(descriptor) }

			var before = stat()
			guard fstat(descriptor, &before) == 0,
				(before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
			else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Pro Edit target is no longer a regular file: \(displayPath)"
				)
			}
			guard before.st_size >= 0, UInt64(before.st_size) <= UInt64(Self.maximumContentBytes) else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Pro Edit target became too large after materialization: \(displayPath)"
				)
			}
			let data = try readAll(descriptor, maximumBytes: Self.maximumContentBytes, displayPath: displayPath)

			var after = stat()
			guard fstat(descriptor, &after) == 0, sameSnapshotMetadata(before, after) else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Pro Edit target changed while it was being read: \(displayPath)"
				)
			}
			return DesktopProEditFileSnapshot(
				bytes: data,
				posixPermissions: Int(before.st_mode & 0o7777),
				fileSystemNumber: UInt64(before.st_dev),
				fileSystemFileNumber: UInt64(before.st_ino),
				fileSize: UInt64(before.st_size),
				modificationDate: modificationDate(before)
			)
		} catch let error as DesktopProEditApplyError {
			throw error
		} catch {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: displayPath,
				message: "Could not re-read Pro Edit target: \(displayPath)"
			)
		}
	}

	private func directoryIdentity(
		descriptor: Int32,
		displayPath: String
	) throws -> DesktopProEditDirectoryIdentity {
		var info = stat()
		guard fstat(descriptor, &info) == 0,
			(info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
		else {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: displayPath,
				message: "Could not verify the exact Pro Edit directory."
			)
		}
		return DesktopProEditDirectoryIdentity(
			fileSystemNumber: UInt64(info.st_dev),
			fileSystemFileNumber: UInt64(info.st_ino)
		)
	}

	private func openParent(
		rootDescriptor: Int32,
		components: [String],
		displayPath: String
	) throws -> Int32 {
		var current = dup(rootDescriptor)
		guard current >= 0 else {
			throw DesktopProEditApplyError(
				.sourceChanged,
				path: displayPath,
				message: "Could not retain the Pro Edit workspace root."
			)
		}
		for component in components {
			let next = component.withCString {
				openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			}
			_ = close(current)
			guard next >= 0 else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "A Pro Edit target parent changed before snapshot: \(displayPath)"
				)
			}
			current = next
		}
		return current
	}

	private func readAll(
		_ descriptor: Int32,
		maximumBytes: Int,
		displayPath: String
	) throws -> Data {
		var output = Data()
		var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
		while true {
			let count = buffer.withUnsafeMutableBytes {
				posixRead(descriptor, $0.baseAddress!, $0.count)
			}
			if count < 0, errno == EINTR {
				continue
			}
			guard count >= 0 else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Could not read the exact Pro Edit target: \(displayPath)"
				)
			}
			if count == 0 { return output }
			guard count <= maximumBytes - output.count else {
				throw DesktopProEditApplyError(
					.sourceChanged,
					path: displayPath,
					message: "Pro Edit target became too large after materialization: \(displayPath)"
				)
			}
			output.append(contentsOf: buffer.prefix(count))
		}
	}

	private func sameSnapshotMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
		guard lhs.st_dev == rhs.st_dev,
			lhs.st_ino == rhs.st_ino,
			lhs.st_mode == rhs.st_mode,
			lhs.st_size == rhs.st_size
		else { return false }
		#if os(Linux)
		return lhs.st_mtim.tv_sec == rhs.st_mtim.tv_sec
			&& lhs.st_mtim.tv_nsec == rhs.st_mtim.tv_nsec
			&& lhs.st_ctim.tv_sec == rhs.st_ctim.tv_sec
			&& lhs.st_ctim.tv_nsec == rhs.st_ctim.tv_nsec
		#else
		return lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
			&& lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
			&& lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
			&& lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
		#endif
	}

	private func modificationDate(_ info: stat) -> Date {
		#if os(Linux)
		return Date(
			timeIntervalSince1970: TimeInterval(info.st_mtim.tv_sec)
				+ TimeInterval(info.st_mtim.tv_nsec) / 1_000_000_000
		)
		#else
		return Date(
			timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
				+ TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
		)
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

	private func attributes(at path: String, displayPath: String) throws -> [FileAttributeKey: Any] {
		do {
			return try fileManager.attributesOfItem(atPath: path)
		} catch {
			throw DesktopProEditApplyError(
				.unsafePath,
				path: displayPath,
				message: "Could not validate the Pro Edit target path: \(displayPath)"
			)
		}
	}

	private func isSymbolicLink(_ attributes: [FileAttributeKey: Any]) -> Bool {
		attributes[.type] as? FileAttributeType == .typeSymbolicLink
	}

	private func contains(_ path: String, root: String) -> Bool {
		path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
	}

	private func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
		lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
	}

	private func unsafePath(_ plan: DesktopProEditWritePlan, _ message: String) -> DesktopProEditApplyError {
		DesktopProEditApplyError(.unsafePath, path: plan.displayPath, message: message)
	}
}
