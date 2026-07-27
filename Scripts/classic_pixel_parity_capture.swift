#!/usr/bin/env swift

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CaptureFailure: Error, CustomStringConvertible {
	case message(String)

	var description: String {
		switch self {
		case .message(let value):
			return value
		}
	}
}

struct Arguments {
	let pid: pid_t
	let title: String
	let output: URL
	let scenario: URL
	let width: CGFloat
	let height: CGFloat

	static func parse() throws -> Arguments {
		let raw = Array(CommandLine.arguments.dropFirst())
		func value(_ flag: String) throws -> String {
			guard let index = raw.firstIndex(of: flag), raw.indices.contains(index + 1) else {
				throw CaptureFailure.message("missing \(flag)")
			}
			return raw[index + 1]
		}
		guard let pid = pid_t(try value("--pid")), pid > 0 else {
			throw CaptureFailure.message("--pid must be a positive process identifier")
		}
		guard let width = Double(try value("--width")),
		      let height = Double(try value("--height")),
		      width > 0,
		      height > 0
		else {
			throw CaptureFailure.message("--width and --height must be positive")
		}
		return Arguments(
			pid: pid,
			title: try value("--title"),
			output: URL(fileURLWithPath: try value("--output")),
			scenario: URL(fileURLWithPath: try value("--scenario")),
			width: CGFloat(width),
			height: CGFloat(height)
		)
	}
}

func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
	var value: CFTypeRef?
	guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
		return nil
	}
	return value
}

func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
	copyAttribute(element, attribute) as? String
}

func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
	guard let value = copyAttribute(element, attribute),
	      CFGetTypeID(value) == AXValueGetTypeID()
	else {
		return nil
	}
	var point = CGPoint.zero
	guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
		return nil
	}
	return point
}

func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
	guard let value = copyAttribute(element, attribute),
	      CFGetTypeID(value) == AXValueGetTypeID()
	else {
		return nil
	}
	var size = CGSize.zero
	guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
		return nil
	}
	return size
}

func setFrame(_ window: AXUIElement, origin: CGPoint, size: CGSize) throws {
	var mutableOrigin = origin
	var mutableSize = size
	guard let position = AXValueCreate(.cgPoint, &mutableOrigin),
	      let dimensions = AXValueCreate(.cgSize, &mutableSize)
	else {
		throw CaptureFailure.message("could not construct accessibility frame values")
	}
	guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success else {
		throw CaptureFailure.message("accessibility could not position the target window")
	}
	guard AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success else {
		throw CaptureFailure.message("accessibility could not size the target window")
	}
}

func matchingWindow(application: AXUIElement, title: String) throws -> AXUIElement {
	guard let windows = copyAttribute(application, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
		throw CaptureFailure.message("accessibility did not expose application windows")
	}
	let matches = windows.filter {
		stringAttribute($0, kAXTitleAttribute as CFString) == title
	}
	guard matches.count == 1, let window = matches.first else {
		throw CaptureFailure.message("expected one AX window titled \(title.debugDescription), found \(matches.count)")
	}
	return window
}

func flattenedElements(root: AXUIElement) throws -> [AXUIElement] {
	var pending = [root]
	var result: [AXUIElement] = []
	while let element = pending.popLast() {
		result.append(element)
		if result.count > 20_000 {
			throw CaptureFailure.message("accessibility hierarchy exceeded 20,000 elements")
		}
		if let children = copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
			pending.append(contentsOf: children.reversed())
		}
	}
	return result
}

func elementMatches(_ element: AXUIElement, selector: [String: Any]) -> Bool {
	let attributes: [(String, CFString)] = [
		("role", kAXRoleAttribute as CFString),
		("title", kAXTitleAttribute as CFString),
		("identifier", kAXIdentifierAttribute as CFString),
		("description", kAXDescriptionAttribute as CFString),
	]
	for (key, attribute) in attributes {
		if let expected = selector[key] as? String,
		   stringAttribute(element, attribute) != expected
		{
			return false
		}
	}
	return true
}

