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
	case proEdit = "pro_edit"
}

indirect enum HeadlessOracleJSONValue: Codable, Equatable, Sendable {
	case null
	case string(String)
	case int(Int)
	case double(Double)
	case bool(Bool)
	case array([HeadlessOracleJSONValue])
	case object([String: HeadlessOracleJSONValue])

	var objectValue: [String: HeadlessOracleJSONValue]? {
		guard case .object(let value) = self else { return nil }
		return value
	}

	var arrayValue: [HeadlessOracleJSONValue]? {
		guard case .array(let value) = self else { return nil }
		return value
	}

	var stringValue: String? {
		guard case .string(let value) = self else { return nil }
		return value
	}

	var nonnegativeIntValue: Int? {
		guard case .int(let value) = self, value >= 0 else { return nil }
		return value
	}

	func redacted(token: String?) -> HeadlessOracleJSONValue {
		switch self {
		case .null, .int, .double, .bool:
			return self
		case .string(let value):
			return .string(Self.redacted(value, token: token))
		case .array(let values):
			return .array(values.map { $0.redacted(token: token) })
		case .object(let object):
			var redactedObject: [String: HeadlessOracleJSONValue] = [:]
			for (key, value) in object {
				redactedObject[Self.redacted(key, token: token)] = value.redacted(token: token)
			}
			return .object(redactedObject)
		}
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .string(let value): try container.encode(value)
		case .int(let value): try container.encode(value)
		case .double(let value): try container.encode(value)
		case .bool(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() { self = .null }
		else if let value = try? container.decode(String.self) { self = .string(value) }
		else if let value = try? container.decode(Bool.self) { self = .bool(value) }
		else if let value = try? container.decode(Int.self) { self = .int(value) }
		else if let value = try? container.decode(Double.self) { self = .double(value) }
		else if let value = try? container.decode([HeadlessOracleJSONValue].self) { self = .array(value) }
		else { self = .object(try container.decode([String: HeadlessOracleJSONValue].self)) }
	}

	private static func redacted(_ value: String, token: String?) -> String {
		guard let token, !token.isEmpty else { return value }
		return value.replacingOccurrences(of: token, with: "[REDACTED]")
	}
}

struct HeadlessOracleProviderRequest: Equatable, Sendable {
	let pairID: UUID
	let lane: HeadlessOracleLane
	let model: String
	let reasoningEffort: String?
	let systemPrompt: String
	let userPrompt: String
}

struct HeadlessOracleTokenUsage: Equatable, Sendable {
	let promptTokens: Int?
	let completionTokens: Int?
	let totalTokens: Int?
}

struct HeadlessOracleProviderMetadata: Equatable, Sendable {
	let httpStatus: Int
	let latencyMilliseconds: Int
	let responseID: String?
	let requestID: String?
	let observedModelID: String?
	let finishReason: String?
	let usage: HeadlessOracleTokenUsage?
	let conversationID: String?
	let baselineAssistantMessageID: String?
	let recovery: HeadlessOracleJSONValue?
}

struct HeadlessOracleProviderCompletion: Equatable, Sendable {
	let content: String
	let metadata: HeadlessOracleProviderMetadata
}

struct HeadlessOracleProviderError: Equatable, Sendable {
	let message: String?
	let type: String?
	let param: String?
	let code: String?
	let failureReason: String?
}

protocol HeadlessOracleProvider: Sendable {
	func complete(_ request: HeadlessOracleProviderRequest) async throws -> HeadlessOracleProviderCompletion
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
	let latencyMilliseconds: Int?
	let requestID: String?
	let providerError: HeadlessOracleProviderError?
	let providerMetadata: HeadlessOracleProviderMetadata?
	let rawErrorBody: String?
	let rawErrorBodyTruncated: Bool
	let recovery: HeadlessOracleJSONValue?
	let retryable: Bool?
	let retryAfterSeconds: Int?

	init(
		_ code: HeadlessOracleProviderFailureCode,
		message: String,
		httpStatus: Int? = nil,
		latencyMilliseconds: Int? = nil,
		requestID: String? = nil,
		providerError: HeadlessOracleProviderError? = nil,
		providerMetadata: HeadlessOracleProviderMetadata? = nil,
		rawErrorBody: String? = nil,
		rawErrorBodyTruncated: Bool = false,
		recovery: HeadlessOracleJSONValue? = nil,
		retryable: Bool? = nil,
		retryAfterSeconds: Int? = nil
	) {
		self.code = code
		self.message = message
		self.httpStatus = httpStatus
		self.latencyMilliseconds = latencyMilliseconds
		self.requestID = requestID
		self.providerError = providerError
		self.providerMetadata = providerMetadata
		self.rawErrorBody = rawErrorBody
		self.rawErrorBodyTruncated = rawErrorBodyTruncated
		self.recovery = recovery
		self.retryable = retryable
		self.retryAfterSeconds = retryAfterSeconds
	}
}

actor OpenAICompatibleOracleProvider: HeadlessOracleProvider {
	static let maximumResponseBytes = 2 * 1_024 * 1_024
	static let maximumRawErrorBodyBytes = 16 * 1_024
	static let maximumRecoveryBytes = 16 * 1_024
	static let maximumProviderStringBytes = 1_024

	private let configuration: HeadlessOracleConfiguration
	private let session: URLSession
	private let responseDelegate: HeadlessBoundedResponseDelegate

	init(configuration: HeadlessOracleConfiguration, session: URLSession? = nil) {
		self.configuration = configuration
		let delegate = HeadlessBoundedResponseDelegate()
		let sessionConfiguration: URLSessionConfiguration
		if let session {
			sessionConfiguration = session.configuration
		} else {
			sessionConfiguration = .ephemeral
			sessionConfiguration.timeoutIntervalForRequest = TimeInterval(configuration.timeoutSeconds)
			sessionConfiguration.timeoutIntervalForResource = TimeInterval(configuration.timeoutSeconds)
		}
		self.session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
		responseDelegate = delegate
	}

	func complete(_ request: HeadlessOracleProviderRequest) async throws -> HeadlessOracleProviderCompletion {
		let started = DispatchTime.now().uptimeNanoseconds
		do {
			let urlRequest = try Self.makeURLRequest(request, configuration: configuration)
			let (data, response) = try await responseDelegate.data(
				for: urlRequest,
				using: session,
				maximumBytes: Self.maximumResponseBytes
			)
			let latencyMilliseconds = Self.elapsedMilliseconds(since: started)
			guard let httpResponse = response as? HTTPURLResponse else {
				throw HeadlessOracleProviderFailure(
					.invalidResponse,
					message: "Provider returned a non-HTTP response.",
					latencyMilliseconds: latencyMilliseconds
				)
			}
			return try Self.decodeResponse(
				statusCode: httpResponse.statusCode,
				data: data,
				bearerToken: configuration.bearerToken,
				requestID: Self.requestID(from: httpResponse),
				retryAfterSeconds: Self.retryAfterSeconds(from: httpResponse),
				latencyMilliseconds: latencyMilliseconds
			)
		} catch let failure as HeadlessResponseCollectionFailure {
			let response = failure.response
			throw HeadlessOracleProviderFailure(
				.invalidResponse,
				message: "Oracle provider response exceeded 2 MiB.",
				httpStatus: response?.statusCode,
				latencyMilliseconds: Self.elapsedMilliseconds(since: started),
				requestID: Self.boundedRedacted(
					response.flatMap(Self.requestID(from:)),
					token: configuration.bearerToken
				)
			)
		} catch is CancellationError {
			throw CancellationError()
		} catch let failure as HeadlessOracleProviderFailure {
			throw failure
		} catch let error as URLError {
			if Task.isCancelled || error.code == .cancelled {
				throw CancellationError()
			}
			throw Self.transportFailure(
				for: error,
				latencyMilliseconds: Self.elapsedMilliseconds(since: started)
			)
		} catch {
			if Task.isCancelled { throw CancellationError() }
			throw HeadlessOracleProviderFailure(
				.networkError,
				message: "Oracle provider network request failed.",
				latencyMilliseconds: Self.elapsedMilliseconds(since: started),
				retryable: false
			)
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
			let reasoningEffort: String?

			enum CodingKeys: String, CodingKey {
				case model, messages, stream
				case reasoningEffort = "reasoning_effort"
			}
		}

		var urlRequest = URLRequest(url: configuration.endpoint)
		urlRequest.httpMethod = "POST"
		urlRequest.timeoutInterval = TimeInterval(configuration.timeoutSeconds)
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
		urlRequest.setValue("RepoPromptHeadless/\(PortableContract.softwareVersion)", forHTTPHeaderField: "User-Agent")
		if let token = configuration.bearerToken {
			urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}
		urlRequest.httpBody = try JSONEncoder().encode(Body(
			model: request.model,
			messages: [
				Message(role: "system", content: request.systemPrompt),
				Message(role: "user", content: request.userPrompt)
			],
			stream: false,
			reasoningEffort: request.reasoningEffort
		))
		return urlRequest
	}

	static func transportFailure(
		for error: URLError,
		latencyMilliseconds: Int? = nil
	) -> HeadlessOracleProviderFailure {
		if error.code == .timedOut {
			return HeadlessOracleProviderFailure(
				.timeout,
				message: "Oracle provider request timed out.",
				latencyMilliseconds: latencyMilliseconds,
				retryable: true
			)
		}
		let retryable = switch error.code {
		case .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable:
			true
		default:
			false
		}
		return HeadlessOracleProviderFailure(
			.networkError,
			message: "Oracle provider network request failed.",
			latencyMilliseconds: latencyMilliseconds,
			retryable: retryable
		)
	}

	static func decodeResponse(
		statusCode: Int,
		data: Data,
		bearerToken: String?,
		requestID: String? = nil,
		retryAfterSeconds: Int? = nil,
		latencyMilliseconds: Int = 0
	) throws -> HeadlessOracleProviderCompletion {
		let safeRequestID = boundedRedacted(requestID, token: bearerToken)
		guard data.count <= maximumResponseBytes else {
			throw HeadlessOracleProviderFailure(
				.invalidResponse,
				message: "Oracle provider response exceeded 2 MiB.",
				httpStatus: statusCode,
				latencyMilliseconds: latencyMilliseconds,
				requestID: safeRequestID
			)
		}

		if !(200 ... 299).contains(statusCode) {
			let decoded = try? JSONDecoder().decode(HeadlessOracleJSONValue.self, from: data)
			let object = decoded?.objectValue
			let providerObject = object?["error"]?.objectValue
			let providerError = HeadlessOracleProviderError(
				message: boundedRedacted(providerObject?["message"]?.stringValue, token: bearerToken),
				type: boundedRedacted(providerObject?["type"]?.stringValue, token: bearerToken),
				param: boundedRedacted(providerObject?["param"]?.stringValue, token: bearerToken),
				code: boundedRedacted(providerObject?["code"]?.stringValue, token: bearerToken),
				failureReason: boundedRedacted(providerObject?["failure_reason"]?.stringValue, token: bearerToken)
			)
			let message = providerError.message ?? "Oracle provider returned HTTP \(statusCode)."
			let rawBodySource: String?
			if let decoded {
				let sanitized = decoded.redacted(token: bearerToken)
				let encoder = JSONEncoder()
				encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
				rawBodySource = try? String(decoding: encoder.encode(sanitized), as: UTF8.self)
			} else if bearerToken == nil {
				rawBodySource = String(decoding: data, as: UTF8.self)
			} else {
				rawBodySource = nil
			}
			let rawBody = rawBodySource.map { boundedUTF8($0, maximumBytes: maximumRawErrorBodyBytes) }
			throw HeadlessOracleProviderFailure(
				.httpError,
				message: message,
				httpStatus: statusCode,
				latencyMilliseconds: latencyMilliseconds,
				requestID: safeRequestID,
				providerError: providerError,
				rawErrorBody: rawBody,
				rawErrorBodyTruncated: (rawBodySource?.utf8.count ?? data.count) > maximumRawErrorBodyBytes,
				recovery: boundedRecovery(object?["recovery"], token: bearerToken),
				retryable: [408, 425, 429, 500, 502, 503, 504].contains(statusCode),
				retryAfterSeconds: retryAfterSeconds
			)
		}

		do {
			let decoded = try JSONDecoder().decode(HeadlessOracleJSONValue.self, from: data)
			guard let object = decoded.objectValue else {
				throw HeadlessOracleProviderFailure(
					.invalidResponse,
					message: "Oracle provider returned an invalid chat-completions response.",
					httpStatus: statusCode,
					latencyMilliseconds: latencyMilliseconds,
					requestID: safeRequestID
				)
			}
			let firstChoice = object["choices"]?.arrayValue?.first?.objectValue
			let usageObject = object["usage"]?.objectValue
			let usage = usageObject.map {
				HeadlessOracleTokenUsage(
					promptTokens: $0["prompt_tokens"]?.nonnegativeIntValue,
					completionTokens: $0["completion_tokens"]?.nonnegativeIntValue,
					totalTokens: $0["total_tokens"]?.nonnegativeIntValue
				)
			}
			let metadata = HeadlessOracleProviderMetadata(
				httpStatus: statusCode,
				latencyMilliseconds: max(0, latencyMilliseconds),
				responseID: boundedRedacted(object["id"]?.stringValue, token: bearerToken),
				requestID: safeRequestID,
				observedModelID: boundedRedacted(object["model"]?.stringValue, token: bearerToken),
				finishReason: boundedRedacted(firstChoice?["finish_reason"]?.stringValue, token: bearerToken),
				usage: usage,
				conversationID: boundedRedacted(object["conversation_id"]?.stringValue, token: bearerToken),
				baselineAssistantMessageID: boundedRedacted(object["baseline_assistant_message_id"]?.stringValue, token: bearerToken),
				recovery: boundedRecovery(object["recovery"], token: bearerToken)
			)
			guard
				let message = firstChoice?["message"]?.objectValue,
				let content = message["content"]?.stringValue
			else {
				throw HeadlessOracleProviderFailure(
					.invalidResponse,
					message: "Oracle provider response contained no completion choice.",
					httpStatus: statusCode,
					latencyMilliseconds: latencyMilliseconds,
					requestID: safeRequestID,
					providerMetadata: metadata
				)
			}
			return HeadlessOracleProviderCompletion(
				content: redacted(content, token: bearerToken),
				metadata: metadata
			)
		} catch let failure as HeadlessOracleProviderFailure {
			throw failure
		} catch {
			throw HeadlessOracleProviderFailure(
				.invalidResponse,
				message: "Oracle provider returned an invalid chat-completions response.",
				httpStatus: statusCode,
				latencyMilliseconds: latencyMilliseconds,
				requestID: safeRequestID
			)
		}
	}

	static func requestID(from response: HTTPURLResponse) -> String? {
		response.value(forHTTPHeaderField: "X-Request-ID") ?? response.value(forHTTPHeaderField: "Request-ID")
	}

	static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
		guard
			let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
			let seconds = Int(value),
			seconds >= 0
		else { return nil }
		return seconds
	}

	private static func elapsedMilliseconds(since started: UInt64) -> Int {
		let now = DispatchTime.now().uptimeNanoseconds
		guard now >= started else { return 0 }
		return Int(min((now - started) / 1_000_000, UInt64(Int.max)))
	}

	private static func bounded(_ value: String?) -> String? {
		guard let value else { return nil }
		guard value.utf8.count > maximumProviderStringBytes else { return value }
		return boundedUTF8(value, maximumBytes: maximumProviderStringBytes)
	}

	private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
		let data = Data(value.utf8.prefix(maximumBytes))
		if let exact = String(data: data, encoding: .utf8) { return exact }
		var bytes = data
		while !bytes.isEmpty {
			bytes.removeLast()
			if let exact = String(data: bytes, encoding: .utf8) { return exact }
		}
		return ""
	}

	private static func boundedRedacted(_ value: String?, token: String?) -> String? {
		bounded(value.map { redacted($0, token: token) })
	}

	private static func boundedRecovery(_ value: HeadlessOracleJSONValue?, token: String?) -> HeadlessOracleJSONValue? {
		guard let value else { return nil }
		let redacted = value.redacted(token: token)
		guard
			let encoded = try? JSONEncoder().encode(redacted),
			encoded.count <= maximumRecoveryBytes
		else { return nil }
		return redacted
	}

	private static func redacted(_ message: String, token: String?) -> String {
		guard let token, !token.isEmpty else { return message }
		return message.replacingOccurrences(of: token, with: "[REDACTED]")
	}
}

