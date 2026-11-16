import AppKit
import LintelCore
import WebKit

/// The app's own browser profile. Modules read pages through it, so a site the user signed in to here stays signed in.
@MainActor
final class BrowserHost: NSObject, WKNavigationDelegate {
    static let profile = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6F1D2C1E-7B5A-4E0B-9C55-0A6C1B6E9D01")!)
    static let pageTimeout: TimeInterval = 25
    // WKWebView's default user agent omits the Safari token, which many sites treat as an unsupported browser.
    static let applicationName = "Version/26.0 Safari/605.1.15"

    enum Extraction {
        case text(selector: String)
        case all(selector: String)
        case outline

        var script: String {
            switch self {
            case .text:
                """
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                  const element = document.querySelector(selector);
                  const found = element ? element.innerText.trim() : '';
                  if (found) return found;
                  await new Promise((resolve) => setTimeout(resolve, 250));
                }
                return null;
                """
            case .all:
                """
                const deadline = Date.now() + 8000;
                while (Date.now() < deadline) {
                  const found = Array.from(document.querySelectorAll(selector)).map((e) => e.innerText.trim()).filter(Boolean);
                  if (found.length) return found.slice(0, 50);
                  await new Promise((resolve) => setTimeout(resolve, 250));
                }
                return [];
                """
            case .outline:
                """
                await new Promise((resolve) => setTimeout(resolve, 1500));
                const describe = (element) => {
                  if (element.id && document.querySelectorAll('#' + CSS.escape(element.id)).length === 1) return '#' + CSS.escape(element.id);
                  const parts = [];
                  let node = element;
                  while (node && node.nodeType === 1 && parts.length < 4) {
                    let part = node.tagName.toLowerCase();
                    if (node.id) { parts.unshift('#' + CSS.escape(node.id)); break; }
                    const names = Array.from(node.classList).filter((name) => /^[a-zA-Z][\\w-]*$/.test(name)).slice(0, 2);
                    if (names.length) part += '.' + names.join('.');
                    const test = node.getAttribute('data-testid');
                    if (test) part = '[data-testid="' + test + '"]';
                    parts.unshift(part);
                    node = node.parentElement;
                  }
                  return parts.join(' > ');
                };
                const lines = [];
                const seen = new Set();
                for (const element of document.querySelectorAll('h1,h2,h3,h4,p,li,td,th,span,a,button,strong,em,b,time,label,dd,dt,div')) {
                  if (lines.length >= 160) break;
                  const own = Array.from(element.childNodes).filter((n) => n.nodeType === 3).map((n) => n.textContent.trim()).join(' ').trim();
                  if (own.length < 2 || !element.offsetParent) continue;
                  const selector = describe(element);
                  const key = selector + '|' + own.slice(0, 30);
                  if (seen.has(key)) continue;
                  seen.add(key);
                  lines.push(selector + '  =>  ' + own.slice(0, 90));
                }
                return 'Title: ' + document.title + '\\nURL: ' + location.href + '\\n' + lines.join('\\n');
                """
            }
        }

        var arguments: [String: Any] {
            switch self {
            case .text(let selector), .all(let selector): ["selector": selector]
            case .outline: [:]
            }
        }
    }

    private struct Job {
        let url: URL
        let extraction: Extraction
        let completion: (Result<JSONValue, ModuleFailure>) -> Void
    }

    private var queue: [Job] = []
    private var active: (job: Job, webView: WKWebView)?
    private var signInWindows: [BrowserWindowController] = []

    func extract(_ extraction: Extraction, from url: URL) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.append(Job(url: url, extraction: extraction) { continuation.resume(with: $0) })
            startNext()
        }
    }

    /// One page at a time: background page loads are heavy, and a burst of them looks like a bot to the site.
    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let webView = Self.makeWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
        webView.navigationDelegate = self
        active = (job, webView)
        webView.load(URLRequest(url: job.url))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageTimeout) { [weak self, weak webView] in
            guard let self, let webView, self.active?.webView === webView else { return }
            self.finish(.failure(ModuleFailure("\(job.url.host() ?? "the page") timed out")))
        }
    }

    private func finish(_ result: Result<JSONValue, ModuleFailure>) {
        guard let finished = active else { return }
        active = nil
        finished.webView.navigationDelegate = nil
        finished.webView.stopLoading()
        finished.job.completion(result)
        startNext()
    }

    static func makeWebView(frame: NSRect, isPersistent: Bool = true) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = isPersistent ? profile : .nonPersistent()
        configuration.applicationNameForUserAgent = applicationName
        return WKWebView(frame: frame, configuration: configuration)
    }

    func openSignInWindow(at url: URL) {
        let controller = BrowserWindowController(url: url)
        signInWindows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            self?.signInWindows.removeAll { $0 === controller }
        }
        controller.show()
    }

    static func clearProfile() async {
        await profile.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    static func signedInHosts() async -> [String] {
        let records = await profile.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        return records.map(\.displayName).sorted()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let current = active, current.webView === webView else { return }
        webView.callAsyncJavaScript(
            current.job.extraction.script, arguments: current.job.extraction.arguments, in: nil, in: .page
        ) { [weak self] result in
            guard let self, self.active?.webView === webView else { return }
            switch result {
            case .success(let value): self.finish(.success(JSONValue(any: value)))
            case .failure(let error): self.finish(.failure(ModuleFailure(error.localizedDescription)))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if active?.webView === webView { finish(.failure(ModuleFailure(error.localizedDescription))) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if active?.webView === webView { finish(.failure(ModuleFailure(error.localizedDescription))) }
    }
}

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, NSTextFieldDelegate {
    var onClose: () -> Void = {}
    private let window: NSWindow
    private let webView: WKWebView
    private let addressField = NSTextField()

    init(url: URL) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
        )
        webView = BrowserHost.makeWebView(frame: .zero)
        super.init()
        window.title = "Lintel Browser"
        window.isReleasedWhenClosed = false
        window.delegate = self

        addressField.stringValue = url.absoluteString
        addressField.delegate = self
        addressField.target = self
        addressField.action = #selector(go)
        addressField.bezelStyle = .roundedBezel
        addressField.placeholderString = "Address"

        let back = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!, target: webView, action: #selector(WKWebView.goBack(_:)))
        let forward = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")!, target: webView, action: #selector(WKWebView.goForward(_:)))
        let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")!, target: webView, action: #selector(WKWebView.reload(_:)))
        for button in [back, forward, reload] { button.bezelStyle = .texturedRounded }
        let toolbar = NSStackView(views: [back, forward, reload, addressField])
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let stack = NSStackView(views: [toolbar, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        window.contentView = stack
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func go() {
        var address = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        if !address.contains("://") { address = "https://" + address }
        if let url = URL(string: address) { webView.load(URLRequest(url: url)) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        addressField.stringValue = webView.url?.absoluteString ?? ""
        window.title = webView.url?.host().map { "Lintel Browser — \($0)" } ?? "Lintel Browser"
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
