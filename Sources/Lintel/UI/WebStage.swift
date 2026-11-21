import AppKit
import LintelCore
import SwiftUI
import WebKit

/// A live page from the signed-in browser profile, framed inside a panel.
struct WebClipView: View {
    let node: ViewNode
    let context: RenderContext

    var body: some View {
        let address = node.string("url") ?? ""
        let heightToken = node.string("height")
        let fillsWidget = context.isInWidget && (heightToken == nil || heightToken == "fill")
        let fixedHeight = CGFloat(context.metrics.blockHeight(heightToken ?? "large"))
        if let url = URL(string: address), let manifest = context.manifest, manifest.allows(url) {
            WebClip(
                url: url, selector: node.string("selector"), isInteractive: node.bool("interactive"),
                zoom: min(max(node.number("zoom") ?? 1, 0.25), 3),
                reloadSeconds: node.number("reloadSeconds").map { max($0, 15) }, manifest: manifest
            )
            .frame(maxWidth: .infinity, minHeight: fillsWidget ? 80 : fixedHeight, maxHeight: fillsWidget ? .infinity : fixedHeight)
            .clipShape(context.tileShape)
            .overlay(context.tileShape.stroke(context.separator, lineWidth: 1))
        } else {
            NodeView(node: ViewNode(.note, ["value": .string("\(address) is not covered by this module's permissions"), "tone": "bad"]), context: context)
        }
    }
}

private final class PassThroughContainer: NSView {
    var isInteractive = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }
}

private struct WebClip: NSViewRepresentable {
    let url: URL
    let selector: String?
    let isInteractive: Bool
    let zoom: Double
    let reloadSeconds: Double?
    let manifest: ModuleManifest

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = PassThroughContainer()
        let webView = BrowserHost.makeWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        context.coordinator.webView = webView
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        (container as? PassThroughContainer)?.isInteractive = isInteractive
        let coordinator = context.coordinator
        coordinator.manifest = manifest
        coordinator.selector = selector
        coordinator.webView?.pageZoom = zoom
        if coordinator.loadedURL != url {
            coordinator.loadedURL = url
            coordinator.webView?.load(URLRequest(url: url))
        }
        if coordinator.reloadSeconds != reloadSeconds {
            coordinator.reloadSeconds = reloadSeconds
            coordinator.reloadTimer?.invalidate()
            if let reloadSeconds {
                coordinator.reloadTimer = Timer.scheduledTimer(withTimeInterval: reloadSeconds, repeats: true) { [weak coordinator] _ in
                    MainActor.assumeIsolated { _ = coordinator?.webView?.reload() }
                }
            }
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.reloadTimer?.invalidate()
        coordinator.webView?.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var webView: WKWebView?
        var manifest: ModuleManifest?
        var selector: String?
        var loadedURL: URL?
        var reloadSeconds: Double?
        var reloadTimer: Timer?

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let target = navigationAction.request.url else { return decisionHandler(.cancel) }
            if navigationAction.targetFrame?.isMainFrame == false || target.scheme == "about" {
                return decisionHandler(.allow)
            }
            if manifest?.allows(target) == true { return decisionHandler(.allow) }
            if navigationAction.navigationType == .linkActivated, target.scheme == "https" { NSWorkspace.shared.open(target) }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            frame()
            // Pages that fill in after load move the element; follow it for the first few seconds.
            for delay in [1.0, 3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.frame() }
            }
        }

        private func frame() {
            guard let selector, !selector.isEmpty else { return }
            webView?.callAsyncJavaScript(
                """
                const element = document.querySelector(selector);
                if (!element) return false;
                const box = element.getBoundingClientRect();
                window.scrollTo(box.left + window.scrollX - 8, box.top + window.scrollY - 8);
                return true;
                """,
                arguments: ["selector": selector], in: nil, in: .defaultClient
            ) { _ in }
        }
    }
}

/// A small web app a module supplies, sandboxed: no network beyond the module's hosts, and a bridge to its actions.
struct MiniAppView: View {
    let node: ViewNode
    let context: RenderContext

    var body: some View {
        let heightToken = node.string("height")
        let fillsWidget = context.isInWidget && (heightToken == nil || heightToken == "fill")
        let fixedHeight = CGFloat(context.metrics.blockHeight(heightToken ?? "large"))
        MiniApp(
            html: node.string("html") ?? "", state: node.props["state"] ?? .null, variables: Self.variables(context),
            hosts: context.manifest?.hosts ?? [], perform: context.performForResult
        )
        .frame(maxWidth: .infinity, minHeight: fillsWidget ? 80 : fixedHeight, maxHeight: fillsWidget ? .infinity : fixedHeight)
        .clipShape(context.tileShape)
    }

