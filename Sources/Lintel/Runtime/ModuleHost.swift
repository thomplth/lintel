import AppKit
import LintelCore

struct ModuleListing: Identifiable, Equatable {
    enum Origin: String {
        case builtIn = "Built in"
        case library = "Library"
        case user = "Yours"
    }

    let id: String
    var title: String
    var icon: String
    var summary: String
    var origin: Origin
    var isEnabled: Bool
    var permissions: [String]
    var failure: String?
    var needsApproval: Bool
    var hasConfigure = false
    var file: URL
}

struct Trial {
    var description: ModuleDescription?
    var chip: ViewNode?
    var panel: ViewNode?
    var problems: [ViewProblem] = []
    var failure: String?

    var errors: [String] {
        (failure.map { [$0] } ?? []) + problems.filter { $0.severity == .error }.map(\.message)
    }
}

/// Finds modules on disk, keeps them loaded in the helper, renders them on their schedules and publishes the results.
@MainActor
final class ModuleHost {
    private struct Source: Equatable {
        var key: String
        var file: URL
        var origin: ModuleListing.Origin
        var stamp: Date
    }

    private struct Loaded {
        var source: Source
        var text: String
        var usesAttention: Bool
        var description: ModuleDescription?
        var backgroundActivity: ModuleBackgroundActivity?
        var failure: String?
        var needsApproval = false
        var timer: Timer?
        var scheduledInterval: TimeInterval?
        var hasRenderedInitialSurface = false
        var isRenderingChip = false
        var isRenderingWidget = false
        var isRenderingPanel = false
        var generation: Int
    }

    let home: AppHome
    let model: BarModel
    let runner: RunnerClient
    let services: HostServices
    let jobs: JobHost
    private let sampler = SystemSampler()
    private var loaded: [String: Loaded] = [:]
    private var blocked: [String: Date] = [:]
    private var approvals: [String: Approval]
    private var stamps: [URL: Date?] = [:]
    private var generation = 0
    private var trialCount = 0
    private var watcher: Timer?
    private var dataTimer: Timer?
    private var dataTimerInterval: TimeInterval?
    private var panelTimer: Timer?
    private var isBarActive = false
    private var isBarHidden = false
    private var inspectedModuleID: String?
    private var bundledBuiltInCache: [Source]?
    private var bundledLibraryCache: [String: Source]?
    private var libraryCache: [String: (stamp: Date, description: ModuleDescription)] = [:]
    var onSettingsChanged: () -> Void = {}
    var onModulesChanged: () -> Void = {}
    var onModuleAction: (String) -> Void = { _ in }

