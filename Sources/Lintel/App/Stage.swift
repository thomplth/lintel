import AppKit
import LintelCore
import ScreenCaptureKit
import SwiftUI

/// A stand-in desktop for looking at the bar and a panel over busy content without touching the real desktop.
/// The window sits below ordinary windows and is photographed on its own, so nothing on screen is disturbed or captured.
@MainActor
final class Stage {
    private let window: NSWindow
    private let model: BarModel

    init(model: BarModel, size: CGSize, backdrop: Backdrop.Style, matrixSlotID: String? = nil) {
        self.model = model
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        let hostingView: NSView
        if let matrixSlotID {
            let v = NSHostingView(rootView: MatrixStageView(model: model, slotID: matrixSlotID, backdrop: backdrop))
            v.sizingOptions = []
            hostingView = v
        } else {
            let v = NSHostingView(rootView: StageView(model: model, backdrop: backdrop, maxPanelHeight: size.height - 90))
            v.sizingOptions = []
            hostingView = v
        }
        window.contentView = hostingView
        model.maxBarWidth = size.width - 32
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()
    }

    func capture(to file: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw ModuleFailure("the stage window is not visible to screen capture")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width) * 2
        configuration.height = Int(window.frame.height) * 2
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration
        )
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ModuleFailure("the capture could not be encoded")
        }
        try data.write(to: file)
    }

    func close() {
        window.orderOut(nil)
    }
}

private struct StageView: View {
    @ObservedObject var model: BarModel
    let backdrop: Backdrop.Style
    let maxPanelHeight: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Backdrop(style: backdrop)
            VStack(alignment: model.alignment, spacing: 0) {
                BarView(model: model)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: model.alignment, vertical: .top))
                    .fixedSize(horizontal: false, vertical: true)
                if model.panel != nil {
                    PanelView(model: model, maxHeight: maxPanelHeight, onSize: { _ in })
                        .padding(.top, -PanelView.margin + 6)
                        .padding(.horizontal, -PanelView.margin + 8)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: model.alignment, vertical: .top))
        }
    }
}

private struct MatrixStageView: View {
    @ObservedObject var model: BarModel
    let slotID: String
    let backdrop: Backdrop.Style

    var body: some View {
        let metrics = Metrics(model.theme)
        let viewports = WidgetViewport.canonicalMatrix(for: metrics)
        ZStack(alignment: .topLeading) {
            Backdrop(style: backdrop)
            if let slot = model.slot(slotID) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(viewports.prefix(3), id: \.id) { vp in
                            cell(vp, slot: slot)
                        }
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(viewports.dropFirst(3), id: \.id) { vp in
                            cell(vp, slot: slot)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func cell(_ vp: WidgetViewport, slot: Slot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(vp.title)  \(Int(vp.size.width))×\(Int(vp.size.height))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.6), radius: 2)
            WidgetCardView(
                slot: slot,
                box: WidgetBox(vp.size),
                node: slot.widgetNode,
                configureNode: slot.configureNode,
                isConfiguring: false,
                isLoading: slot.widgetNode == nil,
                failure: slot.failure,
                theme: model.theme,
                anchor: .right,
                isPeek: false,
                isSelected: false,
                isResizingThis: false,
                isDraggingThis: false,
                columnCount: 1,
                stackCount: 1,
                model: model
            )
            .equatable()
        }
    }
}

struct Backdrop: View {
    enum Style: String {
        case photo, light, dark, document
    }

    let style: Style

