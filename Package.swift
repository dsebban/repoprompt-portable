// swift-tools-version: 6.1
import PackageDescription

let package = Package(
	name: "repoprompt-portable",
	platforms: [.macOS(.v13)],
	products: [
		.library(name: "RepoPromptCore", targets: ["RepoPromptCore"]),
		.library(name: "RepoPromptHeadless", targets: ["RepoPromptHeadless"]),
		.executable(name: "repoprompt-headless", targets: ["RepoPromptHeadlessServer"]),
		.executable(name: "repoprompt-portable-cli", targets: ["RepoPromptPortableCLI"])
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-log.git", "1.6.3"..<"1.7.0"),
		.package(
			url: "https://github.com/provencher/swift-sdk.git",
			revision: "cb6a62f7c266ed535792b3e9e6e05dc3f0dac8e4"
		),
		.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
		.package(url: "https://github.com/repoprompt/swift-tree-sitter.git", revision: "a778ef4fb7f0d3ad00185f42ce83c688373c4361"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
		.package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-c-sharp.git", exact: "0.23.5"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
		.package(url: "https://github.com/tree-sitter/tree-sitter-php.git", exact: "0.24.2")
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
			name: "TreeSitterScannerSupport",
			path: "TreeSitterScannerSupport",
			sources: ["src/javascript/scanner.c", "src/python/scanner.c"],
			publicHeadersPath: "include"
		),
		.target(
			name: "RepoPromptCodeMap",
			dependencies: [
				"TreeSitterScannerSupport",
				.product(name: "Crypto", package: "swift-crypto"),
				.product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
				.product(name: "TreeSitterC", package: "tree-sitter-c"),
				.product(name: "TreeSitterGo", package: "tree-sitter-go"),
				.product(name: "TreeSitterJava", package: "tree-sitter-java"),
				.product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
				.product(name: "TreeSitterPython", package: "tree-sitter-python"),
				.product(name: "TreeSitterRust", package: "tree-sitter-rust"),
				.product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
				.product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
				.product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
				.product(name: "TreeSitterCSharp", package: "tree-sitter-c-sharp"),
				.product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
				.product(name: "TreeSitterPHP", package: "tree-sitter-php")
			],
			path: "RepoPromptCodeMap"
		),
		.target(
			name: "RepoPromptHeadless",
			dependencies: [
				"RepoPromptCore",
				"RepoPromptCodeMap",
				.product(name: "Crypto", package: "swift-crypto"),
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
			dependencies: ["RepoPromptHeadless", "RepoPromptCodeMap"],
			path: "RepoPromptHeadlessTests",
			resources: [.copy("Fixtures")]
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
