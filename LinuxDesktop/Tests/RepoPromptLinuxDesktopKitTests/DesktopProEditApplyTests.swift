import Foundation
import RepoPromptHeadless
import XCTest
@testable import RepoPromptLinuxDesktopKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class DesktopProEditApplyTests: XCTestCase {
	func testGenerateParsePreflightAndMaterializeDoNotWriteBeforeExplicitApply() async throws {
		let fixture = try await Fixture()
		defer { fixture.cleanup() }
		let created = fixture.root.appendingPathComponent("Created.swift")
		let before = try treeSnapshot(fixture.root)
		let artifact = try PortableProEditArtifactParser.parse(createArtifact(path: "Created.swift", content: "struct Created {}\n"))
		XCTAssertEqual(try treeSnapshot(fixture.root), before)
		let preflight = try await fixture.resolveChosen(artifact)
		XCTAssertEqual(try treeSnapshot(fixture.root), before)

		let session = try await fixture.proEditService.materialize(preflight)

		XCTAssertEqual(session.changedPaths, ["Created.swift"])
		var state = DesktopState()
		state.proEditSession = session
		XCTAssertTrue(state.proEditReviewIsComplete)
		XCTAssertTrue(state.canApplyProEdit)
		XCTAssertEqual(try treeSnapshot(fixture.root), before)
		XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))

		let summary = try await fixture.proEditService.apply(session.id)

		XCTAssertEqual(summary.appliedPaths, ["Created.swift"])
		XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "struct Created {}\n")
		XCTAssertTrue(try residue(in: fixture.root).isEmpty)
	}

	func testTruncatedMaterializationPreviewCannotBeAppliedFromDesktopState() async throws {
		let fixture = try await Fixture()
		defer { fixture.cleanup() }
		let content = String(repeating: "x", count: DesktopContextText.maximumCharacters + 1)
		let artifact = try PortableProEditArtifactParser.parse(
			createArtifact(path: "Large.swift", content: content)
		)
		let preflight = try await fixture.resolveChosen(artifact)
		let session = try await fixture.proEditService.materialize(preflight)
		var state = DesktopState()
		state.proEditSession = session

		XCTAssertFalse(state.proEditReviewIsComplete)
		XCTAssertFalse(state.canApplyProEdit)
		XCTAssertFalse(
			FileManager.default.fileExists(
				atPath: fixture.root.appendingPathComponent("Large.swift").path
			)
		)
	}

	func testCreateSessionRejectsReviewedParentIdentityReplacementBeforeApply() async throws {
		let fixture = try await Fixture()
		defer { fixture.cleanup() }
		let parent = fixture.root.appendingPathComponent("Sources", isDirectory: true)
		let detached = fixture.root.appendingPathComponent("ReviewedSources", isDirectory: true)
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
		let artifact = try PortableProEditArtifactParser.parse(
			createArtifact(path: "Sources/Created.swift", content: "created\n")
		)
		let preflight = try await fixture.resolveChosen(artifact)
		let session = try await fixture.proEditService.materialize(preflight)
		try FileManager.default.moveItem(at: parent, to: detached)
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

		do {
			_ = try await fixture.proEditService.apply(session.id)
			XCTFail("A create session must remain bound to its reviewed parent directory identity.")
		} catch let error as DesktopProEditApplyError {
			XCTAssertEqual(error.code, .sourceChanged)
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("Created.swift").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: detached.appendingPathComponent("Created.swift").path))
		XCTAssertTrue(try residue(in: parent).isEmpty)
		XCTAssertTrue(try residue(in: detached).isEmpty)
	}

	func testTruncatedDerivedDiffDoesNotBlockApplyWhenExactProposedPaneIsComplete() async throws {
		let fixture = try await Fixture()
		defer { fixture.cleanup() }
		let content = String(repeating: "x\n", count: 30_000)
		XCTAssertLessThan(content.count, DesktopContextText.maximumCharacters)
		let artifact = try PortableProEditArtifactParser.parse(
			createArtifact(path: "LargeDiff.swift", content: content)
		)
		let preflight = try await fixture.resolveChosen(artifact)
		let session = try await fixture.proEditService.materialize(preflight)
		let proposal = try XCTUnwrap(session.files.first)
		XCTAssertLessThan(try XCTUnwrap(proposal.proposedContent).count, DesktopContextText.maximumCharacters)
		XCTAssertGreaterThan(try XCTUnwrap(proposal.replacementDiff).count, DesktopContextText.maximumCharacters)
		var state = DesktopState()
		state.proEditSession = session

		XCTAssertTrue(DesktopContextText(try XCTUnwrap(proposal.replacementDiff)).truncated)
		XCTAssertTrue(state.proEditReviewIsComplete)
		XCTAssertTrue(state.canApplyProEdit)
		XCTAssertFalse(
			FileManager.default.fileExists(
				atPath: fixture.root.appendingPathComponent("LargeDiff.swift").path
			)
		)
		let summary = try await fixture.proEditService.apply(session.id)
		XCTAssertEqual(summary.appliedPaths, ["LargeDiff.swift"])
		XCTAssertEqual(
			try String(
				contentsOf: fixture.root.appendingPathComponent("LargeDiff.swift"),
				encoding: .utf8
			),
			content
		)
	}

	func testPartialMaterializationReturnsOrderedRowsWithoutApplyAuthority() async throws {
		let fixture = try await Fixture()
		defer { fixture.cleanup() }
		let artifact = try PortableProEditArtifactParser.parse("""
		<chatName="Partial preview"/>
		<Plan>Preview one valid and one ambiguous create.</Plan>
		<file path="Proposed.swift" action="create">
		<change><description>Create file</description><content>proposed
		</content><complexity>1</complexity></change>
		</file>
		<file path="Failed.swift" action="create">
		<change><description>First content</description><content>first
		</content><complexity>1</complexity></change>
		<change><description>Second content</description><content>second
		</content><complexity>1</complexity></change>
		</file>
		""")
		let preflight = try await fixture.resolveChosen(artifact)

		let session = try await fixture.proEditService.materialize(preflight)

		XCTAssertEqual(session.files.map(\.target.displayPath), ["Proposed.swift", "Failed.swift"])
		XCTAssertEqual(session.files[0].status, .proposed)
		XCTAssertEqual(
			session.files[1].status,
			.failed(
				code: "ambiguous_create_content",
				message: "Pro Edit create targets require exactly one complete-content change."
			)
		)
		XCTAssertTrue(session.changedPaths.isEmpty)
		do {
			_ = try await fixture.proEditService.apply(session.id)
			XCTFail("Partial previews must not mint apply authority.")
		} catch let error as DesktopProEditApplyError {
			XCTAssertEqual(error.code, .invalidSession)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Proposed.swift").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Failed.swift").path))
	}

	func testWriterAppliesMixedEditAndCreateByteExactlyAndPreservesModes() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let existing = root.appendingPathComponent("Existing.swift")
		let created = root.appendingPathComponent("Created.swift")
		let original = Data("struct Existing {}\n".utf8)
		try original.write(to: existing)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: existing.path)
		let plans = [
			plan(
				root: root,
				path: "Existing.swift",
				action: .delegateEdit,
				expected: try fileSnapshot(existing),
				content: Data("struct Existing { let changed = true }\n".utf8)
			),
			plan(
				root: root,
				path: "Created.swift",
				action: .create,
				expected: nil,
				content: Data("struct Created {}\n".utf8)
			)
		]

		let summary = try DesktopProEditWriter().write(plans, roots: [root.path])

		XCTAssertEqual(summary.appliedPaths, ["Created.swift", "Existing.swift"])
		XCTAssertEqual(try Data(contentsOf: existing), Data("struct Existing { let changed = true }\n".utf8))
		XCTAssertEqual(try Data(contentsOf: created), Data("struct Created {}\n".utf8))
		XCTAssertEqual(try permissions(existing), 0o600)
		XCTAssertEqual(try permissions(created), 0o644)
		XCTAssertTrue(try residue(in: root).isEmpty)
	}

	func testConcurrentSourceMutationFailsBeforeWorkspaceMutation() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let existing = root.appendingPathComponent("Existing.swift")
		let original = Data("original\n".utf8)
		try original.write(to: existing)
		let change = plan(
			root: root,
			path: "Existing.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(existing),
			content: Data("proposed\n".utf8)
		)
		try Data("concurrent mutation\n".utf8).write(to: existing)
		let before = try treeSnapshot(root)

		XCTAssertThrowsError(try DesktopProEditWriter().write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(try treeSnapshot(root), before)
		XCTAssertTrue(try residue(in: root).isEmpty)
	}

	func testPathGuardRejectsOversizedSnapshotBeforeReadingPastBound() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Oversized.swift")
		try Data(
			repeating: 0x78,
			count: DesktopProEditPathGuard.maximumContentBytes + 1
		).write(to: target)
		let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
		let expected = DesktopProEditFileSnapshot(
			bytes: Data(),
			posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644,
			fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
			fileSystemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
			fileSize: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
			modificationDate: attributes[.modificationDate] as? Date ?? .distantPast
		)
		let change = plan(
			root: root,
			path: "Oversized.swift",
			action: .delegateEdit,
			expected: expected,
			content: Data("proposed\n".utf8)
		)
		let guardrail = DesktopProEditPathGuard(roots: [root.path])
		let validated = try XCTUnwrap(guardrail.validateAll([change]).first)

		XCTAssertThrowsError(try guardrail.revalidate(validated)) {
			let error = $0 as? DesktopProEditApplyError
			XCTAssertEqual(error?.code, .sourceChanged)
			XCTAssertTrue(error?.message.contains("too large") == true)
		}
	}

	func testInjectedCommitFailureRollsBackEveryAppliedTargetAndCleansResidue() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		var plans: [DesktopProEditWritePlan] = []
		for index in 0..<3 {
			let path = "File\(index).swift"
			let url = root.appendingPathComponent(path)
			let bytes = Data("original \(index)\n".utf8)
			try bytes.write(to: url)
			plans.append(plan(
				root: root,
				path: path,
				action: .delegateEdit,
				expected: try fileSnapshot(url),
				content: Data("changed \(index)\n".utf8)
			))
		}
		let before = try treeSnapshot(root)

		XCTAssertThrowsError(
			try DesktopProEditWriter(injectedCommitFailureIndex: 1).write(plans, roots: [root.path])
		) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .writeFailed)
		}

		XCTAssertEqual(try treeSnapshot(root), before)
		XCTAssertTrue(try residue(in: root).isEmpty)
	}

	func testCommitHookTargetReplacementIsDetectedWithoutOverwritingThirdPartyBytes() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			if case .beforeCommit(index: 0, path: _) = event {
				try Data("third-party\n".utf8).write(to: target, options: .atomic)
			}
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(try Data(contentsOf: target), Data("third-party\n".utf8))
		XCTAssertTrue(try residue(in: root).isEmpty)
	}

	func testCommitHookParentReplacementDoesNotWriteIntoReplacementDirectory() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let parent = root.appendingPathComponent("Sources", isDirectory: true)
		let detached = root.appendingPathComponent("DetachedSources", isDirectory: true)
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
		let original = parent.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: original)
		let change = plan(
			root: root,
			path: "Sources/Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(original),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			if case .beforeCommit(index: 0, path: _) = event {
				try FileManager.default.moveItem(at: parent, to: detached)
				try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
				try Data("third-party\n".utf8).write(to: parent.appendingPathComponent("Target.swift"))
			}
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(
			try Data(contentsOf: parent.appendingPathComponent("Target.swift")),
			Data("third-party\n".utf8)
		)
		XCTAssertEqual(
			try Data(contentsOf: detached.appendingPathComponent("Target.swift")),
			Data("original\n".utf8)
		)
		XCTAssertTrue(try residue(in: parent).isEmpty)
		XCTAssertTrue(try residue(in: detached).isEmpty)
	}

	func testRollbackRefusesToDeleteConcurrentReplacementAndRetainsRecoveryFiles() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let first = root.appendingPathComponent("First.swift")
		let second = root.appendingPathComponent("Second.swift")
		try Data("first original\n".utf8).write(to: first)
		try Data("second original\n".utf8).write(to: second)
		let plans = [
			plan(
				root: root,
				path: "First.swift",
				action: .delegateEdit,
				expected: try fileSnapshot(first),
				content: Data("first proposed\n".utf8)
			),
			plan(
				root: root,
				path: "Second.swift",
				action: .delegateEdit,
				expected: try fileSnapshot(second),
				content: Data("second proposed\n".utf8)
			)
		]

		XCTAssertThrowsError(try DesktopProEditWriter(
			injectedCommitFailureIndex: 1,
			eventHook: { event in
				if case .beforeRollback(index: 0, path: _) = event {
					try Data("third-party\n".utf8).write(to: first, options: .atomic)
				}
			}
		).write(plans, roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .rollbackFailed)
		}

		XCTAssertEqual(try Data(contentsOf: first), Data("third-party\n".utf8))
		XCTAssertEqual(try Data(contentsOf: second), Data("second original\n".utf8))
		XCTAssertFalse(try residue(in: root).isEmpty, "Original recovery bytes must remain when safe rollback is impossible.")
	}

	func testCorrectiveRecoveryPreservesReplacementsArrivingAfterRevalidationAndVerification() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			switch event {
			case .beforePublishMutation(index: 0, path: _):
				try Data("third-party-before-exchange\n".utf8).write(to: target, options: .atomic)
			case .beforeCorrectiveMutation(index: 0, path: _):
				try Data("third-party-after-exchange\n".utf8).write(to: target, options: .atomic)
			default:
				break
			}
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(
			try artifactData(in: root).contains(Data("third-party-before-exchange\n".utf8)),
			"The source replacement displaced during corrective recovery must be retained."
		)
		XCTAssertTrue(
			try artifactData(in: root).contains(Data("third-party-after-exchange\n".utf8)),
			"The published replacement displaced during corrective recovery must be retained."
		)
	}

	func testRollbackDetectsSameInodeMutationAfterVerificationAndPreservesBytes() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let first = root.appendingPathComponent("First.swift")
		let second = root.appendingPathComponent("Second.swift")
		try Data("first original\n".utf8).write(to: first)
		try Data("second original\n".utf8).write(to: second)
		let observation = InodeObservation()
		let plans = [
			plan(
				root: root,
				path: "First.swift",
				action: .delegateEdit,
				expected: try fileSnapshot(first),
				content: Data("first proposed\n".utf8)
			),
			plan(
				root: root,
				path: "Second.swift",
				action: .delegateEdit,
				expected: try fileSnapshot(second),
				content: Data("second proposed\n".utf8)
			)
		]

		XCTAssertThrowsError(try DesktopProEditWriter(
			injectedCommitFailureIndex: 1,
			eventHook: { event in
				guard case .beforeRollbackMutation(index: 0, path: _) = event else { return }
				let before = try inode(first)
				let handle = try FileHandle(forWritingTo: first)
				try handle.truncate(atOffset: 0)
				try handle.write(contentsOf: Data("same-inode-third-party\n".utf8))
				try handle.synchronize()
				try handle.close()
				observation.record(before: before, after: try inode(first))
			}
		).write(plans, roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .rollbackFailed)
		}

		XCTAssertEqual(observation.value?.before, observation.value?.after)
		XCTAssertEqual(try Data(contentsOf: first), Data("same-inode-third-party\n".utf8))
		XCTAssertEqual(try Data(contentsOf: second), Data("second original\n".utf8))
		XCTAssertFalse(try residue(in: root).isEmpty)
	}

	func testParentAcquisitionNeverFollowsIntermediateSymlinkSwappedAfterValidation() throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: outside)
		}
		let sources = root.appendingPathComponent("Sources", isDirectory: true)
		let nested = sources.appendingPathComponent("Nested", isDirectory: true)
		let detached = root.appendingPathComponent("Detached", isDirectory: true)
		try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(
			at: outside.appendingPathComponent("Nested", isDirectory: true),
			withIntermediateDirectories: true
		)
		let create = plan(
			root: root,
			path: "Sources/Nested/Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case .beforeParentAcquisition(index: 0, path: _) = event else { return }
			try FileManager.default.moveItem(at: sources, to: detached)
			try FileManager.default.createSymbolicLink(
				atPath: sources.path,
				withDestinationPath: outside.path
			)
		}).write([create], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .unsafePath)
		}

		XCTAssertFalse(
			FileManager.default.fileExists(
				atPath: outside.appendingPathComponent("Nested/Created.swift").path
			)
		)
		XCTAssertFalse(
			FileManager.default.fileExists(
				atPath: detached.appendingPathComponent("Nested/Created.swift").path
			)
		)
	}

	func testWriterRejectsReviewedRootIdentityReplacement() throws {
		let container = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: container) }
		let root = container.appendingPathComponent("Workspace", isDirectory: true)
		let detached = container.appendingPathComponent("ReviewedWorkspace", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)
		try FileManager.default.moveItem(at: root, to: detached)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

		XCTAssertThrowsError(try DesktopProEditWriter().write([create], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created.swift").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: detached.appendingPathComponent("Created.swift").path))
	}

	func testBackupStagingFailureRemovesOnlyOwnedTemporaryFile() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case .beforeBackupStaging(index: 0, path: _) = event else { return }
			throw DesktopProEditApplyError(.writeFailed, message: "Injected backup staging failure.")
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .writeFailed)
		}

		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(try residue(in: root).isEmpty)
	}

	func testFailedWriteCleanupQuarantinesAndPreservesRacedReplacement() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case let .afterStagingFileCreated(index: 0, path: _, name: name) = event,
				name.hasSuffix(".tmp")
			else {
				return
			}
			try Data("third-party-staging\n".utf8)
				.write(to: root.appendingPathComponent(name), options: .atomic)
			throw DesktopProEditApplyError(.writeFailed, message: "Injected staging write failure.")
		}).write([create], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .writeFailed)
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created.swift").path))
		XCTAssertTrue(
			try residueData(in: root).contains(Data("third-party-staging\n".utf8)),
			"Failed-write cleanup must retain a raced replacement rather than unlink it."
		)
	}

	func testCreateCorrectsStagedReplacementAfterRevalidationAndPreservesUnexpectedBytes() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			try Data("unexpected-create-staging\n".utf8)
				.write(to: root.appendingPathComponent(name), options: .atomic)
		}).write([create], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created.swift").path))
		XCTAssertTrue(
			try artifactData(in: root).contains(Data("unexpected-create-staging\n".utf8)),
			"The replaced create staging bytes must be retained after absence is restored."
		)
	}

	func testDelegateCorrectsStagedReplacementAfterRevalidationAndRestoresOriginal() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			try Data("unexpected-delegate-staging\n".utf8)
				.write(to: root.appendingPathComponent(name), options: .atomic)
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(
			try artifactData(in: root).contains(Data("unexpected-delegate-staging\n".utf8)),
			"The replaced delegate staging bytes must be retained after the original is restored."
		)
	}

	func testCreateRecoversWhenOversizedStagingReplacementCannotBeSnapshotted() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let oversized = Data(
			repeating: 0x78,
			count: DesktopProEditPathGuard.maximumContentBytes + 1
		)
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			try oversized.write(to: root.appendingPathComponent(name), options: .atomic)
		}).write([create], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created.swift").path))
		XCTAssertTrue(try artifactSizes(in: root).contains(oversized.count))
	}

	func testDelegateRecoversWhenOversizedStagingReplacementCannotBeSnapshotted() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let oversized = Data(
			repeating: 0x79,
			count: DesktopProEditPathGuard.maximumContentBytes + 1
		)
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			try oversized.write(to: root.appendingPathComponent(name), options: .atomic)
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(try artifactSizes(in: root).contains(oversized.count))
	}

	func testCreateRecoversWhenSymlinkStagingReplacementCannotBeSnapshotted() throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: outside)
		}
		let outsideFile = outside.appendingPathComponent("Outside.swift")
		try Data("outside\n".utf8).write(to: outsideFile)
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			let staging = root.appendingPathComponent(name)
			try FileManager.default.removeItem(at: staging)
			try FileManager.default.createSymbolicLink(
				atPath: staging.path,
				withDestinationPath: outsideFile.path
			)
		}).write([create], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created.swift").path))
		XCTAssertTrue(try artifactSymlinkDestinations(in: root).contains(outsideFile.path))
		XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside\n".utf8))
	}

	func testDelegateRecoversWhenSymlinkStagingReplacementCannotBeSnapshotted() throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: outside)
		}
		let outsideFile = outside.appendingPathComponent("Outside.swift")
		try Data("outside\n".utf8).write(to: outsideFile)
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			let staging = root.appendingPathComponent(name)
			try FileManager.default.removeItem(at: staging)
			try FileManager.default.createSymbolicLink(
				atPath: staging.path,
				withDestinationPath: outsideFile.path
			)
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(try artifactSymlinkDestinations(in: root).contains(outsideFile.path))
		XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside\n".utf8))
	}

	func testCreateRecoversFromFIFOStagingReplacementWithoutBlocking() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)
		let writer = DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			try replaceWithFIFO(root.appendingPathComponent(name))
		})

		let outcome = try boundedWrite(writer: writer, plans: [create], roots: [root.path])

		assertApplyFailure(outcome, code: .sourceChanged)
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Created.swift").path))
		XCTAssertTrue(try artifactContainsFIFO(in: root))
	}

	func testDelegateRecoversFromFIFOStagingReplacementWithoutBlocking() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)
		let writer = DesktopProEditWriter(eventHook: { event in
			guard case let .beforeStagedPublish(index: 0, path: _, name: name) = event else {
				return
			}
			try replaceWithFIFO(root.appendingPathComponent(name))
		})

		let outcome = try boundedWrite(writer: writer, plans: [change], roots: [root.path])

		assertApplyFailure(outcome, code: .sourceChanged)
		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(try artifactContainsFIFO(in: root))
	}

	func testCreateRecoversFromFIFOAfterPublishReplacementWithoutBlocking() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Created.swift")
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)
		let writer = DesktopProEditWriter(eventHook: { event in
			guard case .afterPublish(index: 0, path: _) = event else {
				return
			}
			try replaceWithFIFO(target)
		})

		let outcome = try boundedWrite(writer: writer, plans: [create], roots: [root.path])

		assertApplyFailure(outcome, code: .sourceChanged)
		XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
		XCTAssertTrue(try artifactContainsFIFO(in: root))
	}

	func testDelegateRecoversFromFIFOAfterPublishReplacementWithoutBlocking() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)
		let writer = DesktopProEditWriter(eventHook: { event in
			guard case .afterPublish(index: 0, path: _) = event else {
				return
			}
			try replaceWithFIFO(target)
		})

		let outcome = try boundedWrite(writer: writer, plans: [change], roots: [root.path])

		assertApplyFailure(outcome, code: .sourceChanged)
		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(try artifactContainsFIFO(in: root))
	}

	func testCreateRecoversFromRegularAfterPublishReplacement() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Created.swift")
		let replacement = Data("third-party-after-publish\n".utf8)
		let create = plan(
			root: root,
			path: "Created.swift",
			action: .create,
			expected: nil,
			content: Data("created\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case .afterPublish(index: 0, path: _) = event else {
				return
			}
			try replacement.write(to: target, options: .atomic)
		}).write([create], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
		XCTAssertTrue(try artifactData(in: root).contains(replacement))
	}

	func testDelegateRecoversFromRegularAfterPublishReplacement() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		let replacement = Data("third-party-after-publish\n".utf8)
		try Data("original\n".utf8).write(to: target)
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		XCTAssertThrowsError(try DesktopProEditWriter(eventHook: { event in
			guard case .afterPublish(index: 0, path: _) = event else {
				return
			}
			try replacement.write(to: target, options: .atomic)
		}).write([change], roots: [root.path])) {
			XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, .sourceChanged)
		}

		XCTAssertEqual(try Data(contentsOf: target), Data("original\n".utf8))
		XCTAssertTrue(try artifactData(in: root).contains(replacement))
	}

	func testFinalCleanupQuarantinesAndPreservesRacedReplacement() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let mutation = OneShotMutation()
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		let summary = try DesktopProEditWriter(eventHook: { event in
			guard case let .beforeOwnedCleanup(path: _, name: name) = event,
				mutation.claim()
			else {
				return
			}
			try Data("third-party-final-cleanup\n".utf8)
				.write(to: root.appendingPathComponent(name), options: .atomic)
		}).write([change], roots: [root.path])

		XCTAssertEqual(summary.appliedPaths, ["Target.swift"])
		XCTAssertEqual(try Data(contentsOf: target), Data("proposed\n".utf8))
		XCTAssertTrue(
			try residueData(in: root).contains(Data("third-party-final-cleanup\n".utf8)),
			"Final cleanup must retain a raced replacement rather than unlink it."
		)
	}

	func testVerifiedQuarantineIsRetainedWhenItsNameIsReplacedAfterVerification() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("Target.swift")
		try Data("original\n".utf8).write(to: target)
		let mutation = OneShotMutation()
		let change = plan(
			root: root,
			path: "Target.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(target),
			content: Data("proposed\n".utf8)
		)

		let summary = try DesktopProEditWriter(eventHook: { event in
			guard case let .afterQuarantineVerification(
				path: _,
				name: _,
				quarantineName: quarantineName
			) = event,
				mutation.claim()
			else {
				return
			}
			try Data("third-party-after-quarantine-verification\n".utf8)
				.write(to: root.appendingPathComponent(quarantineName), options: .atomic)
		}).write([change], roots: [root.path])

		XCTAssertEqual(summary.appliedPaths, ["Target.swift"])
		XCTAssertEqual(try Data(contentsOf: target), Data("proposed\n".utf8))
		XCTAssertTrue(
			try artifactData(in: root).contains(Data("third-party-after-quarantine-verification\n".utf8)),
			"A mutable quarantine name must never be unlinked after verification."
		)
	}

	func testGuardRejectsSymlinkEscapesFoldersDuplicatesAndOverlaps() throws {
		let root = try temporaryDirectory()
		let outside = try temporaryDirectory()
		defer {
			try? FileManager.default.removeItem(at: root)
			try? FileManager.default.removeItem(at: outside)
		}
		let outsideFile = outside.appendingPathComponent("Outside.swift")
		try Data("outside\n".utf8).write(to: outsideFile)
		let link = root.appendingPathComponent("Linked.swift")
		try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outsideFile.path)
		let linkedPlan = plan(
			root: root,
			path: "Linked.swift",
			action: .delegateEdit,
			expected: try fileSnapshot(outsideFile),
			content: Data("escape\n".utf8)
		)
		assertWriterError(.unsafePath, plans: [linkedPlan], roots: [root.path])

		let linkedDirectory = root.appendingPathComponent("LinkedDirectory")
		try FileManager.default.createSymbolicLink(atPath: linkedDirectory.path, withDestinationPath: outside.path)
		let intermediatePlan = plan(
			root: root,
			path: "LinkedDirectory/Created.swift",
			action: .create,
			expected: nil,
			content: Data("escape\n".utf8)
		)
		assertWriterError(.unsafePath, plans: [intermediatePlan], roots: [root.path])

		let folder = root.appendingPathComponent("Folder", isDirectory: true)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let folderPlan = plan(
			root: root,
			path: "Folder",
			action: .delegateEdit,
			expected: try fileSnapshot(folder),
			content: Data("no\n".utf8)
		)
		assertWriterError(.targetIsDirectory, plans: [folderPlan], roots: [root.path])

		let duplicate = plan(root: root, path: "Created.swift", action: .create, expected: nil, content: Data("one\n".utf8))
		assertWriterError(.duplicateTarget, plans: [duplicate, duplicate], roots: [root.path])
		let overlap = plan(root: root, path: "Parent", action: .create, expected: nil, content: Data("one\n".utf8))
		let child = plan(root: root, path: "Parent/Child", action: .create, expected: nil, content: Data("two\n".utf8))
		assertWriterError(.overlappingTarget, plans: [overlap, child], roots: [root.path])

		let outsidePlan = DesktopProEditWritePlan(
			rootIndex: 0,
			relativePath: "../Outside.swift",
			absolutePath: outsideFile.path,
			displayPath: "../Outside.swift",
			action: .create,
			expected: nil,
			proposedBytes: Data("escape\n".utf8)
		)
		assertWriterError(.unsafePath, plans: [outsidePlan], roots: [root.path])
		XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside\n".utf8))
		XCTAssertTrue(try residue(in: root).isEmpty)
	}

	func testCreateCollisionFailsWithoutOverwritingOrResidue() throws {
		let root = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: root) }
		let collision = root.appendingPathComponent("Collision.swift")
		try Data("keep\n".utf8).write(to: collision)
		let before = try treeSnapshot(root)
		let create = plan(
			root: root,
			path: "Collision.swift",
			action: .create,
			expected: nil,
			content: Data("overwrite\n".utf8)
		)

		assertWriterError(.createCollision, plans: [create], roots: [root.path])

		XCTAssertEqual(try treeSnapshot(root), before)
		XCTAssertTrue(try residue(in: root).isEmpty)
	}

	func testNewMaterializationInvalidatesOlderSessionAndSelectionMutationBlocksApply() async throws {
		let fixture = try await Fixture()
		defer { fixture.cleanup() }
		let first = try await fixture.materializeCreate(path: "First.swift")
		let second = try await fixture.materializeCreate(path: "Second.swift")

		do {
			_ = try await fixture.proEditService.apply(first.id)
			XCTFail("Expected stale session rejection.")
		} catch let error as DesktopProEditApplyError {
			XCTAssertEqual(error.code, .staleSession)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("First.swift").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Second.swift").path))

		_ = try await fixture.workspaceService.addFiles([fixture.selected.path])
		do {
			_ = try await fixture.proEditService.apply(second.id)
			XCTFail("Expected stale selection rejection.")
		} catch let error as DesktopProEditApplyError {
			XCTAssertEqual(error.code, .staleSelection)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Second.swift").path))
		XCTAssertTrue(try residue(in: fixture.root).isEmpty)
	}

	func testApplyReservationRejectsConcurrentApplyMaterializeAndDiscard() async throws {
		let gate = ApplyGate()
		let fixture = try await Fixture(beforeApplyValidation: {
			await gate.pause()
		})
		defer { fixture.cleanup() }
		let session = try await fixture.materializeCreate(path: "First.swift")
		let applyTask = Task {
			try await fixture.proEditService.apply(session.id)
		}
		await gate.waitUntilPaused()

		do {
			_ = try await fixture.proEditService.apply(session.id)
			XCTFail("Expected concurrent apply rejection.")
		} catch let error as DesktopProEditApplyError {
			XCTAssertEqual(error.code, .applyInProgress)
		}
		await fixture.proEditService.discard(session.id)
		let artifact = try PortableProEditArtifactParser.parse(
			createArtifact(path: "Second.swift", content: "second\n")
		)
		let preflight = try await fixture.resolveChosen(artifact)
		do {
			_ = try await fixture.proEditService.materialize(preflight)
			XCTFail("Expected concurrent materialization rejection.")
		} catch let error as DesktopProEditApplyError {
			XCTAssertEqual(error.code, .applyInProgress)
		}

		await gate.resume()
		let summary = try await applyTask.value
		XCTAssertEqual(summary.appliedPaths, ["First.swift"])
		XCTAssertEqual(
			try Data(contentsOf: fixture.root.appendingPathComponent("First.swift")),
			Data("created\n".utf8)
		)
	}
}

private final class Fixture {
	let root: URL
	let selected: URL
	let workspaceService: PortableWorkspaceService
	let proEditService: DesktopProEditService

	init(beforeApplyValidation: (@Sendable () async -> Void)? = nil) async throws {
		root = try temporaryDirectory()
		selected = root.appendingPathComponent("Selected.swift")
		try Data("struct Selected {}\n".utf8).write(to: selected)
		let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(
			options: HeadlessOptions(roots: [root.path], persist: false)
		)
		workspaceService = PortableWorkspaceService(bootstrap: bootstrap)
		let workspace = await workspaceService.workspace()
		proEditService = DesktopProEditService(
			workspace: workspace,
			workspaceService: workspaceService,
			writer: DesktopProEditWriter(),
			beforeApplyValidation: beforeApplyValidation
		)
	}

	func materializeCreate(path: String) async throws -> DesktopProEditSession {
		let artifact = try PortableProEditArtifactParser.parse(createArtifact(path: path, content: "created\n"))
		let preflight = try await resolveChosen(artifact)
		return try await proEditService.materialize(preflight)
	}

	func resolveChosen(
		_ artifact: PortableProEditArtifact,
		lane: PortablePlanLane.Name = .primary
	) async throws -> PortableProEditPreflight {
		let response = artifactSource(artifact)
		let generation = PortableProEditGeneration(
			selection: await workspaceService.selection(),
			result: PortablePlanResult(
				pairID: UUID(),
				status: .completed,
				primary: PortablePlanLane(
					name: .primary,
					modelRawID: "primary-model",
					status: .completed,
					response: response,
					errorCode: nil,
					errorMessage: nil
				),
				secondary: PortablePlanLane(
					name: .secondary,
					modelRawID: "secondary-model",
					status: .completed,
					response: response,
					errorCode: nil,
					errorMessage: nil
				),
				context: try await workspaceService.previewContext()
			)
		)
		return try await workspaceService.resolveProEditArtifact(
			artifact,
			expectedGeneration: generation,
			lane: lane
		)
	}

	func cleanup() {
		try? FileManager.default.removeItem(at: root)
	}
}

private actor ApplyGate {
	private var paused = false
	private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
	private var resumeContinuation: CheckedContinuation<Void, Never>?

	func pause() async {
		paused = true
		for waiter in pauseWaiters { waiter.resume() }
		pauseWaiters.removeAll()
		await withCheckedContinuation { continuation in
			resumeContinuation = continuation
		}
	}

	func waitUntilPaused() async {
		if paused { return }
		await withCheckedContinuation { continuation in
			pauseWaiters.append(continuation)
		}
	}

	func resume() {
		resumeContinuation?.resume()
		resumeContinuation = nil
	}
}

private final class InodeObservation: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: (before: UInt64, after: UInt64)?

	var value: (before: UInt64, after: UInt64)? {
		lock.withLock { stored }
	}

	func record(before: UInt64, after: UInt64) {
		lock.withLock {
			stored = (before, after)
		}
	}
}

