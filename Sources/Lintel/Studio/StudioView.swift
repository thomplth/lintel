import AppKit
import LintelCore
import SwiftUI

struct StudioView: View {
    let app: AppController
    let controller: StudioWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: StudioState

    var body: some View {
        NavigationSplitView {
            StudioSidebar(app: app, controller: controller, model: model, jobs: jobs, state: state)
                .navigationSplitViewColumnWidth(min: 205, ideal: 235, max: 290)
        } detail: {
            Group {
                switch state.selection {
                case .dashboard:
                    StudioDashboardPane(app: app, controller: controller, model: model, jobs: jobs, state: state)
                case .module(let id):
                    StudioModuleInspector(app: app, controller: controller, model: model, jobs: jobs, state: state, moduleID: id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $state.showAssistant) {
                StudioAssistantPane(app: app, controller: controller, model: model, state: state)
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
                .help("Refresh modules and previews")

                Button {
                    state.selection = .dashboard
                    state.showAssistant = true
                    model.chatDraft = "Build a new module that "
                    model.chatFocusRequests += 1
                } label: {
                    Label("New Module", systemImage: "plus")
                }
                .help("Ask the assistant to build a new module")

                Button {
                    app.showSettings(tab: .general)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Lintel Settings")

                Button {
                    state.showAssistant.toggle()
                } label: {
                    Label("Assistant", systemImage: "sparkles")
                }
                .help(state.showAssistant ? "Hide Assistant" : "Show Assistant")
            }
        }
        .frame(minWidth: 920, minHeight: 560)
    }
}

// MARK: Sidebar

private struct StudioSidebar: View {
    let app: AppController
    let controller: StudioWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: StudioState

    private var alertCount: Int {
        let failingModules = state.listings.filter { $0.failure != nil || $0.needsApproval }.count
        return failingModules + jobs.failingCount
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selection) {
                Section("Overview") {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        Text("Dashboard")
                            .fontWeight(.medium)
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
                    .tag(StudioSelection.dashboard)
                }

                ForEach([ModuleListing.Origin.user, .library, .builtIn], id: \.self) { origin in
                    let group = state.listings.filter { $0.origin == origin }
                    if !group.isEmpty {
                        Section(origin == .user ? "Yours" : origin == .library ? "Library" : "Built in") {
                            ForEach(group) { listing in
                                SidebarModuleRow(app: app, model: model, jobs: jobs, listing: listing)
                                    .tag(StudioSelection.module(listing.id))
                            }
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

                Spacer()

                Button {
                    ModuleSharing.importModule(app: app) { controller.refresh() }
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
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

    private var statusColor: Color {
        if liveFailure != nil || moduleJobs.contains(where: { $0.effectiveStatus == .failed }) { return .red }
        if liveNeedsApproval { return .orange }
        if moduleJobs.contains(where: { $0.effectiveStatus == .running }) { return .blue }
        return listing.isEnabled ? .green : .secondary.opacity(0.45)
    }

    private var trailingText: String {
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

// MARK: Dashboard

private struct StudioDashboardPane: View {
    let app: AppController
    let controller: StudioWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: StudioState

    private var enabledListings: [ModuleListing] { state.listings.filter(\.isEnabled) }
    private var issueListings: [ModuleListing] { state.listings.filter { $0.failure != nil || $0.needsApproval } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dashboard")
                            .font(.title2.weight(.semibold))
                        Text("Live overview of all modules, background poll loops, and scheduled jobs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let pid = app.runner.processIdentifier {
                        HStack(spacing: 6) {
                            Circle().fill(app.runner.isRunning ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text("Runtime PID \(pid)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                }

                // KPI cards
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    KPICard(
                        title: "Active Modules",
                        value: "\(enabledListings.count)",
                        caption: "of \(state.listings.count) installed",
                        symbol: "puzzlepiece.extension",
                        tint: .accentColor
                    )
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

                // Scheduled Jobs across all modules
                StudioCard(
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

                // Modules & Background Processes table
                StudioCard(
                    title: "Modules & Background Activity",
                    subtitle: "Every active module’s poll cadence, scheduled jobs, network hosts, and CLI tools."
                ) {
                    if enabledListings.isEmpty {
                        Text("No enabled modules.").foregroundStyle(.secondary)
                    } else {
                        ForEach(enabledListings) { listing in
                            DashboardModuleRow(app: app, jobs: jobs, listing: listing) {
                                state.selection = .module(listing.id)
                            }
                            if listing.id != enabledListings.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(22)
        }
        .id(state.tick / 100000) // preserve scroll position while allowing reactive updates
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
    }
}

private struct DashboardModuleRow: View {
    let app: AppController
    @ObservedObject var jobs: JobHost
    let listing: ModuleListing
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
                        }
                    }

                    // Explicit background process tags
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

// MARK: Module Inspector

private struct StudioModuleInspector: View {
    let app: AppController
    let controller: StudioWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var jobs: JobHost
    @ObservedObject var state: StudioState
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
                    ForEach(StudioInspectorTab.allCases) { tab in
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
                ContentUnavailableView("Module not found", systemImage: "puzzlepiece.extension", description: Text("Select a module from the sidebar."))
            }
        }
        .navigationTitle(listing?.title ?? moduleID)
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
                        state.selection = .dashboard
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

                // Live Preview
                if listing.isEnabled && !needsApproval {
                    StudioCard(title: "Live Preview", subtitle: "Real-time render of the bar chip and panel using your current theme.") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Text("Bar Chip").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                if let chip = slot?.chip {
                                    let chipContext = RenderContext(theme: model.theme, surface: .chip, material: .glass, moduleID: listing.id, manifest: app.host.manifest(of: listing.id))
                                    NodeView(node: chip, context: chipContext)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(.black.opacity(0.25), in: Capsule())
                                } else {
                                    Text("No chip rendered yet").font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button {
                                    app.host.renderChip(listing.id)
                                    controller.refreshPreview(for: listing.id)
                                } label: {
                                    Label("Re-render", systemImage: "arrow.clockwise")
                                }
                                .controlSize(.small)
                            }

                            if let node = state.previewPanelNode {
                                Divider()
                                let panelContext = makePanelContext(listing.id)
                                ScrollView(.vertical) {
                                    VStack(alignment: .leading, spacing: panelContext.metrics.sectionSpacing) {
                                        if node.component == .column, node.props.isEmpty {
                                            ForEach(Array(node.children.enumerated()), id: \.offset) { child in
                                                NodeView(node: child.element, context: panelContext)
                                            }
                                        } else {
                                            NodeView(node: node, context: panelContext)
                                        }
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxWidth: 460, maxHeight: 380, alignment: .leading)
                                .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.quaternary, lineWidth: 1))
                            } else if state.previewIsLoading {
                                HStack { ProgressView().controlSize(.small); Text("Rendering panel…").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }

                // Scheduled Jobs owned by this module
                if !moduleJobs.isEmpty {
                    StudioCard(title: "Scheduled Jobs", subtitle: "Background jobs declared by this module’s jobs: { … } block.") {
                        ForEach(moduleJobs) { snap in
                            JobRowView(jobs: jobs, snapshot: snap, showModuleLink: false, onSelectModule: {})
                            if snap.id != moduleJobs.last?.id { Divider() }
                        }
                    }
                }

                // Background Activity Breakdown
                StudioCard(title: "Background Processes & Permissions", subtitle: "Everything this module runs or accesses behind the scenes.") {
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
                        StudioCard(title: "Recent Job Runs") {
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

                    StudioCard(title: "Console Output") {
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

    private func makePanelContext(_ id: String) -> RenderContext {
        var ctx = RenderContext(theme: model.theme, surface: .panel, material: .glass, moduleID: id, manifest: app.host.manifest(of: id))
        ctx.perform = { action, payload in
            Task {
                await app.host.perform(id, action: action, payload: payload)
                controller.refreshPreview(for: id)
            }
        }
        ctx.performForResult = { action, payload in
            let res = await app.host.perform(id, action: action, payload: payload)
            controller.refreshPreview(for: id)
            return res
        }
        return ctx
    }
}

// MARK: Shared Job Row

private struct JobRowView: View {
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

// MARK: Interactive Assistant Chat Inspector

private struct StudioAssistantPane: View {
    let app: AppController
    let controller: StudioWindowController
    @ObservedObject var model: BarModel
    @ObservedObject var state: StudioState
    @FocusState private var isComposerFocused: Bool

    private var focusedListing: ModuleListing? {
        guard let id = model.studioFocusedModuleID else { return nil }
        return state.listings.first { $0.id == id }
    }

    private var quickPrompts: [String] {
        if let focused = focusedListing {
            if let err = focused.failure {
                return ["Fix this error: \(err.prefix(80))", "Add a scheduled background job to \(focused.title)", "Improve the panel layout"]
            }
            return ["Add a scheduled job to \(focused.title)", "Add error alerts to \(focused.title)", "Refine \(focused.title)'s bar chip"]
        }
        return [
            "Build a module with a scheduled background job",
            "Switch to the Ink look",
            "Add a module with the Bitcoin price",
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistant").font(.headline)
                    if !model.engineName.isEmpty {
                        Text(model.engineName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if model.isChatBusy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    app.chat.command("clear", nil)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
                .disabled(model.chat.isEmpty || model.isChatBusy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let focused = focusedListing {
                HStack(spacing: 6) {
                    Image(systemName: focused.icon).font(.caption).foregroundStyle(.tint)
                    Text("Context: \(focused.title)").font(.caption).lineLimit(1)
                    Spacer()
                    Button {
                        model.studioFocusedModuleID = nil
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Chat globally instead of focusing \(focused.title)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Develop, debug, and extend your modules here. Selecting a module shares its source, job status, and recent logs automatically.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                ForEach(quickPrompts, id: \.self) { prompt in
                                    Button {
                                        submit(prompt)
                                    } label: {
                                        HStack {
                                            Text(prompt).font(.footnote).multilineTextAlignment(.leading)
                                            Spacer(minLength: 6)
                                            Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 4)
                        }

                        ForEach(model.chat) { message in
                            chatBubble(message).id(message.id)
                        }

                        if model.isChatBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.chatActivity.isEmpty ? "Thinking…" : model.chatActivity)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("studio-activity")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.chat.count) { scroll(proxy) }
                .onChange(of: model.isChatBusy) { scroll(proxy) }
                .onAppear { scroll(proxy) }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    focusedListing.map { "Change \($0.title)…" } ?? "Build a module or change the bar…",
                    text: $model.chatDraft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .onSubmit { submit(model.chatDraft) }

                Button {
                    submit(model.chatDraft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isChatBusy
                                ? Color.secondary.opacity(0.4)
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isChatBusy || model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .onChange(of: model.chatFocusRequests) { isComposerFocused = true }
    }

    private func submit(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.isChatBusy else { return }
        model.chatDraft = ""
        app.chat.submit(trimmed)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if model.isChatBusy {
                proxy.scrollTo("studio-activity", anchor: .bottom)
            } else if let last = model.chat.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder private func chatBubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 28)
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                if let detail = message.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if message.needsApproval || message.canUndoTheme || message.moduleID != nil {
                    let pendingApproval = message.needsApproval && message.moduleID.map { model.slot($0)?.needsApproval == true } == true
                    HStack(spacing: 8) {
                        if pendingApproval, let id = message.moduleID {
                            Button("Allow Permissions") {
                                app.host.approve(id)
                                app.chat.markApproved(id)
                                state.selection = .module(id)
                                controller.refresh()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.refresh() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else if message.needsApproval {
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if let id = message.moduleID {
                            Button("Inspect") {
                                state.selection = .module(id)
                                controller.refresh()
                            }
                            .controlSize(.small)
                        }
                        if message.canUndoTheme {
                            Button("Undo Theme") { app.chat.command("undo", message) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: Helpers

private struct StudioCard<Content: View>: View {
    let title: String
    var subtitle: String?
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
        }
    }
}

private struct TagPill: View {
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

private struct ActivityRow: View {
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

private func formatSeconds(_ seconds: Double) -> String {
    let s = Int(seconds)
    if s >= 3600 && s % 3600 == 0 { return "\(s / 3600)h" }
    if s >= 60 && s % 60 == 0 { return "\(s / 60)m" }
    return "\(s)s"
}

private func formatRelative(_ date: Date) -> String {
    let secs = max(0, Int(Date().timeIntervalSince(date)))
    if secs < 45 { return "just now" }
    if secs < 3600 { return "\(secs / 60)m ago" }
    if secs < 86400 { return "\(secs / 3600)h ago" }
    return "\(secs / 86400)d ago"
}

private func formatCountdown(_ date: Date) -> String {
    let secs = Int(date.timeIntervalSinceNow)
    if secs <= 5 { return "due now" }
    let h = secs / 3600
    let m = (secs % 3600) / 60
    if h > 0 { return "in \(h)h \(String(format: "%02d", m))m" }
    if m > 0 { return "in \(m)m" }
    return "in \(secs)s"
}

private func formatTimestamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f.string(from: date)
}