    static func variables(_ context: RenderContext) -> [String: String] {
        func css(_ color: Color) -> String {
            let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
            return "rgba(\(Int(resolved.redComponent * 255)), \(Int(resolved.greenComponent * 255)), \(Int(resolved.blueComponent * 255)), \(String(format: "%.3f", resolved.alphaComponent)))"
        }
        return [
            "--lt-text": css(context.primary), "--lt-secondary": css(context.secondary), "--lt-tertiary": css(context.tertiary),
            "--lt-accent": css(context.accent), "--lt-on-accent": css(context.onAccent), "--lt-fill": css(context.fill),
            "--lt-strong-fill": css(context.strongFill), "--lt-separator": css(context.separator),
            "--lt-good": css(.green), "--lt-warn": css(.orange), "--lt-bad": css(.red),
            "--lt-radius": "\(context.metrics.tileCornerRadius)px", "--lt-unit": "\(context.metrics.unit)px",
            "--lt-font-size": "\(context.metrics.fontSize(role: "label"))px",
            "--lt-font-family": context.theme.fontDesign == "monospaced" ? "ui-monospace, Menlo, monospace"
                : context.theme.fontDesign == "serif" ? "ui-serif, 'New York', serif"
                : context.theme.fontDesign == "rounded" ? "ui-rounded, -apple-system, system-ui" : "-apple-system, system-ui",
        ]
    }
}

private struct MiniApp: NSViewRepresentable {
    let html: String
    let state: JSONValue
    let variables: [String: String]
    let hosts: [String]
    let perform: (String, JSONValue) async -> JSONValue

    static let bridge = """
    window.lintel = {
      _handlers: [], _state: null, _hasState: false,
      send: function (action, payload) {
        return window.webkit.messageHandlers.lintel.postMessage({ action: String(action), payload: payload === undefined ? null : payload });
      },
      onState: function (handler) { this._handlers.push(handler); if (this._hasState) handler(this._state); },
      _setState: function (state) {
        this._state = state; this._hasState = true;
        this._handlers.forEach(function (handler) { try { handler(state); } catch (error) { console.error(error); } });
      },
      _setVariables: function (variables) {
        for (var name in variables) document.documentElement.style.setProperty(name, variables[name]);
      }
    };
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "lintel")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // No public switch makes a WKWebView's backing transparent on macOS; this key is the long-standing way.
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.perform = perform
        coordinator.state = state
        coordinator.variables = variables
        if coordinator.loadedHTML != html || coordinator.loadedHosts != hosts {
            coordinator.loadedHTML = html
            coordinator.loadedHosts = hosts
            coordinator.load(html: html, hosts: hosts)
        } else {
            coordinator.push()
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        var webView: WKWebView?
        var perform: (String, JSONValue) async -> JSONValue = { _, _ in .null }
        var state: JSONValue = .null
        var variables: [String: String] = [:]
        var loadedHTML: String?
        var loadedHosts: [String] = []
        private var isReady = false

        func load(html: String, hosts: [String]) {
            isReady = false
            // WebKit's rule syntax has no alternation, hence one rule per scheme.
            var rules: [[String: Any]] = ["^https?://", "^wss?://", "^ftp://"].map {
                ["trigger": ["url-filter": $0], "action": ["type": "block"]]
            }
            for host in hosts {
                let name = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
                let escaped = (name.split(separator: ":").first.map(String.init) ?? name).replacingOccurrences(of: ".", with: "\\.")
                for scheme in ["https?", "wss?"] {
                    rules.append(["trigger": ["url-filter": "^\(scheme)://([a-z0-9.-]*\\.)?\(escaped)[:/]"], "action": ["type": "ignore-previous-rules"]])
                }
            }
            let encoded = (try? JSONSerialization.data(withJSONObject: rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let identifier = "lintel-app-\(abs(encoded.hashValue))"
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { [weak self] list, _ in
                MainActor.assumeIsolated {
                    guard let self, let webView = self.webView, self.loadedHTML == html else { return }
                    // Without its rule list the app would have open network access, so it does not load at all.
                    guard let list else {
                        FileHandle.standardError.write(Data("lintel: a mini app's network rules did not compile; it was not loaded\n".utf8))
                        return
                    }
                    webView.configuration.userContentController.removeAllContentRuleLists()
                    webView.configuration.userContentController.add(list)
                    let kit = Resources.text("Kit/kit.css") ?? ""
                    let root = self.variables.map { "\($0.key): \($0.value);" }.sorted().joined(separator: " ")
                    let document = """
                    <!doctype html><html><head><meta charset="utf-8">
                    <meta name="viewport" content="width=device-width, initial-scale=1">
                    <style>:root { \(root) }\n\(kit)</style></head><body>\(html)</body></html>
                    """
                    webView.loadHTMLString(document, baseURL: nil)
                }
            }
        }

        func push() {
            guard isReady, let webView else { return }
            webView.evaluateJavaScript("window.lintel._setVariables(\(JSONValue.object(variables.mapValues(JSONValue.string)).text)); window.lintel._setState(\(state.text));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            push()
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let target = navigationAction.request.url
            if navigationAction.navigationType == .other, target?.scheme == "about" { return decisionHandler(.allow) }
            if navigationAction.navigationType == .linkActivated, let target, target.scheme == "https" { NSWorkspace.shared.open(target) }
            decisionHandler(navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel)
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            let body = JSONValue(any: message.body)
            guard let action = body["action"].string else { return replyHandler(nil, "lintel.send needs an action name") }
            Task {
                let result = await perform(action, body["payload"])
                replyHandler(result.isNull ? nil : result.any, nil)
            }
        }
    }
}
