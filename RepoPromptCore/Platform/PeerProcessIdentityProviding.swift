import Foundation

public protocol PeerProcessIdentityProviding: Sendable {
	func peerProcessID(forConnectedSocket fd: Int32) -> Int?
	func executablePath(forPID pid: Int) -> String?
}
