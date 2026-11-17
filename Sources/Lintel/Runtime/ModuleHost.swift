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
        var description: ModuleDescription?
        var failure: String?
        var needsApproval = false
        var timer: Timer?
        var isRenderingChip = false
        var isRenderingPanel = false
        var generation: Int
    }

    let home: AppHome
    let model: BarModel
    let runner: RunnerClient
    let services: HostServices
    private let sampler = SystemSampler()
    private var loaded: [String: Loaded] = [:]
    private var blocked: [String: Date] = [:]
    private var approvals: [String: Approval]
    private var stamps: [URL: Date?] = [:]
    private var generation = 0
    private var trialCount = 0
    private var watcher: Timer?
    private var dataTimer: Timer?
    private var panelTimer: Timer?
    private var libraryCache: [String: (stamp: Date, description: ModuleDescription)] = [:]
    var onSettingsChanged: () -> Void = {}

    init(home: AppHome, model: BarModel, runner: RunnerClient, services: HostServices) {
        self.home = home
        self.model = model
        self.runner = runner
        self.services = services
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.renderChip(key) }
        }
        services.onAttention = { [weak self] key, isRaised in
            guard let self, let index = self.model.slots.firstIndex(where: { $0.id == key && $0.kind == .module }),
                  self.model.slots[index].isRaised != isRaised
            else { return }
            self.model.slots[index].isRaised = isRaised
        }
        model.manifestFor = { [weak self] id in self?.loaded[id]?.description?.manifest }
    }

    static func symbolExists(_ name: String) -> Bool {
        SymbolNames.exists(name)
    }

    func start(watching: Bool = true) {
        runner.start()
        runner.setData(sampler.snapshot())
        sync()
        dataTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushData() }
        }
        guard watching else { return }
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// For one-off runs that load no modules: start the helper and give it one full reading.
    func primeData() {
        runner.start()
        sampler.needs = SystemSampler.Needs(sources: ["host.network host.disk host.processes host.audio host.bluetooth"])
        runner.setData(sampler.snapshot())
    }

    private func pushData() {
        sampler.snapshot { [weak self] data in self?.runner.setData(data) }
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
            if layout != model.layout { model.layout = layout }
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
        func add(_ files: [URL], _ origin: ModuleListing.Origin, only: Set<String>? = nil) {
            for file in files {
                let key = file.deletingPathExtension().lastPathComponent
                if let only, !only.contains(key) { continue }
                guard let stamp = Resources.bundled(file)?.modified ?? AppHome.modificationDate(of: file) else { continue }
                sources[key] = Source(key: key, file: file, origin: origin, stamp: stamp)
            }
        }
        add(Resources.files(in: "Modules", extension: "js"), .builtIn)
        add(Resources.files(in: "Library", extension: "js"), .library, only: Set(model.settings.enabledLibrary))
        add(userModuleFiles(), .user)
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
        loaded[source.key] = Loaded(source: source, text: text, generation: current)
        publish(source.key)
        updateNeeds()
        Task {
            do {
                let description = try await runner.load(key: source.key, source: text, storage: .object(services.storage(for: source.key)))
                guard loaded[source.key]?.generation == current else { return }
                guard description.manifest.id == source.key else {
                    throw ModuleFailure("meta.id is '\(description.manifest.id)' but the file is named \(source.key).js; they must match")
                }
                loaded[source.key]?.description = description
                let isApproved = source.origin != .user || description.manifest.permissions.isEmpty
                    || approvals[source.key]?.covers(description.manifest) == true
                loaded[source.key]?.needsApproval = !isApproved
                services.grants[source.key] = HostServices.Grant(manifest: description.manifest)
                publish(source.key)
                if isApproved { schedule(source.key) }
            } catch {
                guard loaded[source.key]?.generation == current else { return }
                loaded[source.key]?.failure = ModuleFailure.describe(error)
                publish(source.key)
            }
        }
    }

    private func unload(_ key: String) {
        guard let entry = loaded.removeValue(forKey: key) else { return }
        entry.timer?.invalidate()
        runner.unload(key: key)
        services.grants[key] = nil
        model.slots.removeAll { $0.id == key && $0.kind == .module }
        if model.panel?.slotID == key, model.panel?.content == .module { closePanel() }
        updateNeeds()
    }

    private func updateNeeds() {
        sampler.needs = SystemSampler.Needs(sources: loaded.values.map(\.text))
    }

    private func schedule(_ key: String) {
        guard let manifest = loaded[key]?.description?.manifest else { return }
        loaded[key]?.timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: manifest.refreshSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderChip(key) }
        }
        timer.tolerance = min(manifest.refreshSeconds / 10, 5)
        loaded[key]?.timer = timer
        renderChip(key)
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

    private func publish(_ key: String, chip: ViewNode? = nil) {
        guard let entry = loaded[key] else { return }
        let previous = model.slot(key)
        var slot = Slot(id: key, title: entry.description?.manifest.title ?? key)
        if let manifest = entry.description?.manifest {
            slot.icon = Self.symbolExists(manifest.icon) ? manifest.icon : "puzzlepiece.extension"
            slot.isPinned = manifest.pinned
            slot.order = manifest.order
            slot.panelWidth = manifest.panelWidth
            slot.permissions = manifest.permissions
        } else {
            slot.order = 999
        }
        slot.hasPanel = entry.description?.hasPanel ?? false
        slot.failure = entry.failure
        slot.needsApproval = entry.needsApproval
        slot.isUserModule = entry.source.origin == .user
        slot.chip = chip ?? previous?.chip
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
            return (parsed.node, parsed.node == nil ? "\(surface == .chip ? "render" : "panel")() returned nothing" : nil)
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

    // MARK: Panels

    func openPanel(_ key: String) {
        model.panel = PanelState(slotID: key, content: .module, isLoading: true)
        sampler.isPanelOpen = true
        sampler.refreshProcesses { [weak self] in
            self?.pushData()
            self?.renderPanel(key)
        }
        renderPanel(key)
        panelTimer?.invalidate()
        let interval = loaded[key]?.description?.manifest.panelRefreshSeconds ?? 5
        panelTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderPanel(key) }
        }
    }

    func closePanel() {
        panelTimer?.invalidate()
        panelTimer = nil
        sampler.isPanelOpen = false
        if model.panel != nil { model.panel = nil }
    }

    func renderPanel(_ key: String) {
        guard model.panel?.slotID == key, model.panel?.content == .module, let entry = loaded[key] else { return }
        guard entry.description?.hasPanel == true, !entry.needsApproval, entry.failure == nil || entry.description != nil else {
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
        renderChip(key)
        renderPanel(key)
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
        do {
            let chip = ViewNode.parse(try await runner.render(key: key, surface: .chip))
            trial.chip = chip.node
            trial.problems += chip.problems
            if trial.description?.hasPanel == true {
                let panel = ViewNode.parse(try await runner.render(key: key, surface: .panel))
                trial.panel = panel.node
                trial.problems += panel.problems
            }
        } catch {
            trial.failure = "it threw while rendering: \(ModuleFailure.describe(error)). Catch expected failures and return a calm fallback view"
            return trial
        }
        trial.problems += DesignLint.check(
            chip: trial.chip, panel: trial.panel, manifest: trial.description!.manifest,
            actions: trial.description!.actions, symbolExists: Self.symbolExists
        )
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
        sync()
    }

    func approve(_ id: String) {
        guard let manifest = loaded[id]?.description?.manifest else { return }
        approvals[id] = Approval(permissions: manifest.permissions)
        home.save(approvals, to: home.approvalsFile)
        stamps[home.approvalsFile] = AppHome.modificationDate(of: home.approvalsFile)
        loaded[id]?.needsApproval = false
        publish(id)
        schedule(id)
        if model.panel?.slotID == id { openPanel(id) }
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: home.moduleFile(id: id))
        try? FileManager.default.removeItem(at: home.promptFile(id: id))
        services.forgetStorage(for: id)
        approvals[id] = nil
        home.save(approvals, to: home.approvalsFile)
        var layout = model.layout
        layout.remove(id)
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
        sync()
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
                needsApproval: entry.needsApproval, file: entry.source.file
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
                permissions: description.manifest.permissions, failure: nil, needsApproval: false, file: file
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