private struct HeadlessResponseCollectionFailure: Error {
	let response: HTTPURLResponse?
}

private final class HeadlessBoundedResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private struct State {
		let continuation: CheckedContinuation<(Data, URLResponse), Error>
		let maximumBytes: Int
		var data = Data()
		var response: URLResponse?
		var exceededLimit = false
	}

	private let lock = NSLock()
	private var states: [Int: State] = [:]

	func data(
		for request: URLRequest,
		using session: URLSession,
		maximumBytes: Int
	) async throws -> (Data, URLResponse) {
		let taskBox = HeadlessURLSessionTaskBox()
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				let task = session.dataTask(with: request)
				lock.lock()
				states[task.taskIdentifier] = State(
					continuation: continuation,
					maximumBytes: maximumBytes
				)
				lock.unlock()
				taskBox.install(task)
				task.resume()
			}
		} onCancel: {
			taskBox.cancel()
		}
	}

	func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive response: URLResponse,
		completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
	) {
		var shouldCancel = false
		lock.lock()
		if var state = states[dataTask.taskIdentifier] {
			state.response = response
			if response.expectedContentLength > Int64(state.maximumBytes) {
				state.exceededLimit = true
				shouldCancel = true
			} else if response.expectedContentLength > 0 {
				state.data.reserveCapacity(Int(response.expectedContentLength))
			}
			states[dataTask.taskIdentifier] = state
		}
		lock.unlock()
		completionHandler(shouldCancel ? .cancel : .allow)
	}

	func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive data: Data
	) {
		var shouldCancel = false
		lock.lock()
		if var state = states[dataTask.taskIdentifier], !state.exceededLimit {
			if data.count > state.maximumBytes - state.data.count {
				state.exceededLimit = true
				shouldCancel = true
			} else {
				state.data.append(data)
			}
			states[dataTask.taskIdentifier] = state
		}
		lock.unlock()
		if shouldCancel {
			dataTask.cancel()
		}
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		didCompleteWithError error: Error?
	) {
		lock.lock()
		let state = states.removeValue(forKey: task.taskIdentifier)
		lock.unlock()
		guard let state else { return }
		if state.exceededLimit {
			state.continuation.resume(throwing: HeadlessResponseCollectionFailure(
				response: state.response as? HTTPURLResponse
			))
		} else if let error {
			state.continuation.resume(throwing: error)
		} else if let response = state.response {
			state.continuation.resume(returning: (state.data, response))
		} else {
			state.continuation.resume(throwing: URLError(.badServerResponse))
		}
	}

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

private final class HeadlessURLSessionTaskBox: @unchecked Sendable {
	private let lock = NSLock()
	private var task: URLSessionTask?
	private var cancelled = false

	func install(_ task: URLSessionTask) {
		lock.lock()
		self.task = task
		let shouldCancel = cancelled
		lock.unlock()
		if shouldCancel {
			task.cancel()
		}
	}

	func cancel() {
		lock.lock()
		cancelled = true
		let task = task
		lock.unlock()
		task?.cancel()
	}
}
