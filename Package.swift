// swift-tools-version: 6.1
import PackageDescription

let package = Package(
	name: "repoprompt-portable",
	platforms: [.macOS(.v13)],
	products: [
		.library(name: "RepoPromptCore", targets: ["RepoPromptCore"]),
		.executable(name: "repoprompt-headless", targets: ["RepoPromptHeadlessServer"]),
		.executable(name: "repoprompt-portable-cli", targets: ["RepoPromptPortableCLI"])
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-log.git", exact: "1.6.3"),
		.package(
			url: "https://github.com/provencher/swift-sdk.git",
			revision: "cb6a62f7c266ed535792b3e9e6e05dc3f0dac8e4"
		)
	],
	targets: [
		.target(
			name: "RepoPromptCore",
			dependencies: [
				.product(name: "Logging", package: "swift-log"),
				.product(name: "MCP", package: "swift-sdk")
			],
			path: "RepoPromptCore"
		),
		.target(
			name: "RepoPromptHeadless",
			dependencies: [
				"RepoPromptCore",
				.product(name: "Logging", package: "swift-log"),
				.product(name: "MCP", package: "swift-sdk")
			],
			path: "RepoPromptHeadless"
		),
		.executableTarget(
			name: "RepoPromptHeadlessServer",
			dependencies: ["RepoPromptHeadless"],
			path: "RepoPromptHeadlessServer"
		),
		.executableTarget(
			name: "RepoPromptPortableCLI",
			dependencies: [
				"RepoPromptHeadless",
				.product(name: "MCP", package: "swift-sdk")
			],
			path: "RepoPromptPortableCLI"
		),
		.testTarget(
			name: "RepoPromptHeadlessTests",
			dependencies: ["RepoPromptHeadless"],
			path: "RepoPromptHeadlessTests"
		),
		.testTarget(
			name: "RepoPromptPortableCLITests",
			dependencies: [
				"RepoPromptPortableCLI",
				"RepoPromptHeadless",
				.product(name: "MCP", package: "swift-sdk")
			],
			path: "RepoPromptPortableCLITests"
		)
	],
	swiftLanguageModes: [.v5]
)