private final class OneShotMutation: @unchecked Sendable {
	private let lock = NSLock()
	private var available = true

	func claim() -> Bool {
		lock.withLock {
			guard available else { return false }
			available = false
			return true
		}
	}
}

private final class WriterResultBox: @unchecked Sendable {
	private let lock = NSLock()
	private var stored: Result<DesktopProEditApplySummary, Error>?

	func store(_ result: Result<DesktopProEditApplySummary, Error>) {
		lock.withLock {
			stored = result
		}
	}

	func value() -> Result<DesktopProEditApplySummary, Error>? {
		lock.withLock { stored }
	}
}

private enum BoundedWriterError: Error {
	case timedOut
	case missingResult
}

private func createArtifact(path: String, content: String) -> String {
	"""
	<chatName="Create file"/>
	<Plan>Create one file.</Plan>
	<file path="\(path)" action="create">
	<change><description>Create complete file</description><content>\(content)</content><complexity>1</complexity></change>
	</file>
	"""
}

private func artifactSource(_ artifact: PortableProEditArtifact) -> String {
	var source = """
	<chatName="\(artifact.chatName)"/>
	<Plan>\(artifact.plan)</Plan>

	"""
	for file in artifact.files {
		source += "<file path=\"\(file.path)\" action=\"\(file.action.rawValue)\">\n"
		for change in file.changes {
			source += """
				<change>
				<description>\(change.description)</description>
				<content>\(change.content)</content>
				<complexity>\(change.complexity)</complexity>
				</change>

				"""
		}
		source += "</file>\n"
	}
	return source
}

