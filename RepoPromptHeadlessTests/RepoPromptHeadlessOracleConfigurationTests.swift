import Foundation
@testable import RepoPromptHeadless
import XCTest

final class RepoPromptHeadlessOracleConfigurationTests: XCTestCase {
	func testEnvironmentOnlyConfigurationAllowsSameModelsAndExactEndpoint() throws {
		let endpoint = "https://provider.example/v1/chat/completions?tenant=one"
		let configuration = try XCTUnwrap(HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_ENDPOINT": endpoint,
			"REPOPROMPT_ORACLE_PRIMARY_MODEL": "same-model",
			"REPOPROMPT_ORACLE_SECONDARY_MODEL": "same-model",
			"REPOPROMPT_ORACLE_API_KEY": "secret",
			"REPOPROMPT_ORACLE_TIMEOUT_SECONDS": "2700",
			"REPOPROMPT_ORACLE_REASONING_EFFORT": " xhigh "
		]))

		XCTAssertEqual(configuration.endpoint.absoluteString, endpoint)
		XCTAssertEqual(configuration.primaryModel, "same-model")
		XCTAssertEqual(configuration.secondaryModel, "same-model")
		XCTAssertEqual(configuration.bearerToken, "secret")
		XCTAssertEqual(configuration.timeoutSeconds, 2700)
		XCTAssertEqual(configuration.reasoningEffort, "xhigh")
	}

	func testConfigurationIsDisabledWhenRequiredValuesAreAbsent() throws {
		XCTAssertNil(try HeadlessOracleConfiguration.resolve(environment: [:]))
		XCTAssertNil(try HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_API_KEY": "unused",
			"REPOPROMPT_ORACLE_REASONING_EFFORT": "xhigh",
			"REPOPROMPT_ORACLE_TIMEOUT_SECONDS": "2700"
		]))
	}

	func testOpenCodeGoDefaultsToDeepSeekV4Flash() throws {
		let configuration = try XCTUnwrap(HeadlessOracleConfiguration.resolve(environment: [
			"OPENCODE_API_KEY": "go-secret",
			"REPOPROMPT_ORACLE_TIMEOUT_SECONDS": "30"
		]))

		XCTAssertEqual(configuration.endpoint, HeadlessOracleConfiguration.openCodeGoEndpoint)
		XCTAssertEqual(configuration.primaryModel, "deepseek-v4-flash")
		XCTAssertEqual(configuration.secondaryModel, "deepseek-v4-flash")
		XCTAssertEqual(configuration.bearerToken, "go-secret")
		XCTAssertEqual(configuration.timeoutSeconds, 30)
	}

	func testLongTimeoutBoundariesAndCompoundModelIDsArePreserved() throws {
		let endpoint = try XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions"))
		for timeout in [601, 2_700, 3_600] {
			let configuration = try HeadlessOracleConfiguration(
				endpoint: endpoint,
				primaryModel: "gpt-5.6-sol",
				secondaryModel: "openrouter/team:gpt-5.6-sol[variant=secondary]",
				timeoutSeconds: timeout,
				reasoningEffort: "xhigh"
			)
			XCTAssertEqual(configuration.timeoutSeconds, timeout)
			XCTAssertEqual(configuration.primaryModel, "gpt-5.6-sol")
			XCTAssertEqual(configuration.secondaryModel, "openrouter/team:gpt-5.6-sol[variant=secondary]")
		}
		XCTAssertThrowsError(try HeadlessOracleConfiguration(
			endpoint: endpoint,
			primaryModel: "gpt-5.6-sol",
			secondaryModel: "secondary",
			timeoutSeconds: 3_601
		))
	}

	func testReasoningEffortRejectsEmptyOversizedAndControlCharacters() throws {
		let endpoint = try XCTUnwrap(URL(string: "https://provider.example/v1/chat/completions"))
		for invalid in ["", "   ", String(repeating: "x", count: 65), "xhigh\n", "xhigh\0"] {
			XCTAssertThrowsError(try HeadlessOracleConfiguration(
				endpoint: endpoint,
				primaryModel: "primary",
				secondaryModel: "secondary",
				reasoningEffort: invalid
			), "Expected rejection for \(invalid.debugDescription)")
		}
	}

	func testPartialAndInvalidConfigurationIsRejected() {
		XCTAssertThrowsError(try HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_ENDPOINT": "https://provider.example/v1/chat/completions",
			"REPOPROMPT_ORACLE_PRIMARY_MODEL": "primary"
		]))
		XCTAssertThrowsError(try HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_ENDPOINT": "file:///tmp/provider",
			"REPOPROMPT_ORACLE_PRIMARY_MODEL": "primary",
			"REPOPROMPT_ORACLE_SECONDARY_MODEL": "secondary"
		]))
		XCTAssertThrowsError(try HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_ENDPOINT": "https://user:pass@provider.example/v1#fragment",
			"REPOPROMPT_ORACLE_PRIMARY_MODEL": "primary",
			"REPOPROMPT_ORACLE_SECONDARY_MODEL": "secondary"
		]))
		XCTAssertThrowsError(try HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_ENDPOINT": "https://provider.example/v1/chat/completions",
			"REPOPROMPT_ORACLE_PRIMARY_MODEL": "primary",
			"REPOPROMPT_ORACLE_SECONDARY_MODEL": "secondary",
			"REPOPROMPT_ORACLE_TIMEOUT_SECONDS": "0"
		]))
		XCTAssertThrowsError(try HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_ENDPOINT": "https://provider.example/v1/chat/completions",
			"REPOPROMPT_ORACLE_PRIMARY_MODEL": String(repeating: "é", count: 129),
			"REPOPROMPT_ORACLE_SECONDARY_MODEL": "secondary"
		]))
	}

	func testOracleCLIOptionsRemainRejectedAndUsageDocumentsEnvironment() throws {
		XCTAssertThrowsError(try HeadlessOptions.parse(["--oracle-endpoint", "https://example.test"]))
		let usage = HeadlessOptions.usage(executable: "repoprompt-headless")
		XCTAssertTrue(usage.contains("REPOPROMPT_ORACLE_ENDPOINT"))
		XCTAssertTrue(usage.contains("REPOPROMPT_ORACLE_REASONING_EFFORT"))
		XCTAssertTrue(usage.contains("1...3600"))
		XCTAssertFalse(usage.contains("--oracle-endpoint"))
	}
}
