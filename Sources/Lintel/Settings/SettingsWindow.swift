import AppKit
import ApplicationServices
import LintelCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case welcome, general, appearance, items, modules, assistant, browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .general: "General"
        case .appearance: "Appearance"
        case .items: "Bar Items"
        case .modules: "Modules"
        case .assistant: "Assistant"
        case .browser: "Browser & Secrets"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .items: "rectangle.3.group"
        case .modules: "puzzlepiece.extension"
        case .assistant: "sparkles"
        case .browser: "safari"
        }
    }
}

@MainActor
final class SettingsState: ObservableObject {
    @Published var tab = SettingsTab.general
    @Published var listings: [ModuleListing] = []
    @Published var menuBarItems: [KnownMenuBarItem] = []
    @Published var trackedApps: [(bundle: String, isAllowed: Bool)] = []
    @Published var signedInSites: [String] = []
    @Published var secretNames: [String] = []
    @Published var notice = ""
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let app: AppController
    private(set) var window: NSWindow?
    private let state = SettingsState()

    init(app: AppController) {
        self.app = app
    }

    func show(tab: SettingsTab) {
        state.tab = tab
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.title = "Lintel Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(app: app, model: app.model, state: state))
            window.center()
            self.window = window
        }
        app.adoption.wantsListing = true
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        Task {
            state.listings = await app.host.listings()
            state.signedInSites = await BrowserHost.signedInHosts()
        }
        state.secretNames = SecretStore(home: app.home).names.filter { $0 != ChatEngine.apiKeySecret }
        state.trackedApps = MenuBarItems.trackedApplications()
        app.adoption.scan { [weak self] in
            guard let self else { return }
            self.state.menuBarItems = self.app.adoption.listing
        }
    }

    func windowWillClose(_ notification: Notification) {
        app.adoption.wantsListing = false
    }
}

private struct SettingsView: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @ObservedObject var state: SettingsState

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { state.tab }, set: { state.tab = $0 ?? .general })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch state.tab {
                    case .welcome: WelcomePane(app: app, model: model, state: state)
                    case .general: GeneralPane(app: app, model: model)
                    case .appearance: AppearancePane(app: app, model: model)
                    case .items: ItemsPane(app: app, model: model, state: state)
                    case .modules: ModulesPane(app: app, model: model, state: state)
                    case .assistant: AssistantPane(app: app, model: model)
                    case .browser: BrowserPane(app: app, state: state)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(state.tab.title)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct Card<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let footer { Text(footer).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

@MainActor
private func settingBinding<Value>(_ app: AppController, _ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(get: { app.model.settings[keyPath: path] }, set: { value in
        var settings = app.model.settings
        settings[keyPath: path] = value
        app.host.update(settings)
        app.chat.refreshEngineName()
    })
}

// MARK: Welcome

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isGranted ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !isGranted { Button("Allow…", action: action) }
        }
    }
}

private struct WelcomePane: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @ObservedObject var state: SettingsState
    @State private var tick = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var menuBarAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lintel is the floating bar at the top of your screen.").font(.title2).fontWeight(.semibold)
            Text("Rest the pointer on it, or press \(model.settings.toggleShortcut.label), to open it. Click any item for its panel. Ask the assistant (the sparkle) to restyle the bar or build something new for it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Card(title: "Permissions", footer: "Both are optional. Without them the bar still shows its own modules; it just cannot adopt other apps' menu bar items.") {
            PermissionRow(
                title: "Accessibility", detail: "Lists the items in the system menu bar and opens their menus when you click them in Lintel.",
                isGranted: AXIsProcessTrusted()
            ) {
                let prompt = "AXTrustedCheckOptionPrompt" as CFString
                _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            }
            Divider()
            PermissionRow(
                title: "Screen Recording", detail: "Copies each adopted item's own picture out of the menu bar. Without it, items show a symbol or their name. macOS will show a recording notice.",
                isGranted: CGPreflightScreenCaptureAccess()
            ) { _ = CGRequestScreenCaptureAccess() }
            Divider()
            PermissionRow(
                title: "Hide the system menu bar", detail: "Lintel is designed to stand in for it. Set “Automatically hide and show the menu bar” to Always in System Settings › Menu Bar.",
                isGranted: menuBarAutoHides
            ) { MenuBarItems.openMenuBarSettings() }
        }
        .id(tick)
        Card(title: "Pick a look", footer: "You can change every detail later in Appearance, or just tell the assistant what you want.") {
            PresetPicker(app: app, model: model)
        }
        HStack {
            Spacer()
            Button("Start Using Lintel") {
                var settings = model.settings
                settings.hasOnboarded = true
                app.host.update(settings)
                state.tab = .general
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .onReceive(timer) { _ in tick += 1 }
    }
}