    var body: some View {
        switch style {
        case .light: Color(white: 0.96)
        case .dark: Color(white: 0.08)
        case .photo:
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.32), Color(red: 0.86, green: 0.28, blue: 0.44), Color(red: 0.24, green: 0.2, blue: 0.56), Color(red: 0.05, green: 0.1, blue: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { canvas, size in
                    for index in 0..<9 {
                        let x = size.width * (0.08 + 0.11 * Double(index))
                        let radius = size.height * (0.12 + 0.05 * Double(index % 4))
                        let circle = Path(ellipseIn: CGRect(x: x - radius, y: size.height * (0.15 + 0.09 * Double((index * 5) % 7)) - radius, width: radius * 2, height: radius * 2))
                        canvas.fill(circle, with: .color(index % 2 == 0 ? .white.opacity(0.16) : .black.opacity(0.18)))
                    }
                }
            }
        case .document:
            Color.white.overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Quarterly planning notes").font(.system(size: 26, weight: .bold)).foregroundStyle(.black)
                    ForEach(0..<34, id: \.self) { line in
                        Text("The quick brown fox jumps over the lazy dog while the bar floats above ordinary window content, line \(line).")
                            .font(.system(size: 13)).foregroundStyle(.black.opacity(0.85)).lineLimit(1)
                    }
                }
                .padding(.leading, 220)
                .padding(.top, 8)
                .fixedSize()
            }
            .clipped()
        }
    }
}

/// Lets a script or a test drive the running app: `Lintel ctl '{"cmd":"open","slot":"system"}'`.
@MainActor
final class ControlChannel {
    nonisolated static let name = Notification.Name("app.lintel.control")
    private unowned let app: AppController
    /// Lets a test confirm that keystrokes really reach this app before it types anything.
    private var keyEventsSeen = 0