func exactElement(in window: AXUIElement, selector: [String: Any]) throws -> AXUIElement {
	let elements = try flattenedElements(root: window)
	let matches = elements.filter {
		elementMatches($0, selector: selector)
	}
	guard matches.count == 1, let result = matches.first else {
		let candidates = elements.prefix(80).map {
			[
				stringAttribute($0, kAXRoleAttribute as CFString) ?? "",
				stringAttribute($0, kAXTitleAttribute as CFString) ?? "",
				stringAttribute($0, kAXDescriptionAttribute as CFString) ?? "",
			].joined(separator: "|")
		}.joined(separator: ", ")
		throw CaptureFailure.message(
			"scenario selector must match exactly once, found \(matches.count): \(selector); "
				+ "first elements: \(candidates)"
		)
	}
	return result
}

func applyScenario(_ scenarioURL: URL, to window: AXUIElement) throws {
	let data = try Data(contentsOf: scenarioURL)
	guard let scenario = try JSONSerialization.jsonObject(with: data) as? [String: Any],
	      scenario["schema_version"] as? Int == 1
	else {
		throw CaptureFailure.message("unsupported or malformed scenario")
	}
	guard let actions = scenario["ax_actions"] as? [[String: Any]] else {
		throw CaptureFailure.message("scenario is missing ax_actions")
	}
	for action in actions {
		guard let kind = action["action"] as? String,
		      let selector = action["selector"] as? [String: Any]
		else {
			throw CaptureFailure.message("malformed accessibility action")
		}
		let element = try exactElement(in: window, selector: selector)
		switch kind {
		case "press":
			guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
				throw CaptureFailure.message("could not press scenario element: \(selector)")
			}
		case "set_value":
			guard let value = action["value"] as? String,
			      AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success
			else {
				throw CaptureFailure.message("could not set scenario element value: \(selector)")
			}
		case "set_scroll_value":
			guard let value = action["value"] as? Double,
			      AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFNumber) == .success
			else {
				throw CaptureFailure.message("could not set scenario scroll value: \(selector)")
			}
		default:
			throw CaptureFailure.message("unsupported accessibility action: \(kind)")
		}
	}
	if let focusSelector = scenario["focus_selector"] as? [String: Any] {
		let element = try exactElement(in: window, selector: focusSelector)
		guard AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFBoolean) == .success else {
			throw CaptureFailure.message("could not focus scenario element: \(focusSelector)")
		}
	}
}

func activateApplication(pid: pid_t, application: AXUIElement, window: AXUIElement) throws {
	guard let runningApplication = NSRunningApplication(processIdentifier: pid) else {
		throw CaptureFailure.message("could not resolve the target running application")
	}
	guard runningApplication.activate(options: [.activateAllWindows]) else {
		throw CaptureFailure.message("could not activate the target running application")
	}
	_ = AXUIElementSetAttributeValue(
		application,
		kAXFrontmostAttribute as CFString,
		true as CFBoolean
	)
	_ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFBoolean)
	_ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)

	let deadline = Date().addingTimeInterval(5)
	while Date() < deadline {
		let frontmost = copyAttribute(application, kAXFrontmostAttribute as CFString) as? Bool
		if runningApplication.isActive && frontmost == true {
			return
		}
		Thread.sleep(forTimeInterval: 0.1)
	}
	throw CaptureFailure.message("target application did not become active and frontmost")
}

func waitForStableFrame(
	window: AXUIElement,
	expectedSize: CGSize,
	timeout: TimeInterval = 10
) throws -> (CGPoint, CGSize) {
	let deadline = Date().addingTimeInterval(timeout)
	var previous: (CGPoint, CGSize)?
	var lastObserved: (CGPoint, CGSize)?
	var consecutive = 0
	while Date() < deadline {
		guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
		      let size = sizeAttribute(window, kAXSizeAttribute as CFString)
		else {
			throw CaptureFailure.message("accessibility window frame is unavailable")
		}
		lastObserved = (position, size)
		if abs(size.width - expectedSize.width) > 0.5 || abs(size.height - expectedSize.height) > 0.5 {
			consecutive = 0
		} else if let previous,
		          abs(previous.0.x - position.x) < 0.1,
		          abs(previous.0.y - position.y) < 0.1,
		          abs(previous.1.width - size.width) < 0.1,
		          abs(previous.1.height - size.height) < 0.1
		{
			consecutive += 1
			if consecutive >= 3 {
				return (position, size)
			}
		} else {
			consecutive = 1
		}
		previous = (position, size)
		Thread.sleep(forTimeInterval: 0.1)
	}
	let observed = lastObserved.map {
		"\($0.1.width)x\($0.1.height) at \($0.0.x),\($0.0.y)"
	} ?? "unavailable"
	throw CaptureFailure.message(
		"window frame did not settle at \(expectedSize.width)x\(expectedSize.height); last observed \(observed)"
	)
}

