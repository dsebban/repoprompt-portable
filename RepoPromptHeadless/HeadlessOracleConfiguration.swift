import Foundation

public struct HeadlessOracleConfiguration: Equatable, Sendable {
	public static let defaultTimeoutSeconds = 120
	public static let timeoutRange = 1 ... 3_600
	public static let openCodeGoEndpoint = URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!
	public static let openCodeGoModel = "deepseek-v4-flash"

	public let endpoint: URL
	public let primaryModel: String
	public let secondaryModel: String
	public let bearerToken: String?
	public let timeoutSeconds: Int
	public let reasoningEffort: String?

	public init(
		endpoint: URL,
		primaryModel: String,
		secondaryModel: String,
		bearerToken: String? = nil,
		timeoutSeconds: Int = defaultTimeoutSeconds,
		reasoningEffort: String? = nil
	) throws {
		try Self.validate(endpoint: endpoint)
		self.endpoint = endpoint
		self.primaryModel = try Self.validatedModel(primaryModel, name: "Primary")
		self.secondaryModel = try Self.validatedModel(secondaryModel, name: "Secondary")
		guard Self.timeoutRange.contains(timeoutSeconds) else {
			throw HeadlessRuntimeError(
				"REPOPROMPT_ORACLE_TIMEOUT_SECONDS must be between 1 and 3600.",
				exitCode: .configuration
			)
		}
		self.bearerToken = bearerToken.flatMap { token in token.isEmpty ? nil : token }
		self.timeoutSeconds = timeoutSeconds
		self.reasoningEffort = try Self.validatedReasoningEffort(reasoningEffort)
	}

	public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> HeadlessOracleConfiguration? {
		let endpointValue = environment["REPOPROMPT_ORACLE_ENDPOINT"]
		let primaryValue = environment["REPOPROMPT_ORACLE_PRIMARY_MODEL"]
		let secondaryValue = environment["REPOPROMPT_ORACLE_SECONDARY_MODEL"]

		guard endpointValue != nil || primaryValue != nil || secondaryValue != nil else {
			guard let apiKey = nonempty(environment["OPENCODE_API_KEY"]) else {
				return nil
			}
			return try HeadlessOracleConfiguration(
				endpoint: openCodeGoEndpoint,
				primaryModel: openCodeGoModel,
				secondaryModel: openCodeGoModel,
				bearerToken: apiKey,
				timeoutSeconds: try resolvedTimeout(environment),
				reasoningEffort: environment["REPOPROMPT_ORACLE_REASONING_EFFORT"]
			)
		}
		guard
			let endpointString = nonempty(endpointValue),
			let primaryModel = nonempty(primaryValue),
			let secondaryModel = nonempty(secondaryValue),
			let endpoint = URL(string: endpointString)
		else {
			throw HeadlessRuntimeError(
				"Oracle configuration requires REPOPROMPT_ORACLE_ENDPOINT, REPOPROMPT_ORACLE_PRIMARY_MODEL, and REPOPROMPT_ORACLE_SECONDARY_MODEL.",
				exitCode: .configuration
			)
		}

		return try HeadlessOracleConfiguration(
			endpoint: endpoint,
			primaryModel: primaryModel,
			secondaryModel: secondaryModel,
			bearerToken: environment["REPOPROMPT_ORACLE_API_KEY"],
			timeoutSeconds: try resolvedTimeout(environment),
			reasoningEffort: environment["REPOPROMPT_ORACLE_REASONING_EFFORT"]
		)
	}

	private static func resolvedTimeout(_ environment: [String: String]) throws -> Int {
		guard let rawTimeout = environment["REPOPROMPT_ORACLE_TIMEOUT_SECONDS"] else {
			return defaultTimeoutSeconds
		}
		guard let parsed = Int(rawTimeout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			throw HeadlessRuntimeError(
				"REPOPROMPT_ORACLE_TIMEOUT_SECONDS must be an integer between 1 and 3600.",
				exitCode: .configuration
			)
		}
		return parsed
	}

	private static func nonempty(_ value: String?) -> String? {
		guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}

	private static func validatedReasoningEffort(_ raw: String?) throws -> String? {
		guard let raw else { return nil }
		let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			!value.isEmpty,
			value.utf8.count <= 64,
			!raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
		else {
			throw HeadlessRuntimeError(
				"REPOPROMPT_ORACLE_REASONING_EFFORT must contain 1...64 UTF-8 bytes without control characters.",
				exitCode: .configuration
			)
		}
		return value
	}

	private static func validate(endpoint: URL) throws {
		guard
			let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
			let scheme = components.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			components.host?.isEmpty == false,
			components.user == nil,
			components.password == nil,
			components.fragment == nil
		else {
			throw HeadlessRuntimeError(
				"REPOPROMPT_ORACLE_ENDPOINT must be an absolute http(s) URL without credentials or a fragment.",
				exitCode: .configuration
			)
		}
	}

	private static func validatedModel(_ raw: String, name: String) throws -> String {
		let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !model.isEmpty, model.utf8.count <= 256 else {
			throw HeadlessRuntimeError(
				"\(name) Oracle model ID must contain 1...256 UTF-8 bytes.",
				exitCode: .configuration
			)
		}
		return model
	}
}
