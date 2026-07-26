import Foundation
import RepoPromptCore
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessOracleWorkflowTests: XCTestCase {
	func testBothLanesStartConcurrentlyAndSameModelStillCallsProviderTwice() async throws {
		let provider = RecordingOracleProvider(
			primary: .response("primary answer"),
			secondary: .response("secondary answer")
		)
		let workflow = try makeWorkflow(provider: provider, primaryModel: "same", secondaryModel: "same")
		let result = try await workflow.execute(mode: .proEdit, request: "  edit  ", context: try emptyContext())
		let requests = await provider.recordedRequests()

		XCTAssertEqual(requests.count, 2)
		XCTAssertEqual(Set(requests.map(\.lane.rawValue)), Set(["primary", "secondary"]))
		XCTAssertEqual(requests.map(\.model), ["same", "same"])
		XCTAssertEqual(requests.map(\.reasoningEffort), ["xhigh", "xhigh"])
		XCTAssertEqual(requests[0].userPrompt, requests[1].userPrompt)
		XCTAssertEqual(requests[0].pairID, requests[1].pairID)
		XCTAssertEqual(result.pairStatus, .completed)
		XCTAssertEqual(result.primary.response, "primary answer")
		XCTAssertEqual(result.secondary.response, "secondary answer")
	}

	func testReverseCompletionPreservesPrimarySecondaryResultOrder() async throws {
		let provider = RecordingOracleProvider(
			primary: .response("slow primary"),
			secondary: .response("fast secondary"),
			primaryDelayNanoseconds: 50_000_000
		)
		let result = try await makeWorkflow(provider: provider).execute(
			mode: .proEdit,
			request: "edit",
			context: try emptyContext()
		)

		let completedLanes = await provider.completedLanes()
		XCTAssertEqual(completedLanes, [.secondary, .primary])
		XCTAssertEqual(result.primary.lane, .primary)
		XCTAssertEqual(result.primary.response, "slow primary")
		XCTAssertEqual(result.primary.providerMetadata?.observedModelID, "primary-model")
		XCTAssertEqual(result.secondary.lane, .secondary)
		XCTAssertEqual(result.secondary.response, "fast secondary")
		XCTAssertEqual(result.secondary.providerMetadata?.observedModelID, "secondary-model")
	}

	func testIndependentPartialFailureDoesNotCancelSibling() async throws {
		let provider = RecordingOracleProvider(
			primary: .response("primary survives"),
			secondary: .failure(.init(.httpError, message: "secondary failed", httpStatus: 500))
		)
		let result = try await makeWorkflow(provider: provider).execute(
			mode: .proEdit,
			request: "edit",
			context: try emptyContext()
		)

		XCTAssertEqual(result.pairStatus, .partialFailure)
		XCTAssertEqual(result.primary.status, .completed)
		XCTAssertEqual(result.primary.response, "primary survives")
		XCTAssertEqual(result.secondary.status, .failed)
		XCTAssertEqual(result.secondary.failure?.code, "http_error")
		let completionCount = await provider.completedLanes().count
		XCTAssertEqual(completionCount, 2)
	}

	func testPrimaryFailureNeverPromotesSecondary() async throws {
		let provider = RecordingOracleProvider(
			primary: .failure(.init(.timeout, message: "primary timeout")),
			secondary: .response("secondary must stay secondary")
		)
		let result = try await makeWorkflow(provider: provider).execute(
			mode: .chat,
			request: "answer",
			context: try emptyContext()
		)

		XCTAssertEqual(result.pairStatus, .partialFailure)
		XCTAssertEqual(result.primary.status, .failed)
		XCTAssertNil(result.primary.response)
		XCTAssertEqual(result.primary.failure?.code, "timeout")
		XCTAssertEqual(result.secondary.response, "secondary must stay secondary")
	}

	func testProEditBothFailuresRemainIndependentTerminalResults() async throws {
		let provider = RecordingOracleProvider(
			primary: .failure(.init(.networkError, message: "primary network")),
			secondary: .failure(.init(.invalidResponse, message: "secondary invalid"))
		)
		let result = try await makeWorkflow(provider: provider).execute(
			mode: .proEdit,
			request: "edit",
			context: try emptyContext()
		)

		XCTAssertEqual(result.pairStatus, .failed)
		XCTAssertEqual(result.primary.failure?.code, "network_error")
		XCTAssertEqual(result.secondary.failure?.code, "invalid_response")
	}

	func testProEditEmptyCompletionRetainsProviderMetadataOnFailedLane() async throws {
		let provider = RecordingOracleProvider(
			primary: .response("   "),
			secondary: .response("secondary answer")
		)
		let result = try await makeWorkflow(provider: provider).execute(
			mode: .proEdit,
			request: "edit",
			context: try emptyContext()
		)

		XCTAssertEqual(result.primary.status, .failed)
		XCTAssertEqual(result.primary.failure?.code, "empty_response")
		XCTAssertEqual(result.primary.providerMetadata?.httpStatus, 200)
		XCTAssertEqual(result.primary.providerMetadata?.conversationID, "conversation-primary")
		XCTAssertEqual(result.secondary.status, .completed)
	}

	func testParentCancellationReachesBothProviderRequests() async throws {
		let provider = CancellingOracleProvider()
		let workflow = try makeWorkflow(provider: provider)
		let task = Task {
			try await workflow.execute(mode: .proEdit, request: "wait", context: try emptyContext())
		}
		try await provider.waitForArrivals(2)
		task.cancel()

		do {
			_ = try await task.value
			XCTFail("Expected cancellation")
		} catch is CancellationError {
			// Expected.
		}
		try await provider.waitForCancellations(2)
		let cancellationCount = await provider.cancellationCount()
		XCTAssertEqual(cancellationCount, 2)
	}

	private func makeWorkflow(
		provider: any HeadlessOracleProvider,
		primaryModel: String = "primary-model",
		secondaryModel: String = "secondary-model"
	) throws -> HeadlessOracleWorkflow {
		let configuration = try HeadlessOracleConfiguration(
			endpoint: XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions")),
			primaryModel: primaryModel,
			secondaryModel: secondaryModel,
			reasoningEffort: "xhigh"
		)
		return HeadlessOracleWorkflow(configuration: configuration, provider: provider)
	}

	private func emptyContext() throws -> HeadlessWorkspaceContext {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return HeadlessWorkspaceContextBuilder(roots: [root.path]).build(
			selection: WorkspaceSelectionSnapshot(),
			maximumBytes: 1_024
		)
	}
}