// MARK: General

private struct GeneralPane: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Card(title: "Position", footer: "You can also drag the open bar sideways; it snaps to the nearest of the three positions.") {
            Picker("Bar position", selection: settingBinding(app, \.anchor)) {
                Text("Left").tag(BarAnchor.left)
                Text("Centre").tag(BarAnchor.center)
                Text("Right").tag(BarAnchor.right)
            }
            .pickerStyle(.segmented)
            LabeledSlider(title: "Distance from the screen edge", value: settingBinding(app, \.edgeInset), range: 0...400, unit: "pt")
        }
        Card(title: "Opening the bar", footer: "With the menu bar set to hide, the top edge above the bar no longer brings it in. Hold ⌥ there to reach it, or use the rest of the top edge.") {
            Toggle("Open when the pointer rests on it", isOn: settingBinding(app, \.hoverActivates))
            Toggle("Keep the hidden menu bar from sliding in above the bar", isOn: settingBinding(app, \.guardsTopEdge))
            LabeledSlider(title: "Rest time before it opens", value: settingBinding(app, \.dwell), range: 0...1.5, unit: "s", digits: 2)
            LabeledSlider(title: "Stays open after the pointer leaves", value: settingBinding(app, \.grace), range: 0.1...3, unit: "s", digits: 1)
            Divider()
            ShortcutRow(title: "Open the assistant", shortcut: settingBinding(app, \.toggleShortcut))
            ShortcutRow(title: "Hide or show the whole bar", shortcut: settingBinding(app, \.hideShortcut))
            Toggle("Show the assistant button in the bar", isOn: settingBinding(app, \.showsAssistant))
        }
        Card(title: "System", footer: "Click the Dock icon to open the whole bar, and again to open Settings. Private features use undocumented parts of macOS: hiding other apps' items from the system menu bar directly, and letting modules run command-line tools you approve.") {
            Toggle("Open Lintel at login", isOn: Binding(get: { launchesAtLogin }, set: { isOn in
                do {
                    if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    launchesAtLogin = isOn
                } catch {
                    launchesAtLogin = SMAppService.mainApp.status == .enabled
                }
            }))
            .disabled(Bundle.main.bundleIdentifier == nil)
            Toggle("Show Lintel in the Dock", isOn: settingBinding(app, \.showsInDock))
            Toggle("Private features", isOn: Binding(get: { model.settings.isPrivateEdition }, set: { isOn in
                var settings = model.settings
                settings.edition = isOn ? "private" : "public"
                app.host.update(settings)
            }))
            Button("Show Welcome Again") { app.showSettings(tab: .welcome) }
            Button("Quit Lintel") { NSApp.terminate(nil) }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = ""
    var digits = 0

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Slider(value: $value, in: range).frame(width: 220)
            Text("\(String(format: "%.\(digits)f", value)) \(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    @Binding var shortcut: Shortcut
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(isRecording ? "Press keys…" : shortcut.label) { isRecording ? stop() : record() }
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stop)
    }

    private func record() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 || flags.isEmpty {
                stop()
                return nil
            }
            var carbon = 0, label = ""
            if flags.contains(.control) { carbon |= 0x1000; label += "⌃" }
            if flags.contains(.option) { carbon |= 0x0800; label += "⌥" }
            if flags.contains(.shift) { carbon |= 0x0200; label += "⇧" }
            if flags.contains(.command) { carbon |= 0x0100; label += "⌘" }
            label += (event.charactersIgnoringModifiers ?? "?").uppercased()
            shortcut = Shortcut(keyCode: Int(event.keyCode), modifiers: carbon, label: label)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: Appearance

