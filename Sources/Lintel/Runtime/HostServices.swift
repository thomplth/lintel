import AppKit
import LintelCore
import UserNotifications

/// Answers what modules ask of the app, after checking each request against the module's declared permissions.
@MainActor
final class HostServices {
    struct Grant {
        var manifest: ModuleManifest
        /// A trial run may reach its declared hosts but nothing personal: no signed-in pages, secrets or tools.
        var isTrial = false
    }

    private let home: AppHome
    private let browser: BrowserHost
    private let secrets: SecretStore
    var settings: AppSettings
    var grants: [String: Grant] = [:]
    var onRefreshRequest: (String) -> Void = { _ in }
    var onAttention: (String, Bool) -> Void = { _, _ in }
    private(set) var logs: [String: [String]] = [:]
    private var storageCache: [String: [String: JSONValue]] = [:]
    private let redirects = RedirectGuard()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: redirects, delegateQueue: nil)

    init(home: AppHome, browser: BrowserHost, settings: AppSettings) {
        self.home = home
        self.browser = browser
        self.settings = settings
        secrets = SecretStore(home: home)
    }

    func call(module: String, name: String, arguments: [JSONValue]) async throws -> JSONValue {
        guard let grant = grants[module] else { throw ModuleFailure("the module is not loaded") }
        let manifest = grant.manifest
        func argument(_ index: Int) -> JSONValue { index < arguments.count ? arguments[index] : .null }
        func permittedURL(_ index: Int) throws -> URL {
            guard let address = argument(index).string, let url = URL(string: address), manifest.allows(url) else {
                throw ModuleFailure("\(argument(index).string ?? "that address") is not covered by this module's permissions")
            }
            return url
        }
        func require(_ capability: Capability, as permission: String) throws {
            guard manifest.allows(capability) else {
                throw ModuleFailure("this needs '\(permission)' in meta.permissions")
            }
            guard !grant.isTrial else {
                throw ModuleFailure("'\(permission)' is unavailable until the user approves the module")
            }
        }

        switch name {
        case "fetch":
            return .string(try await fetch(try permittedURL(0), options: argument(1), manifest: manifest))
        case "browser.text", "browser.all":
            let url = try permittedURL(0)
            guard !grant.isTrial else {
                throw ModuleFailure("signed-in pages are unavailable until the user approves the module")
            }
            let selector = argument(1).string ?? "body"
            return try await browser.extract(name == "browser.text" ? .text(selector: selector) : .all(selector: selector), from: url)
        case "secret":
            let secret = argument(0).string ?? ""
            try require(.secret(secret), as: "secret:\(secret)")
            return secrets.get(secret).map(JSONValue.string) ?? .null
        case "exec":
            let tool = argument(0).string ?? ""
            try require(.exec(tool), as: "exec:\(tool)")
            guard settings.isPrivateEdition else { throw ModuleFailure("running tools is not available in this edition") }
            return try await execute(tool, arguments: (argument(1).array ?? []).compactMap(\.string))
        case "audio.setVolume":
            try require(.audio, as: "audio")
            try SystemSampler.setVolume(argument(0).number ?? 0)
            return .null
        case "audio.setMuted":
            try require(.audio, as: "audio")
            try SystemSampler.setMuted(argument(0).bool ?? false)
            return .null
        default:
            throw ModuleFailure("host has no function '\(name)'")
        }
    }

    func post(module: String, name: String, arguments: [JSONValue]) {
        guard let grant = grants[module] else { return }
        func text(_ index: Int) -> String { index < arguments.count ? arguments[index].string ?? "" : "" }
        switch name {
        case "storage.set":
            guard arguments.count == 2, !grant.isTrial else { return }
            var stored = storage(for: grant.manifest.id)
            stored[text(0)] = arguments[1]
            saveStorage(stored, for: grant.manifest.id)
        case "storage.remove":
            guard !grant.isTrial else { return }
            var stored = storage(for: grant.manifest.id)
            stored[text(0)] = nil
            saveStorage(stored, for: grant.manifest.id)
        case "notify":
            guard grant.manifest.allows(.notify), !grant.isTrial else { return }
            Self.notify(title: text(0), body: text(1), module: grant.manifest.title)
        case "open":
            guard !grant.isTrial, let url = URL(string: text(0)), url.scheme == "https" else { return }
            NSWorkspace.shared.open(url)
        case "copy":
            guard grant.manifest.allows(.clipboard), !grant.isTrial else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(0), forType: .string)
        case "refresh":
            onRefreshRequest(module)
        case "attention":
            if !grant.isTrial { onAttention(module, arguments.first?.bool ?? false) }
        case "log":
            let line = arguments.compactMap(\.string).joined(separator: " ")
            logs[module, default: []].append(String(line.prefix(500)))
            if logs[module]!.count > 100 { logs[module]!.removeFirst(logs[module]!.count - 100) }
        default:
            break
        }
    }

    func storage(for id: String) -> [String: JSONValue] {
        if let cached = storageCache[id] { return cached }
        let loaded = home.loadStorage(id: id).object ?? [:]
        storageCache[id] = loaded
        return loaded
    }

    private func saveStorage(_ stored: [String: JSONValue], for id: String) {
        storageCache[id] = stored
        home.save(JSONValue.object(stored), to: home.storageFile(id: id))
    }

    func forgetStorage(for id: String) {
        storageCache[id] = nil
        try? FileManager.default.removeItem(at: home.storageFile(id: id))
    }

    private func fetch(_ url: URL, options: JSONValue, manifest: ModuleManifest) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = options["method"].string?.uppercased() ?? "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in options["headers"].object ?? [:] {
            if let value = value.string { request.setValue(value, forHTTPHeaderField: name) }
        }
        let body = options["body"]
        if let text = body.string, body.object == nil {
            request.httpBody = Data(text.utf8)
        } else if body.object != nil || body.array != nil {
            request.httpBody = Data(body.text.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        redirects.allow(manifest, for: request)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw ModuleFailure("\(url.host() ?? "the server") redirected to a host outside this module's permissions")
        } catch {
            throw ModuleFailure("\(url.host() ?? "the server"): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ModuleFailure("HTTP \(status) from \(url.host() ?? "the server")") }
        guard data.count <= 2_000_000 else { throw ModuleFailure("the response from \(url.host() ?? "the server") is larger than 2 MB") }
        return String(decoding: data, as: UTF8.self)
    }

    private func execute(_ tool: String, arguments: [String]) async throws -> JSONValue {
        guard let executable = Self.find(tool: tool) else { throw ModuleFailure("\(tool) is not installed") }
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"].reduce(into: [String: String]()) { $0[$1] = inherited[$1] }
        environment["PATH"] = Self.toolDirectories.joined(separator: ":")
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result = try Shell.run(
                        executable, arguments, timeout: 20, environment: environment,
                        directory: FileManager.default.temporaryDirectory
                    )
                    continuation.resume(returning: [
                        "status": .number(Double(result.status)),
                        "stdout": .string(String(result.stdout.prefix(400_000))),
                        "stderr": .string(String(result.stderr.prefix(20_000))),
                    ])
                } catch {
                    continuation.resume(throwing: ModuleFailure("\(tool) could not be started: \(error.localizedDescription)"))
                }
            }
        }
    }

    nonisolated static var toolDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }

    nonisolated static func find(tool: String) -> String? {
        guard !tool.contains("/") else { return nil }
        return toolDirectories.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func notify(title: String, body: String, module: String) {
        // UNUserNotificationCenter raises an exception in a process that is not inside an app bundle.
        guard Bundle.main.bundleIdentifier != nil else {
            FileHandle.standardError.write(Data("notification from \(module): \(title) — \(body)\n".utf8))
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
            guard isGranted else { return }
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? module : title
            content.subtitle = title.isEmpty ? "" : module
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Follows a redirect only while it stays inside the hosts the requesting module declared.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var manifests: [URL: ModuleManifest] = [:]

    func allow(_ manifest: ModuleManifest, for request: URLRequest) {
        guard let url = request.url else { return }
        lock.withLock { manifests[url] = manifest }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let manifest = lock.withLock { task.originalRequest?.url.flatMap { manifests[$0] } }
        guard let target = request.url, let manifest, manifest.allows(target) else {
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let url = task.originalRequest?.url else { return }
        lock.withLock { manifests[url] = nil }
    }
}
