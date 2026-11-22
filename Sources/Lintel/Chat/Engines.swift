import Foundation
import FoundationModels
import LintelCore

struct ChatTurn {
    enum Role: String {
        case user, assistant
    }

    var role: Role
    var text: String
}

/// A connected model that can build modules and rearrange the bar. Each one answers a system prompt plus a transcript.
enum ChatEngine {
    case subscription(SubscriptionCLI, model: String)
    case anthropic(endpoint: URL, model: String, key: String)
    case openAICompatible(endpoint: URL, model: String, key: String)

    var name: String {
        switch self {
        case .subscription(let cli, _): cli.vendor == .claude ? "Claude subscription" : "ChatGPT subscription"
        case .anthropic(_, let model, _): model
        case .openAICompatible(_, let model, _): model
        }
    }

    static let apiKeySecret = "assistant-api-key"

    static func resolve(settings: AppSettings, secrets: SecretStore) -> ChatEngine? {
        func api() -> ChatEngine? {
            guard let key = secrets.get(apiKeySecret), !key.isEmpty, let endpoint = URL(string: settings.apiEndpoint) else { return nil }
            return settings.apiStyle == "openai"
                ? .openAICompatible(endpoint: endpoint, model: settings.apiModel, key: key)
                : .anthropic(endpoint: endpoint, model: settings.apiModel, key: key)
        }
        func cli(_ vendor: SubscriptionCLI.Vendor) -> ChatEngine? {
            SubscriptionCLI.find(vendor).map { .subscription($0, model: settings.cliModel) }
        }
        switch settings.engine {
        case "claude": return cli(.claude)
        case "codex": return cli(.codex)
        case "api": return api()
        case "on-device": return nil
        default: return cli(.claude) ?? cli(.codex) ?? api()
        }
    }

    func complete(system: String, turns: [ChatTurn]) async throws -> String {
        switch self {
        case .subscription(let cli, let model):
            return try await cli.complete(system: system, prompt: Self.transcript(turns), model: model)
        case .anthropic(let endpoint, let model, let key):
            return try await Self.messages(endpoint: endpoint, model: model, key: key, system: system, turns: turns)
        case .openAICompatible(let endpoint, let model, let key):
            return try await Self.chatCompletions(endpoint: endpoint, model: model, key: key, system: system, turns: turns)
        }
    }

    private static func transcript(_ turns: [ChatTurn]) -> String {
        guard turns.count > 1 else { return turns.first?.text ?? "" }
        return turns.map { "\($0.role == .assistant ? "Your earlier reply" : "User"):\n\($0.text)" }.joined(separator: "\n\n")
    }

    private static func post(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONValue.parse(String(decoding: data, as: UTF8.self)))?["error"]["message"].string
            switch status {
            case 401, 403: throw ModuleFailure("the provider rejected the API key (HTTP \(status))")
            case 429: throw ModuleFailure("the provider is rate limiting this key; try again shortly")
            case 500...: throw ModuleFailure("the provider is having trouble (HTTP \(status)); try again shortly")
            default: throw ModuleFailure("the provider returned HTTP \(status): \(detail ?? String(decoding: data.prefix(200), as: UTF8.self))")
            }
        }
        guard let value = try? JSONValue.parse(String(decoding: data, as: UTF8.self)) else {
            throw ModuleFailure("the provider's reply was not JSON")
        }
        return value
    }

    private static func messages(endpoint: URL, model: String, key: String, system: String, turns: [ChatTurn]) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "v1/messages"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Without fallbacks a safety decline simply ends the request; with them the API re-runs it on another model.
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": model, "max_tokens": 16000, "system": system, "fallbacks": "default",
            "output_config": ["effort": "medium"],
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let reply = try await post(request)
        switch reply["stop_reason"].string {
        case "refusal": throw ModuleFailure("the model declined this request")
        case "max_tokens": throw ModuleFailure("the model's reply was cut off at the length limit; ask for something smaller")
        default: break
        }
        return (reply["content"].array ?? []).filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined()
    }

    private static func chatCompletions(endpoint: URL, model: String, key: String, system: String, turns: [ChatTurn]) async throws -> String {
        var request = URLRequest(url: endpoint.appending(path: "v1/chat/completions"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]] + turns.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let reply = try await post(request)
        guard let text = reply["choices"].array?.first?["message"]["content"].string else {
            throw ModuleFailure("the provider's reply had no message")
        }
        return text
    }
}

/// Runs the vendor's own signed-in command-line tool, so the app never handles the subscription's credentials.
struct SubscriptionCLI {
    enum Vendor: String {
        case claude
        case codex
    }

    let vendor: Vendor
    let executable: URL

    static func find(_ vendor: Vendor) -> SubscriptionCLI? {
        HostServices.find(tool: vendor.rawValue).map { SubscriptionCLI(vendor: vendor, executable: URL(fileURLWithPath: $0)) }
    }

