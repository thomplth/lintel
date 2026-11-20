import Foundation

public enum Capability: Hashable, Sendable {
    case notify
    case audio
    case clipboard
    case jobs
    case exec(String)
    case secret(String)

    public init?(_ text: String) {
        switch text {
        case "notify": self = .notify
        case "audio": self = .audio
        case "clipboard": self = .clipboard
        case "jobs": self = .jobs
        default:
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) })
            else { return nil }
            switch parts[0] {
            case "exec": self = .exec(parts[1])
            case "secret": self = .secret(parts[1])
            default: return nil
            }
        }
    }

    public var explanation: String {
        switch self {
        case .notify: "Post notifications"
        case .audio: "Change the volume and mute"
        case .clipboard: "Write to the clipboard"
        case .jobs: "Read and control scheduled jobs across all modules"
        case .exec(let tool): "Run the command-line tool \(tool)"
        case .secret(let name): "Read the saved secret \"\(name)\""
        }
    }
}

public struct ModuleManifest: Equatable, Sendable {
    public var id: String
    public var title: String
    public var icon: String
    public var summary: String
    public var pinned: Bool
    public var order: Int
    public var refreshSeconds: Double
    public var panelRefreshSeconds: Double
    public var panelWidth: String
    public var permissions: [String]

    public struct Invalid: Error, Equatable {
        public let message: String
    }

    public init(_ meta: JSONValue) throws {
        guard meta.object != nil else { throw Invalid(message: "meta must be an object") }
        guard let id = meta["id"].string, Self.isValid(id: id) else {
            throw Invalid(message: "meta.id must be lowercase letters, digits and dashes, at most 40 characters")
        }
        self.id = id
        title = meta["title"].string ?? id
        icon = meta["icon"].string ?? "puzzlepiece.extension"
        summary = meta["summary"].string ?? meta["description"].string ?? ""
        pinned = meta["pinned"].bool ?? false
        order = Int(meta["order"].number ?? 50)
        refreshSeconds = min(max(meta["refreshSeconds"].number ?? 60, 1), 86_400)
        panelRefreshSeconds = min(max(meta["panelRefreshSeconds"].number ?? min(refreshSeconds, 5), 1), refreshSeconds)
        panelWidth = meta["panelWidth"].string.flatMap { ["small", "medium", "large"].contains($0) ? $0 : nil } ?? "medium"
        permissions = (meta["permissions"].array ?? []).compactMap(\.string).map { $0.lowercased() == $0 || $0.contains(":") ? $0 : $0.lowercased() }
        for permission in permissions where Capability(permission) == nil && !Self.isHostPattern(permission) {
            throw Invalid(message: "meta.permissions entry '\(permission)' is neither a host (api.example.com, *.example.com, localhost:8080) nor a capability (notify, audio, clipboard, jobs, exec:<tool>, secret:<name>)")
        }
    }

    public var hosts: [String] {
        permissions.filter { Capability($0) == nil }
    }

    public var capabilities: [Capability] {
        permissions.compactMap(Capability.init)
    }

    public func allows(_ capability: Capability) -> Bool {
        capabilities.contains(capability)
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return false }
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (scheme == "http" && isLoopback) else { return false }
        let authority = url.port.map { "\(host):\($0)" } ?? host
        return hosts.contains { pattern in
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))
                return host.hasSuffix(suffix) || host == String(suffix.dropFirst())
            }
            return pattern == host || pattern == authority
        }
    }

    public static func isValid(id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.count <= 40 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first)
            && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func isHostPattern(_ text: String) -> Bool {
        var host = text
        if host.hasPrefix("*.") { host = String(host.dropFirst(2)) }
        if let colon = host.lastIndex(of: ":") {
            guard let port = Int(host[host.index(after: colon)...]), (1...65535).contains(port) else { return false }
            host = String(host[..<colon])
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host == "localhost" || labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// What the user agreed to for one module; any wider permission set needs a fresh approval.
public struct Approval: Equatable, Codable, Sendable {
    public var permissions: [String]

    public init(permissions: [String]) {
        self.permissions = permissions.sorted()
    }

    public func covers(_ manifest: ModuleManifest) -> Bool {
        Set(manifest.permissions).isSubset(of: Set(permissions))
    }
}