    init(app: AppController) {
        self.app = app
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.keyEventsSeen += 1
            return event
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.name, object: nil, queue: .main) { [weak self] note in
            let text = note.object as? String ?? "{}"
            MainActor.assumeIsolated { self?.handle((try? JSONValue.parse(text)) ?? .null) }
        }
    }

    nonisolated static func post(_ command: String) {
        DistributedNotificationCenter.default().postNotificationName(name, object: command, userInfo: nil, deliverImmediately: true)
    }

    private func handle(_ command: JSONValue) {
        switch command["cmd"].string {
        case "open": if let slot = command["slot"].string { app.openModulePanel(slot) }
        case "resize":
            if let slot = command["slot"].string {
                if command["collapse"].bool == true {
                    app.host.setWidget(slot, to: nil)
                } else if let w = command["width"].number, let h = command["height"].number {
                    app.host.setWidget(slot, to: WidgetBox(width: w, height: h))
                } else {
                    let shape = app.model.slot(slot)?.defaultShape ?? .card
                    app.host.setWidget(slot, to: Metrics(app.model.theme).defaultWidgetBox(for: shape))
                }
            }
        case "stack":
            if let slot = command["slot"].string, let column = command["column"].number {
                let index = Int(command["index"].number ?? 0)
                app.host.moveWidget(slot, to: .stack(column: Int(column), index: index))
            }
        case "close": app.closePanel()
        case "assistant": app.openAssistant(draft: command["draft"].string)
        case "studio": app.showStudio(module: command["module"].string, focusChat: command["chat"].bool ?? false)
        case "chat": if let text = command["text"].string { app.openAssistant(); app.chat.submit(text) }
        case "jobs":
            guard let path = command["path"].string else { return }
            let list = app.host.jobs.snapshots.map {
                JobPlanner.jsonSnapshot(moduleID: $0.moduleID, moduleTitle: $0.moduleTitle, spec: $0.spec, record: $0.record)
            }
            try? JSONValue.array(list).text.write(toFile: path, atomically: true, encoding: .utf8)
        case "job-run":
            if let key = command["key"].string, let colon = key.firstIndex(of: ":") {
                let mod = String(key[..<colon])
                let job = String(key[key.index(after: colon)...])
                Task { await app.host.jobs.runNow(moduleID: mod, jobID: job) }
            } else if let mod = command["module"].string, let job = command["job"].string {
                Task { await app.host.jobs.runNow(moduleID: mod, jobID: job) }
            }
        case "hold": app.bar?.hold()
        case "dock": app.dockClicked()
        case "release": app.closePanel(); app.bar?.release()
        case "settings": app.showSettings(tab: command["tab"].string.flatMap(SettingsTab.init(rawValue:)) ?? .general)
        case "action":
            if let slot = command["slot"].string, let action = command["action"].string {
                Task { await app.host.perform(slot, action: action, payload: command["payload"]) }
            }
        case "windows":
            guard let path = command["path"].string else { return }
            let report: [JSONValue] = app.windows.map { entry in
                [
                    "name": .string(entry.name), "id": .number(Double(entry.window.windowNumber)),
                    "x": .number(entry.window.frame.minX), "y": .number(entry.window.frame.minY),
                    "width": .number(entry.window.frame.width), "height": .number(entry.window.frame.height),
                ]
            }
            try? JSONValue.array(report).text.write(toFile: path, atomically: true, encoding: .utf8)
        case "state":
            guard let path = command["path"].string else { return }
            let slots: [JSONValue] = app.model.slots.map { slot in
                let box = app.model.layout.widgetBox(of: slot.id)
                return ["id": .string(slot.id), "title": .string(slot.title), "failure": slot.failure.map(JSONValue.string) ?? .null,
                 "needsApproval": .bool(slot.needsApproval), "hasChip": .bool(slot.chip != nil || slot.image != nil),
                 "widget": box.map { ["width": .number($0.width), "height": .number($0.height)] } ?? .null,
                 "frame": app.bar?.screenFrame(ofSlot: slot.id).map { [.number($0.minX), .number($0.minY), .number($0.width), .number($0.height)] } ?? .null]
            }
            let state: JSONValue = [
                "active": .bool(app.model.isActive), "panel": app.model.panel.map { .string($0.slotID) } ?? .null,
                "panelBox": app.model.panel.map { ["width": .number($0.widgetBox.width), "height": .number($0.widgetBox.height)] } ?? .null,
                "panelFailure": app.model.panel?.failure.map(JSONValue.string) ?? .null,
                "temporarilyExpandedWidget": app.model.temporaryExpandedWidget.map {
                    ["id": .string($0.slotID), "width": .number($0.box.width), "height": .number($0.box.height)]
                } ?? .null,
                "rows": .array(app.model.visibleRows.map { .array($0.map { .string($0.id) }) }),
                "widgetColumns": .array(app.model.visibleWidgetColumns.map { col in
                    .array(col.map { ["id": .string($0.slot.id), "width": .number($0.box.width), "height": .number($0.box.height)] })
                }),
                "slots": .array(slots),
                "chat": .array(app.model.chat.suffix(6).map { ["role": .string($0.role.rawValue), "text": .string($0.text)] }),
                "chatBusy": .bool(app.model.isChatBusy), "keyEventsSeen": .number(Double(keyEventsSeen)),
                "keyWindow": app.windows.first { $0.window.isKeyWindow }.map { .string($0.name) } ?? .null, "hidden": .bool(app.model.isHidden),
                "hiddenByUser": .bool(app.model.visibility.isHiddenByUser),
                "autoHiddenInFullScreen": .bool(app.model.visibility.isAutoHiddenInFullScreen),
                "inFullScreen": .bool(app.model.visibility.isInFullScreen),
                "autoHideInFullScreen": .bool(app.model.settings.autoHideInFullScreen),
                "theme": .object(app.model.theme.patch), "anchor": .string(app.model.settings.anchor.rawValue),
                "carrying": app.model.rearrangement.map { .string("\($0.key) \($0.drop.map { "\($0)" } ?? "none") \($0.phase) at \(app.model.carried.point)") } ?? .null,
                "barFrame": app.bar.map { .string("\($0.contentFrame)") } ?? .null,
                "guardedTopEdge": app.bar?.guardedTopEdge.map { .string("\($0)") } ?? .null,
                "pointerTap": .bool(app.pointerTap.isRunning), "menuBarRowBudget": .number(Double(min(app.model.menuBarRowBudget, 99999))), "accessibility": .bool(AXIsProcessTrusted()),
                "screenRecording": .bool(CGPreflightScreenCaptureAccess()),
                "keyboardSelection": app.model.keyboardSelection.map(JSONValue.string) ?? .null,
            ]
            try? state.text.write(toFile: path, atomically: true, encoding: .utf8)
        case "metrics":
            guard let path = command["path"].string, let line = try? app.perf.snapshot().line() else { return }
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        case "close-settings": app.windows.first { $0.name == "settings" }?.window.close()
        case "reveal-menu-bar": app.adoption.reveal {}
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }
}
