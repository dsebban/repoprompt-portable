import AppKit
import Foundation

let targetExecutableName = "repoprompt-linux-desktop"
let targetBundleParent = "/tmp/repoprompt-classic-pixel-parity/"
let deadline = Date().addingTimeInterval(120)

func targetProcessIdentifiers() -> [pid_t] {
	let process = Process()
	let output = Pipe()
	process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
	process.arguments = ["-x", targetExecutableName]
	process.standardOutput = output
	process.standardError = FileHandle.nullDevice
	do {
		try process.run()
		process.waitUntilExit()
	} catch {
		return []
	}
	let data = output.fileHandleForReading.readDataToEndOfFile()
	let text = String(decoding: data, as: UTF8.self)
	return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
}

while Date() < deadline {
	for processIdentifier in targetProcessIdentifiers() {
		guard let application = NSRunningApplication(processIdentifier: processIdentifier),
		      let executableURL = application.executableURL,
		      executableURL.path.hasPrefix(targetBundleParent)
		else { continue }
		let activated = application.activate(options: [.activateIgnoringOtherApps])
		print("pid=\(processIdentifier) path=\(executableURL.path) activated=\(activated)")
		exit(activated ? 0 : 2)
	}
	Thread.sleep(forTimeInterval: 0.05)
}

fputs("timed out waiting for \(targetExecutableName) under \(targetBundleParent)\n", stderr)
exit(1)
