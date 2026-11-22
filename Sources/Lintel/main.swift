import AppKit
import Foundation
import LintelCore

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "runner" {
    RunnerProcess.main()
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func emit(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

switch arguments.first {
case "ctl":
    ControlChannel.post(arguments.dropFirst().first ?? "{}")
    // Delivery is asynchronous; leaving at once can drop the notification.
    Thread.sleep(forTimeInterval: 0.2)
    exit(0)
case "metrics":
    let file = FileManager.default.temporaryDirectory.appending(path: "lintel-metrics-\(UUID().uuidString).json")
    ControlChannel.post(#"{"cmd":"metrics","path":"\#(file.path)"}"#)
    for _ in 0..<20 where !FileManager.default.fileExists(atPath: file.path) { Thread.sleep(forTimeInterval: 0.1) }
    guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder.metrics.decode(MetricsRecord.self, from: data) else {
        FileHandle.standardError.write(Data("lintel: no running Lintel answered; metrics are only in debug and local builds\n".utf8))
        exit(1)
    }
    try? FileManager.default.removeItem(at: file)
    let encoder = JSONEncoder.metrics
    encoder.outputFormatting.insert(.prettyPrinted)
    emit(String(decoding: (try? encoder.encode(record)) ?? Data(), as: UTF8.self))
    exit(0)
case "guide":
    emit(DesignGuide.reference)
    exit(0)
default:
    break
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppController?
    private var stage: Stage?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        app?.dockClicked()
        return false
    }

    @objc func showSettings(_ sender: Any?) {
        app?.showWindow(.general)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = AppController(home: .standard)
        self.app = app
        switch arguments.first {
        case "trial":
            app.host.primeData()
            Task { await self.trial(app) }
        case "stage":
            app.startModules(watching: false)
            Task { await self.shoot(app) }
        case "chat":
            app.startModules(watching: false)
            Task {
                let reply = await app.chat.handle(arguments.dropFirst().filter { !$0.hasPrefix("--") }.joined(separator: " "), approving: arguments.contains("--approve"))
                emit(reply.text + (reply.detail.map { "\n\($0)" } ?? ""))
                exit(reply.isError ? 1 : 0)
            }
        case "export":
            app.startModules(watching: false)
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                let listings = await app.host.listings()
                guard arguments.count == 3, let listing = listings.first(where: { $0.id == arguments[1] }),
                      let source = Resources.source(of: listing.file)
                else {
                    emit("usage: Lintel export <module id> <file>")
                    exit(1)
                }
                app.home.save(ModuleBundle(
                    id: listing.id, title: listing.title, permissions: listing.permissions,
                    prompt: app.host.prompt(of: listing.id), source: source
                ), to: URL(fileURLWithPath: arguments[2]))
                emit(arguments[2])
                exit(0)
            }
        case "import":
            app.host.primeData()
            Task {
                guard arguments.count >= 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
                    emit("usage: Lintel import <file> [--approve]")
                    exit(1)
                }
                let bundle = try? JSONDecoder().decode(ModuleBundle.self, from: data)
                let source = bundle?.source ?? String(decoding: data, as: UTF8.self)
                let trial = await app.host.trial(source: source)
                guard trial.errors.isEmpty, let manifest = trial.description?.manifest else {
                    emit("not installed:\n  " + trial.errors.joined(separator: "\n  "))
                    exit(1)
                }
                try? app.host.install(source: source, id: manifest.id, prompt: bundle?.prompt)
                if arguments.contains("--approve"), !manifest.permissions.isEmpty {
                    app.home.save(app.home.loadApprovals().merging([manifest.id: Approval(permissions: manifest.permissions)]) { $1 }, to: app.home.approvalsFile)
                }
                emit("installed \(manifest.id)" + (manifest.permissions.isEmpty ? "" : " (asks for: \(manifest.permissions.joined(separator: ", ")))"))
                exit(0)
            }
        case "items":
            let items = MenuBarItems.scanNow()
            for item in items {
                emit("\(item.key) | \(item.label) | \(Int(item.frame.minX)),\(Int(item.frame.minY)) \(Int(item.frame.width))x\(Int(item.frame.height))")
            }
            guard let index = arguments.firstIndex(of: "--pictures"), index + 1 < arguments.count else { exit(0) }
            let folder = URL(fileURLWithPath: arguments[index + 1])
            Task {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (key, picture) in await MenuBarItems.pictures(of: items) {
                    let kind = picture.map { $0.isTemplate ? "monochrome" : "colour" } ?? "empty"
                    let file = folder.appending(path: "\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key).png")
                    if let image = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
                    }
                    emit("\(key): \(kind)")
                }
                exit(0)
            }
        default:
            app.startModules()
            app.startInterface()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let app else { return }
        for url in urls where url.pathExtension == ModuleBundle.fileExtension || url.pathExtension == "js" {
            ModuleSharing.importModule(app: app, from: url)
        }
    }

    private func trial(_ app: AppController) async {
        var failed = false
        for path in arguments.dropFirst() {
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
                emit("\(path): cannot read")
                failed = true
                continue
            }
            let trial = await app.host.trial(source: source)
            let name = URL(fileURLWithPath: path).lastPathComponent
            if trial.errors.isEmpty {
                let warnings = trial.problems.filter { $0.severity == .warning }.map(\.message)
                emit("\(name): ok" + (warnings.isEmpty ? "" : "\n  warning: " + warnings.joined(separator: "\n  warning: ")))
            } else {
                failed = true
                emit("\(name): FAILED\n  " + trial.errors.joined(separator: "\n  "))
            }
            if arguments.contains("--dump") {
                emit("  chip: \(String(describing: trial.chip))")
            }
        }
        exit(failed ? 1 : 0)
    }

    /// `stage --out /tmp/shots --shots halo/idle,halo/active,ink/panel:system [--backdrop photo] [--size 900x620]`
    private func shoot(_ app: AppController) async {
        let directory = URL(fileURLWithPath: option("out") ?? "/tmp/lintel-stage")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dimensions = (option("size") ?? "900x620").split(separator: "x").compactMap { Double($0) }
        let size = CGSize(width: dimensions.first ?? 900, height: dimensions.last ?? 620)
        let backdrop = Backdrop.Style(rawValue: option("backdrop") ?? "photo") ?? .photo
        let baseTheme = app.model.theme
        if let anchor = option("anchor").flatMap(BarAnchor.init(rawValue:)) { app.model.settings.anchor = anchor }
        try? await Task.sleep(for: .seconds(Double(option("wait") ?? "3") ?? 3))
        let stage = Stage(model: app.model, size: size, backdrop: backdrop)
        self.stage = stage

        for shot in (option("shots") ?? "halo/idle,halo/active").split(separator: ",").map(String.init) {
            let parts = shot.split(separator: "/", maxSplits: 1).map(String.init)
            let state = parts.last ?? "idle"
            app.model.theme = parts.count == 2 ? (Theme.preset(parts[0]) ?? baseTheme) : baseTheme
            stage.updateAdaptiveBackdrop()
            app.host.closePanel()
            for id in Array(app.model.layout.widgets.keys) {
                app.host.setWidget(id, to: nil)
            }
            if state.hasPrefix("matrix:") {
                let id = String(state.dropFirst(7))
                app.host.renderWidget(id)
                try? await Task.sleep(for: .seconds(1.2))
                let matrixStage = Stage(model: app.model, size: CGSize(width: max(size.width, 1020), height: max(size.height, 920)), backdrop: backdrop, matrixSlotID: id)
                try? await Task.sleep(for: .seconds(Double(option("settle") ?? "1.2") ?? 1.2))
                let file = directory.appending(path: shot.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".png")
                do {
                    try await matrixStage.capture(to: file)
                    emit(file.path)
                } catch {
                    emit("failed \(shot): \(ModuleFailure.describe(error))")
                }
                matrixStage.close()
                continue
            } else if state.hasPrefix("widget:") {
                // Format: widget:col0Top:240x180/col0Bottom:240x140+col1:320x260
                let spec = String(state.dropFirst(7))
                var layout = app.model.layout
                layout.widgets = [:]
                layout.widgetColumns = []
                for colSpec in spec.split(separator: "+").map(String.init) {
                    var colIDs: [String] = []
                    for itemSpec in colSpec.split(separator: "/").map(String.init) {
                        let parts = itemSpec.split(separator: ":").map(String.init)
                        guard let id = parts.first else { continue }
                        let dims = (parts.dropFirst().first ?? "300x240").split(separator: "x").compactMap { Double($0) }
                        let box = WidgetBox(width: dims.first ?? 300, height: dims.last ?? 240)
                        layout.widgets[id] = box
                        colIDs.append(id)
                        app.host.ensureWidgetRendered(id)
                    }
                    if !colIDs.isEmpty { layout.widgetColumns.append(colIDs) }
                }
                app.host.update(layout)
                for id in layout.widgets.keys { app.host.renderWidget(id) }
                app.model.isActive = false
            } else {
                app.model.isActive = state != "idle"
                if state.hasPrefix("panel:") {
                    let id = String(state.dropFirst(6))
                    if id == AppController.assistantSlot {
                        app.model.panel = PanelState(slotID: id, content: .assistant)
                    } else {
                        app.host.openPanel(id)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(Double(option("settle") ?? "1.6") ?? 1.6))
            let file = directory.appending(path: shot.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".png")
            do {
                try await stage.capture(to: file)
                emit(file.path)
            } catch {
                emit("failed \(shot): \(ModuleFailure.describe(error))")
            }
        }
        for slot in app.model.slots where slot.failure != nil {
            emit("module \(slot.id) failed: \(slot.failure ?? "")")
        }
        exit(0)
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let mainMenu = EditCommand.makeMainMenu()
    application.mainMenu = mainMenu
    application.windowsMenu = EditCommand.windowsMenu(in: mainMenu)
    application.delegate = delegate
    application.run()
}
