#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package enum POSIXCompat {
	#if canImport(Darwin)
	package typealias PollFD = Darwin.pollfd
	package typealias NFDS = Darwin.nfds_t
	#elseif canImport(Glibc)
	package typealias PollFD = Glibc.pollfd
	package typealias NFDS = Glibc.nfds_t
	#endif

	package static let fGetFD: Int32 = F_GETFD
	package static let fSetFD: Int32 = F_SETFD
	package static let fGetFL: Int32 = F_GETFL
	package static let fSetFL: Int32 = F_SETFL
	package static let fdCloseOnExec: Int32 = FD_CLOEXEC
	package static let oNonBlock: Int32 = O_NONBLOCK
	package static let pollOut: Int16 = Int16(POLLOUT)
	package static let pollHangupOrError: Int16 = Int16(POLLHUP | POLLERR | POLLNVAL)
	package static let shutdownReadWrite: Int32 = Int32(SHUT_RDWR)

	package static let eIntr: Int32 = EINTR
	package static let eAgain: Int32 = EAGAIN
	package static let eWouldBlock: Int32 = EWOULDBLOCK
	package static let ePipe: Int32 = EPIPE

	package static var lastErrno: Int32 {
		errno
	}

	package static func getUID() -> uid_t {
		getuid()
	}

	package static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer!, _ count: Int) -> Int {
		#if canImport(Darwin)
		return Darwin.read(fd, buffer, count)
		#elseif canImport(Glibc)
		return Glibc.read(fd, buffer, count)
		#endif
	}

	package static func write(_ fd: Int32, _ buffer: UnsafeRawPointer!, _ count: Int) -> Int {
		#if canImport(Darwin)
		return Darwin.write(fd, buffer, count)
		#elseif canImport(Glibc)
		return Glibc.write(fd, buffer, count)
		#endif
	}

	package static func fcntl(_ fd: Int32, _ command: Int32) -> Int32 {
		#if canImport(Darwin)
		return Darwin.fcntl(fd, command)
		#elseif canImport(Glibc)
		return Glibc.fcntl(fd, command)
		#endif
	}

	package static func fcntl(_ fd: Int32, _ command: Int32, _ value: Int32) -> Int32 {
		#if canImport(Darwin)
		return Darwin.fcntl(fd, command, value)
		#elseif canImport(Glibc)
		return Glibc.fcntl(fd, command, value)
		#endif
	}

	package static func poll(_ fds: UnsafeMutablePointer<PollFD>!, _ nfds: NFDS, _ timeout: Int32) -> Int32 {
		#if canImport(Darwin)
		return Darwin.poll(fds, nfds, timeout)
		#elseif canImport(Glibc)
		return Glibc.poll(fds, nfds, timeout)
		#endif
	}

	@discardableResult
	package static func shutdown(_ fd: Int32, _ how: Int32) -> Int32 {
		#if canImport(Darwin)
		return Darwin.shutdown(fd, how)
		#elseif canImport(Glibc)
		return Glibc.shutdown(fd, how)
		#endif
	}
}
