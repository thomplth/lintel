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

    init(model: BarModel, size: CGSize, backdrop: Backdrop.Style) {
        self.model = model
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        let hostingView = NSHostingView(rootView: StageView(model: model, backdrop: backdrop, maxPanelHeight: size.height - 90))
        hostingView.sizingOptions = []
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
        case "close": app.closePanel()
        case "assistant": app.openAssistant(draft: command["draft"].string)
        case "chat": if let text = command["text"].string { app.openAssistant(); app.chat.submit(text) }
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
                ["id": .string(slot.id), "title": .string(slot.title), "failure": slot.failure.map(JSONValue.string) ?? .null,
                 "needsApproval": .bool(slot.needsApproval), "hasChip": .bool(slot.chip != nil || slot.image != nil),
                 "frame": app.bar?.screenFrame(ofSlot: slot.id).map { [.number($0.minX), .number($0.minY), .number($0.width), .number($0.height)] } ?? .null]
            }
            let state: JSONValue = [
                "active": .bool(app.model.isActive), "panel": app.model.panel.map { .string($0.slotID) } ?? .null,
                "panelFailure": app.model.panel?.failure.map(JSONValue.string) ?? .null,
                "rows": .array(app.model.visibleRows.map { .array($0.map { .string($0.id) }) }), "slots": .array(slots),
                "chat": .array(app.model.chat.suffix(6).map { ["role": .string($0.role.rawValue), "text": .string($0.text)] }),
                "chatBusy": .bool(app.model.isChatBusy), "keyEventsSeen": .number(Double(keyEventsSeen)),
                "keyWindow": app.windows.first { $0.window.isKeyWindow }.map { .string($0.name) } ?? .null, "hidden": .bool(app.model.isHiddenByUser),
                "theme": .object(app.model.theme.patch), "anchor": .string(app.model.settings.anchor.rawValue),
                "carrying": app.model.rearrangement.map { .string("\($0.key) \($0.drop.map { "\($0)" } ?? "none") \($0.phase) at \(app.model.carried.point)") } ?? .null,
                "barFrame": app.bar.map { .string("\($0.contentFrame)") } ?? .null,
                "guardedTopEdge": app.bar?.guardedTopEdge.map { .string("\($0)") } ?? .null,
                "pointerTap": .bool(app.pointerTap.isRunning), "menuBarRowBudget": .number(Double(min(app.model.menuBarRowBudget, 99999))), "accessibility": .bool(AXIsProcessTrusted()),
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
