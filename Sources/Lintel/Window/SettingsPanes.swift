import AppKit
import ApplicationServices
import Combine
import LintelCore
import ServiceManagement
import SwiftUI

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

struct WelcomePane: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var state: MainWindowState
    @State private var tick = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var menuBarAutoHides: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(
                    "Lintel is the floating bar at the top of your screen.",
                    subtitle: "Rest the pointer on it, or press \(model.settings.toggleShortcut.label), to open it. Click any item for its panel, or press \(model.settings.keyboardShortcut.label) and use the arrow keys and Return. Ask the assistant (the sparkle) to restyle the bar or build something new for it."
                )

                WindowCard(
                    title: "Permissions",
                    footer: "Both are optional. Without them the bar still shows its own modules; it just cannot adopt other apps' menu bar items."
                ) {
                    PermissionRow(
                        title: "Accessibility",
                        detail: "Lists the items in the system menu bar and opens their menus when you click them in Lintel.",
                        isGranted: AXIsProcessTrusted()
                    ) {
                        let prompt = "AXTrustedCheckOptionPrompt" as CFString
                        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                    }
                    Divider()
                    PermissionRow(
                        title: "Screen Recording",
                        detail: "Copies each adopted item's own picture out of the menu bar. Without it, items show a symbol or their name. macOS will show a recording notice.",
                        isGranted: CGPreflightScreenCaptureAccess()
                    ) { _ = CGRequestScreenCaptureAccess() }
                    Divider()
                    PermissionRow(
                        title: "Hide the system menu bar",
                        detail: "Lintel is designed to stand in for it. Set “Automatically hide and show the menu bar” to Always in System Settings › Menu Bar.",
                        isGranted: menuBarAutoHides
                    ) { MenuBarItems.openMenuBarSettings() }
                }
                .id(tick)

                WindowCard(
                    title: "Pick a look",
                    footer: "You can change every detail later in Appearance, or just tell the assistant what you want."
                ) {
                    PresetPicker(app: app, model: model)
                }

                HStack {
                    Spacer()
                    if model.settings.hasOnboarded {
                        Button("Done") {
                            state.selection = .general
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button("Start Using Lintel") {
                            var settings = model.settings
                            settings.hasOnboarded = true
                            app.host.update(settings)
                            state.selection = .dashboard
                            state.showAssistant = true
                            controller.close()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(timer) { _ in tick += 1 }
        .navigationTitle("Welcome")
    }
}

// MARK: Bar Layout

struct BarLayoutPane: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var state: MainWindowState

    private func edit(_ change: (inout BarLayout) -> Void) {
        var layout = model.layout
        layout.materialise(
            model.layoutItems.filter { item in !item.isOptIn || layout.rows.contains { $0.contains(item.key) } },
            keepsFirstRow: model.isFirstRowInMenuBar
        )
        change(&layout)
        app.host.update(layout)
        app.adoption.scanIfNeeded(force: true)
    }

    private func title(_ key: String) -> String {
        model.slot(key)?.title
            ?? state.listings.first { $0.id == key }?.title
            ?? state.menuBarItems.first { $0.key == key }?.label
            ?? key
    }

    private func showHidden(_ key: String) {
        if let listing = state.listings.first(where: { $0.id == key }), !listing.isEnabled {
            app.host.setEnabled(listing.id, true, origin: listing.origin)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.refresh() }
            return
        }
        let isOptIn = model.slot(key)?.isOptIn == true || key.hasPrefix("menubar:")
        edit { $0.show(key, isOptIn: isOptIn) }
    }

    var body: some View {
        let rows = model.layout.arranged(model.layoutItems, isActive: true)
        let activeWidgets = model.layout.widgets.keys.sorted()

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader("Bar Layout", subtitle: "Arrange bar rows, manage pinned desktop widgets, and adopt system menu bar items.")

                if !activeWidgets.isEmpty {
                    WindowCard(
                        title: "Desktop Widgets",
                        footer: "Desktop widgets stay visible while idle. Drag any widget's corner on the desktop to resize or collapse it back to a chip."
                    ) {
                        ForEach(activeWidgets, id: \.self) { id in
                            let box = model.layout.widgets[id]
                            HStack(spacing: 8) {
                                Image(systemName: model.slot(id)?.icon ?? "puzzlepiece.extension")
                                    .foregroundStyle(.tint)
                                    .frame(width: 20)
                                Text(title(id)).fontWeight(.medium)
                                if let box {
                                    Text("\(Int(box.width)) × \(Int(box.height)) pt")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Inspect") { state.selection = .module(id) }
                                    .controlSize(.small)
                                Button("Collapse to Chip") { app.host.setWidget(id, to: nil) }
                                    .controlSize(.small)
                            }
                            if id != activeWidgets.last { Divider() }
                        }
                    }
                }

                WindowCard(
                    title: "Rows",
                    footer: "One row is the classic bar; one item per row is a vertical stack. Pinned items always show; the rest appear when the bar is open."
                ) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Row \(row.offset + 1)").font(.footnote).foregroundStyle(.secondary)
                            ForEach(row.element.filter { $0 != AppController.assistantSlot }, id: \.self) { key in
                                HStack(spacing: 6) {
                                    Image(systemName: model.slot(key)?.kind == .menuBarItem ? "menubar.rectangle" : model.slot(key)?.icon ?? "puzzlepiece.extension")
                                        .frame(width: 20)
                                    if state.listings.contains(where: { $0.id == key }) {
                                        Button(title(key)) { state.selection = .module(key) }
                                            .buttonStyle(.plain)
                                            .lineLimit(1)
                                    } else {
                                        Text(title(key)).lineLimit(1)
                                    }
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
                                    Button { edit { $0.setHidden(key, true, keepsFirstRow: model.isFirstRowInMenuBar) } } label: { Image(systemName: "eye.slash") }
                                        .help("Hide from the bar")
                                }
                            }
                        }
                        if row.offset < rows.count - 1 { Divider() }
                    }
                }

                if !model.layout.hidden.isEmpty {
                    WindowCard(title: "Hidden") {
                        ForEach(model.layout.hidden, id: \.self) { key in
                            HStack {
                                Text(title(key))
                                Spacer()
                                Button("Show") { showHidden(key) }
                            }
                        }
                    }
                }

                WindowCard(
                    title: "System menu bar items",
                    footer: AXIsProcessTrusted()
                        ? "Adding an item shows it in Lintel; clicking it there opens its real menu. While the system menu bar is hidden, macOS only exposes Apple's items, so other apps' items are remembered from the last time it was showing, and clicking one in Lintel briefly brings the menu bar in."
                        : "Lintel needs the Accessibility permission to see these."
                ) {
                    if !AXIsProcessTrusted() {
                        HStack {
                            Text("Accessibility permission is required to list system menu bar items.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Permissions…") { state.selection = .welcome }
                        }
                    } else if state.menuBarItems.isEmpty {
                        Text("No items found yet.").foregroundStyle(.secondary)
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
                        Button("Refresh") { controller.refreshMenuBarItems() }
                        Button("Find Other Apps' Items") {
                            app.adoption.reveal { controller.refreshMenuBarItems() }
                        }
                        .help("Briefly brings the system menu bar in. macOS only exposes other apps' items while it is showing.")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Bar Layout")
    }
}

