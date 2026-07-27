import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessOracleProviderTests: XCTestCase {
	func testRequestCodecUsesExactSurfReasoningShapeAndBearerHeader() throws {
		let endpoint = try XCTUnwrap(URL(string: "https://provider.example/custom/chat?tenant=one"))
		let configuration = try HeadlessOracleConfiguration(
			endpoint: endpoint,
			primaryModel: "gpt-5.6-sol",
			secondaryModel: "openrouter/team:gpt-5.6-sol[variant=secondary]",
			bearerToken: "secret-token",
			timeoutSeconds: 2_700,
			reasoningEffort: "xhigh"
		)
		let request = HeadlessOracleProviderRequest(
			pairID: UUID(),
			lane: .primary,
			model: configuration.primaryModel,
			reasoningEffort: configuration.reasoningEffort,
			systemPrompt: "system",
			userPrompt: "shared"
		)

		let encoded = try OpenAICompatibleOracleProvider.makeURLRequest(request, configuration: configuration)
		XCTAssertEqual(encoded.url, endpoint)
		XCTAssertEqual(encoded.httpMethod, "POST")
		XCTAssertEqual(encoded.timeoutInterval, 2_700)
		XCTAssertEqual(encoded.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
		XCTAssertEqual(encoded.value(forHTTPHeaderField: "Content-Type"), "application/json")
		XCTAssertEqual(
			encoded.value(forHTTPHeaderField: "User-Agent"),
			"RepoPromptHeadless/\(PortableContract.softwareVersion)"
		)
		let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(encoded.httpBody)) as? [String: Any])
		XCTAssertEqual(Set(json.keys), Set(["model", "messages", "stream", "reasoning_effort"]))
		XCTAssertEqual(json["model"] as? String, "gpt-5.6-sol")
		XCTAssertEqual(json["stream"] as? Bool, false)
		XCTAssertEqual(json["reasoning_effort"] as? String, "xhigh")
		let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
		XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
		XCTAssertEqual(messages.map { $0["content"] as? String }, ["system", "shared"])
		XCTAssertNil(json["pairID"])
		XCTAssertNil(json["lane"])
	}

	func testRequestOmitsReasoningAndAuthorizationWhenUnconfigured() throws {
		let configuration = try HeadlessOracleConfiguration(
			endpoint: XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions")),
			primaryModel: "gpt-5.6-sol",
			secondaryModel: "secondary"
		)
		let request = HeadlessOracleProviderRequest(
			pairID: UUID(),
			lane: .secondary,
			model: "openrouter/team:gpt-5.6-sol[variant=secondary]",
			reasoningEffort: nil,
			systemPrompt: "system",
			userPrompt: "shared"
		)
		let encoded = try OpenAICompatibleOracleProvider.makeURLRequest(request, configuration: configuration)
		let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(encoded.httpBody)) as? [String: Any])
		XCTAssertEqual(json["model"] as? String, "openrouter/team:gpt-5.6-sol[variant=secondary]")
		XCTAssertNil(json["reasoning_effort"])
		XCTAssertNil(encoded.value(forHTTPHeaderField: "Authorization"))
	}

	func testSurfSuccessContractPreservesRecoveryMetadata() throws {
		let success = Data(#"{"id":"chatcmpl_fixture_primary","object":"chat.completion","created":1720000000,"model":"gpt-5.6-sol","conversation_id":"conversation-primary","baseline_assistant_message_id":"assistant-baseline-primary","recovery":{"attempted":true,"recovered":true,"source":"fixture"},"choices":[{"index":0,"message":{"role":"assistant","content":"answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}"#.utf8)
		let completion = try OpenAICompatibleOracleProvider.decodeResponse(
			statusCode: 200,
			data: success,
			bearerToken: nil,
			requestID: "chatcmpl_fixture_primary",
			latencyMilliseconds: 321
		)

		XCTAssertEqual(completion.content, "answer")
		XCTAssertEqual(completion.metadata.httpStatus, 200)
		XCTAssertEqual(completion.metadata.latencyMilliseconds, 321)
		XCTAssertEqual(completion.metadata.responseID, "chatcmpl_fixture_primary")
		XCTAssertEqual(completion.metadata.requestID, "chatcmpl_fixture_primary")
		XCTAssertEqual(completion.metadata.observedModelID, "gpt-5.6-sol")
		XCTAssertEqual(completion.metadata.finishReason, "stop")
		XCTAssertEqual(completion.metadata.conversationID, "conversation-primary")
		XCTAssertEqual(completion.metadata.baselineAssistantMessageID, "assistant-baseline-primary")
		XCTAssertEqual(completion.metadata.usage, .init(promptTokens: 11, completionTokens: 7, totalTokens: 18))
		XCTAssertEqual(completion.metadata.recovery, .object([
			"attempted": .bool(true),
			"recovered": .bool(true),
			"source": .string("fixture")
		]))
	}

	func testSurfErrorContractPreservesStatusBodyRecoveryAndRedactsBearer() throws {
		let rawBody = #"{"error":{"message":"token secret-token rejected","type":"rate_limit_error","param":"reasoning_effort","code":"rate_limited","failure_reason":"active_recovery"},"recovery":{"attempted":true,"source":"secret-token recovery"}}"#
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 429,
				data: Data(rawBody.utf8),
				bearerToken: "secret-token",
				requestID: "chatcmpl_error_fixture",
				retryAfterSeconds: 30,
				latencyMilliseconds: 456
			)
			XCTFail("Expected HTTP error")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertEqual(failure.code, .httpError)
			XCTAssertEqual(failure.httpStatus, 429)
			XCTAssertEqual(failure.latencyMilliseconds, 456)
			XCTAssertEqual(failure.requestID, "chatcmpl_error_fixture")
			XCTAssertEqual(failure.providerError, .init(
				message: "token [REDACTED] rejected",
				type: "rate_limit_error",
				param: "reasoning_effort",
				code: "rate_limited",
				failureReason: "active_recovery"
			))
			let sanitizedBody = try XCTUnwrap(failure.rawErrorBody)
			XCTAssertFalse(sanitizedBody.contains("secret-token"))
			let sanitizedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sanitizedBody.utf8)) as? [String: Any])
			XCTAssertEqual((sanitizedJSON["error"] as? [String: Any])?["message"] as? String, "token [REDACTED] rejected")
			XCTAssertFalse(failure.rawErrorBodyTruncated)
			XCTAssertEqual(failure.recovery, .object([
				"attempted": .bool(true),
				"source": .string("[REDACTED] recovery")
			]))
			XCTAssertEqual(failure.retryable, true)
			XCTAssertEqual(failure.retryAfterSeconds, 30)
			XCTAssertFalse(String(describing: failure).contains("secret-token"))
		}
	}

	func testRawErrorBodyIsBoundedAndTransportFailuresAreRetryable() throws {
		let body = try JSONSerialization.data(withJSONObject: [
			"error": ["message": String(repeating: "x", count: OpenAICompatibleOracleProvider.maximumRawErrorBodyBytes * 2)]
		])
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(statusCode: 502, data: body, bearerToken: nil)
			XCTFail("Expected HTTP error")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertEqual(failure.rawErrorBody?.utf8.count, OpenAICompatibleOracleProvider.maximumRawErrorBodyBytes)
			XCTAssertTrue(failure.rawErrorBodyTruncated)
			XCTAssertEqual(failure.retryable, true)
		}

		let boundarySecret = "secret-token"
		let boundaryBody = String(repeating: "x", count: OpenAICompatibleOracleProvider.maximumRawErrorBodyBytes - 3) + boundarySecret
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 500,
				data: Data(boundaryBody.utf8),
				bearerToken: boundarySecret
			)
			XCTFail("Expected HTTP error")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertNil(failure.rawErrorBody, "Malformed error bodies are omitted when a bearer token prevents credential-safe decoding")
		}

		let escapedBody = Data(#"{"error":{"message":"token \u0073ecret-token rejected"}}"#.utf8)
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 500,
				data: escapedBody,
				bearerToken: boundarySecret
			)
			XCTFail("Expected HTTP error")
		} catch let failure as HeadlessOracleProviderFailure {
			let sanitized = try XCTUnwrap(failure.rawErrorBody)
			XCTAssertFalse(sanitized.contains("secret-token"))
			XCTAssertFalse(sanitized.contains(#"\u0073ecret-token"#))
		}

		let oversizedError = try JSONSerialization.data(withJSONObject: [
			"error": ["message": String(repeating: "z", count: OpenAICompatibleOracleProvider.maximumResponseBytes + 1)],
			"recovery": ["attempted": true]
		])
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(statusCode: 503, data: oversizedError, bearerToken: nil)
			XCTFail("Expected oversized response rejection")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertEqual(failure.code, .invalidResponse)
			XCTAssertEqual(failure.httpStatus, 503)
			XCTAssertNil(failure.rawErrorBody)
			XCTAssertNil(failure.recovery)
		}

		let oversizedRecovery = try JSONSerialization.data(withJSONObject: [
			"error": ["message": "retry later"],
			"recovery": ["detail": String(repeating: "r", count: OpenAICompatibleOracleProvider.maximumRecoveryBytes + 1)]
		])
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(statusCode: 503, data: oversizedRecovery, bearerToken: nil)
			XCTFail("Expected HTTP error")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertEqual(failure.code, .httpError)
			XCTAssertNil(failure.recovery)
		}

		let timeout = OpenAICompatibleOracleProvider.transportFailure(for: URLError(.timedOut), latencyMilliseconds: 900)
		XCTAssertEqual(timeout.code, .timeout)
		XCTAssertEqual(timeout.latencyMilliseconds, 900)
		XCTAssertEqual(timeout.retryable, true)
		let network = OpenAICompatibleOracleProvider.transportFailure(for: URLError(.cannotConnectToHost))
		XCTAssertEqual(network.code, .networkError)
		XCTAssertEqual(network.retryable, true)
		let permanent = OpenAICompatibleOracleProvider.transportFailure(for: URLError(.serverCertificateUntrusted))
		XCTAssertEqual(permanent.retryable, false)
	}

	func testMalformedRequiredAndOptionalMetadataBehavior() throws {
		for data in [Data("not-json".utf8), Data(#"{"choices":[]}"#.utf8)] {
			XCTAssertThrowsError(try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 200,
				data: data,
				bearerToken: nil
			)) { error in
				XCTAssertEqual((error as? HeadlessOracleProviderFailure)?.code, .invalidResponse)
			}
		}

		let malformedOptional = Data(#"{"id":42,"model":false,"choices":[{"message":{"content":"answer"},"finish_reason":7}],"usage":{"prompt_tokens":-1,"completion_tokens":1.5,"total_tokens":2}}"#.utf8)
		let completion = try OpenAICompatibleOracleProvider.decodeResponse(
			statusCode: 200,
			data: malformedOptional,
			bearerToken: nil
		)
		XCTAssertEqual(completion.content, "answer")
		XCTAssertNil(completion.metadata.responseID)
		XCTAssertNil(completion.metadata.observedModelID)
		XCTAssertNil(completion.metadata.finishReason)
		XCTAssertEqual(completion.metadata.usage, .init(promptTokens: nil, completionTokens: nil, totalTokens: 2))

		let missingContent = Data(#"{"id":"chatcmpl-missing","model":"gpt-5.6-sol","conversation_id":"conversation-missing","recovery":{"attempted":true},"choices":[{"message":{},"finish_reason":"stop"}]}"#.utf8)
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 200,
				data: missingContent,
				bearerToken: nil,
				requestID: "chatcmpl-missing",
				latencyMilliseconds: 12
			)
			XCTFail("Expected invalid response")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertEqual(failure.providerMetadata?.responseID, "chatcmpl-missing")
			XCTAssertEqual(failure.providerMetadata?.conversationID, "conversation-missing")
			XCTAssertEqual(failure.providerMetadata?.recovery, .object(["attempted": .bool(true)]))
		}

		let redactedSuccess = Data(#"{"choices":[{"message":{"content":"secret-token"}}]}"#.utf8)
		XCTAssertEqual(
			try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 200,
				data: redactedSuccess,
				bearerToken: "secret-token"
			).content,
			"[REDACTED]"
		)

		let oversized = Data(repeating: 0x20, count: OpenAICompatibleOracleProvider.maximumResponseBytes + 1)
		XCTAssertThrowsError(try OpenAICompatibleOracleProvider.decodeResponse(
			statusCode: 200,
			data: oversized,
			bearerToken: nil
		)) { error in
			XCTAssertEqual((error as? HeadlessOracleProviderFailure)?.code, .invalidResponse)
		}
	}

	func testSurfHeaderContractPreservesRequestIDAndNumericRetryAfter() throws {
		let token = String(repeating: "t", count: OpenAICompatibleOracleProvider.maximumProviderStringBytes + 100)
		let response = try XCTUnwrap(HTTPURLResponse(
			url: XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions")),
			statusCode: 429,
			httpVersion: "HTTP/1.1",
			headerFields: ["X-Request-ID": token, "Retry-After": " 30 "]
		))
		XCTAssertEqual(OpenAICompatibleOracleProvider.requestID(from: response), token)
		XCTAssertEqual(OpenAICompatibleOracleProvider.retryAfterSeconds(from: response), 30)

		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 429,
				data: Data(#"{"error":{"message":"rate limited"}}"#.utf8),
				bearerToken: token,
				requestID: OpenAICompatibleOracleProvider.requestID(from: response),
				retryAfterSeconds: OpenAICompatibleOracleProvider.retryAfterSeconds(from: response)
			)
			XCTFail("Expected HTTP error")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertEqual(failure.requestID, "[REDACTED]")
			XCTAssertEqual(failure.retryAfterSeconds, 30)
		}
	}

	func testOversizedChunkedSuccessAndErrorBodiesAreCancelledAtStreamingCap() async throws {
		OversizedChunkedURLProtocol.reset()
		for statusCode in [200, 503] {
			let endpoint = try XCTUnwrap(URL(
				string: "https://chunked-provider.example/\(statusCode)"
			))
			let configuration = try HeadlessOracleConfiguration(
				endpoint: endpoint,
				primaryModel: "primary",
				secondaryModel: "secondary"
			)
			let sessionConfiguration = URLSessionConfiguration.ephemeral
			sessionConfiguration.protocolClasses = [OversizedChunkedURLProtocol.self]
			let injectedSession = URLSession(configuration: sessionConfiguration)
			defer { injectedSession.invalidateAndCancel() }
			let provider = OpenAICompatibleOracleProvider(
				configuration: configuration,
				session: injectedSession
			)

			do {
				_ = try await provider.complete(providerRequest(model: "primary"))
				XCTFail("Expected the chunked response to exceed the streaming cap.")
			} catch let failure as HeadlessOracleProviderFailure {
				XCTAssertEqual(failure.code, .invalidResponse)
				XCTAssertEqual(failure.httpStatus, statusCode)
				XCTAssertEqual(failure.requestID, "chunked-\(statusCode)")
				XCTAssertEqual(failure.message, "Oracle provider response exceeded 2 MiB.")
			}
		}
		XCTAssertEqual(OversizedChunkedURLProtocol.stopCount, 2)
		XCTAssertLessThan(
			OversizedChunkedURLProtocol.deliveredBytes,
			4 * OpenAICompatibleOracleProvider.maximumResponseBytes,
			"The provider must cancel each chunked transfer instead of consuming the complete fixture."
		)
	}

	func testCancellingProviderTaskCancelsStreamingTransport() async throws {
		OversizedChunkedURLProtocol.reset()
		let configuration = try HeadlessOracleConfiguration(
			endpoint: XCTUnwrap(URL(string: "https://chunked-provider.example/200")),
			primaryModel: "primary",
			secondaryModel: "secondary"
		)
		let sessionConfiguration = URLSessionConfiguration.ephemeral
		sessionConfiguration.protocolClasses = [OversizedChunkedURLProtocol.self]
		let injectedSession = URLSession(configuration: sessionConfiguration)
		defer { injectedSession.invalidateAndCancel() }
		let provider = OpenAICompatibleOracleProvider(
			configuration: configuration,
			session: injectedSession
		)
		let operation = Task {
			try await provider.complete(providerRequest(model: "primary"))
		}
		try await Task.sleep(nanoseconds: 5_000_000)
		operation.cancel()

		do {
			_ = try await operation.value
			XCTFail("Expected cancellation.")
		} catch is CancellationError {
			// Expected.
		}
		XCTAssertEqual(OversizedChunkedURLProtocol.stopCount, 1)
	}

	private func providerRequest(model: String) -> HeadlessOracleProviderRequest {
		HeadlessOracleProviderRequest(
			pairID: UUID(),
			lane: .primary,
			model: model,
			reasoningEffort: nil,
			systemPrompt: "system",
			userPrompt: "user"
		)
	}
}

