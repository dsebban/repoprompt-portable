import Foundation
import RepoPromptCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct RepoPromptHeadlessMain {
	static func main() async {
		ignoreSIGPIPE()

		let executable = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "repoprompt-headless"
		do {
			let options = try HeadlessOptions.parse(Array(CommandLine.arguments.dropFirst()))
			if options.help {
				write(HeadlessOptions.usage(executable: executable), to: .standardOutput)
				exit(HeadlessExitCode.success.rawValue)
			}

			let oracleConfiguration = try HeadlessOracleConfiguration.resolve()

			guard !stdioLooksInteractive() else {
				write(HeadlessOptions.usage(executable: executable) + "\n", to: .standardError)
				write("No MCP stdio transport detected; connect stdin/stdout to an MCP host.\n", to: .standardError)
				exit(HeadlessExitCode.usage.rawValue)
			}

			let bootstrap = try await HeadlessWorkspaceBootstrap.bootstrap(options: options)
			let service = HeadlessMCPService(
				options: options,
				bootstrap: bootstrap,
				oracleConfiguration: oracleConfiguration
			)
			try await service.run()
			exit(HeadlessExitCode.success.rawValue)
		} catch let error as HeadlessRuntimeError {
			write("\(error.message)\n", to: .standardError)
			if error.exitCode == .usage {
				write(HeadlessOptions.usage(executable: executable) + "\n", to: .standardError)
			}
			exit(error.exitCode.rawValue)
		} catch {
			write("repoprompt-headless: \(error)\n", to: .standardError)
			exit(HeadlessExitCode.runtime.rawValue)
		}
	}

	private static func ignoreSIGPIPE() {
		#if canImport(Darwin) || canImport(Glibc)
		_ = signal(SIGPIPE, SIG_IGN)
		#endif
	}

	private static func stdioLooksInteractive() -> Bool {
		#if canImport(Darwin) || canImport(Glibc)
		return isatty(STDIN_FILENO) == 1 || isatty(STDOUT_FILENO) == 1
		#else
		return false
		#endif
	}

	private static func write(_ string: String, to handle: FileHandle) {
		handle.write(Data(string.utf8))
	}
}
