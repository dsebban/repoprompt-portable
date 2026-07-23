package enum POSIXDescriptorSupport {
	@discardableResult
	package static func setCloseOnExec(_ fd: Int32) -> Bool {
		let flags = POSIXCompat.fcntl(fd, POSIXCompat.fGetFD)
		guard flags != -1 else { return false }
		return POSIXCompat.fcntl(fd, POSIXCompat.fSetFD, flags | POSIXCompat.fdCloseOnExec) != -1
	}

	@discardableResult
	package static func shutdownSocketReadWrite(_ fd: Int32) -> Bool {
		POSIXCompat.shutdown(fd, POSIXCompat.shutdownReadWrite) == 0
	}
}