private struct PresetPicker: View {
    let app: AppController
    @ObservedObject var model: BarModel

    static let blurbs = [
        "halo": "Plain text with a shadow; glass on hover", "glass": "Liquid Glass capsules, always",
        "ink": "Solid dark capsules and panels", "paper": "Solid light, serif", "terminal": "Monospaced green on black",
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(Theme.presetNames, id: \.self) { name in
                let theme = Theme.preset(name) ?? Theme()
                let context = RenderContext(theme: theme, surface: .chip, material: SurfaceMaterial(idle: theme.idleMaterial))
                Button {
                    app.host.update(theme)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                            Text("12%  09:41")
                        }
                        .font(context.font())
                        .foregroundStyle(theme.idleMaterial == "glass" ? Color.white : context.primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(
                            theme.idleMaterial == "solid" ? AnyShapeStyle(context.surfaceFill)
                                : theme.idleMaterial == "glass" ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.clear),
                            in: context.chipShape
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(LinearGradient(colors: [.orange, .pink, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
                        Text(name.capitalized).fontWeight(.medium)
                        Text(Self.blurbs[name] ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    }
                    .padding(8)
                    .background(model.theme.preset == name ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(model.theme.preset == name ? Color.accentColor : Color.secondary.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AppearancePane: View {
    let app: AppController
    @ObservedObject var model: BarModel

    var body: some View {
        Card(title: "Design language") { PresetPicker(app: app, model: model) }
        Card(title: "Details", footer: "Every module, built in or generated, draws from these values, so one change restyles everything.") {
            ForEach(Theme.fields.filter { $0.name != "preset" }, id: \.name) { field in
                ThemeFieldRow(app: app, model: model, field: field)
            }
        }
        HStack {
            Button("Undo Last Change") { _ = app.host.undoTheme() }
            Button("Reset to Halo") { app.host.update(Theme()) }
        }
    }
}

private struct ThemeFieldRow: View {
    let app: AppController
    @ObservedObject var model: BarModel
    let field: Theme.Field

    private var label: String {
        field.name.reduce(into: "") { result, character in
            if character.isUppercase { result += " " }
            result += result.isEmpty ? character.uppercased() : String(character).lowercased()
        }
    }

    private func set(_ value: JSONValue) {
        app.host.update(model.theme.applying([field.name: value]))
    }

    var body: some View {
        HStack {
            Text(label).help(field.doc)
            Spacer()
            switch field.kind {
            case .number(let range, let path):
                Slider(value: Binding(get: { model.theme[keyPath: path] }, set: { set(.number(($0 * 20).rounded() / 20)) }), in: range).frame(width: 200)
                Text(String(format: range.upperBound <= 1 ? "%.2f" : "%.0f", model.theme[keyPath: path]))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            case .choice(let options, let path):
                Picker("", selection: Binding(get: { model.theme[keyPath: path] }, set: { set(.string($0)) })) {
                    ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            case .color(let path):
                ColorPicker("", selection: Binding(
                    get: { RenderContext.color(hex: model.theme[keyPath: path]) },
                    set: { color in
                        guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
                        set(.string(String(format: "#%02X%02X%02X", Int(resolved.redComponent * 255), Int(resolved.greenComponent * 255), Int(resolved.blueComponent * 255))))
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                Text(model.theme[keyPath: path]).monospaced().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
        }
    }
}

// MARK: Items

private struct ItemsPane: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @ObservedObject var state: SettingsState

    private func edit(_ change: (inout BarLayout) -> Void) {
        var layout = model.layout
        layout.materialise(model.layoutItems.filter { item in !item.isOptIn || layout.rows.contains { $0.contains(item.key) } })
        change(&layout)
        app.host.update(layout)
        app.adoption.scanIfNeeded(force: true)
    }

    private func title(_ key: String) -> String {
        model.slot(key)?.title ?? state.menuBarItems.first { $0.key == key }?.label ?? key
    }

    var body: some View {
        let rows = model.layout.arranged(model.layoutItems, isActive: true)
        Card(title: "Rows", footer: "One row is the classic bar; one item per row is a vertical stack. Pinned items always show; the rest appear when the bar is open.") {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Row \(row.offset + 1)").font(.footnote).foregroundStyle(.secondary)
                    ForEach(row.element.filter { $0 != AppController.assistantSlot }, id: \.self) { key in
                        HStack(spacing: 6) {
                            Image(systemName: model.slot(key)?.kind == .menuBarItem ? "menubar.rectangle" : model.slot(key)?.icon ?? "puzzlepiece.extension")
                                .frame(width: 20)
                            Text(title(key)).lineLimit(1)
                            Spacer()
                            Toggle("Pinned", isOn: Binding(
                                get: { model.layout.isPinned(key, default: model.slot(key)?.isPinned ?? false) },
                                set: { isOn in edit { $0.pinned[key] = isOn } }
                            ))
                            .toggleStyle(.checkbox)
                            ControlGroup {
                                Button { edit { $0.shift(key, by: -1) } } label: { Image(systemName: "arrow.left") }
                                Button { edit { $0.shift(key, by: 1) } } label: { Image(systemName: "arrow.right") }
                                Button { edit { $0.moveToRow(key, offset: -1) } } label: { Image(systemName: "arrow.up") }
                                Button { edit { $0.moveToRow(key, offset: 1) } } label: { Image(systemName: "arrow.down") }
                            }
                            .frame(width: 130)
                            Button { edit { $0.setHidden(key, true) } } label: { Image(systemName: "eye.slash") }
                                .help("Hide from the bar")
                        }
                    }
                }
                if row.offset < rows.count - 1 { Divider() }
            }
        }
        if !model.layout.hidden.isEmpty {
            Card(title: "Hidden") {
                ForEach(model.layout.hidden, id: \.self) { key in
                    HStack {
                        Text(title(key))
                        Spacer()
                        Button("Show") { edit { $0.setHidden(key, false) } }
                    }
                }
            }
        }
        Card(
            title: "System menu bar items",
            footer: AXIsProcessTrusted()
                ? "Adding an item shows it in Lintel; clicking it there opens its real menu. While the system menu bar is hidden, macOS only exposes Apple's items, so other apps' items are remembered from the last time it was showing, and clicking one in Lintel briefly brings the menu bar in."
                : "Lintel needs the Accessibility permission to see these. Open Welcome to allow it."
        ) {
            if state.menuBarItems.isEmpty {
                Text(AXIsProcessTrusted() ? "No items found yet." : "Not available.").foregroundStyle(.secondary)
            }
            ForEach(state.menuBarItems, id: \.key) { item in
                let isAdopted = model.layout.rows.contains { $0.contains(item.key) }
                let tracked = state.trackedApps.first { $0.bundle == item.owner }
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label).lineLimit(1)
                        Text(item.owner).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let tracked {
                        Toggle("In system menu bar", isOn: Binding(get: { tracked.isAllowed }, set: { isAllowed in
                            if model.settings.isPrivateEdition {
                                do {
                                    try MenuBarItems.setAllowedInSystemMenuBar(bundle: item.owner, allowed: isAllowed)
                                    state.trackedApps = MenuBarItems.trackedApplications()
                                } catch {
                                    state.notice = ModuleFailure.describe(error)
                                }
                            } else {
                                MenuBarItems.openMenuBarSettings()
                            }
                        }))
                        .toggleStyle(.checkbox)
                    }
                    Button(isAdopted ? "Remove from Lintel" : "Add to Lintel") {
                        edit { layout in
                            if isAdopted { layout.remove(item.key) } else { layout.place(item.key, row: max(layout.rows.count - 1, 0), at: 0) }
                        }
                    }
                }
            }
            if !state.notice.isEmpty { Text(state.notice).font(.footnote).foregroundStyle(.red) }
            HStack {
                Button("Refresh") { app.showSettings(tab: .items) }
                Button("Find Other Apps' Items") {
                    app.adoption.reveal { app.showSettings(tab: .items) }
                }
                .help("Briefly brings the system menu bar in. macOS only exposes other apps' items while it is showing.")
            }
        }
    }
}

// MARK: Modules

private struct ModulesPane: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @ObservedObject var state: SettingsState

    var body: some View {
        HStack {
            Button("Import Module…") { ModuleSharing.importModule(app: app) { app.showSettings(tab: .modules) } }
            Button("Open Modules Folder") { NSWorkspace.shared.open(app.home.modulesDirectory) }
            Spacer()
            Button("Ask the Assistant to Build One") { app.openAssistant() }
        }
        ForEach([ModuleListing.Origin.user, .builtIn, .library], id: \.self) { origin in
            let listings = state.listings.filter { $0.origin == origin }
            if !listings.isEmpty {
                Card(title: origin == .user ? "Yours" : origin == .builtIn ? "Built in" : "Library") {
                    ForEach(listings) { listing in
                        ModuleRow(app: app, listing: listing)
                        if listing.id != listings.last?.id { Divider() }
                    }
                }
            }
        }
        .id(model.slots.count)
    }
}

private struct ModuleRow: View {
    let app: AppController
    let listing: ModuleListing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: listing.icon).font(.title3).frame(width: 26).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(listing.title).fontWeight(.medium)
                if !listing.summary.isEmpty {
                    Text(listing.summary).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !listing.permissions.isEmpty {
                    Text("Uses: " + listing.permissions.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                }
                if let failure = listing.failure {
                    Text(failure).font(.footnote).foregroundStyle(.red).lineLimit(3)
                } else if listing.needsApproval {
                    Text("Waiting for you to allow its permissions. Click it in the bar.").font(.footnote).foregroundStyle(.orange)
                }
            }
            Spacer()
            if listing.origin == .user {
                Menu {
                    Button("Export…") { ModuleSharing.export(listing, app: app) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([listing.file]) }
                    Button("Remove", role: .destructive) {
                        app.host.remove(listing.id)
                        app.showSettings(tab: .modules)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
            Toggle("", isOn: Binding(get: { listing.isEnabled }, set: { isOn in
                app.host.setEnabled(listing.id, isOn, origin: listing.origin)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { app.showSettings(tab: .modules) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

enum ModuleSharing {
    @MainActor
    static func export(_ listing: ModuleListing, app: AppController) {
        guard let source = Resources.source(of: listing.file) else { return }
        let bundle = ModuleBundle(id: listing.id, title: listing.title, permissions: listing.permissions, prompt: app.host.prompt(of: listing.id), source: source)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(listing.id).\(ModuleBundle.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.home.save(bundle, to: url)
    }

    @MainActor
    static func importModule(app: AppController, from file: URL? = nil, completion: @escaping () -> Void = {}) {
        var url = file
        if url == nil {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.message = "Choose a .\(ModuleBundle.fileExtension) file or a module's .js file"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let source = (try? JSONDecoder().decode(ModuleBundle.self, from: data))?.source ?? String(decoding: data, as: UTF8.self)
        let prompt = (try? JSONDecoder().decode(ModuleBundle.self, from: data))?.prompt
        Task {
            let trial = await app.host.trial(source: source)
            let alert = NSAlert()
            guard trial.errors.isEmpty, let manifest = trial.description?.manifest else {
                alert.messageText = "This module cannot be installed"
                alert.informativeText = trial.errors.prefix(4).joined(separator: "\n")
                alert.runModal()
                return
            }
            alert.messageText = "Install “\(manifest.title)”?"
            let asks = manifest.permissions.isEmpty
                ? "It asks for no permissions."
                : "It asks to:\n" + manifest.permissions.map { "• " + (Capability($0)?.explanation ?? "Contact \($0)") }.joined(separator: "\n") + "\n\nIt stays off until you allow that from the bar."
            alert.informativeText = "\(manifest.summary)\n\n\(asks)\n\nModules run code. Install only from people you trust\(prompt == nil ? "." : ", or ask the assistant to rebuild it from its original request:\n“\(prompt!.prefix(200))”")"
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try? app.host.install(source: source, id: manifest.id, prompt: prompt)
            completion()
        }
    }
}

// MARK: Assistant

private struct AssistantPane: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @State private var apiKey = ""
    @State private var hasKey = false

    var body: some View {
        let claude = SubscriptionCLI.find(.claude), codex = SubscriptionCLI.find(.codex)
        Card(title: "Model", footer: "Subscriptions run the vendor's own signed-in command-line tool, so Lintel never sees your account. The model on this Mac can only adjust appearance.") {
            Picker("Use", selection: settingBinding(app, \.engine)) {
                Text("Automatic").tag("auto")
                Text("Claude subscription\(claude == nil ? " (Claude Code not found)" : "")").tag("claude")
                Text("ChatGPT subscription\(codex == nil ? " (Codex not found)" : "")").tag("codex")
                Text("API key").tag("api")
                Text("On-device only").tag("on-device")
            }
            HStack {
                Text("Now using")
                Spacer()
                Text(model.engineName).foregroundStyle(.secondary)
            }
            TextField("Model for the subscription tool (optional)", text: settingBinding(app, \.cliModel))
        }
        Card(title: "API key", footer: "The key is stored in your Keychain. Choose OpenAI-compatible for other providers and local model servers.") {
            Picker("API", selection: settingBinding(app, \.apiStyle)) {
                Text("Anthropic").tag("anthropic")
                Text("OpenAI-compatible").tag("openai")
            }
            .pickerStyle(.segmented)
            TextField("Endpoint", text: settingBinding(app, \.apiEndpoint))
            TextField("Model", text: settingBinding(app, \.apiModel))
            HStack {
                SecureField(hasKey ? "A key is saved" : "API key", text: $apiKey)
                Button("Save") {
                    SecretStore(home: app.home).set(ChatEngine.apiKeySecret, apiKey)
                    apiKey = ""
                    hasKey = SecretStore(home: app.home).get(ChatEngine.apiKeySecret) != nil
                    app.chat.refreshEngineName()
                }
                .disabled(apiKey.isEmpty)
                if hasKey {
                    Button("Remove") {
                        SecretStore(home: app.home).set(ChatEngine.apiKeySecret, nil)
                        hasKey = false
                        app.chat.refreshEngineName()
                    }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { hasKey = SecretStore(home: app.home).get(ChatEngine.apiKeySecret) != nil }
    }
}

// MARK: Browser

private struct BrowserPane: View {
    let app: AppController
    @ObservedObject var state: SettingsState
    @State private var address = ""
    @State private var secretName = ""
    @State private var secretValue = ""

    var body: some View {
        Card(title: "Sign in to a site", footer: "Lintel keeps its own browser profile. Sign in here once and modules you approve for that site can read its pages.") {
            HStack {
                TextField("github.com", text: $address).textFieldStyle(.roundedBorder).onSubmit(open)
                Button("Open", action: open).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !state.signedInSites.isEmpty {
                Text("Sites with saved data: " + state.signedInSites.prefix(30).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Clear All Browser Data", role: .destructive) {
                Task {
                    await BrowserHost.clearProfile()
                    state.signedInSites = []
                }
            }
        }
        Card(title: "Secrets for modules", footer: "A module can read a secret only if its permissions name it (secret:name) and you allowed that. Secrets are never shown to the assistant.") {
            ForEach(state.secretNames, id: \.self) { name in
                HStack {
                    Image(systemName: "key")
                    Text(name).monospaced()
                    Spacer()
                    Button("Remove") {
                        SecretStore(home: app.home).set(name, nil)
                        state.secretNames.removeAll { $0 == name }
                    }
                }
            }
            HStack {
                TextField("name", text: $secretName).textFieldStyle(.roundedBorder).frame(width: 160)
                SecureField("value", text: $secretValue).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let name = secretName.trimmingCharacters(in: .whitespaces)
                    SecretStore(home: app.home).set(name, secretValue)
                    if !state.secretNames.contains(name) { state.secretNames.append(name) }
                    secretName = ""
                    secretValue = ""
                }
                .disabled(Capability("secret:\(secretName.trimmingCharacters(in: .whitespaces))") == nil || secretValue.isEmpty)
            }
        }
    }

    private func open() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        if let url = URL(string: text) { app.browser.openSignInWindow(at: url) }
    }
}
