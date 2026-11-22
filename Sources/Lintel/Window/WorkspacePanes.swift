import AppKit
import LintelCore
import SwiftUI

// MARK: Dashboard

struct DashboardPane: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: MainWindowState

    private var enabledListings: [ModuleListing] {
        state.listings
            .filter(\.isEnabled)
            .sorted { lhs, rhs in
                let lhsHidden = model.layout.isHidden(lhs.id)
                let rhsHidden = model.layout.isHidden(rhs.id)
                if lhsHidden != rhsHidden { return !lhsHidden }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
    private var issueListings: [ModuleListing] { state.listings.filter { $0.failure != nil || $0.needsApproval } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PaneHeader("Dashboard", subtitle: "Live overview of active modules, background poll loops, and scheduled jobs.") {
                    if let pid = app.runner.processIdentifier {
                        HStack(spacing: 6) {
                            Circle().fill(app.runner.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text("Runtime PID \(String(pid))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    Button { state.selection = .modules } label: {
                        KPICard(
                            title: "Active Modules",
                            value: "\(enabledListings.count)",
                            caption: "of \(state.listings.count) installed",
                            symbol: "puzzlepiece.extension",
                            tint: .accentColor
                        )
                    }
                    .buttonStyle(.plain)

                    KPICard(
                        title: "Scheduled Jobs",
                        value: "\(jobs.snapshots.count)",
                        caption: jobs.runningCount > 0 ? "\(jobs.runningCount) running now" : "\(jobs.snapshots.filter { $0.record.enabled }.count) enabled",
                        symbol: "clock.arrow.circlepath",
                        tint: jobs.runningCount > 0 ? .blue : .accentColor
                    )

                    let issues = issueListings.count + jobs.failingCount
                    KPICard(
                        title: "Needs Attention",
                        value: "\(issues)",
                        caption: issues == 0 ? "All healthy" : "Errors or approvals",
                        symbol: issues == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: issues == 0 ? .green : .red
                    )

                    let cliCount = enabledListings.filter { !(app.host.backgroundActivity(of: $0.id)?.tools.isEmpty ?? true) }.count
                    KPICard(
                        title: "CLI & Web Hooks",
                        value: "\(cliCount)",
                        caption: "modules invoking tools",
                        symbol: "terminal",
                        tint: .secondary
                    )
                }

                WindowCard(
                    title: "Scheduled Jobs",
                    subtitle: "Background tasks managed by Lintel (cron, interval, or dynamic reset schedules)."
                ) {
                    if jobs.snapshots.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No scheduled jobs registered yet").fontWeight(.medium)
                                Text("Add a jobs: { … } block to any module—or ask the Assistant on the right—to run background tasks with wake catch-up and error alerts.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(jobs.snapshots) { snap in
                            JobRowView(jobs: jobs, snapshot: snap, showModuleLink: true) {
                                state.selection = .module(snap.moduleID)
                            }
                            if snap.id != jobs.snapshots.last?.id { Divider() }
                        }
                    }
                }

                WindowCard(
                    title: "Modules & Background Activity",
                    subtitle: "Every active module’s poll cadence, scheduled jobs, network hosts, and CLI tools."
                ) {
                    if enabledListings.isEmpty {
                        HStack {
                            Text("No enabled modules.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Browse Modules") { state.selection = .modules }
                        }
                    } else {
                        ForEach(enabledListings) { listing in
                            DashboardModuleRow(app: app, jobs: jobs, listing: listing, isHiddenFromBar: model.layout.isHidden(listing.id)) {
                                state.selection = .module(listing.id)
                            }
                            if listing.id != enabledListings.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(24)
        }
        .id(state.tick / 100000)
        .navigationTitle("Dashboard")
    }
}

private struct KPICard: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol).font(.caption).foregroundStyle(tint)
            }
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct DashboardModuleRow: View {
    let app: AppController
    @ObservedObject var jobs: JobHost
    let listing: ModuleListing
    let isHiddenFromBar: Bool
    let onSelect: () -> Void

    var body: some View {
        let activity = app.host.backgroundActivity(of: listing.id)
        let modJobs = jobs.snapshots(for: listing.id)
        let hasJobError = modJobs.contains { $0.effectiveStatus == .failed }

        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: listing.icon)
                    .font(.title3)
                    .foregroundStyle(listing.failure != nil || hasJobError ? .red : .accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(listing.title).fontWeight(.medium)
                        Text(listing.origin.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                        if listing.needsApproval {
                            TagPill(text: "Needs approval", color: .orange)
                        } else if listing.failure != nil || hasJobError {
                            TagPill(text: "Error", color: .red)
                        } else if isHiddenFromBar {
                            TagPill(text: "Hidden from bar", color: .orange)
                        }
                    }

                    HStack(spacing: 6) {
                        if let activity {
                            TagPill(text: "Poll \(formatSeconds(activity.refreshSeconds))", color: .secondary)
                            if activity.jobCount > 0 {
                                TagPill(text: activity.jobCount == 1 ? "1 scheduled job" : "\(activity.jobCount) scheduled jobs", color: hasJobError ? .red : .blue)
                            }
                            if !activity.tools.isEmpty {
                                TagPill(text: "CLI: \(activity.tools.joined(separator: ", "))", color: .purple)
                            }
                            if !activity.hosts.isEmpty {
                                TagPill(text: "HTTP: \(activity.hosts.prefix(2).joined(separator: ", "))", color: .teal)
                            }
                            if activity.usesBrowser {
                                TagPill(text: "Browser", color: .indigo)
                            }
                            if !activity.samplers.isEmpty {
                                TagPill(text: "OS: \(activity.samplers.prefix(3).joined(separator: ", "))", color: .secondary)
                            }
                        } else {
                            Text(listing.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }

                    if let failure = listing.failure {
                        Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }
}

// MARK: Modules Catalog

struct ModulesCatalogPane: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case enabled = "Enabled"
        case user = "Yours"
        case builtIn = "Built in"
        case library = "Library"

        var id: String { rawValue }
    }

    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: MainWindowState
    @State private var filter: Filter = .all
    @State private var searchText = ""

    private var filteredListings: [ModuleListing] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.listings.filter { listing in
            switch filter {
            case .all: break
            case .enabled: guard listing.isEnabled else { return false }
            case .user: guard listing.origin == .user else { return false }
            case .builtIn: guard listing.origin == .builtIn else { return false }
            case .library: guard listing.origin == .library else { return false }
            }
            if query.isEmpty { return true }
            return listing.title.lowercased().contains(query)
                || listing.id.lowercased().contains(query)
                || listing.summary.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader("Modules", subtitle: "Enable built-in and library modules, inspect code and logs, or ask the assistant to build new ones.") {
                    HStack(spacing: 8) {
                        Button("Import…") { ModuleSharing.importModule(app: app) { controller.refresh() } }
                        Button("Modules Folder") { NSWorkspace.shared.open(app.home.modulesDirectory) }
                        Button("Build New") {
                            state.showAssistant = true
                            model.chatDraft = "Build a new module that "
                            model.chatFocusRequests += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                HStack(spacing: 12) {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 360)

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter modules…", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(width: 220)
                }

                let groups: [ModuleListing.Origin] = [.user, .builtIn, .library]
                let nonEmptyGroups = groups.filter { origin in
                    filteredListings.contains { $0.origin == origin }
                }

                if nonEmptyGroups.isEmpty {
                    WindowCard(title: "No matching modules") {
                        Text(searchText.isEmpty ? "No modules in this category yet." : "No modules match “\(searchText)”.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(nonEmptyGroups, id: \.self) { origin in
                        let group = filteredListings.filter { $0.origin == origin }
                        WindowCard(title: origin == .user ? "Yours" : origin == .builtIn ? "Built in" : "Library") {
                            ForEach(group) { listing in
                                CatalogModuleRow(
                                    app: app,
                                    controller: controller,
                                    jobs: jobs,
                                    listing: listing,
                                    isHidden: model.layout.isHidden(listing.id),
                                    isWidget: model.layout.isWidget(listing.id),
                                    onInspect: { state.selection = .module(listing.id) }
                                )
                                if listing.id != group.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Modules")
    }
}

private struct CatalogModuleRow: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var jobs: JobHost
    let listing: ModuleListing
    let isHidden: Bool
    let isWidget: Bool
    let onInspect: () -> Void

    var body: some View {
        let modJobs = jobs.snapshots(for: listing.id)
        HStack(alignment: .center, spacing: 10) {
            Button(action: onInspect) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: listing.icon)
                        .font(.title3)
                        .frame(width: 26)
                        .foregroundStyle(listing.isEnabled ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(listing.title).fontWeight(.medium)
                            if isWidget {
                                TagPill(text: "Widget", color: .accentColor)
                            }
                            if !modJobs.isEmpty {
                                TagPill(text: modJobs.count == 1 ? "1 job" : "\(modJobs.count) jobs", color: .blue)
                            }
                            if listing.needsApproval {
                                TagPill(text: "Needs approval", color: .orange)
                            } else if listing.failure != nil {
                                TagPill(text: "Error", color: .red)
                            } else if listing.isEnabled && isHidden {
                                TagPill(text: "Hidden from bar", color: .orange)
                            }
                        }
                        if !listing.summary.isEmpty {
                            Text(listing.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !listing.permissions.isEmpty {
                            Text("Uses: " + listing.permissions.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if let failure = listing.failure {
                            Text(failure).font(.footnote).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if listing.isEnabled && isHidden {
                Button("Show in Bar") {
                    app.host.showInBar(listing.id)
                }
                .controlSize(.small)
            }

            Button(listing.hasConfigure ? "Configure" : "Inspect", action: onInspect)
                .controlSize(.small)

            if listing.origin == .user {
                Menu {
                    Button("Open File") { NSWorkspace.shared.open(listing.file) }
                    Button("Export…") { ModuleSharing.export(listing, app: app) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([listing.file]) }
                    Divider()
                    Button("Remove", role: .destructive) {
                        app.host.remove(listing.id)
                        controller.refresh()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }

            Toggle("", isOn: Binding(get: { listing.isEnabled }, set: { isOn in
                app.host.setEnabled(listing.id, isOn, origin: listing.origin)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.refresh() }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

// MARK: Module Inspector

struct ModuleInspectorPane: View {
    let app: AppController
    let controller: MainWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: MainWindowState
    let moduleID: String

    private var listing: ModuleListing? { state.listings.first { $0.id == moduleID } }
    private var slot: Slot? { model.slot(moduleID) }
    private var moduleJobs: [JobSnapshot] { jobs.snapshots(for: moduleID) }

    var body: some View {
        VStack(spacing: 0) {
            if let listing {
                inspectorHeader(listing)
                Divider()
                Picker("", selection: $state.inspectorTab) {
                    ForEach(ModuleInspectorTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider()

                switch state.inspectorTab {
                case .overview:
                    overviewTab(listing)
                case .logs:
                    logsTab(listing)
                case .code:
                    codeTab(listing)
                }
            } else {
                ContentUnavailableView("Module not found", systemImage: "puzzlepiece.extension", description: Text("Select a module from the sidebar or browse Modules."))
            }
        }
        .navigationTitle(listing?.title ?? moduleID)
        .task(id: moduleID) {
            if state.configureNode == nil, state.configureFailure == nil, !state.configureIsLoading, app.host.hasConfigure(of: moduleID) {
                controller.refreshConfigure(for: moduleID)
            }
            if state.previewPanelNode == nil, state.previewPanelFailure == nil, !state.previewIsLoading {
                controller.refreshPreview(for: moduleID)
            }
        }
    }

    private func inspectorHeader(_ listing: ModuleListing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: listing.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(listing.title).font(.title3.weight(.semibold))
                    Text(listing.origin.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                    Text(listing.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    if model.layout.isWidget(listing.id) {
                        TagPill(text: "Desktop widget", color: .accentColor)
                    }
                }
                if !listing.summary.isEmpty {
                    Text(listing.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()

            Button {
                app.host.reload(listing.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { controller.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload module")

            if listing.origin == .user {
                Button {
                    NSWorkspace.shared.open(listing.file)
                } label: {
                    Label("Open File", systemImage: "square.and.pencil")
                }
                .help("Open \(listing.id).js in your default editor")

                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([listing.file]) }
                    Button("Export…") { ModuleSharing.export(listing, app: app) }
                    Divider()
                    Button("Delete Module", role: .destructive) {
                        app.host.remove(listing.id)
                        state.selection = .modules
                        controller.refresh()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }

            Toggle("", isOn: Binding(
                get: { listing.isEnabled },
                set: { isOn in
                    app.host.setEnabled(listing.id, isOn, origin: listing.origin)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.refresh() }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func overviewTab(_ listing: ModuleListing) -> some View {
        let needsApproval = slot?.needsApproval ?? listing.needsApproval
        let activeFailure = slot?.failure ?? listing.failure ?? state.previewPanelFailure
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if needsApproval {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.shield.fill").font(.title3).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Waiting for permission approval").fontWeight(.semibold)
                            Text("Requests: " + listing.permissions.joined(separator: ", "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Allow Permissions") {
                            app.host.approve(listing.id)
                            app.chat.markApproved(listing.id)
                            controller.refresh()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.refresh() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if let failure = activeFailure {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Module error").fontWeight(.semibold)
                            Text(failure).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Ask Assistant to Fix") {
                            state.showAssistant = true
                            app.chat.submit("Fix the error in \(listing.id): \(failure)")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if listing.isEnabled && model.layout.isHidden(listing.id) {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "eye.slash.fill").font(.title3).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Hidden from the bar").fontWeight(.semibold)
                            Text("This module is enabled, but currently hidden from your bar.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Bar") {
                            app.host.showInBar(listing.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if listing.isEnabled && !needsApproval {
                    ModulePreviewCard(app: app, controller: controller, model: model, state: state, listing: listing)
                }

                let hasConfigure = listing.hasConfigure || slot?.hasConfigure == true || app.host.hasConfigure(of: listing.id)
                if hasConfigure {
                    if listing.isEnabled && !needsApproval {
                        if let configureNode = state.configureNode {
                            ModuleConfigView(
                                node: configureNode,
                                perform: { action, payload in
                                    Task {
                                        await app.host.perform(listing.id, action: action, payload: payload)
                                        controller.refreshModule(listing.id)
                                    }
                                },
                                performForResult: { action, payload in
                                    await app.host.perform(listing.id, action: action, payload: payload)
                                }
                            )
                        } else if let failure = state.configureFailure {
                            WindowCard(title: "Configuration") {
                                Text(failure)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        } else if state.configureIsLoading {
                            WindowCard(title: "Configuration") {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading configuration…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            WindowCard(title: "Configuration") {
                                HStack {
                                    Text("Configuration unavailable.").font(.footnote).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Reload") { controller.refreshConfigure(for: listing.id) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    } else if !listing.isEnabled {
                        WindowCard(title: "Configuration") {
                            Text("Enable \(listing.title) above to configure its settings.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !moduleJobs.isEmpty {
                    WindowCard(title: "Scheduled Jobs", subtitle: "Background jobs declared by this module’s jobs: { … } block.") {
                        ForEach(moduleJobs) { snap in
                            JobRowView(jobs: jobs, snapshot: snap, showModuleLink: false, onSelectModule: {})
                            if snap.id != moduleJobs.last?.id { Divider() }
                        }
                    }
                }

                WindowCard(title: "Background Processes & Permissions", subtitle: "Everything this module runs or accesses behind the scenes.") {
                    if let activity = app.host.backgroundActivity(of: listing.id) {
                        ActivityRow(label: "Render Poll Loop", value: "Every \(formatSeconds(activity.refreshSeconds)) (panel: \(formatSeconds(activity.panelRefreshSeconds)))")
                        Divider()
                        ActivityRow(label: "Scheduled Jobs", value: activity.jobCount == 0 ? "None" : "\(activity.jobCount) background job(s)")
                        Divider()
                        ActivityRow(label: "CLI Tools (exec)", value: activity.tools.isEmpty ? "None" : activity.tools.joined(separator: ", "))
                        Divider()
                        ActivityRow(label: "Network Hosts", value: activity.hosts.isEmpty ? "None" : activity.hosts.joined(separator: ", "))
                        Divider()
                        ActivityRow(label: "Signed-in Browser", value: activity.usesBrowser ? "Yes (WKWebView)" : "No")
                        Divider()
                        ActivityRow(label: "OS Samplers", value: activity.samplers.isEmpty ? "None" : activity.samplers.joined(separator: ", "))
                        Divider()
                        ActivityRow(label: "Keychain Secrets", value: activity.secrets.isEmpty ? "None" : activity.secrets.joined(separator: ", "))
                    } else {
                        Text(listing.permissions.isEmpty ? "No permissions declared." : "Permissions: " + listing.permissions.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    private func logsTab(_ listing: ModuleListing) -> some View {
        let lines = app.host.logs(of: listing.id)
        let recentJobRuns = moduleJobs.flatMap { snap in
            snap.record.recentRuns.map { run in (job: snap.spec.title, run: run) }
        }.sorted { $0.run.startedAt > $1.run.startedAt }

        return VStack(spacing: 0) {
            HStack {
                Text("\(lines.count) log entries · \(recentJobRuns.count) recent job runs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                .controlSize(.small)
                .disabled(lines.isEmpty)
                Button("Clear") {
                    app.host.clearLogs(of: listing.id)
                    state.tick += 1
                }
                .controlSize(.small)
                .disabled(lines.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !recentJobRuns.isEmpty {
                        WindowCard(title: "Recent Job Runs") {
                            ForEach(Array(recentJobRuns.prefix(15).enumerated()), id: \.offset) { item in
                                let entry = item.element
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: entry.run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(entry.run.succeeded ? .green : .red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(entry.job).fontWeight(.medium)
                                            Text("\(entry.run.durationMs) ms").font(.caption.monospaced()).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(formatTimestamp(entry.run.startedAt)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                        if let err = entry.run.error, !err.isEmpty {
                                            Text(err).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                                        } else if let sum = entry.run.summary, !sum.isEmpty {
                                            Text(sum).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if item.offset < min(recentJobRuns.count, 15) - 1 { Divider() }
                            }
                        }
                    }

                    WindowCard(title: "Console Output") {
                        if lines.isEmpty {
                            Text("No logs yet. Call host.log(...) inside your module or trigger a job to see live output here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(lines.suffix(120).enumerated()), id: \.offset) { entry in
                                    Text(entry.element)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(entry.element.contains("failed") ? Color.red : Color.primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .id(state.tick)
    }

    private func codeTab(_ listing: ModuleListing) -> some View {
        let editable = listing.origin == .user
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(listing.file.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if state.codeDirty {
                    TagPill(text: "Modified", color: .orange)
                }
                if !state.codeStatus.isEmpty {
                    Text(state.codeStatus)
                        .font(.caption)
                        .foregroundStyle(state.codeErrors.isEmpty ? Color.secondary : Color.red)
                }
                Spacer()
                if editable {
                    Button("Revert") {
                        controller.loadCodeIfNeeded(for: listing.id, force: true)
                    }
                    .controlSize(.small)
                    .disabled(!state.codeDirty)

                    Button("Validate & Save") {
                        controller.saveCode(for: listing.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                } else {
                    Button("Copy Source") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.codeDraft, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            if !state.codeErrors.isEmpty || !state.codeWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(state.codeErrors, id: \.self) { err in
                        Label(err, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
                    }
                    ForEach(state.codeWarnings, id: \.self) { warn in
                        Label(warn, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(state.codeErrors.isEmpty ? Color.orange.opacity(0.1) : Color.red.opacity(0.1))
            }

            Divider()

            if editable {
                TextEditor(text: Binding(
                    get: { state.codeDraft },
                    set: { newValue in
                        state.codeDraft = newValue
                        state.codeDirty = true
                    }
                ))
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
            } else {
                ScrollView {
                    Text(state.codeDraft)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
    }
}

// MARK: Shared Job Row

struct JobRowView: View {
    @ObservedObject var jobs: JobHost
    let snapshot: JobSnapshot
    let showModuleLink: Bool
    let onSelectModule: () -> Void

    private var statusColor: Color {
        switch snapshot.effectiveStatus {
        case .ok: .green
        case .running: .blue
        case .failed: .red
        case .paused: .secondary
        case .idle: .secondary
        }
    }

    private var statusSymbol: String {
        switch snapshot.effectiveStatus {
        case .ok: "checkmark.circle.fill"
        case .running: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .idle: "circle.dashed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if snapshot.effectiveStatus == .running {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .frame(width: 16)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(snapshot.spec.title).fontWeight(.medium)
                        if showModuleLink {
                            Button(snapshot.moduleTitle, action: onSelectModule)
                                .buttonStyle(.plain)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Text(snapshot.spec.trigger.summary)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        if let last = snapshot.record.lastRunAt {
                            let dur = snapshot.record.durationMs.map { " (\($0)ms)" } ?? ""
                            Text("Last: \(formatRelative(last))\(dur)")
                        } else {
                            Text("Never run")
                        }
                        if snapshot.effectiveStatus == .paused {
                            Text("· Paused")
                        } else if let next = snapshot.record.nextRunAt {
                            Text("· Next: \(formatCountdown(next))")
                        }
                        if let summary = snapshot.record.summary, !summary.isEmpty, snapshot.record.lastError == nil {
                            Text("· \(summary)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    if snapshot.record.lastError != nil {
                        Button {
                            jobs.clearError(moduleID: snapshot.moduleID, jobID: snapshot.spec.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .controlSize(.small)
                        .help("Dismiss error")
                    }

                    Button {
                        jobs.setEnabled(moduleID: snapshot.moduleID, jobID: snapshot.spec.id, enabled: !snapshot.record.enabled)
                    } label: {
                        Image(systemName: snapshot.record.enabled ? "pause.fill" : "play.fill")
                    }
                    .controlSize(.small)
                    .help(snapshot.record.enabled ? "Pause job" : "Resume job")

                    Button("Run") {
                        Task { await jobs.runNow(moduleID: snapshot.moduleID, jobID: snapshot.spec.id) }
                    }
                    .controlSize(.small)
                    .disabled(snapshot.effectiveStatus == .running)
                }
            }

            if let err = snapshot.record.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 2)
    }
}
