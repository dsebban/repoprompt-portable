import Foundation

public protocol FileSystemProviding: Sendable {
	func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
	func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL]
	func contents(atPath path: String) -> Data?
	func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws
	func removeItem(at url: URL) throws
}

extension FileManager: FileSystemProviding {}