    init(home: AppHome, model: BarModel, runner: RunnerClient, services: HostServices) {
        self.home = home
        self.model = model
        self.runner = runner
        self.services = services
        self.jobs = JobHost(home: home, runner: runner, services: services)
        approvals = home.loadApprovals()
        runner.onCall = { [weak services] module, name, arguments in
            guard let services else { throw ModuleFailure("the app is shutting down") }
            return try await services.call(module: module, name: name, arguments: arguments)
        }
        runner.onPost = { [weak services] module, name, arguments in
            services?.post(module: module, name: name, arguments: arguments)
        }
        runner.onRestart = { [weak self] blamed in self?.recover(blamed: blamed) }
        services.onRefreshRequest = { [weak self] key in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.renderActiveSurface(key)
            }
        }
        services.onAttention = { [weak self] key, isRaised in
            guard let self, let index = self.model.slots.firstIndex(where: { $0.id == key && $0.kind == .module }),
                  self.model.slots[index].isRaised != isRaised
            else { return }
            self.model.slots[index].isRaised = isRaised
            self.refreshSchedulingAndSampling(revealNewSurfaces: isRaised)
        }
        services.onJobRun = { [weak self] caller, name in
            guard let self, let target = self.jobs.resolve(callerModule: caller, identifier: name) else {
                throw ModuleFailure("cannot access job '\(name)'")
            }
            return await self.jobs.runNow(moduleID: target.moduleID, jobID: target.jobID)
        }
        services.onJobSetNext = { [weak self] caller, name, date in
            guard let self, let target = self.jobs.resolve(callerModule: caller, identifier: name) else { return }
            self.jobs.setNext(moduleID: target.moduleID, jobID: target.jobID, date: date)
        }
        services.onJobSetEnabled = { [weak self] caller, name, enabled in
            guard let self, let target = self.jobs.resolve(callerModule: caller, identifier: name) else { return }
            self.jobs.setEnabled(moduleID: target.moduleID, jobID: target.jobID, enabled: enabled)
        }
        services.onJobClearError = { [weak self] caller, name in
            guard let self, let target = self.jobs.resolve(callerModule: caller, identifier: name) else { return }
            self.jobs.clearError(moduleID: target.moduleID, jobID: target.jobID)
        }
        jobs.loadedModulesProvider = { [weak self] in
            guard let self else { return [] }
            return self.loaded.compactMap { key, entry in
                guard let manifest = entry.description?.manifest, !entry.needsApproval else { return nil }
                return (id: key, allowsAllJobs: manifest.allows(.jobs))
            }
        }
        jobs.onChanged = { [weak self] affected in
            guard let self else { return }
            if let affected {
                self.renderActiveSurface(affected)
                self.renderPanel(affected)
            }
            for (key, entry) in self.loaded where key != affected && entry.description?.manifest.allows(.jobs) == true {
                self.renderActiveSurface(key)
                self.renderPanel(key)
            }
            self.onModulesChanged()
        }
        model.manifestFor = { [weak self] id in self?.loaded[id]?.description?.manifest }
    }

    static func symbolExists(_ name: String) -> Bool {
        SymbolNames.exists(name)
    }

    func start(watching: Bool = true) {
        runner.start()
        sampler.demand = .all
        runner.setData(sampler.snapshot())
        jobs.start()
        sync()
        refreshSchedulingAndSampling()
        guard watching else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        timer.tolerance = 0.5
        watcher = timer
    }

    /// For one-off runs that load no modules: start the helper and give it one full reading.
    func primeData() {
        runner.start()
        sampler.demand = .all
        runner.setData(sampler.snapshot())
    }

    func setBarActive(_ active: Bool) {
        guard isBarActive != active else { return }
        isBarActive = active
        refreshSchedulingAndSampling(revealNewSurfaces: active)
    }

    func setBarHidden(_ hidden: Bool) {
        guard isBarHidden != hidden else { return }
        isBarHidden = hidden
        refreshSchedulingAndSampling(revealNewSurfaces: !hidden)
    }

    func setInspectedModule(_ id: String?) {
        guard inspectedModuleID != id else { return }
        inspectedModuleID = id
        refreshSchedulingAndSampling(revealNewSurfaces: id != nil)
    }

    func setFirstRowInMenuBar(_ inMenuBar: Bool) {
        refreshSchedulingAndSampling(revealNewSurfaces: inMenuBar)
    }

    private func pushData(then after: (() -> Void)? = nil) {
        sampler.snapshot { [weak self] data in
            self?.runner.setData(data)
            after?()
        }
    }

    // MARK: Discovery

    private func changed(_ file: URL) -> Bool {
        let stamp = AppHome.modificationDate(of: file)
        if let known = stamps[file], known == stamp { return false }
        stamps[file] = stamp
        return true
    }

    func sync() {
        if changed(home.settingsFile) {
            let settings = home.loadSettings()
            if settings != model.settings {
                model.settings = settings
                services.settings = settings
                onSettingsChanged()
            }
        }
        if changed(home.themeFile) {
            let theme = home.loadTheme()
            if theme != model.theme { model.theme = theme }
        }
        if changed(home.layoutFile) {
            let layout = home.loadLayout()
            if layout != model.layout {
                model.layout = layout
                refreshSchedulingAndSampling(revealNewSurfaces: true)
            }
        }
        if changed(home.approvalsFile) { approvals = home.loadApprovals() }

        let sources = discover()
        for key in loaded.keys where sources[key] == nil { unload(key) }
        for (key, source) in sources where loaded[key]?.source != source {
            if blocked[key] == source.stamp { continue }
            unload(key)
            load(source)
        }
    }

    private func discover() -> [String: Source] {
        var sources: [String: Source] = [:]
        // Bundled built-in and library modules never change at runtime; cache their metadata once.
        let builtIn: [Source]
        if let cached = bundledBuiltInCache {
            builtIn = cached
        } else {
            let scanned = Resources.files(in: "Modules", extension: "js").compactMap { file -> Source? in
                let key = file.deletingPathExtension().lastPathComponent
                guard let stamp = Resources.bundled(file)?.modified ?? AppHome.modificationDate(of: file) else { return nil }
                return Source(key: key, file: file, origin: .builtIn, stamp: stamp)
            }
            bundledBuiltInCache = scanned
            builtIn = scanned
        }
        for source in builtIn { sources[source.key] = source }

        let library: [String: Source]
        if let cached = bundledLibraryCache {
            library = cached
        } else {
            var scanned: [String: Source] = [:]
            for file in Resources.files(in: "Library", extension: "js") {
                let key = file.deletingPathExtension().lastPathComponent
                guard let stamp = Resources.bundled(file)?.modified ?? AppHome.modificationDate(of: file) else { continue }
                scanned[key] = Source(key: key, file: file, origin: .library, stamp: stamp)
            }
            bundledLibraryCache = scanned
            library = scanned
        }
        for key in model.settings.enabledLibrary {
            if let source = library[key] { sources[key] = source }
        }

        for file in userModuleFiles() {
            let key = file.deletingPathExtension().lastPathComponent
            guard let stamp = AppHome.modificationDate(of: file) else { continue }
            sources[key] = Source(key: key, file: file, origin: .user, stamp: stamp)
        }
        for key in model.settings.disabledModules { sources[key] = nil }
        return sources
    }

    private func userModuleFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: home.modulesDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "js" }
    }

    // MARK: Loading

    private func load(_ source: Source) {
        generation += 1
        let current = generation
        let text = Resources.source(of: source.file) ?? ""
        loaded[source.key] = Loaded(
            source: source,
            text: text,
            usesAttention: ModuleRenderPolicy.usesAttention(source: text),
            generation: current
        )
        publish(source.key)
        Task {
            do {
                let description = try await runner.load(key: source.key, source: text, storage: .object(services.storage(for: source.key)))
                guard loaded[source.key]?.generation == current else { return }
                guard description.manifest.id == source.key else {
                    throw ModuleFailure("meta.id is '\(description.manifest.id)' but the file is named \(source.key).js; they must match")
                }
                loaded[source.key]?.description = description
                loaded[source.key]?.backgroundActivity = ModuleBackgroundActivity.analyze(
                    manifest: description.manifest, jobs: description.jobs, source: text
                )
                let isApproved = source.origin != .user || description.manifest.permissions.isEmpty
                    || approvals[source.key]?.covers(description.manifest) == true
                loaded[source.key]?.needsApproval = !isApproved
                services.grants[source.key] = HostServices.Grant(manifest: description.manifest)
                publish(source.key)
                if isApproved {
                    jobs.register(moduleID: source.key, moduleTitle: description.manifest.title, jobs: description.jobs)
                    jobs.pushSnapshotsToModule(source.key, allowsAllJobs: description.manifest.allows(.jobs))
                    refreshSchedulingAndSampling(revealNewSurfaces: true)
                }
                onModulesChanged()
            } catch {
                guard loaded[source.key]?.generation == current else { return }
                loaded[source.key]?.failure = ModuleFailure.describe(error)
                publish(source.key)
                onModulesChanged()
            }
        }
    }

    private func unload(_ key: String) {
        guard let entry = loaded.removeValue(forKey: key) else { return }
        entry.timer?.invalidate()
        jobs.unregister(moduleID: key)
        runner.unload(key: key)
        services.grants[key] = nil
        model.slots.removeAll { $0.id == key && $0.kind == .module }
        if model.panel?.slotID == key, model.panel?.content == .module { closePanel() }
        refreshSchedulingAndSampling()
        onModulesChanged()
    }

    /// Reconciles per-module render timers and demand-driven `SystemSampler` polling against what is
    /// currently visible (or attention-capable). Hidden modules and idle unpinned non-attention modules
    /// pause their timers and sampler subsystems until revealed.
    private func refreshSchedulingAndSampling(revealNewSurfaces: Bool = false) {
        let raised = Set(model.slots.filter(\.isRaised).map(\.id))
        let idleRows = model.layout.arranged(
            model.layoutItems, isActive: false, raised: raised, keepsFirstRow: model.isFirstRowInMenuBar
        )
        let visibleIdleKeys = Set(idleRows.joined())

        var activeModules: [SamplerDemand.ActiveModule] = []
        var wokenKeys: [String] = []
        var initialKeys: [String] = []

        for key in loaded.keys {
            guard let entry = loaded[key], let desc = entry.description, !entry.needsApproval else { continue }
            let isHidden = model.layout.isHidden(key)
            let isWidget = model.layout.isWidget(key)
            let target = ModuleRenderPolicy.Target(
                isHiddenInLayout: isHidden,
                isWidget: isWidget,
                isVisibleWhileIdle: visibleIdleKeys.contains(key),
                usesAttention: entry.usesAttention,
                isBarActive: isBarActive,
                isBarHidden: isBarHidden
            )
            let shouldRun = ModuleRenderPolicy.shouldRenderPeriodically(target)
            if shouldRun {
                let interval = isWidget ? desc.manifest.panelRefreshSeconds : desc.manifest.refreshSeconds
                if entry.timer == nil || entry.scheduledInterval != interval {
                    let wasPaused = entry.timer == nil
                    entry.timer?.invalidate()
                    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.renderActiveSurface(key) }
                    }
                    timer.tolerance = min(max(interval * 0.15, 0.1), 5)
                    loaded[key]?.timer = timer
                    loaded[key]?.scheduledInterval = interval
                    if wasPaused && (revealNewSurfaces || !entry.hasRenderedInitialSurface) {
                        wokenKeys.append(key)
                    }
                }
                activeModules.append(SamplerDemand.ActiveModule(
                    source: entry.text,
                    refreshSeconds: interval,
                    hasExpandedSurface: isWidget
                ))
            } else {
                if entry.timer != nil {
                    entry.timer?.invalidate()
                    loaded[key]?.timer = nil
                    loaded[key]?.scheduledInterval = nil
                }
                if !entry.hasRenderedInitialSurface, !isHidden {
                    initialKeys.append(key)
                }
            }
        }

        // Open click-to-peek panel and visible MainWindow inspector also drive sampler demand (including processes).
        for expandedKey in [model.panel?.content == .module ? model.panel?.slotID : nil, inspectedModuleID].compactMap({ $0 }) {
            guard let entry = loaded[expandedKey], let desc = entry.description, !entry.needsApproval else { continue }
            activeModules.append(SamplerDemand.ActiveModule(
                source: entry.text,
                refreshSeconds: desc.manifest.panelRefreshSeconds,
                hasExpandedSurface: true
            ))
        }

        let demand = SamplerDemand.resolve(modules: activeModules)
        let hadDemand = !sampler.demand.isEmpty
        sampler.demand = demand

        if dataTimerInterval != demand.recommendedInterval {
            dataTimer?.invalidate()
            dataTimer = nil
            dataTimerInterval = demand.recommendedInterval
            if let interval = demand.recommendedInterval {
                let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pushData() }
                }
                timer.tolerance = min(interval * 0.2, 3)
                dataTimer = timer
            }
        }

        for key in initialKeys {
            loaded[key]?.hasRenderedInitialSurface = true
            renderActiveSurface(key)
        }
        if !wokenKeys.isEmpty {
            for key in wokenKeys { loaded[key]?.hasRenderedInitialSurface = true }
            if revealNewSurfaces, !demand.isEmpty {
                pushData { [weak self] in
                    for key in wokenKeys { self?.renderActiveSurface(key) }
                }
            } else {
                for key in wokenKeys { renderActiveSurface(key) }
            }
        } else if revealNewSurfaces, !demand.isEmpty, !hadDemand {
            pushData()
        }
    }

    func renderActiveSurface(_ key: String) {
        if model.layout.isWidget(key) {
            renderWidget(key)
        } else {
            renderChip(key)
        }
    }

    func setWidget(_ key: String, to box: WidgetBox?) {
        var layout = model.layout
        layout.setWidget(box, for: key)
        update(layout)
        if box != nil, model.panel?.slotID == key {
            closePanel()
        }
    }

    func moveWidget(_ key: String, to drop: WidgetShelfDrop) {
        var layout = model.layout
        layout.moveWidget(key, to: drop)
        update(layout)
    }

    func ensureWidgetRendered(_ key: String) {
        if model.slot(key)?.widgetNode == nil {
            renderWidget(key)
        }
    }

    func setPeekBox(_ key: String, to box: WidgetBox) {
        if var panel = model.panel, panel.slotID == key, panel.widgetBox != box {
            panel.widgetBox = box
            model.panel = panel
        }
        if model.layout.panelSize(of: key) != box {
            var layout = model.layout
            layout.setPanelSize(box, for: key)
            update(layout)
        }
    }

    private func recover(blamed: String?) {
        if let blamed, let entry = loaded[blamed] {
            blocked[blamed] = entry.source.stamp
            entry.timer?.invalidate()
            loaded[blamed]?.timer = nil
            generation += 1
            loaded[blamed]?.generation = generation
            loaded[blamed]?.isRenderingChip = false
            loaded[blamed]?.description = nil
            loaded[blamed]?.failure = "Stopped: it ran for more than \(Int(RunnerClient.busyLimit)) seconds without finishing"
            publish(blamed)
        }
        for (key, entry) in loaded where key != blamed {
            entry.timer?.invalidate()
            loaded[key] = nil
            load(entry.source)
        }
    }

    // MARK: Publishing

    private func publish(_ key: String, chip: ViewNode? = nil, widget: ViewNode? = nil) {
        guard let entry = loaded[key] else { return }
        let previous = model.slot(key)
        var slot = Slot(id: key, title: entry.description?.manifest.title ?? key)
        if let desc = entry.description {
            let manifest = desc.manifest
            slot.icon = Self.symbolExists(manifest.icon) ? manifest.icon : "puzzlepiece.extension"
            slot.isPinned = manifest.pinned
            slot.order = manifest.order
            slot.permissions = manifest.permissions
            slot.hasWidget = desc.hasWidget
            slot.hasConfigure = desc.hasConfigure
            slot.defaultShape = manifest.defaultShape
        } else {
            slot.order = 999
            slot.hasWidget = false
        }
        slot.failure = entry.failure
        slot.needsApproval = entry.needsApproval
        slot.isUserModule = entry.source.origin == .user
        slot.chip = chip ?? previous?.chip
        slot.widgetNode = widget ?? previous?.widgetNode
        slot.isRaised = previous?.isRaised ?? false
        if let index = model.slots.firstIndex(where: { $0.id == key && $0.kind == .module }) {
            if model.slots[index] != slot {
                Perf.count("module.publish")
                model.slots[index] = slot
            }
        } else {
            model.slots.append(slot)
        }
    }

    private func rendered(_ key: String, _ surface: Surface) async -> (node: ViewNode?, failure: String?) {
        do {
            let parsed = ViewNode.parse(try await runner.render(key: key, surface: surface))
            if let failure = parsed.errors.first { return (nil, failure) }
            if surface == .chip, let offender = parsed.node?.descendants.first(where: { !Catalog.chipComponents.contains($0.component) }) {
                return (nil, "\(offender.component.rawValue) cannot go in the bar item")
            }
            return (parsed.node, parsed.node == nil ? "\(surface == .chip ? "chip" : "widget")() returned nothing" : nil)
        } catch {
            return (nil, ModuleFailure.describe(error))
        }
    }

    func renderChip(_ key: String) {
        guard let entry = loaded[key], entry.description != nil, !entry.needsApproval, !entry.isRenderingChip else { return }
        loaded[key]?.isRenderingChip = true
        let current = entry.generation
        Task {
            let result = await Perf.measure("module.render.chip") { await rendered(key, .chip) }
            guard loaded[key]?.generation == current else { return }
            loaded[key]?.isRenderingChip = false
            loaded[key]?.failure = result.failure
            publish(key, chip: result.node)
        }
    }

    func renderWidget(_ key: String) {
        guard let entry = loaded[key], let desc = entry.description, desc.hasWidget,
              !entry.needsApproval, !entry.isRenderingWidget
        else { return }
        loaded[key]?.isRenderingWidget = true
        let current = entry.generation
        Task {
            let result = await Perf.measure("module.render.widget") { await rendered(key, .panel) }
            guard loaded[key]?.generation == current else { return }
            loaded[key]?.isRenderingWidget = false
            loaded[key]?.failure = result.failure
            publish(key, widget: result.node)
        }
    }

    // MARK: Panels (Transient Click-to-Peek)

    func openPanel(_ key: String, corner: ResizeCorner? = nil) {
        let shape = model.slot(key)?.defaultShape ?? .card
        let metrics = Metrics(model.theme)
        let box: WidgetBox = if let remembered = model.layout.panelSize(of: key) {
            WidgetResize.clampedBox(
                remembered,
                metrics: metrics,
                maxSize: metrics.maxWidgetSize(in: model.maxWidgetScreenSize)
            )
        } else {
            metrics.defaultWidgetBox(for: shape)
        }
        let resolvedCorner = corner ?? WidgetResize.corner(for: model.settings.anchor)
        model.panel = PanelState(slotID: key, content: .module, widgetBox: box, resizeCorner: resolvedCorner, isLoading: true)
        refreshSchedulingAndSampling(revealNewSurfaces: true)
        sampler.refreshProcesses { [weak self] in
            self?.pushData { self?.renderPanel(key) }
        }
        renderPanel(key)
        panelTimer?.invalidate()
        let interval = loaded[key]?.description?.manifest.panelRefreshSeconds ?? 5
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderPanel(key) }
        }
        timer.tolerance = min(max(interval * 0.15, 0.1), 5)
        panelTimer = timer
    }

    func closePanel() {
        panelTimer?.invalidate()
        panelTimer = nil
        if model.panel != nil { model.panel = nil }
        refreshSchedulingAndSampling()
    }

    func renderPanel(_ key: String) {
        guard model.panel?.slotID == key, model.panel?.content == .module, let entry = loaded[key] else { return }
        guard entry.description?.hasWidget == true, !entry.needsApproval, entry.failure == nil || entry.description != nil else {
            model.panel?.isLoading = false
            return
        }
        guard !entry.isRenderingPanel else { return }
        loaded[key]?.isRenderingPanel = true
        let current = entry.generation
        Task {
            let result = await rendered(key, .panel)
            guard loaded[key]?.generation == current else { return }
            loaded[key]?.isRenderingPanel = false
            guard model.panel?.slotID == key, model.panel?.content == .module else { return }
            var panel = model.panel!
            panel.isLoading = false
            panel.failure = result.failure
            if let node = result.node { panel.node = node }
            if panel != model.panel { model.panel = panel }
        }
    }

    @discardableResult
    func perform(_ key: String, action: String, payload: JSONValue) async -> JSONValue {
        guard loaded[key]?.description != nil else { return .null }
        var outcome = JSONValue.null
        do {
            outcome = try await runner.act(key: key, action: action, payload: payload)
        } catch {
            if model.panel?.slotID == key { model.panel?.failure = ModuleFailure.describe(error) }
        }
        renderActiveSurface(key)
        if model.panel?.slotID == key {
            renderPanel(key)
        }
        onModuleAction(key)
        return outcome
    }

    // MARK: Authoring

    func trial(source: String) async -> Trial {
        trialCount += 1
        let key = "trial-\(trialCount)"
        var trial = Trial()
        defer {
            runner.unload(key: key)
            services.grants[key] = nil
        }
        do {
            let description = try await runner.load(key: key, source: source, storage: .object([:]))
            trial.description = description
            services.grants[key] = HostServices.Grant(manifest: description.manifest, isTrial: true)
        } catch {
            trial.failure = ModuleFailure.describe(error)
            return trial
        }
        let desc = trial.description!
        let manifest = desc.manifest
        var configureNode: ViewNode?
        do {
            let chip = ViewNode.parse(try await runner.render(key: key, surface: .chip))
            trial.chip = chip.node
            trial.problems += chip.problems
            if desc.hasWidget {
                let widget = ViewNode.parse(try await runner.renderWidget(key: key))
                trial.problems += widget.problems
                if let node = widget.node {
                    trial.panel = node
                } else {
                    trial.problems.append(.error("widget() returned nothing"))
                }
            }
            if desc.hasConfigure {
                let conf = ViewNode.parse(try await runner.renderConfigure(key: key))
                trial.problems += conf.problems
                configureNode = conf.node
            }
        } catch {
            trial.failure = "it threw while rendering: \(ModuleFailure.describe(error)). Catch expected failures and return a calm fallback view"
            return trial
        }
        trial.problems += DesignLint.check(
            chip: trial.chip, panel: nil, manifest: manifest,
            actions: desc.actions, symbolExists: Self.symbolExists
        )
        if let widgetNode = trial.panel {
            trial.problems += DesignLint.checkWidget(
                widgetNode, manifest: manifest, actions: desc.actions,
                metrics: Metrics(model.theme), symbolExists: Self.symbolExists
            )
        }
        if let configureNode {
            trial.problems += DesignLint.checkConfigure(
                configureNode, manifest: manifest, actions: desc.actions, symbolExists: Self.symbolExists
            )
        }
        return trial
    }

    func install(source: String, id: String, prompt: String?) throws {
        guard ModuleManifest.isValid(id: id) else { throw ModuleFailure("'\(id)' is not a valid module id") }
        home.prepare()
        try source.write(to: home.moduleFile(id: id), atomically: true, encoding: .utf8)
        if let prompt { try? prompt.write(to: home.promptFile(id: id), atomically: true, encoding: .utf8) }
        blocked[id] = nil
        var settings = model.settings
        if settings.disabledModules.contains(id) {
            settings.disabledModules.removeAll { $0 == id }
            update(settings)
        }
        if model.layout.isHidden(id) {
            var layout = model.layout
            layout.show(id)
            update(layout)
        }
        sync()
    }

    func approve(_ id: String) {
        guard let description = loaded[id]?.description else { return }
        let manifest = description.manifest
        approvals[id] = Approval(permissions: manifest.permissions)
        home.save(approvals, to: home.approvalsFile)
        stamps[home.approvalsFile] = AppHome.modificationDate(of: home.approvalsFile)
        loaded[id]?.needsApproval = false
        publish(id)
        jobs.register(moduleID: id, moduleTitle: manifest.title, jobs: description.jobs)
        jobs.pushSnapshotsToModule(id, allowsAllJobs: manifest.allows(.jobs))
        refreshSchedulingAndSampling(revealNewSurfaces: true)
        if model.panel?.slotID == id { openPanel(id) }
        onModulesChanged()
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: home.moduleFile(id: id))
        try? FileManager.default.removeItem(at: home.promptFile(id: id))
        services.forgetStorage(for: id)
        approvals[id] = nil
        home.save(approvals, to: home.approvalsFile)
        var layout = model.layout
        layout.remove(id)
        layout.setWidget(nil, for: id)
        layout.setPanelSize(nil, for: id)
        layout.pinned[id] = nil
        layout.hidden.removeAll { $0 == id }
        if layout != model.layout { update(layout) }
        var settings = model.settings
        settings.enabledLibrary.removeAll { $0 == id }
        if settings != model.settings { update(settings) }
        sync()
    }

    func setEnabled(_ id: String, _ isEnabled: Bool, origin: ModuleListing.Origin) {
        var settings = model.settings
        settings.disabledModules.removeAll { $0 == id }
        settings.enabledLibrary.removeAll { $0 == id }
        if origin == .library {
            if isEnabled { settings.enabledLibrary.append(id) }
        } else if !isEnabled {
            settings.disabledModules.append(id)
        }
        update(settings)
        if model.layout.isHidden(id) {
            var layout = model.layout
            layout.show(id)
            update(layout)
        }
        sync()
    }

    func showInBar(_ id: String, isOptIn: Bool = false) {
        var layout = model.layout
        layout.show(id, isOptIn: isOptIn)
        if layout != model.layout { update(layout) }
    }

    func update(_ settings: AppSettings) {
        model.settings = settings
        services.settings = settings
        home.save(settings, to: home.settingsFile)
        stamps[home.settingsFile] = AppHome.modificationDate(of: home.settingsFile)
        onSettingsChanged()
    }

    func update(_ layout: BarLayout) {
        model.layout = layout
        home.save(layout, to: home.layoutFile)
        stamps[home.layoutFile] = AppHome.modificationDate(of: home.layoutFile)
        refreshSchedulingAndSampling(revealNewSurfaces: true)
    }

    func update(_ theme: Theme) {
        guard theme != model.theme else { return }
        home.saveTheme(theme)
        model.theme = theme
        stamps[home.themeFile] = AppHome.modificationDate(of: home.themeFile)
    }

    func undoTheme() -> Bool {
        guard home.undoTheme() else { return false }
        model.theme = home.loadTheme()
        stamps[home.themeFile] = AppHome.modificationDate(of: home.themeFile)
        return true
    }

    func source(of id: String) -> String? {
        loaded[id]?.text
    }

    func manifest(of id: String) -> ModuleManifest? {
        loaded[id]?.description?.manifest
    }

    func declaredJobs(of id: String) -> [JobManifest] {
        loaded[id]?.description?.jobs ?? []
    }

    func backgroundActivity(of id: String) -> ModuleBackgroundActivity? {
        guard let entry = loaded[id] else { return nil }
        if let cached = entry.backgroundActivity { return cached }
        guard let description = entry.description else { return nil }
        let analyzed = ModuleBackgroundActivity.analyze(manifest: description.manifest, jobs: description.jobs, source: entry.text)
        loaded[id]?.backgroundActivity = analyzed
        return analyzed
    }

    func logs(of id: String) -> [String] {
        services.logs[id] ?? []
    }

    func clearLogs(of id: String) {
        services.clearLogs(for: id)
    }

    func hasConfigure(of id: String) -> Bool {
        loaded[id]?.description?.hasConfigure == true
    }

    func previewPanel(of id: String) async -> (node: ViewNode?, failure: String?) {
        guard let entry = loaded[id], entry.description?.hasWidget == true, !entry.needsApproval else {
            return (nil, loaded[id]?.failure)
        }
        return await rendered(id, .panel)
    }

    func previewConfigure(of id: String) async -> (node: ViewNode?, failure: String?) {
        guard let entry = loaded[id], entry.description?.hasConfigure == true, !entry.needsApproval else {
            return (nil, nil)
        }
        do {
            let parsed = ViewNode.parse(try await runner.renderConfigure(key: id))
            if let failure = parsed.errors.first { return (nil, failure) }
            return (parsed.node, parsed.node == nil ? "configure() returned nothing" : nil)
        } catch {
            return (nil, ModuleFailure.describe(error))
        }
    }

    func reload(_ id: String) {
        guard let entry = loaded[id] else {
            sync()
            return
        }
        blocked[id] = nil
        let source = entry.source
        unload(id)
        load(source)
    }

    func prompt(of id: String) -> String? {
        try? String(contentsOf: home.promptFile(id: id), encoding: .utf8)
    }

    var loadedIDs: [String] {
        loaded.keys.sorted()
    }

    /// Everything the user could have in the bar: what is loaded, what they switched off, and the library on offer.
    func listings() async -> [ModuleListing] {
        var listings: [ModuleListing] = []
        var seen = Set<String>()
        for (key, entry) in loaded {
            seen.insert(key)
            listings.append(ModuleListing(
                id: key, title: entry.description?.manifest.title ?? key, icon: model.slot(key)?.icon ?? "puzzlepiece.extension",
                summary: entry.description?.manifest.summary ?? "", origin: entry.source.origin, isEnabled: true,
                permissions: entry.description?.manifest.permissions ?? [], failure: entry.failure,
                needsApproval: entry.needsApproval, hasConfigure: entry.description?.hasConfigure ?? false, file: entry.source.file
            ))
        }
        let dormant: [(URL, ModuleListing.Origin)] =
            Resources.files(in: "Modules", extension: "js").map { ($0, .builtIn) }
            + Resources.files(in: "Library", extension: "js").map { ($0, .library) }
            + userModuleFiles().map { ($0, .user) }
        for (file, origin) in dormant.reversed() {
            let key = file.deletingPathExtension().lastPathComponent
            guard seen.insert(key).inserted, let description = await describe(file) else { continue }
            listings.append(ModuleListing(
                id: key, title: description.manifest.title, icon: Self.symbolExists(description.manifest.icon) ? description.manifest.icon : "puzzlepiece.extension",
                summary: description.manifest.summary, origin: origin, isEnabled: false,
                permissions: description.manifest.permissions, failure: nil, needsApproval: false,
                hasConfigure: description.hasConfigure, file: file
            ))
        }
        return listings.sorted { ($0.origin.rawValue, $0.title) < ($1.origin.rawValue, $1.title) }
    }

    private func describe(_ file: URL) async -> ModuleDescription? {
        let key = file.deletingPathExtension().lastPathComponent
        guard let stamp = Resources.bundled(file)?.modified ?? AppHome.modificationDate(of: file) else { return nil }
        if let cached = libraryCache[key], cached.stamp == stamp { return cached.description }
        guard let text = Resources.source(of: file) else { return nil }
        trialCount += 1
        let temporary = "describe-\(trialCount)"
        defer { runner.unload(key: temporary) }
        guard let description = try? await runner.load(key: temporary, source: text, storage: .object([:])) else { return nil }
        libraryCache[key] = (stamp, description)
        return description
    }
}