    func complete(system: String, prompt: String, model: String) async throws -> String {
        switch vendor {
        case .claude:
            var arguments = ["-p", "--system-prompt", system, "--tools", "", "--strict-mcp-config", "--no-session-persistence", "--output-format", "json"]
            if !model.isEmpty { arguments += ["--model", model] }
            let output = try await run(arguments, input: prompt)
            guard let result = try? JSONValue.parse(output) else {
                throw ModuleFailure("claude returned unreadable output: \(output.prefix(300))")
            }
            if result["is_error"].bool == true { throw ModuleFailure("claude: \(result["result"].string ?? "unknown error")") }
            return result["result"].string ?? ""
        case .codex:
            let answer = FileManager.default.temporaryDirectory.appending(path: "lintel-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: answer) }
            var arguments = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "-o", answer.path]
            if !model.isEmpty { arguments += ["--model", model] }
            _ = try await run(arguments + ["-"], input: "\(system)\n\n# Request\n\(prompt)")
            return try String(contentsOf: answer, encoding: .utf8)
        }
    }

    private func run(_ arguments: [String], input: String) async throws -> String {
        // A development shell can carry variables that point the CLI at another endpoint or account;
        // the CLI must use its own stored sign-in, as it would when the app is launched from Finder.
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"].reduce(into: [String: String]()) { $0[$1] = inherited[$1] }
        environment["PATH"] = HostServices.toolDirectories.joined(separator: ":")
        let executable = executable
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Shell.run(
                        executable.path, arguments, input: input, timeout: 600, environment: environment,
                        directory: FileManager.default.temporaryDirectory
                    )
                    if result.status == 0 || !result.stdout.isEmpty {
                        continuation.resume(returning: result.stdout)
                    } else {
                        continuation.resume(throwing: ModuleFailure(
                            "\(executable.lastPathComponent) exited with \(result.status): \(result.stderr.suffix(400))"
                        ))
                    }
                } catch {
                    continuation.resume(throwing: ModuleFailure("\(executable.lastPathComponent) could not be started: \(error.localizedDescription)"))
                }
            }
        }
    }
}

@Generable
struct GeneratedThemePatch {
    @Guide(description: "A whole design language to switch to: halo, glass, adaptive, ink, paper or terminal. Null unless the user names one or asks for a wholly different look.")
    var preset: String?
    @Guide(description: "Text size in points, 9 to 32. Bigger text is a larger number. Null to keep.")
    var fontSize: Double?
    @Guide(description: "One of light, regular, medium, semibold, bold. Null to keep.")
    var fontWeight: String?
    @Guide(description: "One of default, rounded, monospaced, serif. Null to keep.")
    var fontDesign: String?
    @Guide(description: "Text colour as #RRGGBB. Null to keep.")
    var textColor: String?
    @Guide(description: "Accent colour for buttons and charts as #RRGGBB. Null to keep.")
    var accentColor: String?
    @Guide(description: "Padding: compact, regular or roomy. Tighter is compact. Null to keep.")
    var density: String?
    @Guide(description: "Gap between items in points, 0 to 40. Tighter or denser is a smaller number; airier is larger. Null to keep.")
    var moduleSpacing: Double?
    @Guide(description: "Corner shape: capsule, rounded or square. Null to keep.")
    var cornerStyle: String?
    @Guide(description: "Blur radius of the shadow behind idle text, 0 to 12. Softer is larger. Null to keep.")
    var shadowBlur: Double?
    @Guide(description: "Opacity of the bar while idle, 0.2 to 1. Subtler or fainter is smaller. Null to keep.")
    var idleOpacity: Double?
    @Guide(description: "Look while the pointer is on the bar: glass, adaptive, solid or plain. Null to keep.")
    var activeMaterial: String?

    var patch: [String: JSONValue] {
        var patch: [String: JSONValue] = [:]
        func set(_ name: String, _ value: String?) { if let value { patch[name] = .string(value) } }
        func set(_ name: String, _ value: Double?) { if let value { patch[name] = .number(value) } }
        set("preset", preset)
        set("fontSize", fontSize)
        set("fontWeight", fontWeight)
        set("fontDesign", fontDesign)
        set("textColor", textColor)
        set("accentColor", accentColor)
        set("density", density)
        set("moduleSpacing", moduleSpacing)
        set("cornerStyle", cornerStyle)
        set("shadowBlur", shadowBlur)
        set("idleOpacity", idleOpacity)
        set("activeMaterial", activeMaterial)
        return patch
    }
}

enum OnDeviceModel {
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    static func themePatch(for message: String, current: Theme) async throws -> [String: JSONValue] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw ModuleFailure("no model is connected, and this Mac's built-in model is unavailable")
        }
        let session = LanguageModelSession(model: model, instructions: """
            You adjust the appearance of a floating status bar. Fill in only the fields the user asks to change \
            and leave every other field null. Make the smallest change that does what was asked: "bigger" or \
            "smaller" text is a step of 2 points, and a size request never changes the weight. Current theme: \(JSONValue.object(current.patch).text).
            """)
        return try await session.respond(to: message, generating: GeneratedThemePatch.self).content.patch
    }
}
