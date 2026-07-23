import Foundation

enum MCPBuildFlavor: String, Codable, Hashable {
    case debug
    case release

    /// Bonjour debug tag fragment appended in debug builds.
    var debugTag: String {
        switch self {
        case .debug:
            return "-DEBUG"
        case .release:
            return ""
        }
    }
}

/// Structured representation of the Bonjour MCP service name used by the app and CLI.
/// Format (current contract):
///     <device-id><debugTag><protocolTag>
/// where debugTag is "-DEBUG" for debug builds and "" for release builds, and
/// protocolTag is the protocol/version suffix (e.g. "-MCP2").
struct MCPServiceName: Equatable, Codable, Hashable {
    let deviceID: String
    let buildFlavor: MCPBuildFlavor
    let protocolTag: String

    init(
        deviceID: String,
        buildFlavor: MCPBuildFlavor,
        protocolTag: String = MCPConstants.serviceVersionTag
    ) {
        self.deviceID = deviceID
        self.buildFlavor = buildFlavor
        self.protocolTag = protocolTag
    }

    /// Encodes the structured components into the advertised Bonjour service name.
    func encoded() -> String {
        deviceID + buildFlavor.debugTag + protocolTag
    }

    /// Parses a service name into structured components. Returns nil if the
    /// name does not contain a protocol tag starting with "-MCP" or if the
    /// device ID is empty after stripping flavor/version fragments.
    static func parse(_ name: String) -> MCPServiceName? {
        guard let range = name.range(of: "-MCP", options: [.backwards]) else { return nil }
        let protocolTag = String(name[range.lowerBound...])
        let prefix = String(name[..<range.lowerBound])
        let buildFlavor: MCPBuildFlavor
        let deviceID: String
        if prefix.hasSuffix(MCPBuildFlavor.debug.debugTag) {
            buildFlavor = .debug
            deviceID = String(prefix.dropLast(MCPBuildFlavor.debug.debugTag.count))
        } else {
            buildFlavor = .release
            deviceID = prefix
        }
        guard !deviceID.isEmpty else { return nil }
        return MCPServiceName(deviceID: deviceID, buildFlavor: buildFlavor, protocolTag: protocolTag)
    }
}