func cgWindow(pid: pid_t, title: String) throws -> (CGWindowID, CGRect) {
	guard let rows = CGWindowListCopyWindowInfo(
		[.optionOnScreenOnly, .excludeDesktopElements],
		kCGNullWindowID
	) as? [[String: Any]]
	else {
		throw CaptureFailure.message("CoreGraphics window inventory is unavailable")
	}
	let matches = rows.compactMap { row -> (CGWindowID, CGRect)? in
		guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
		      (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
		      row[kCGWindowName as String] as? String == title,
		      let number = row[kCGWindowNumber as String] as? NSNumber,
		      let bounds = row[kCGWindowBounds as String] as? NSDictionary,
		      let frame = CGRect(dictionaryRepresentation: bounds)
		else {
			return nil
		}
		return (CGWindowID(number.uint32Value), frame)
	}
	guard matches.count == 1, let match = matches.first else {
		throw CaptureFailure.message("expected one CoreGraphics window titled \(title.debugDescription), found \(matches.count)")
	}
	return match
}

func capture(windowID: CGWindowID, outputURL: URL) throws -> CGImage {
	let systemCaptureURL = outputURL.appendingPathExtension("system.png")
	try? FileManager.default.removeItem(at: systemCaptureURL)
	defer {
		try? FileManager.default.removeItem(at: systemCaptureURL)
	}
	let process = Process()
	process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
	process.arguments = [
		"-x",
		"-o",
		"-t", "png",
		"-l", String(windowID),
		systemCaptureURL.path,
	]
	let errorPipe = Pipe()
	process.standardError = errorPipe
	try process.run()
	process.waitUntilExit()
	guard process.terminationStatus == 0 else {
		let error = String(
			data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
			encoding: .utf8
		) ?? ""
		throw CaptureFailure.message("screencapture failed: \(error.trimmingCharacters(in: .whitespacesAndNewlines))")
	}
	guard let source = CGImageSourceCreateWithURL(systemCaptureURL as CFURL, nil),
	      let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
	else {
		throw CaptureFailure.message("could not decode screencapture PNG")
	}
	let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
	guard let context = CGContext(
		data: nil,
		width: rawImage.width,
		height: rawImage.height,
		bitsPerComponent: 8,
		bytesPerRow: rawImage.width * 4,
		space: colorSpace,
		bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
	) else {
		throw CaptureFailure.message("could not create canonical sRGB context")
	}
	context.setFillColor(NSColor.white.cgColor)
	context.fill(CGRect(x: 0, y: 0, width: rawImage.width, height: rawImage.height))
	context.draw(
		rawImage,
		in: CGRect(x: 0, y: 0, width: rawImage.width, height: rawImage.height)
	)
	guard let image = context.makeImage(),
	      let destination = CGImageDestinationCreateWithURL(
		      outputURL as CFURL,
		      UTType.png.identifier as CFString,
		      1,
		      nil
	      )
	else {
		throw CaptureFailure.message("could not create canonical PNG destination")
	}
	CGImageDestinationAddImage(destination, image, [
		kCGImagePropertyHasAlpha: false,
		kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
	] as CFDictionary)
	guard CGImageDestinationFinalize(destination) else {
		throw CaptureFailure.message("could not finalize canonical PNG")
	}
	return image
}

func sha256(_ url: URL) throws -> String {
	let digest = SHA256.hash(data: try Data(contentsOf: url))
	return digest.map { String(format: "%02x", $0) }.joined()
}

func captureScreen(for requestedSize: CGSize) throws -> (screen: NSScreen, axOrigin: CGPoint) {
	guard let mainScreen = NSScreen.main else {
		throw CaptureFailure.message("no main screen is available")
	}
	let matches = NSScreen.screens.filter {
		abs($0.backingScaleFactor - 2.0) < 0.001
			&& $0.frame.width >= requestedSize.width
			&& $0.frame.height >= requestedSize.height
	}
	guard let screen = matches.first else {
		throw CaptureFailure.message(
			"no 2x display can fit the requested \(requestedSize.width)x\(requestedSize.height)-point window"
		)
	}
	let appKitOrigin = CGPoint(
		x: screen.frame.minX + (screen.frame.width - requestedSize.width) / 2.0,
		y: screen.frame.minY + (screen.frame.height - requestedSize.height) / 2.0
	)
	let axOrigin = CGPoint(
		x: appKitOrigin.x,
		y: mainScreen.frame.height - (appKitOrigin.y + requestedSize.height)
	)
	return (screen, axOrigin)
}

func run() throws {
	let arguments = try Arguments.parse()
	guard AXIsProcessTrusted() else {
		throw CaptureFailure.message(
			"Accessibility permission is required for the invoking terminal/Codex process"
		)
	}
	guard CGPreflightScreenCaptureAccess() else {
		throw CaptureFailure.message(
			"Screen Recording permission is required for the invoking terminal/Codex process"
		)
	}

	let application = AXUIElementCreateApplication(arguments.pid)
	let window = try matchingWindow(application: application, title: arguments.title)
	try activateApplication(pid: arguments.pid, application: application, window: window)
	let requestedSize = CGSize(width: arguments.width, height: arguments.height)
	let selectedScreen = try captureScreen(for: requestedSize)
	try setFrame(window, origin: selectedScreen.axOrigin, size: requestedSize)
	_ = try waitForStableFrame(window: window, expectedSize: requestedSize)
	try applyScenario(arguments.scenario, to: window)
	Thread.sleep(forTimeInterval: 0.3)
	let (position, size) = try waitForStableFrame(window: window, expectedSize: requestedSize)
	guard let runningApplication = NSRunningApplication(processIdentifier: arguments.pid),
	      runningApplication.isActive,
	      copyAttribute(application, kAXFrontmostAttribute as CFString) as? Bool == true
	else {
		throw CaptureFailure.message("target application lost active/frontmost state before capture")
	}
	let (windowID, cgFrame) = try cgWindow(pid: arguments.pid, title: arguments.title)
	let image = try capture(windowID: windowID, outputURL: arguments.output)
	let scale = Double(image.width) / Double(size.width)

	let metadata: [String: Any] = [
		"schema_version": 1,
		"pid": Int(arguments.pid),
		"window_id": Int(windowID),
		"title": arguments.title,
		"ax_frame": [
			"x": Double(position.x),
			"y": Double(position.y),
			"width": Double(size.width),
			"height": Double(size.height),
		],
		"cg_frame": [
			"x": Double(cgFrame.origin.x),
			"y": Double(cgFrame.origin.y),
			"width": Double(cgFrame.width),
			"height": Double(cgFrame.height),
		],
		"raw_pixels": [image.width, image.height],
		"backing_scale": scale,
		"application_active": true,
		"ax_frontmost": true,
		"screen": [
			"frame_x": Double(selectedScreen.screen.frame.minX),
			"frame_y": Double(selectedScreen.screen.frame.minY),
			"frame_width": Double(selectedScreen.screen.frame.width),
			"frame_height": Double(selectedScreen.screen.frame.height),
			"backing_scale": Double(selectedScreen.screen.backingScaleFactor),
		],
		"captured_at": ISO8601DateFormatter().string(from: Date()),
		"sha256": try sha256(arguments.output),
	]
	let output = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
	FileHandle.standardOutput.write(output)
	FileHandle.standardOutput.write(Data([0x0A]))
}

do {
	try run()
} catch {
	FileHandle.standardError.write(Data("classic parity capture failed: \(error)\n".utf8))
	exit(1)
}
#else
import Foundation
FileHandle.standardError.write(Data("classic parity capture requires macOS\n".utf8))
exit(2)
#endif
