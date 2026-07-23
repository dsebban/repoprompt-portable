import Foundation

public enum HeadlessExitCode: Int32, Sendable {
	case success = 0
	case usage = 64
	case configuration = 78
	case runtime = 70
}

public struct HeadlessRuntimeError: Error, CustomStringConvertible, Sendable {
	public let exitCode: HeadlessExitCode
	public let message: String

	public init(_ message: String, exitCode: HeadlessExitCode) {
		self.message = message
		self.exitCode = exitCode
	}

	public var description: String { message }
}
