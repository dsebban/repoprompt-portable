import Dispatch
import Foundation
import Logging
import MCP

public struct StdioMCPTransportError: Error, Equatable, Sendable, CustomStringConvertible {
	public enum Kind: String, Sendable {
		case residualFrameAtEOF
		case notConnected
	}

	public let kind: Kind

	public init(kind: Kind) {
		self.kind = kind
	}

	public var description: String {
		switch kind {
		case .residualFrameAtEOF:
			return "stdin closed with a partial newline-delimited MCP frame"
		case .notConnected:
			return "stdio MCP transport is not connected"
		}
	}
}

/// Direct stdio MCP transport for headless/server use.
///
/// The transport only writes protocol frames to `stdoutFD`. Diagnostics use the injected
/// logger and must be configured by executables to emit to stderr or a no-op handler.
public actor StdioMCPTransport: Transport {
	private let stdinFD: Int32
	private let stdoutFD: Int32
	public nonisolated let logger: Logger
	private let writeStallTimeout: TimeInterval
	private let writePollIntervalMilliseconds: Int32

	private var isConnected = false
	private var streamFinished = false
	private var reader: NewlineDelimitedSocketReader?
	private let readQueue = DispatchQueue(label: "com.repoprompt.mcp.stdio.read", qos: .userInitiated)

	private nonisolated let messageStream: AsyncThrowingStream<Data, Swift.Error>
	private var messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

	public init(
		stdinFD: Int32 = 0,
		stdoutFD: Int32 = 1,
		logger: Logger? = nil,
		writeStallTimeout: TimeInterval = 30.0,
		writePollIntervalMilliseconds: Int32 = 250
	) {
		self.stdinFD = stdinFD
		self.stdoutFD = stdoutFD
		self.logger = logger ?? Logger(label: "mcp.transport.stdio") { _ in SwiftLogNoOpLogHandler() }
		self.writeStallTimeout = writeStallTimeout
		self.writePollIntervalMilliseconds = max(1, writePollIntervalMilliseconds)

		var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
		self.messageStream = AsyncThrowingStream(
			Data.self,
			bufferingPolicy: .bufferingOldest(1024)
		) { continuation = $0 }
		self.messageContinuation = continuation
	}

	public func connect() async throws {
		guard !isConnected else { return }
		streamFinished = false
		do {
			try NonBlockingFDWriter.setNonBlocking(fd: stdinFD)
			try NonBlockingFDWriter.setNonBlocking(fd: stdoutFD)
			try startReader()
			isConnected = true
		} catch {
			isConnected = false
			finishStreamIfNeeded(throwing: error)
			throw error
		}
	}

	public func disconnect() async {
		guard isConnected || !streamFinished else { return }
		isConnected = false
		reader?.stop()
		reader = nil
		finishStreamIfNeeded(throwing: MCPError.connectionClosed)
	}

	public func send(_ message: Data) async throws {
		guard isConnected else {
			throw MCPError.transportError(StdioMCPTransportError(kind: .notConnected))
		}
		let framed = Self.frameWithNewlineIfNeeded(message)
		do {
			try NonBlockingFDWriter.writeAll(
				framed,
				to: stdoutFD,
				stallTimeout: writeStallTimeout,
				pollIntervalMilliseconds: writePollIntervalMilliseconds
			)
		} catch let error as NonBlockingFDWriteError {
			if case .brokenPipe = error {
				finishStreamIfNeeded(throwing: nil)
				isConnected = false
				throw MCPError.connectionClosed
			}
			finishStreamIfNeeded(throwing: error)
			isConnected = false
			throw MCPError.transportError(error)
		} catch {
			finishStreamIfNeeded(throwing: error)
			isConnected = false
			throw error
		}
	}

	public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
		messageStream
	}

	private nonisolated static func frameWithNewlineIfNeeded(_ data: Data) -> Data {
		guard data.last != UInt8(ascii: "\n") else { return data }
		var framed = Data()
		framed.reserveCapacity(data.count + 1)
		framed.append(data)
		framed.append(UInt8(ascii: "\n"))
		return framed
	}

	private func startReader() throws {
		let reader = NewlineDelimitedSocketReader(
			fd: stdinFD,
			queue: readQueue,
			logger: logger,
			onFrame: { [weak self] frame in
				Task { await self?.yieldFrame(frame) }
			},
			onEOF: { [weak self] hasResidualData in
				Task { await self?.handleEOF(hasResidualData: hasResidualData) }
			},
			onError: { [weak self] error in
				Task { await self?.handleReadError(error) }
			}
		)
		try reader.start()
		self.reader = reader
	}

	private func yieldFrame(_ frame: Data) {
		guard !streamFinished else { return }
		messageContinuation.yield(frame)
	}

	private func handleEOF(hasResidualData: Bool) {
		isConnected = false
		if hasResidualData {
			finishStreamIfNeeded(throwing: StdioMCPTransportError(kind: .residualFrameAtEOF))
		} else {
			finishStreamIfNeeded(throwing: nil)
		}
	}

	private func handleReadError(_ error: Swift.Error) {
		isConnected = false
		finishStreamIfNeeded(throwing: error)
	}

	private func finishStreamIfNeeded(throwing error: Swift.Error?) {
		guard !streamFinished else { return }
		streamFinished = true
		if let error {
			messageContinuation.finish(throwing: error)
		} else {
			messageContinuation.finish()
		}
	}
}