private actor RecordingOracleProvider: HeadlessOracleProvider {
	enum Outcome: Sendable {
		case response(String)
		case failure(HeadlessOracleProviderFailure)
	}

	private let primaryOutcome: Outcome
	private let secondaryOutcome: Outcome
	private let primaryDelayNanoseconds: UInt64
	private let secondaryDelayNanoseconds: UInt64
	private var requests: [HeadlessOracleProviderRequest] = []
	private var completions: [HeadlessOracleLane] = []

	init(
		primary: Outcome,
		secondary: Outcome,
		primaryDelayNanoseconds: UInt64 = 0,
		secondaryDelayNanoseconds: UInt64 = 0
	) {
		primaryOutcome = primary
		secondaryOutcome = secondary
		self.primaryDelayNanoseconds = primaryDelayNanoseconds
		self.secondaryDelayNanoseconds = secondaryDelayNanoseconds
	}

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> HeadlessOracleProviderCompletion {
		requests.append(request)
		while requests.count < 2 {
			try await Task.sleep(nanoseconds: 1_000_000)
		}
		let delay = request.lane == .primary ? primaryDelayNanoseconds : secondaryDelayNanoseconds
		if delay > 0 { try await Task.sleep(nanoseconds: delay) }
		completions.append(request.lane)
		let outcome = request.lane == .primary ? primaryOutcome : secondaryOutcome
		switch outcome {
		case .response(let response):
			return HeadlessOracleProviderCompletion(
				content: response,
				metadata: HeadlessOracleProviderMetadata(
					httpStatus: 200,
					latencyMilliseconds: request.lane == .primary ? 50 : 5,
					responseID: "chatcmpl-\(request.lane.rawValue)",
					requestID: "chatcmpl-\(request.lane.rawValue)",
					observedModelID: request.model,
					finishReason: "stop",
					usage: nil,
					conversationID: "conversation-\(request.lane.rawValue)",
					baselineAssistantMessageID: nil,
					recovery: nil
				)
			)
		case .failure(let failure): throw failure
		}
	}

	func recordedRequests() -> [HeadlessOracleProviderRequest] { requests }
	func completedLanes() -> [HeadlessOracleLane] { completions }
}

private actor CancellingOracleProvider: HeadlessOracleProvider {
	private var arrivals = 0
	private var cancellations = 0

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> HeadlessOracleProviderCompletion {
		_ = request
		arrivals += 1
		do {
			while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
		} catch is CancellationError {
			cancellations += 1
			throw CancellationError()
		}
	}

	func waitForArrivals(_ expected: Int) async throws {
		while arrivals < expected { try await Task.sleep(nanoseconds: 1_000_000) }
	}

	func waitForCancellations(_ expected: Int) async throws {
		while cancellations < expected { try await Task.sleep(nanoseconds: 1_000_000) }
	}

	func cancellationCount() -> Int { cancellations }
}
