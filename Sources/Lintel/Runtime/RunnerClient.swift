import Foundation
import LintelCore

struct ModuleFailure: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    static func describe(_ error: Error) -> String {
        (error as? ModuleFailure)?.message
            ?? (error as? ModuleManifest.Invalid)?.message
            ?? (error as? JobManifest.Invalid)?.message
            ?? error.localizedDescription
    }
}

struct ModuleDescription {
    var manifest: ModuleManifest
    var hasPanel: Bool
    var hasConfigure: Bool = false
    var declaredViews: [WidgetSize] = []
    var actions: [String]
    var jobs: [JobManifest] = []
}

/// The app side of the module runtime: starts the helper, routes requests and host calls, and replaces the helper
/// when a module hangs or crashes it.
@MainActor
final class RunnerClient {
    typealias CallHandler = (_ module: String, _ name: String, _ arguments: [JSONValue]) async throws -> JSONValue

    var onCall: CallHandler = { _, name, _ in throw ModuleFailure("host.\(name) is unavailable") }
    var onPost: (_ module: String, _ name: String, _ arguments: [JSONValue]) -> Void = { _, _, _ in }
    /// Called after the helper was replaced; `blamed` is the module that was running when it hung.
    var onRestart: (_ blamed: String?) -> Void = { _ in }

    static let busyLimit: TimeInterval = 4
    static let requestLimit: TimeInterval = 60

    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextRequest = 1
    private var busyTimer: Timer?
    private var latestData: JSONValue = .object([:])
    private var recentStarts: [Date] = []
    private var buffer = Data()

    var isRunning: Bool { process?.isRunning ?? false }
    var processIdentifier: pid_t? { process?.processIdentifier }

    func start() {
        guard process == nil else { return }
        let now = Date()
        recentStarts = recentStarts.filter { now.timeIntervalSince($0) < 30 } + [now]
        guard recentStarts.count <= 6 else {
            FileHandle.standardError.write(Data("lintel: the module runtime keeps failing; not restarting it\n".utf8))
            return
        }
        let process = Process()
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["runner"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        stdout.fileHandleForReading.readChunksUntilEnd { [weak self] chunk in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(chunk, from: process) }
            }
        }
        process.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.helperEnded(ended, blamed: nil) }
            }
        }
        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("lintel: cannot start the module runtime: \(error.localizedDescription)\n".utf8))
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer = Data()
        send(["op": "data", "data": latestData.any])
    }

    func stop() {
        let ending = process
        process = nil
        input = nil
        ending?.terminationHandler = nil
        ending?.terminate()
        failPending("the module runtime stopped")
    }

    func load(key: String, source: String, storage: JSONValue) async throws -> ModuleDescription {
        let reply = try await request(["op": "load", "module": key, "source": source, "storage": storage.any])
        guard reply["hasRender"].bool == true else {
            throw ModuleFailure("defineModule needs a render(host) function")
        }
        let rawJobs = reply["jobs"].array ?? []
        let jobs: [JobManifest] = try rawJobs.map { entry in
            guard entry["hasRun"].bool == true else {
                let id = entry["id"].string ?? "job"
                throw JobManifest.Invalid(message: "job '\(id)' needs a run(host) function")
            }
            return try JobManifest(entry)
        }
        return ModuleDescription(
            manifest: try ModuleManifest(reply["meta"]),
            hasPanel: reply["hasPanel"].bool ?? false,
            hasConfigure: reply["hasConfigure"].bool ?? false,
            declaredViews: (reply["declaredViews"].array ?? []).compactMap { $0.string.flatMap(WidgetSize.init(rawValue:)) },
            actions: (reply["actions"].array ?? []).compactMap(\.string),
            jobs: jobs
        )
    }

    func render(key: String, surface: Surface) async throws -> JSONValue {
        try await request(["op": "render", "module": key, "surface": surface.rawValue])
    }

    func render(key: String, size: WidgetSize) async throws -> JSONValue {
        try await request(["op": "render", "module": key, "surface": size.rawValue])
    }

    func renderConfigure(key: String) async throws -> JSONValue {
        try await request(["op": "render", "module": key, "surface": "configure"])
    }

    func act(key: String, action: String, payload: JSONValue) async throws -> JSONValue {
        try await request(["op": "act", "module": key, "action": action, "payload": payload.any])
    }

    func runJob(key: String, name: String, timeout: TimeInterval) async throws -> JSONValue {
        try await request(["op": "job", "module": key, "job": name], timeout: max(timeout, 30))
    }

    func setJobs(key: String, own: [JSONValue], all: [JSONValue]) {
        send(["op": "jobs", "module": key, "jobs": ["own": own.map(\.any), "all": all.map(\.any)]])
    }

    func unload(key: String) {
        send(["op": "unload", "module": key])
    }

    func setData(_ data: JSONValue) {
        latestData = data
        send(["op": "data", "data": data.any])
    }

    private func request(_ message: [String: Any], timeout: TimeInterval? = nil) async throws -> JSONValue {
        let effectiveTimeout = timeout ?? Self.requestLimit
        if process == nil { start() }
        guard process != nil else { throw ModuleFailure("the module runtime is not running") }
        let identifier = nextRequest
        nextRequest += 1
        var message = message
        message["id"] = identifier
        return try await withCheckedThrowingContinuation { continuation in
            pending[identifier] = continuation
            send(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + effectiveTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    self?.pending.removeValue(forKey: identifier)?.resume(throwing: ModuleFailure("timed out"))
                }
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func receive(_ chunk: Data, from source: Process) {
        guard source === process else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let busy = message["busy"] {
            busyTimer?.invalidate()
            busyTimer = nil
            if let module = busy as? String {
                busyTimer = Timer.scheduledTimer(withTimeInterval: Self.busyLimit, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.replaceHungHelper(blamed: module) }
                }
            }
            return
        }
        if let identifier = message["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: identifier) else { return }
            if let failure = message["error"] as? String {
                continuation.resume(throwing: ModuleFailure(failure))
            } else {
                continuation.resume(returning: JSONValue(any: message["ok"]))
            }
            return
        }
        let module = message["module"] as? String ?? ""
        let arguments = JSONValue(any: message["args"]).array ?? []
        if let name = message["post"] as? String {
            onPost(module, name, arguments)
        } else if let call = message["call"] as? Int, let name = message["name"] as? String {
            let source = process
            Task {
                var reply: [String: Any] = ["op": "reply", "call": call]
                do {
                    reply["ok"] = try await onCall(module, name, arguments).any
                } catch {
                    reply["error"] = ModuleFailure.describe(error)
                }
                if source === self.process { self.send(reply) }
            }
        }
    }

    private func replaceHungHelper(blamed module: String) {
        guard let hung = process else { return }
        hung.terminationHandler = nil
        kill(hung.processIdentifier, SIGKILL)
        helperEnded(hung, blamed: module)
    }

    private func helperEnded(_ ended: Process, blamed: String?) {
        guard ended === process else { return }
        busyTimer?.invalidate()
        busyTimer = nil
        process = nil
        input = nil
        failPending(blamed == nil ? "the module runtime crashed" : "the module runtime was restarted")
        start()
        onRestart(blamed)
    }

    private func failPending(_ reason: String) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: ModuleFailure(reason)) }
    }
}
