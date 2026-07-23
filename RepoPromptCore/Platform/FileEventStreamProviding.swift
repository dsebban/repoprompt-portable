import Foundation

public protocol FileEventStreamProviding: Sendable {
	associatedtype Event: Sendable

	var events: AsyncStream<Event> { get }

	func start() async throws
	func stop() async
}
