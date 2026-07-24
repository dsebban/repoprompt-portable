import Foundation
import RepoPromptHeadless

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct RepoPromptPortableCLIMain {
	static func main() async {
		let executable = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "repoprompt-portable-cli"
		let result = await PortableCLIApplication().run(
			arguments: Array(CommandLine.arguments.dropFirst()),
			executable: executable
		)
		write(result.standardOutput, to: .standardOutput)
		write(result.standardError, to: .standardError)
		exit(result.exitCode.rawValue)
	}

	private static func write(_ string: String, to handle: FileHandle) {
		guard !string.isEmpty else { return }
		handle.write(Data(string.utf8))
	}
}
