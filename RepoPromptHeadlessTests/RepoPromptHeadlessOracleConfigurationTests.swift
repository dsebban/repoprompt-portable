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
			"REPOPROMPT_ORACLE_TIMEOUT_SECONDS": "42"
		]))

		XCTAssertEqual(configuration.endpoint.absoluteString, endpoint)
		XCTAssertEqual(configuration.primaryModel, "same-model")
		XCTAssertEqual(configuration.secondaryModel, "same-model")
		XCTAssertEqual(configuration.bearerToken, "secret")
		XCTAssertEqual(configuration.timeoutSeconds, 42)
	}

	func testConfigurationIsDisabledWhenRequiredValuesAreAbsent() throws {
		XCTAssertNil(try HeadlessOracleConfiguration.resolve(environment: [:]))
		XCTAssertNil(try HeadlessOracleConfiguration.resolve(environment: [
			"REPOPROMPT_ORACLE_API_KEY": "unused"
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
		XCTAssertFalse(usage.contains("--oracle-endpoint"))
	}
}
