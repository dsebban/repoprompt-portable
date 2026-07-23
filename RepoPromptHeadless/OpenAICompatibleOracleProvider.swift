import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum HeadlessOracleLane: String, Equatable, Sendable {
	case primary
	case secondary
}

enum HeadlessOracleMode: String, Equatable, Sendable {
	case chat
	case question
	case plan
	case review
}

struct HeadlessOracleProviderRequest: Equatable, Sendable {
	let pairID: UUID
	let lane: HeadlessOracleLane
	let model: String
	let systemPrompt: String
	let userPrompt: String
}

protocol HeadlessOracleProvider: Sendable {
	func complete(_ request: HeadlessOracleProviderRequest) async throws -> String
}

enum HeadlessOracleProviderFailureCode: String, Equatable, Sendable {
	case timeout
	case networkError = "network_error"
	case httpError = "http_error"
	case invalidResponse = "invalid_response"
}

struct HeadlessOracleProviderFailure: Error, Equatable, Sendable {
	let code: HeadlessOracleProviderFailureCode
	let message: String
	let httpStatus: Int?

	init(_ code: HeadlessOracleProviderFailureCode, message: String, httpStatus: Int? = nil) {
		self.code = code
		self.message = message
		self.httpStatus = httpStatus
	}
}

actor OpenAICompatibleOracleProvider: HeadlessOracleProvider {
	static let maximumResponseBytes = 2 * 1_024 * 1_024

	private let configuration: HeadlessOracleConfiguration
	private let session: URLSession
	private let redirectDelegate: HeadlessRejectRedirectsDelegate?

	init(configuration: HeadlessOracleConfiguration, session: URLSession? = nil) {
		self.configuration = configuration
		if let session {
			self.session = session
			redirectDelegate = nil
		} else {
			let delegate = HeadlessRejectRedirectsDelegate()
			let sessionConfiguration = URLSessionConfiguration.ephemeral
			sessionConfiguration.timeoutIntervalForRequest = TimeInterval(configuration.timeoutSeconds)
			sessionConfiguration.timeoutIntervalForResource = TimeInterval(configuration.timeoutSeconds)
			self.session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
			redirectDelegate = delegate
		}
	}

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> String {
		do {
			let urlRequest = try Self.makeURLRequest(request, configuration: configuration)
			let (data, response) = try await session.data(for: urlRequest)
			guard let httpResponse = response as? HTTPURLResponse else {
				throw HeadlessOracleProviderFailure(.invalidResponse, message: "Provider returned a non-HTTP response.")
			}
			if httpResponse.expectedContentLength > Self.maximumResponseBytes {
				throw HeadlessOracleProviderFailure(.invalidResponse, message: "Oracle provider response exceeded 2 MiB.")
			}
			return try Self.decodeResponse(
				statusCode: httpResponse.statusCode,
				data: data,
				bearerToken: configuration.bearerToken
			)
		} catch is CancellationError {
			throw CancellationError()
		} catch let failure as HeadlessOracleProviderFailure {
			throw failure
		} catch let error as URLError {
			if Task.isCancelled || error.code == .cancelled {
				throw CancellationError()
			}
			throw Self.transportFailure(for: error)
		} catch {
			if Task.isCancelled { throw CancellationError() }
			throw HeadlessOracleProviderFailure(.networkError, message: "Oracle provider network request failed.")
		}
	}

	static func makeURLRequest(
		_ request: HeadlessOracleProviderRequest,
		configuration: HeadlessOracleConfiguration
	) throws -> URLRequest {
		struct Message: Encodable {
			let role: String
			let content: String
		}
		struct Body: Encodable {
			let model: String
			let messages: [Message]
			let stream: Bool
		}

		var urlRequest = URLRequest(url: configuration.endpoint)
		urlRequest.httpMethod = "POST"
		urlRequest.timeoutInterval = TimeInterval(configuration.timeoutSeconds)
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
		urlRequest.setValue("RepoPromptHeadless/0.1.0", forHTTPHeaderField: "User-Agent")
		if let token = configuration.bearerToken {
			urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		urlRequest.httpBody = try JSONEncoder().encode(Body(
			model: request.model,
			messages: [
				Message(role: "system", content: request.systemPrompt),
				Message(role: "user", content: request.userPrompt)
			],
			stream: false
		))
		return urlRequest
	}

	static func transportFailure(for error: URLError) -> HeadlessOracleProviderFailure {
		if error.code == .timedOut {
			return HeadlessOracleProviderFailure(.timeout, message: "Oracle provider request timed out.")
		}
		return HeadlessOracleProviderFailure(.networkError, message: "Oracle provider network request failed.")
	}

	static func decodeResponse(statusCode: Int, data: Data, bearerToken: String?) throws -> String {
		guard data.count <= maximumResponseBytes else {
			throw HeadlessOracleProviderFailure(.invalidResponse, message: "Oracle provider response exceeded 2 MiB.")
		}

		if !(200 ... 299).contains(statusCode) {
			struct ErrorEnvelope: Decodable {
				struct ProviderError: Decodable { let message: String? }
				let error: ProviderError?
			}
			let providerMessage = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
			let message = providerMessage.map {
				redacted(String($0.prefix(1_024)), token: bearerToken)
			} ?? "Oracle provider returned HTTP \(statusCode)."
			throw HeadlessOracleProviderFailure(.httpError, message: message, httpStatus: statusCode)
		}

		struct Response: Decodable {
			struct Choice: Decodable {
				struct Message: Decodable { let content: String }
				let message: Message
			}
			let choices: [Choice]
		}
		do {
			let decoded = try JSONDecoder().decode(Response.self, from: data)
			guard let content = decoded.choices.first?.message.content else {
				throw HeadlessOracleProviderFailure(.invalidResponse, message: "Oracle provider response contained no completion choice.")
			}
			return content
		} catch let failure as HeadlessOracleProviderFailure {
			throw failure
		} catch {
			throw HeadlessOracleProviderFailure(.invalidResponse, message: "Oracle provider returned an invalid chat-completions response.")
		}
	}

	private static func redacted(_ message: String, token: String?) -> String {
		guard let token, !token.isEmpty else { return message }
		return message.replacingOccurrences(of: token, with: "[REDACTED]")
	}
}

private final class HeadlessRejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void
	) {
		completionHandler(nil)
	}
}
