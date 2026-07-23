import Foundation

public protocol SecureKeyValueStorageBackend: AnyObject {
	var persistsValuesAcrossLaunches: Bool { get }

	func save(_ value: String, for key: String, withIntegrityProtection: Bool) throws
	func get(for key: String, verifyIntegrity: Bool) throws -> String
	func getRawData(for key: String) throws -> Data
	func delete(for key: String) throws
}
