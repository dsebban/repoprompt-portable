//
//  NewlineDelimitedSocketReader.swift
//  RepoPrompt
//
//  Shared helper that reads newline-delimited frames from a non-blocking socket
//  using DispatchSourceRead. Keeps blocking work off actor executors and yields
//  frames via callbacks.
//

import Foundation
import Dispatch
import Logging

public enum ReadSourceFDPreflightError: Error, Equatable, CustomStringConvertible, LocalizedError {
	case invalidFileDescriptor(label: String, fd: Int32)
	case descriptorCheckFailed(label: String, fd: Int32, errno: Int32)

	public var description: String {
		switch self {
		case let .invalidFileDescriptor(label, fd):
			"Invalid file descriptor for \(label): \(fd)"
		case let .descriptorCheckFailed(label, fd, errno):
			"File descriptor check failed for \(label) fd=\(fd) errno=\(errno)"
		}
	}

	public var errorDescription: String? { description }
}

public enum ReadSourceFDPreflight {
	public static func validateOpenFD(_ fd: Int32, label: String) throws {
		guard fd >= 0 else {
			throw ReadSourceFDPreflightError.invalidFileDescriptor(label: label, fd: fd)
		}

		guard POSIXCompat.fcntl(fd, POSIXCompat.fGetFL) >= 0 else {
			throw ReadSourceFDPreflightError.descriptorCheckFailed(label: label, fd: fd, errno: POSIXCompat.lastErrno)
		}
	}

	public static func makeReadSource(
		fileDescriptor fd: Int32,
		queue: DispatchQueue,
		label: String
	) throws -> DispatchSourceRead {
		try validateOpenFD(fd, label: label)
		return DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
	}
}

/// Event-driven reader for newline-delimited socket frames.
/// Not actor-isolated; intended to be driven from transports on a dedicated queue.
public final class NewlineDelimitedSocketReader {
	private let fd: Int32
	private let queue: DispatchQueue
	private let logger: Logger
	private let delimiter: UInt8
	private let chunkSize: Int
	private let bufferReservation: Int
	private let onFrame: (Data) -> Void
	private let onEOF: (_ hasResidualData: Bool) -> Void
	private let onError: (Swift.Error) -> Void
	private let onBytesRead: (() -> Void)?
	private let onCancel: (() -> Void)?

	private var source: DispatchSourceRead?
	private var buffer = Data()
	private var started = false

	public init(
		fd: Int32,
		queue: DispatchQueue,
		logger: Logger,
		delimiter: UInt8 = UInt8(ascii: "\n"),
		chunkSize: Int = 16_384,
		bufferReservation: Int = 64 * 1024,
		onFrame: @escaping (Data) -> Void,
		onEOF: @escaping (_ hasResidualData: Bool) -> Void,
		onError: @escaping (Swift.Error) -> Void,
		onBytesRead: (() -> Void)? = nil,
		onCancel: (() -> Void)? = nil
	) {
		self.fd = fd
		self.queue = queue
		self.logger = logger
		self.delimiter = delimiter
		self.chunkSize = chunkSize
		self.bufferReservation = bufferReservation
		self.onFrame = onFrame
		self.onEOF = onEOF
		self.onError = onError
		self.onBytesRead = onBytesRead
		self.onCancel = onCancel
		self.buffer.reserveCapacity(bufferReservation)
	}

	public func start() throws {
		guard !started else { return }

		let source = try ReadSourceFDPreflight.makeReadSource(
			fileDescriptor: fd,
			queue: queue,
			label: "newline-delimited socket reader"
		)
		self.source = source

		source.setEventHandler { [weak self] in
			guard let self else { return }

			let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
			defer { readBuffer.deallocate() }

			var anyBytesRead = false

			while true {
				let bytesRead = POSIXCompat.read(fd, readBuffer, chunkSize)

				if bytesRead < 0 {
					let err = POSIXCompat.lastErrno
					if err == POSIXCompat.eIntr {
						continue
					} else if err == POSIXCompat.eAgain || err == POSIXCompat.eWouldBlock {
						break
					} else {
						let posixError = POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
						logger.error("NewlineDelimitedSocketReader read error: \(err)")
						onError(posixError)
						return
					}
				}

				if bytesRead == 0 {
					if anyBytesRead {
						onBytesRead?()
						emitBufferedFrames()
					}
					onEOF(!buffer.isEmpty)
					return
				}

				buffer.append(readBuffer, count: bytesRead)
				anyBytesRead = true
			}

			if anyBytesRead {
				onBytesRead?()
			}

			emitBufferedFrames()
		}

		source.setCancelHandler { [weak self] in
			guard let self else { return }
			onCancel?()
		}

		source.resume()
		started = true
	}

	private func emitBufferedFrames() {
		while let newlineIndex = buffer.firstIndex(of: delimiter) {
			let frame = buffer[..<newlineIndex]
			let nextStart = buffer.index(after: newlineIndex)
			buffer.removeSubrange(..<nextStart)

			if !frame.isEmpty {
				onFrame(Data(frame))
			}
		}
	}

	public func stop() {
		source?.cancel()
		source = nil
		started = false
	}
}