// MARK: General

struct GeneralSettingsPane: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @ObservedObject var state: MainWindowState
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader("General", subtitle: "Bar placement, hover and full-screen behavior, login item, and system permissions.")

                WindowCard(title: "Position", footer: "You can also drag the open bar sideways; it snaps to the nearest of the three positions.") {
                    Picker("Bar position", selection: settingBinding(app, \.anchor)) {
                        Text("Left").tag(BarAnchor.left)
                        Text("Centre").tag(BarAnchor.center)
                        Text("Right").tag(BarAnchor.right)
                    }
                    .pickerStyle(.segmented)
                    LabeledSlider(title: "Distance from the screen edge", value: settingBinding(app, \.edgeInset), range: 0...400, unit: "pt")
                }

                WindowCard(
                    title: "Opening the bar",
                    footer: "With the menu bar set to hide, the top edge above the bar no longer brings it in. Hold ⌥ there to reach it, or use the rest of the top edge. Press \(model.settings.hideShortcut.label) to show the bar again while in full screen."
                ) {
                    Toggle("Open when the pointer rests on it", isOn: settingBinding(app, \.hoverActivates))
                    Toggle("Keep the hidden menu bar from sliding in above the bar", isOn: settingBinding(app, \.guardsTopEdge))
                    Toggle("Auto-hide the bar in full screen", isOn: settingBinding(app, \.autoHideInFullScreen))
                    LabeledSlider(title: "Rest time before it opens", value: settingBinding(app, \.dwell), range: 0...1.5, unit: "s", digits: 2)
                    LabeledSlider(title: "Stays open after the pointer leaves", value: settingBinding(app, \.grace), range: 0.1...3, unit: "s", digits: 1)
                    Toggle("Show the assistant button in the bar", isOn: settingBinding(app, \.showsAssistant))
                }

                WindowCard(
                    title: "System",
                    footer: "Click the Dock icon to open the whole bar, and again to open Lintel's main window. Private features use undocumented parts of macOS: hiding other apps' items from the system menu bar directly, and letting modules run command-line tools you approve."
                ) {
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
                    HStack(spacing: 10) {
                        Button("Welcome & Permissions…") { state.selection = .welcome }
                        Button("Quit Lintel") { NSApp.terminate(nil) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("General")
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

// MARK: Keyboard

struct KeyboardSettingsPane: View {
    let app: AppController
    @ObservedObject var model: BarModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader("Keyboard", subtitle: "Global shortcuts and keys for navigating and editing modules in the bar.")

                WindowCard(title: "Anywhere", footer: "These work in any app and need a modifier key.") {
                    ShortcutRow(title: "Use the bar from the keyboard", shortcut: settingBinding(app, \.keyboardShortcut))
                    ShortcutRow(title: "Open Lintel & Assistant", shortcut: settingBinding(app, \.toggleShortcut))
                    ShortcutRow(title: "Hide or show the whole bar", shortcut: settingBinding(app, \.hideShortcut))
                }

                WindowCard(
                    title: "In the bar",
                    footer: "While \(model.settings.keyboardShortcut.label) has the bar open. Click a key to change it; a key already used by another action moves here. Esc and 1–9 cannot be changed."
                ) {
                    ForEach(BarAction.allCases, id: \.self) { action in
                        BarKeyRow(action: action, keys: settingBinding(app, \.barKeys))
                    }
                    Divider()
                    FixedKeyRow(title: "Open the module at that position", label: "1–9")
                    FixedKeyRow(title: "Go back from a panel, then close the bar", label: "Esc")
                    HStack {
                        Spacer()
                        Button("Restore Standard Keys") { settingBinding(app, \.barKeys).wrappedValue.resetAll() }
                            .disabled(model.settings.barKeys.isStandard)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Keyboard")
    }
}

private struct BarKeyRow: View {
    let action: BarAction
    @Binding var keys: BarKeymap
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        let bindings = keys.bindings(for: action)
        HStack {
            Text(action.title)
            Spacer()
            if !keys.isStandard(action) {
                Button { keys.reset(action) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Use \(action.standardBindings.map(\.label).joined(separator: " or ")) again")
            }
            Button(isRecording ? "Press a key…" : bindings.isEmpty ? "None" : bindings.map(\.label).joined(separator: " or ")) {
                isRecording ? stop() : record()
            }
            .frame(minWidth: 130)
        }
        .onDisappear(perform: stop)
        // Closing the window does not make its views disappear, so the recorder would otherwise take the next key
        // pressed in the bar.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func record() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let key = BarKey(event), key != .escape else {
                stop()
                return nil
            }
            let binding = BarKeyBinding(key, BarKey.Modifiers(event.modifierFlags))
            if BarKeymap.isReserved(binding) {
                NSSound.beep()
                return nil
            }
            keys.assign(binding, to: action)
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

private struct FixedKeyRow: View {
    let title: String
    let label: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(label).foregroundStyle(.secondary).frame(minWidth: 130)
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
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

struct PresetPicker: View {
    let app: AppController
    @ObservedObject var model: BarModel

    static let blurbs = [
        "halo": "Plain text with a shadow; glass on hover",
        "glass": "Liquid Glass capsules, always",
        "ink": "Solid dark capsules and panels",
        "paper": "Solid light, serif",
        "terminal": "Monospaced green on black",
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            ForEach(Theme.presetNames, id: \.self) { name in
                let theme = Theme.preset(name) ?? Theme()
                let context = RenderContext(theme: theme, surface: .chip, material: SurfaceMaterial(idle: theme.idleMaterial))
                Button {
                    app.host.update(theme)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: "cpu")
                            Text("12%  09:41")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
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

struct AppearanceSettingsPane: View {
    let app: AppController
    @ObservedObject var model: BarModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader("Appearance", subtitle: "Pick a preset or fine-tune typography, materials, spacing, and colors across every module.")

                WindowCard(title: "Design language") { PresetPicker(app: app, model: model) }

                WindowCard(
                    title: "Details",
                    footer: "Every module, built in or generated, draws from these values, so one change restyles everything."
                ) {
                    ForEach(Theme.fields.filter { $0.name != "preset" }, id: \.name) { field in
                        ThemeFieldRow(app: app, model: model, field: field)
                    }
                }

                HStack {
                    Button("Undo Last Change") { _ = app.host.undoTheme() }
                    Button("Reset to Halo") { app.host.update(Theme()) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Appearance")
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

// MARK: Assistant Settings

struct AssistantSettingsPane: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @State private var apiKey = ""
    @State private var hasKey = false

    var body: some View {
        let claude = SubscriptionCLI.find(.claude), codex = SubscriptionCLI.find(.codex)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader("Assistant", subtitle: "Choose the model engine used to restyle the bar, rearrange modules, and author new modules.")

                WindowCard(
                    title: "Model",
                    footer: "Subscriptions run the vendor's own signed-in command-line tool, so Lintel never sees your account. The model on this Mac can only adjust appearance."
                ) {
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

                WindowCard(
                    title: "API key",
                    footer: "The key is stored in your Keychain. Choose OpenAI-compatible for other providers and local model servers."
                ) {
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
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { hasKey = SecretStore(home: app.home).get(ChatEngine.apiKeySecret) != nil }
        .navigationTitle("Assistant")
    }
}

// MARK: Browser & Secrets

struct BrowserSettingsPane: View {
    let app: AppController
    @ObservedObject var state: MainWindowState
    @State private var address = ""
    @State private var secretName = ""
    @State private var secretValue = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader("Browser & Secrets", subtitle: "Manage Lintel's signed-in web profile and Keychain secrets available to approved modules.")

                WindowCard(
                    title: "Sign in to a site",
                    footer: "Lintel keeps its own browser profile. Sign in here once and modules you approve for that site can read its pages."
                ) {
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

                WindowCard(
                    title: "Secrets for modules",
                    footer: "A module can read a secret only if its permissions name it (secret:name) and you allowed that. Secrets are never shown to the assistant."
                ) {
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
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Browser & Secrets")
    }

    private func open() {
        var text = address.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "https://" + text }
        if let url = URL(string: text) { app.browser.openSignInWindow(at: url) }
    }
}
