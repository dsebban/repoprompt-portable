import Foundation

public protocol AppExecutableVerifying: Sendable {
	func isExpectedBundledExecutable(peerPID: Int, executableName: String) -> Bool
}
