//
//  NonBlockingFDWriter.swift
//  repoprompt-mcp
//
//  Bounded no-progress writer for proxy-mode stdout bridging.
//

import Foundation

package enum NonBlockingFDWriteError: Swift.Error, CustomStringConvertible, Equatable, Sendable {
	case cancelled(bytesWritten: Int, totalBytes: Int)
	case brokenPipe(bytesWritten: Int, totalBytes: Int)
	case localTimeout(stallTimeout: TimeInterval, bytesWritten: Int, totalBytes: Int)
	case fcntlFailed(errno: Int32)
	case pollFailed(errno: Int32)
	case writeFailed(errno: Int32, bytesWritten: Int, totalBytes: Int)

	package var provenance: String {
		switch self {
		case .cancelled:
			return "cancelled"
		case .brokenPipe:
			return "broken_pipe"
		case .localTimeout:
			return "local_timeout"
		case .fcntlFailed:
			return "fcntl_failed"
		case .pollFailed:
			return "poll_failed"
		case .writeFailed:
			return "write_failed"
		}
	}

	package var description: String {
		switch self {
		case .cancelled(let bytesWritten, let totalBytes):
			return "write cancelled after \(bytesWritten)/\(totalBytes) bytes"
		case .brokenPipe(let bytesWritten, let totalBytes):
			return "stdout broken pipe after \(bytesWritten)/\(totalBytes) bytes"
		case .localTimeout(let stallTimeout, let bytesWritten, let totalBytes):
			return "stdout write made no progress for \(stallTimeout)s after \(bytesWritten)/\(totalBytes) bytes"
		case .fcntlFailed(let errno):
			return "failed to set non-blocking output mode: \(errno)"
		case .pollFailed(let errno):
			return "stdout poll failed: \(errno)"
		case .writeFailed(let errno, let bytesWritten, let totalBytes):
			return "stdout write failed with errno \(errno) after \(bytesWritten)/\(totalBytes) bytes"
		}
	}
}

package enum NonBlockingFDWriter {
	@discardableResult
	package static func setNonBlocking(fd: Int32) throws -> Int32 {
		let flags = POSIXCompat.fcntl(fd, POSIXCompat.fGetFL)
		guard flags >= 0 else {
			throw NonBlockingFDWriteError.fcntlFailed(errno: POSIXCompat.lastErrno)
		}
		guard flags & POSIXCompat.oNonBlock == 0 else { return flags }
		guard POSIXCompat.fcntl(fd, POSIXCompat.fSetFL, flags | POSIXCompat.oNonBlock) >= 0 else {
			throw NonBlockingFDWriteError.fcntlFailed(errno: POSIXCompat.lastErrno)
		}
		return flags
	}

	package static func restoreFlags(fd: Int32, flags: Int32) throws {
		guard POSIXCompat.fcntl(fd, POSIXCompat.fSetFL, flags) >= 0 else {
			throw NonBlockingFDWriteError.fcntlFailed(errno: POSIXCompat.lastErrno)
		}
	}

	private static func sanitizedPollIntervalMilliseconds(_ value: Int32) -> Int32 {
		max(1, value)
	}

	package static func writeAll(
		_ data: Data,
		to fd: Int32,
		stallTimeout: TimeInterval = 30.0,
		pollIntervalMilliseconds: Int32 = 250,
		setNonBlocking: Bool = true
	) throws {
		if setNonBlocking {
			try self.setNonBlocking(fd: fd)
		}

		var totalWritten = 0
		var lastProgressAt = Date()

		while totalWritten < data.count {
			if Task.isCancelled {
				throw NonBlockingFDWriteError.cancelled(bytesWritten: totalWritten, totalBytes: data.count)
			}

			if Date().timeIntervalSince(lastProgressAt) >= stallTimeout {
				throw NonBlockingFDWriteError.localTimeout(
					stallTimeout: stallTimeout,
					bytesWritten: totalWritten,
					totalBytes: data.count
				)
			}

			let written = data.withUnsafeBytes { buffer in
				let base = buffer.baseAddress!.advanced(by: totalWritten)
				return POSIXCompat.write(fd, base, data.count - totalWritten)
			}

			if written > 0 {
				totalWritten += written
				lastProgressAt = Date()
				continue
			}

			if written == 0 {
				throw NonBlockingFDWriteError.brokenPipe(bytesWritten: totalWritten, totalBytes: data.count)
			}

			let err = POSIXCompat.lastErrno
			if err == POSIXCompat.eIntr { continue }
			if err == POSIXCompat.ePipe {
				throw NonBlockingFDWriteError.brokenPipe(bytesWritten: totalWritten, totalBytes: data.count)
			}
			if err == POSIXCompat.eAgain || err == POSIXCompat.eWouldBlock {
				try waitForWritable(
					fd: fd,
					stallTimeout: stallTimeout,
					pollIntervalMilliseconds: pollIntervalMilliseconds,
					lastProgressAt: lastProgressAt,
					bytesWritten: totalWritten,
					totalBytes: data.count
				)
				continue
			}

			throw NonBlockingFDWriteError.writeFailed(
				errno: err,
				bytesWritten: totalWritten,
				totalBytes: data.count
			)
		}
	}

	private static func waitForWritable(
		fd: Int32,
		stallTimeout: TimeInterval,
		pollIntervalMilliseconds: Int32,
		lastProgressAt: Date,
		bytesWritten: Int,
		totalBytes: Int
	) throws {
		while true {
			if Task.isCancelled {
				throw NonBlockingFDWriteError.cancelled(bytesWritten: bytesWritten, totalBytes: totalBytes)
			}

			let remainingStallSeconds = stallTimeout - Date().timeIntervalSince(lastProgressAt)
			if remainingStallSeconds <= 0 {
				throw NonBlockingFDWriteError.localTimeout(
					stallTimeout: stallTimeout,
					bytesWritten: bytesWritten,
					totalBytes: totalBytes
				)
			}

			var pfd = POSIXCompat.PollFD(fd: fd, events: POSIXCompat.pollOut, revents: 0)
			let remainingMs = max(1, Int32(remainingStallSeconds * 1000))
			let timeoutMs = min(sanitizedPollIntervalMilliseconds(pollIntervalMilliseconds), remainingMs)
			let result = POSIXCompat.poll(&pfd, 1, timeoutMs)

			if result < 0 {
				if POSIXCompat.lastErrno == POSIXCompat.eIntr { continue }
				throw NonBlockingFDWriteError.pollFailed(errno: POSIXCompat.lastErrno)
			}

			if result == 0 { continue }

			if pfd.revents & POSIXCompat.pollHangupOrError != 0 {
				throw NonBlockingFDWriteError.brokenPipe(bytesWritten: bytesWritten, totalBytes: totalBytes)
			}

			if pfd.revents & POSIXCompat.pollOut != 0 {
				return
			}
		}
	}
}
