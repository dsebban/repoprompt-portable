// swift-tools-version: 6.1
import PackageDescription

let package = Package(
	name: "repoprompt-portable",
	platforms: [.macOS(.v13)],
	products: [
		.library(name: "RepoPromptCore", targets: ["RepoPromptCore"]),
		.executable(name: "repoprompt-headless", targets: ["RepoPromptHeadless"])
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
		.executableTarget(
			name: "RepoPromptHeadless",
			dependencies: [
				"RepoPromptCore",
				.product(name: "Logging", package: "swift-log"),
				.product(name: "MCP", package: "swift-sdk")
			],
			path: "RepoPromptHeadless"
		),
		.testTarget(
			name: "RepoPromptHeadlessTests",
			dependencies: ["RepoPromptHeadless"],
			path: "RepoPromptHeadlessTests"
		)
	],
	swiftLanguageModes: [.v5]
)
