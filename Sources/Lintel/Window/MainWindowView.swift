import AppKit
import LintelCore
import SwiftUI

struct MainWindowView: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: MainWindowState

    var body: some View {
        NavigationSplitView {
            MainWindowSidebar(app: app, controller: controller, model: model, jobs: jobs, state: state)
                .navigationSplitViewColumnWidth(min: 205, ideal: 232, max: 280)
        } detail: {
            Group {
                switch state.selection {
                case .welcome:
                    WelcomePane(app: app, controller: controller, model: model, state: state)
                case .dashboard:
                    DashboardPane(app: app, controller: controller, model: model, jobs: jobs, state: state)
                case .modules:
                    ModulesCatalogPane(app: app, controller: controller, model: model, jobs: jobs, state: state)
                case .barLayout:
                    BarLayoutPane(app: app, controller: controller, model: model, state: state)
                case .module(let id):
                    ModuleInspectorPane(app: app, controller: controller, model: model, jobs: jobs, state: state, moduleID: id)
                case .general:
                    GeneralSettingsPane(app: app, model: model, state: state)
                case .appearance:
                    AppearanceSettingsPane(app: app, model: model)
                case .keyboard:
                    KeyboardSettingsPane(app: app, model: model)
                case .assistant:
                    AssistantSettingsPane(app: app, model: model)
                case .browser:
                    BrowserSettingsPane(app: app, state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $state.showAssistant) {
                AssistantInspectorPane(app: app, controller: controller, model: model, state: state)
                    .inspectorColumnWidth(min: 300, ideal: 350, max: 460)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    controller.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh modules, previews, and system state")

                Button {
                    state.showAssistant = true
                    model.chatDraft = "Build a new module that "
                    model.chatFocusRequests += 1
                } label: {
                    Label("New Module", systemImage: "plus")
                }
                .help("Ask the assistant to build a new module")

                Button {
                    state.showAssistant.toggle()
                } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                .help(state.showAssistant ? "Hide Assistant" : "Show Assistant")
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

// MARK: Sidebar

private struct MainWindowSidebar: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: MainWindowState

    private var alertCount: Int {
        let failingModules = state.listings.filter { $0.failure != nil || $0.needsApproval }.count
        return failingModules + jobs.failingCount
    }

    private var enabledCount: Int {
        state.listings.filter(\.isEnabled).count
    }

    private var sidebarListings: [ModuleListing] {
        let ordered = [ModuleListing.Origin.user, .builtIn, .library].flatMap { origin in
            state.listings.filter { $0.origin == origin }
        }
        let entries = ordered.map { listing in
            let liveSlot = model.slot(listing.id)
            let hasFailure = (liveSlot?.failure ?? listing.failure) != nil
            let needsApproval = liveSlot?.needsApproval ?? listing.needsApproval
            let hasJobError = jobs.snapshots(for: listing.id).contains { $0.effectiveStatus == .failed }
            return SidebarModuleEntry(
                id: listing.id,
                isEnabled: listing.isEnabled,
                isUser: listing.origin == .user,
                isHidden: model.layout.isHidden(listing.id),
                needsAttention: hasFailure || needsApproval || hasJobError
            )
        }
        let visibleIDs = Set(MainWindowSection.sidebarModuleIDs(from: entries, selection: state.selection))
        return ordered.filter { visibleIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selection) {
                if MainWindowSection.shouldShowWelcomeInSidebar(hasOnboarded: model.settings.hasOnboarded, selection: state.selection) {
                    Section {
                        Label(MainWindowSection.welcome.title, systemImage: MainWindowSection.welcome.symbol)
                            .tag(MainWindowSection.welcome)
                    }
                }

                Section("Workspace") {
                    HStack(spacing: 8) {
                        Image(systemName: MainWindowSection.dashboard.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        Text(MainWindowSection.dashboard.title)
                        Spacer()
                        if alertCount > 0 {
                            Text("\(alertCount)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.18), in: Capsule())
                                .foregroundStyle(.red)
                        } else if jobs.runningCount > 0 {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .tag(MainWindowSection.dashboard)

                    HStack(spacing: 8) {
                        Image(systemName: MainWindowSection.modules.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        Text(MainWindowSection.modules.title)
                        Spacer()
                        if !state.listings.isEmpty {
                            Text("\(enabledCount)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(MainWindowSection.modules)

                    HStack(spacing: 8) {
                        Image(systemName: MainWindowSection.barLayout.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        Text(MainWindowSection.barLayout.title)
                        Spacer()
                        if !model.layout.hidden.isEmpty {
                            Text("\(model.layout.hidden.count) hidden")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(MainWindowSection.barLayout)
                }

                Section("Settings") {
                    ForEach(MainWindowSection.settingsSections, id: \.self) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }

                if !sidebarListings.isEmpty {
                    Section("Active Modules") {
                        ForEach(sidebarListings) { listing in
                            SidebarModuleRow(app: app, model: model, jobs: jobs, listing: listing)
                                .tag(MainWindowSection.module(listing.id))
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    state.showAssistant = true
                    model.chatDraft = "Build a new module that "
                    model.chatFocusRequests += 1
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Ask the assistant to build a new module")

                Spacer()

                Button {
                    ModuleSharing.importModule(app: app) { controller.refresh() }
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Import a .lintelmodule or .js file")

                Button {
                    NSWorkspace.shared.open(app.home.modulesDirectory)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open Modules Folder in Finder")
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

private struct SidebarModuleRow: View {
    let app: AppController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    let listing: ModuleListing

    private var moduleJobs: [JobSnapshot] { jobs.snapshots(for: listing.id) }
    private var liveNeedsApproval: Bool { model.slot(listing.id)?.needsApproval ?? listing.needsApproval }
    private var liveFailure: String? { model.slot(listing.id)?.failure ?? listing.failure }
    private var isHiddenFromBar: Bool { listing.isEnabled && model.layout.isHidden(listing.id) }

    private var statusColor: Color {
        if liveFailure != nil || moduleJobs.contains(where: { $0.effectiveStatus == .failed }) { return .red }
        if liveNeedsApproval { return .orange }
        if isHiddenFromBar { return .secondary }
        if moduleJobs.contains(where: { $0.effectiveStatus == .running }) { return .blue }
        return listing.isEnabled ? .green : .secondary.opacity(0.45)
    }

    private var trailingText: String {
        if isHiddenFromBar { return "hidden" }
        if !moduleJobs.isEmpty {
            return moduleJobs.count == 1 ? "1 job" : "\(moduleJobs.count) jobs"
        }
        if let manifest = app.host.manifest(of: listing.id) {
            let s = Int(manifest.refreshSeconds)
            return s >= 60 && s % 60 == 0 ? "\(s / 60)m" : "\(s)s"
        }
        return listing.isEnabled ? "" : "off"
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Image(systemName: listing.icon)
                .foregroundStyle(listing.isEnabled ? .primary : .secondary)
                .frame(width: 16)
            Text(listing.title)
                .lineLimit(1)
                .foregroundStyle(listing.isEnabled ? .primary : .secondary)
            Spacer(minLength: 4)
            if !trailingText.isEmpty {
                Text(trailingText)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Shared Window Primitives

struct PaneHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

struct WindowCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct TagPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct ActivityRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
        }
        .font(.callout)
    }
}

@MainActor
func settingBinding<Value>(_ app: AppController, _ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
    Binding(get: { app.model.settings[keyPath: path] }, set: { value in
        var settings = app.model.settings
        settings[keyPath: path] = value
        app.host.update(settings)
        app.chat.refreshEngineName()
    })
}

func formatSeconds(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s >= 3600 && s % 3600 == 0 { return "\(s / 3600)h" }
    if s >= 60 && s % 60 == 0 { return "\(s / 60)m" }
    return "\(s)s"
}

func formatRelative(_ date: Date) -> String {
    let secs = max(0, Int(Date().timeIntervalSince(date)))
    if secs < 45 { return "just now" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    if secs < 86400 { return "\(secs / 3600)h ago" }
    return "\(secs / 86400)d ago"
}

func formatCountdown(_ date: Date) -> String {
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 5 { return "due now" }
    let h = secs / 3600
    let m = (secs % 3600) / 60
    if h > 0 { return "in \(h)h \(String(format: "%02d", m))m" }
    if m > 0 { return "in \(m)m" }
    return "in \(secs)s"
}

func formatTimestamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f.string(from: date)
}
