// swift-tools-version: 6.1
import PackageDescription

let package = Package(
	name: "LinuxDesktop",
	platforms: [.macOS(.v13)],
	products: [
		.executable(name: "repoprompt-linux-desktop", targets: ["RepoPromptLinuxDesktop"])
	],
	dependencies: [
		.package(name: "repoprompt-portable", path: ".."),
		.package(url: "https://github.com/stackotter/swift-cross-ui.git", exact: "0.8.0")
	],
	targets: [
		.target(
			name: "RepoPromptLinuxDesktopKit",
			dependencies: [
				.product(name: "RepoPromptHeadless", package: "repoprompt-portable"),
				.product(name: "SwiftCrossUI", package: "swift-cross-ui")
			]
		),
		.executableTarget(
			name: "RepoPromptLinuxDesktop",
			dependencies: [
				"RepoPromptLinuxDesktopKit",
				.product(name: "RepoPromptHeadless", package: "repoprompt-portable"),
				.product(name: "SwiftCrossUI", package: "swift-cross-ui"),
				.product(name: "DefaultBackend", package: "swift-cross-ui")
			]
		),
		.testTarget(
			name: "RepoPromptLinuxDesktopKitTests",
			dependencies: [
				"RepoPromptLinuxDesktopKit",
				.product(name: "RepoPromptHeadless", package: "repoprompt-portable")
			]
		)
	],
	swiftLanguageModes: [.v5]
)
