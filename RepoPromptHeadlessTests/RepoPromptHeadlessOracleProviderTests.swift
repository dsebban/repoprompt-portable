import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessOracleProviderTests: XCTestCase {
	func testRequestCodecUsesExactEndpointHeadersAndOpenAIChatShape() throws {
		let endpoint = try XCTUnwrap(URL(string: "https://provider.example/custom/chat?tenant=one"))
		let configuration = try HeadlessOracleConfiguration(
			endpoint: endpoint,
			primaryModel: "primary",
			secondaryModel: "secondary",
			bearerToken: "secret-token",
			timeoutSeconds: 33
		)
		let pairID = UUID()
		let request = HeadlessOracleProviderRequest(
			pairID: pairID,
			lane: .primary,
			model: "primary",
			systemPrompt: "system",
			userPrompt: "shared"
		)

		let encoded = try OpenAICompatibleOracleProvider.makeURLRequest(request, configuration: configuration)
		XCTAssertEqual(encoded.url, endpoint)
		XCTAssertEqual(encoded.httpMethod, "POST")
		XCTAssertEqual(encoded.timeoutInterval, 33)
		XCTAssertEqual(encoded.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
		XCTAssertEqual(encoded.value(forHTTPHeaderField: "Content-Type"), "application/json")
		let body = try XCTUnwrap(encoded.httpBody)
		let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
		XCTAssertEqual(json["model"] as? String, "primary")
		XCTAssertEqual(json["stream"] as? Bool, false)
		let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
		XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
		XCTAssertEqual(messages.map { $0["content"] as? String }, ["system", "shared"])
		XCTAssertNil(json["pairID"])
		XCTAssertNil(json["lane"])
	}

	func testResponseCodecAndErrorMapping() throws {
		let success = Data(#"{"choices":[{"message":{"content":"answer"}}]}"#.utf8)
		XCTAssertEqual(
			try OpenAICompatibleOracleProvider.decodeResponse(statusCode: 200, data: success, bearerToken: nil),
			"answer"
		)

		let timeout = OpenAICompatibleOracleProvider.transportFailure(for: URLError(.timedOut))
		XCTAssertEqual(timeout.code, .timeout)
		let network = OpenAICompatibleOracleProvider.transportFailure(for: URLError(.cannotConnectToHost))
		XCTAssertEqual(network.code, .networkError)

		let errorBody = Data(#"{"error":{"message":"token secret-token rejected"}}"#.utf8)
		do {
			_ = try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 401,
				data: errorBody,
				bearerToken: "secret-token"
			)
			XCTFail("Expected HTTP error")
		} catch let failure as HeadlessOracleProviderFailure {
			XCTAssertEqual(failure.code, .httpError)
			XCTAssertEqual(failure.httpStatus, 401)
			XCTAssertFalse(failure.message.contains("secret-token"))
			XCTAssertTrue(failure.message.contains("[REDACTED]"))
		}
	}

	func testMalformedMissingAndOversizedResponsesAreRejected() {
		for data in [Data("not-json".utf8), Data(#"{"choices":[]}"#.utf8)] {
			XCTAssertThrowsError(try OpenAICompatibleOracleProvider.decodeResponse(
				statusCode: 200,
				data: data,
				bearerToken: nil
			)) { error in
				XCTAssertEqual((error as? HeadlessOracleProviderFailure)?.code, .invalidResponse)
			}
		}
		let oversized = Data(repeating: 0x20, count: OpenAICompatibleOracleProvider.maximumResponseBytes + 1)
		XCTAssertThrowsError(try OpenAICompatibleOracleProvider.decodeResponse(
			statusCode: 200,
			data: oversized,
			bearerToken: nil
		)) { error in
			XCTAssertEqual((error as? HeadlessOracleProviderFailure)?.code, .invalidResponse)
		}
	}
}
