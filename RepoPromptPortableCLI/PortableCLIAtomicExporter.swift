import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PortableCLIAtomicExporter {
	public static func write(_ data: Data, to rawPath: String) throws {
		let expanded = (rawPath as NSString).expandingTildeInPath
		let absolute = expanded.hasPrefix("/")
			? expanded
			: (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
		let destination = URL(fileURLWithPath: (absolute as NSString).standardizingPath)
		let name = destination.lastPathComponent
		guard !name.isEmpty, name != ".", name != "..", !rawPath.hasSuffix("/") else {
			throw PortableCLIExportError("Export destination must name a new regular file.")
		}

		let parent = destination.deletingLastPathComponent().path
		let directoryFD = parent.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
		guard directoryFD >= 0 else { throw PortableCLIExportError.posix("open export directory") }
		defer { _ = close(directoryFD) }

		var directoryInfo = stat()
		guard retryOnInterrupt({ fstat(directoryFD, &directoryInfo) }) == 0 else { throw PortableCLIExportError.posix("inspect export directory") }
		let sharedWritable = directoryInfo.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
		let sticky = directoryInfo.st_mode & mode_t(0o1000) != 0
		guard !sharedWritable || sticky else {
			throw PortableCLIExportError("Export directory must not be group/world-writable unless it has the sticky bit.")
		}

		let temporaryName = ".repoprompt-export-\(UUID().uuidString).tmp"
		let fileFD = temporaryName.withCString {
			openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
		}
		guard fileFD >= 0 else { throw PortableCLIExportError.posix("create export temporary file") }
		var expectedIdentity: FileIdentity?
		defer {
			if let expectedIdentity {
				_ = unlinkIfSame(temporaryName, in: directoryFD, identity: expectedIdentity)
			} else {
				_ = temporaryName.withCString { pointer in
					retryOnInterrupt { unlinkat(directoryFD, pointer, 0) }
				}
			}
			_ = close(fileFD)
		}
		let writtenIdentity = try identity(of: fileFD)
		expectedIdentity = writtenIdentity

		var destinationInstalled = false
		do {
			try writeAll(data, to: fileFD)
			guard retryOnInterrupt({ fchmod(fileFD, mode_t(0o600)) }) == 0 else { throw PortableCLIExportError.posix("set export permissions") }
			guard retryOnInterrupt({ fsync(fileFD) }) == 0 else { throw PortableCLIExportError.posix("sync export data") }

			let installed = temporaryName.withCString { temporary in
				name.withCString { destination in
					linkat(directoryFD, temporary, directoryFD, destination, 0)
				}
			}
			guard installed == 0 else { throw PortableCLIExportError.posix("install export without overwrite") }
			destinationInstalled = true
			guard identity(of: name, in: directoryFD) == writtenIdentity else {
				throw PortableCLIExportError("Installed export identity did not match written data.")
			}
			guard unlinkIfSame(temporaryName, in: directoryFD, identity: writtenIdentity) else {
				throw PortableCLIExportError("Export temporary file identity changed before cleanup.")
			}
			guard retryOnInterrupt({ fsync(directoryFD) }) == 0 else { throw PortableCLIExportError.posix("sync export directory") }
		} catch {
			if destinationInstalled {
				_ = unlinkIfSame(name, in: directoryFD, identity: writtenIdentity)
				_ = retryOnInterrupt({ fsync(directoryFD) })
			}
			throw error
		}
	}

	private struct FileIdentity: Equatable {
		let device: dev_t
		let inode: ino_t
	}

	private static func identity(of fileDescriptor: Int32) throws -> FileIdentity {
		var info = stat()
		guard retryOnInterrupt({ fstat(fileDescriptor, &info) }) == 0 else { throw PortableCLIExportError.posix("inspect export temporary file") }
		return FileIdentity(device: info.st_dev, inode: info.st_ino)
	}

	private static func identity(of name: String, in directoryFD: Int32) -> FileIdentity? {
		var info = stat()
		let result = name.withCString { pointer in
			retryOnInterrupt { fstatat(directoryFD, pointer, &info, AT_SYMLINK_NOFOLLOW) }
		}
		guard result == 0 else { return nil }
		return FileIdentity(device: info.st_dev, inode: info.st_ino)
	}

	private static func unlinkIfSame(_ name: String, in directoryFD: Int32, identity expected: FileIdentity) -> Bool {
		guard let current = identity(of: name, in: directoryFD) else { return errno == ENOENT }
		guard current == expected else { return false }
		return name.withCString { pointer in
			retryOnInterrupt { unlinkat(directoryFD, pointer, 0) }
		} == 0
	}

	private static func retryOnInterrupt(_ operation: () -> Int32) -> Int32 {
		var result: Int32
		repeat { result = operation() } while result == -1 && errno == EINTR
		return result
	}

	private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
		try data.withUnsafeBytes { bytes in
			var offset = 0
			while offset < bytes.count {
				let result: Int
				#if canImport(Darwin)
				result = Darwin.write(fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
				#else
				result = Glibc.write(fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
				#endif
				if result < 0, errno == EINTR { continue }
				guard result > 0 else { throw PortableCLIExportError.posix("write export data") }
				offset += result
			}
		}
	}
}

public struct PortableCLIExportError: Error, CustomStringConvertible, Sendable {
	public let message: String

	public init(_ message: String) {
		self.message = message
	}

	static func posix(_ operation: String) -> PortableCLIExportError {
		let code = errno
		return PortableCLIExportError("\(operation) failed: \(String(cString: strerror(code)))")
	}

	public var description: String { message }
}
