import Foundation
import JavaScriptCore
import LintelCore

/// The helper side of the module runtime: owns every module's JavaScript context and speaks JSON lines with the app.
/// It lives in its own process so that a module stuck in a loop can be killed without freezing the bar.
final class RunnerProcess {
    private var contexts: [String: JSContext] = [:]
    private var exceptions: [String: String] = [:]
    private var pendingCalls: [Int: (resolve: JSValue, reject: JSValue, module: String)] = [:]
    private var nextCall = 1
    private var dataJSON = "{}"
    private let output = FileHandle.standardOutput
    private let virtualMachine = JSVirtualMachine()!

    static func main() -> Never {
        // A closed pipe must end the process quietly instead of raising SIGPIPE mid-write.
        signal(SIGPIPE, SIG_IGN)
        let runner = RunnerProcess()
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                DispatchQueue.main.async { runner.handle(message) }
            }
            exit(0)
        }
        reader.stackSize = 1 << 20
        reader.start()
        dispatchMain()
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed]) else { return }
        data.append(0x0A)
        do { try output.write(contentsOf: data) } catch { exit(0) }
    }

    private func handle(_ message: [String: Any]) {
        let request = message["id"] as? Int
        let module = message["module"] as? String ?? ""
        switch message["op"] as? String {
        case "load":
            load(module, source: message["source"] as? String ?? "", storage: message["storage"] ?? [String: Any](), request: request)
        case "unload":
            contexts[module] = nil
            exceptions[module] = nil
            pendingCalls = pendingCalls.filter { $0.value.module != module }
        case "render":
            invoke(module, function: "__render", arguments: [message["surface"] as? String ?? "chip"], request: request)
        case "act":
            let payload = Self.json(message["payload"] ?? NSNull())
            invoke(module, function: "__act", arguments: [message["action"] as? String ?? "", payload], request: request)
        case "data":
            dataJSON = Self.json(message["data"] ?? [String: Any]())
            for (key, context) in contexts {
                entering(key) { context.objectForKeyedSubscript("__setData").call(withArguments: [dataJSON]) }
            }
        case "reply":
            guard let call = message["call"] as? Int, let pending = pendingCalls.removeValue(forKey: call) else { return }
            entering(pending.module) {
                if let failure = message["error"] as? String {
                    pending.reject.call(withArguments: [failure])
                } else {
                    pending.resolve.call(withArguments: [Self.json(message["ok"] ?? NSNull())])
                }
            }
        default:
            break
        }
    }

    private func entering(_ module: String, _ body: () -> Void) {
        send(["busy": module])
        body()
        send(["busy": NSNull()])
    }

    private func load(_ module: String, source: String, storage: Any, request: Int?) {
        guard let context = JSContext(virtualMachine: virtualMachine) else {
            reply(request, error: "JavaScriptCore is unavailable")
            return
        }
        context.exceptionHandler = { [weak self] _, exception in
            guard let exception else { return }
            let line = exception.objectForKeyedSubscript("line")
            let suffix = line?.isNumber == true ? " (line \(line!.toInt32()))" : ""
            self?.exceptions[module] = (exception.toString() ?? "unknown error") + suffix
        }
        install(in: context, module: module)
        exceptions[module] = nil
        var description: JSValue?
        entering(module) {
            context.evaluateScript(ModulePrelude.source, withSourceURL: URL(string: "lintel://prelude.js"))
            context.objectForKeyedSubscript("__setData").call(withArguments: [dataJSON])
            context.objectForKeyedSubscript("__setStorage").call(withArguments: [Self.json(storage)])
            context.evaluateScript(source, withSourceURL: URL(string: "lintel://\(module).js"))
            if exceptions[module] == nil { description = context.objectForKeyedSubscript("__describe").call(withArguments: []) }
        }
        if let failure = exceptions[module] {
            reply(request, error: failure)
            return
        }
        guard let description, description.isString,
              let parsed = try? JSONSerialization.jsonObject(with: Data(description.toString().utf8))
        else {
            reply(request, error: "the file never called defineModule({ meta, render })")
            return
        }
        contexts[module] = context
        reply(request, ok: parsed)
    }

    private func invoke(_ module: String, function: String, arguments: [Any], request: Int?) {
        guard let context = contexts[module] else {
            reply(request, error: "the module is not loaded")
            return
        }
        var isFinished = false
        let done: @convention(block) (JSValue, JSValue) -> Void = { [weak self] result, failure in
            guard !isFinished else { return }
            isFinished = true
            if failure.isNull || failure.isUndefined {
                let parsed = try? JSONSerialization.jsonObject(with: Data(result.toString().utf8), options: [.fragmentsAllowed])
                self?.reply(request, ok: parsed ?? NSNull())
            } else {
                self?.reply(request, error: failure.toString())
            }
        }
        exceptions[module] = nil
        entering(module) {
            context.objectForKeyedSubscript(function).call(withArguments: arguments + [unsafeBitCast(done, to: AnyObject.self)])
        }
        if let failure = exceptions[module], !isFinished {
            isFinished = true
            reply(request, error: failure)
        }
    }

    private func install(in context: JSContext, module: String) {
        let call: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] name, arguments, resolve, reject in
            guard let self else { return }
            let identifier = self.nextCall
            self.nextCall += 1
            self.pendingCalls[identifier] = (resolve, reject, module)
            let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [Any]()
            self.send(["call": identifier, "module": module, "name": name, "args": parsed])
        }
        context.setObject(call, forKeyedSubscript: "__call" as NSString)

        let post: @convention(block) (String, String) -> Void = { [weak self] name, arguments in
            let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [Any]()
            self?.send(["post": name, "module": module, "args": parsed])
        }
        context.setObject(post, forKeyedSubscript: "__post" as NSString)
    }

    private func reply(_ request: Int?, ok value: Any) {
        guard let request else { return }
        send(["id": request, "ok": value])
    }

    private func reply(_ request: Int?, error: String) {
        guard let request else { return }
        send(["id": request, "error": error])
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }
}
