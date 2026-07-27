import Foundation
import Crypto

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum HeadlessSecureFileError: Error {
	case openFailed
	case outsideWorkspace
	case notRegularFile
	case tooLarge(Int)
	case changedDuringRead
}

struct HeadlessSecureFile: Equatable, Sendable {
	let data: Data
	let byteCount: Int
	let canonicalPath: String
	let deviceID: UInt64
	let fileID: UInt64
	let sha256: String
}

enum HeadlessSecureFileReader {
	static func read(path: String, roots: [String], maximumBytes: Int) throws -> HeadlessSecureFile {
		let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
		let realRoots = roots.map {
			URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
		}
		guard realRoots.contains(where: { contains(resolvedPath, root: $0) }) else {
			throw HeadlessSecureFileError.outsideWorkspace
		}
		let descriptor = open(resolvedPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
		guard descriptor >= 0 else { throw HeadlessSecureFileError.openFailed }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		defer { try? handle.close() }

		var info = stat()
		guard fstat(descriptor, &info) == 0 else { throw HeadlessSecureFileError.openFailed }
		guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
			throw HeadlessSecureFileError.notRegularFile
		}
		let openedPath = try resolvedDescriptorPath(descriptor, fallbackPath: resolvedPath)
		guard realRoots.contains(where: { contains(openedPath, root: $0) }) else {
			throw HeadlessSecureFileError.outsideWorkspace
		}
		guard info.st_size >= 0, info.st_size <= Int64(Int.max) else {
			throw HeadlessSecureFileError.tooLarge(Int.max)
		}
		let byteCount = Int(info.st_size)
		guard byteCount <= maximumBytes else { throw HeadlessSecureFileError.tooLarge(byteCount) }
		let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
		guard data.count <= maximumBytes else { throw HeadlessSecureFileError.tooLarge(data.count) }
		var finalInfo = stat()
		guard fstat(descriptor, &finalInfo) == 0 else { throw HeadlessSecureFileError.openFailed }
		guard info.st_dev == finalInfo.st_dev,
			info.st_ino == finalInfo.st_ino,
			info.st_size == finalInfo.st_size,
			data.count == byteCount
		else {
			throw HeadlessSecureFileError.changedDuringRead
		}
		return HeadlessSecureFile(
			data: data,
			byteCount: byteCount,
			canonicalPath: openedPath,
			deviceID: UInt64(info.st_dev),
			fileID: UInt64(info.st_ino),
			sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		)
	}

	private static func resolvedDescriptorPath(_ descriptor: Int32, fallbackPath: String) throws -> String {
		#if os(Linux)
		let path = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(descriptor)")
		return URL(fileURLWithPath: path).standardizedFileURL.path
		#else
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
			throw HeadlessSecureFileError.openFailed
		}
		return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
		#endif
	}

	private static func contains(_ path: String, root: String) -> Bool {
		path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
	}
}