private func plan(
	root: URL,
	path: String,
	action: PortableProEditAction,
	expected: DesktopProEditFileSnapshot?,
	content: Data
) -> DesktopProEditWritePlan {
	let parent = root.appendingPathComponent(path).deletingLastPathComponent()
	return DesktopProEditWritePlan(
		rootIndex: 0,
		relativePath: path,
		absolutePath: root.appendingPathComponent(path).standardizedFileURL.path,
		displayPath: path,
		action: action,
		expected: expected,
		proposedBytes: content,
		reviewedRootIdentity: try? directoryIdentity(root),
		reviewedParentIdentity: try? directoryIdentity(parent)
	)
}

private func directoryIdentity(_ url: URL) throws -> DesktopProEditDirectoryIdentity {
	let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
	return DesktopProEditDirectoryIdentity(
		fileSystemNumber: try XCTUnwrap((attributes[.systemNumber] as? NSNumber)?.uint64Value),
		fileSystemFileNumber: try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
	)
}

private func temporaryDirectory() throws -> URL {
	let url = FileManager.default.temporaryDirectory
		.appendingPathComponent("DesktopProEditApplyTests-\(UUID().uuidString)", isDirectory: true)
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

private func permissions(_ url: URL) throws -> Int {
	let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
	return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private func fileSnapshot(_ url: URL) throws -> DesktopProEditFileSnapshot {
	let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
	let bytes: Data
	if attributes[.type] as? FileAttributeType == .typeDirectory {
		bytes = Data()
	} else {
		bytes = try Data(contentsOf: url)
	}
	return DesktopProEditFileSnapshot(
		bytes: bytes,
		posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644,
		fileSystemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
		fileSystemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
		fileSize: (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64(bytes.count),
		modificationDate: attributes[.modificationDate] as? Date ?? .distantPast
	)
}

private func inode(_ url: URL) throws -> UInt64 {
	let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
	return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}

private func residue(in root: URL) throws -> [String] {
	try FileManager.default.contentsOfDirectory(atPath: root.path)
		.filter {
			$0.hasPrefix(".repoprompt-pro-edit-")
				&& !$0.hasSuffix(".quarantine")
		}
}

private func residueData(in root: URL) throws -> [Data] {
	try residue(in: root).map {
		try Data(contentsOf: root.appendingPathComponent($0))
	}
}

private func artifactData(in root: URL) throws -> [Data] {
	try FileManager.default.contentsOfDirectory(atPath: root.path)
		.filter { $0.hasPrefix(".repoprompt-pro-edit-") }
		.map { try Data(contentsOf: root.appendingPathComponent($0)) }
}

private func artifactSizes(in root: URL) throws -> [Int] {
	try FileManager.default.contentsOfDirectory(atPath: root.path)
		.filter { $0.hasPrefix(".repoprompt-pro-edit-") }
		.compactMap {
			let attributes = try FileManager.default.attributesOfItem(
				atPath: root.appendingPathComponent($0).path
			)
			return (attributes[.size] as? NSNumber)?.intValue
		}
}

private func artifactSymlinkDestinations(in root: URL) throws -> [String] {
	try FileManager.default.contentsOfDirectory(atPath: root.path)
		.filter { $0.hasPrefix(".repoprompt-pro-edit-") }
		.compactMap {
			try? FileManager.default.destinationOfSymbolicLink(
				atPath: root.appendingPathComponent($0).path
			)
		}
}

private func replaceWithFIFO(_ url: URL) throws {
	try FileManager.default.removeItem(at: url)
	guard mkfifo(url.path, mode_t(0o600)) == 0 else {
		throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
	}
}

private func boundedWrite(
	writer: DesktopProEditWriter,
	plans: [DesktopProEditWritePlan],
	roots: [String]
) throws -> Result<DesktopProEditApplySummary, Error> {
	let result = WriterResultBox()
	let completed = DispatchSemaphore(value: 0)
	DispatchQueue.global(qos: .userInitiated).async {
		result.store(Result {
			try writer.write(plans, roots: roots)
		})
		completed.signal()
	}
	guard completed.wait(timeout: .now() + 2) == .success else {
		throw BoundedWriterError.timedOut
	}
	guard let value = result.value() else {
		throw BoundedWriterError.missingResult
	}
	return value
}

private func assertApplyFailure(
	_ result: Result<DesktopProEditApplySummary, Error>,
	code: DesktopProEditApplyError.Code,
	file: StaticString = #filePath,
	line: UInt = #line
) {
	switch result {
	case .success:
		XCTFail("Expected Pro Edit apply to fail.", file: file, line: line)
	case let .failure(error):
		XCTAssertEqual(
			(error as? DesktopProEditApplyError)?.code,
			code,
			file: file,
			line: line
		)
	}
}

private func artifactContainsFIFO(in root: URL) throws -> Bool {
	for name in try FileManager.default.contentsOfDirectory(atPath: root.path)
	where name.hasPrefix(".repoprompt-pro-edit-") {
		var info = stat()
		let result = root.appendingPathComponent(name).path.withCString {
			lstat($0, &info)
		}
		if result == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO) {
			return true
		}
	}
	return false
}

private func treeSnapshot(_ root: URL) throws -> [String: Data] {
	let manager = FileManager.default
	let enumerator = try XCTUnwrap(manager.enumerator(
		at: root,
		includingPropertiesForKeys: [.isDirectoryKey],
		options: []
	))
	var snapshot: [String: Data] = [:]
	for case let url as URL in enumerator {
		let relative = String(url.path.dropFirst(root.path.count + 1))
		if relative.split(separator: "/").contains(where: { $0.hasSuffix(".quarantine") }) {
			continue
		}
		let values = try url.resourceValues(forKeys: [.isDirectoryKey])
		snapshot[relative] = values.isDirectory == true
			? Data("<directory>".utf8)
			: try Data(contentsOf: url)
	}
	return snapshot
}

private func assertWriterError(
	_ code: DesktopProEditApplyError.Code,
	plans: [DesktopProEditWritePlan],
	roots: [String],
	file: StaticString = #filePath,
	line: UInt = #line
) {
	XCTAssertThrowsError(
		try DesktopProEditWriter().write(plans, roots: roots),
		file: file,
		line: line
	) {
		XCTAssertEqual(($0 as? DesktopProEditApplyError)?.code, code, file: file, line: line)
	}
}
