import DefaultBackend
import Foundation
import RepoPromptHeadless
import RepoPromptLinuxDesktopKit
import SwiftCrossUI

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct RepoPromptLinuxDesktopApp: App {
	let arguments: DesktopArguments
	let oracleConfiguration: HeadlessOracleConfiguration?

	init() {
		let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "repoprompt-linux-desktop").lastPathComponent
		do {
			let arguments = try DesktopArguments.parse(Array(CommandLine.arguments.dropFirst()))
			if arguments.help {
				print(DesktopArguments.usage(executable: executable))
				exit(HeadlessExitCode.success.rawValue)
			}
#if os(macOS)
			guard arguments.macOSQA else {
				throw DesktopArgumentError("Pass --macos to launch this Linux-first desktop for macOS QA.")
			}
#else
			guard !arguments.macOSQA else {
				throw DesktopArgumentError("--macos is available only on macOS.")
			}
#endif
			self.arguments = arguments
			self.oracleConfiguration = try HeadlessOracleConfiguration.resolve()
		} catch let error as HeadlessRuntimeError {
			Self.fail(error.message, usage: nil, exitCode: error.exitCode.rawValue)
		} catch {
			Self.fail(
				desktopErrorMessage(error),
				usage: DesktopArguments.usage(executable: executable),
				exitCode: HeadlessExitCode.usage.rawValue
			)
		}
	}

	var body: some Scene {
		WindowGroup("RepoPrompt Portable") {
			RootShellView(arguments: arguments, oracleConfiguration: oracleConfiguration)
		}
		.defaultSize(width: 1100, height: 720)
	}

	private static func fail(_ message: String, usage: String?, exitCode: Int32) -> Never {
		let text = ([message, usage].compactMap { $0 }.joined(separator: "\n\n") + "\n")
		FileHandle.standardError.write(Data(text.utf8))
		exit(exitCode)
	}
}