private final class OversizedChunkedURLProtocol: URLProtocol {
	private static let stateLock = NSLock()
	private static var storedStopCount = 0
	private static var storedDeliveredBytes = 0

	private let instanceLock = NSLock()
	private var stopped = false
	private let deliveryQueue = DispatchQueue(label: "RepoPromptHeadlessTests.OversizedChunkedURLProtocol")
	private let chunk = Data(repeating: 0x78, count: 64 * 1_024)
	private var remainingChunks = 64

	static var stopCount: Int {
		stateLock.lock()
		defer { stateLock.unlock() }
		return storedStopCount
	}

	static var deliveredBytes: Int {
		stateLock.lock()
		defer { stateLock.unlock() }
		return storedDeliveredBytes
	}

	static func reset() {
		stateLock.lock()
		storedStopCount = 0
		storedDeliveredBytes = 0
		stateLock.unlock()
	}

	override class func canInit(with request: URLRequest) -> Bool {
		request.url?.host == "chunked-provider.example"
	}

	override class func canonicalRequest(for request: URLRequest) -> URLRequest {
		request
	}

	override func startLoading() {
		deliveryQueue.async { [self] in
			guard !isStopped else { return }
			let statusCode = Int(request.url?.lastPathComponent ?? "") ?? 200
			guard let response = HTTPURLResponse(
				url: request.url!,
				statusCode: statusCode,
				httpVersion: "HTTP/1.1",
				headerFields: [
					"Content-Type": "application/json",
					"Transfer-Encoding": "chunked",
					"X-Request-ID": "chunked-\(statusCode)"
				]
			) else {
				client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
				return
			}
			client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
			deliverNextChunk()
		}
	}

	override func stopLoading() {
		instanceLock.lock()
		let wasStopped = stopped
		stopped = true
		instanceLock.unlock()
		if !wasStopped {
			Self.stateLock.lock()
			Self.storedStopCount += 1
			Self.stateLock.unlock()
		}
	}

	private var isStopped: Bool {
		instanceLock.lock()
		defer { instanceLock.unlock() }
		return stopped
	}

	private func deliverNextChunk() {
		guard !isStopped else { return }
		guard remainingChunks > 0 else {
			client?.urlProtocolDidFinishLoading(self)
			return
		}
		remainingChunks -= 1
		client?.urlProtocol(self, didLoad: chunk)
		Self.stateLock.lock()
		Self.storedDeliveredBytes += chunk.count
		Self.stateLock.unlock()
		deliveryQueue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
			deliverNextChunk()
		}
	}
}
