import Foundation
import LintelCore
import Security

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int
    var label: String
}

struct AppSettings: Codable, Equatable {
    var anchor = BarAnchor.right
    var edgeInset = 0.0
    var hoverActivates = true
    var guardsTopEdge = true
    var dwell = 0.3
    var grace = 0.6
    var engine = "auto"
    var apiStyle = "anthropic"
    var apiEndpoint = "https://api.anthropic.com"
    var apiModel = "claude-opus-5-5"
    var cliModel = ""
    var disabledModules: [String] = []
    var enabledLibrary: [String] = []
    var edition = "private"
    var hasOnboarded = false
    var showsAssistant = true
    var showsInDock = true
    var adoptsPictures = true
    var toggleShortcut = Shortcut(keyCode: 11, modifiers: 0x1900, label: "⌃⌥⌘B")
    var hideShortcut = Shortcut(keyCode: 4, modifiers: 0x1900, label: "⌃⌥⌘H")

    init() {}

    init(from decoder: Decoder) throws {
        let stored = try [String: JSONValue](from: decoder)
        func value<Value: Decodable>(_ key: String, _ fallback: Value) -> Value {
            guard let raw = stored[key], let decoded = try? JSONDecoder().decode(Value.self, from: Data(raw.text.utf8)) else { return fallback }
            return decoded
        }
        let defaults = AppSettings()
        anchor = value("anchor", defaults.anchor)
        edgeInset = value("edgeInset", defaults.edgeInset)
        hoverActivates = value("hoverActivates", defaults.hoverActivates)
        guardsTopEdge = value("guardsTopEdge", defaults.guardsTopEdge)
        dwell = min(max(value("dwell", defaults.dwell), 0), 3)
        grace = min(max(value("grace", defaults.grace), 0.1), 5)
        engine = value("engine", defaults.engine)
        apiStyle = value("apiStyle", defaults.apiStyle)
        apiEndpoint = value("apiEndpoint", defaults.apiEndpoint)
        apiModel = value("apiModel", defaults.apiModel)
        cliModel = value("cliModel", defaults.cliModel)
        disabledModules = value("disabledModules", defaults.disabledModules)
        enabledLibrary = value("enabledLibrary", defaults.enabledLibrary)
        edition = value("edition", defaults.edition)
        hasOnboarded = value("hasOnboarded", defaults.hasOnboarded)
        showsAssistant = value("showsAssistant", defaults.showsAssistant)
        showsInDock = value("showsInDock", defaults.showsInDock)
        adoptsPictures = value("adoptsPictures", defaults.adoptsPictures)
        toggleShortcut = value("toggleShortcut", defaults.toggleShortcut)
        hideShortcut = value("hideShortcut", defaults.hideShortcut)
    }

    var isPrivateEdition: Bool { edition == "private" }
}

/// Where the app keeps what the user can edit: theme, layout, settings, their modules and each module's storage.
struct AppHome {
    let root: URL

    static var standard: AppHome {
        if let override = ProcessInfo.processInfo.environment["LINTEL_HOME"] {
            return AppHome(root: URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppHome(root: support.appending(path: "Lintel"))
    }

    var usesIsolatedStores: Bool { ProcessInfo.processInfo.environment["LINTEL_HOME"] != nil }

    var modulesDirectory: URL { root.appending(path: "Modules") }
    var storageDirectory: URL { root.appending(path: "Storage") }
    var promptsDirectory: URL { root.appending(path: "Prompts") }
    var themeFile: URL { root.appending(path: "theme.json") }
    var themeHistoryFile: URL { root.appending(path: "theme-history.json") }
    var layoutFile: URL { root.appending(path: "layout.json") }
    var settingsFile: URL { root.appending(path: "settings.json") }
    var approvalsFile: URL { root.appending(path: "approvals.json") }
    var chatFile: URL { root.appending(path: "chat.json") }
    var secretsFile: URL { root.appending(path: "secrets.json") }

    func prepare() {
        for directory in [root, modulesDirectory, storageDirectory, promptsDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func load<Value: Decodable>(_ type: Value.Type, from file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<Value: Encodable>(_ value: Value, to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func loadTheme() -> Theme { load(Theme.self, from: themeFile) ?? Theme() }
    func loadLayout() -> BarLayout { load(BarLayout.self, from: layoutFile) ?? BarLayout() }
    func loadSettings() -> AppSettings { load(AppSettings.self, from: settingsFile) ?? AppSettings() }
    func loadApprovals() -> [String: Approval] { load([String: Approval].self, from: approvalsFile) ?? [:] }

    /// Every theme change keeps the one before it, so any edit, by hand or by chat, is one undo away.
    func saveTheme(_ theme: Theme, rememberingPrevious: Bool = true) {
        let current = loadTheme()
        guard theme != current || !FileManager.default.fileExists(atPath: themeFile.path) else { return }
        if rememberingPrevious {
            var history = load([Theme].self, from: themeHistoryFile) ?? []
            history.append(current)
            save(Array(history.suffix(30)), to: themeHistoryFile)
        }
        save(theme, to: themeFile)
    }

    func undoTheme() -> Bool {
        var history = load([Theme].self, from: themeHistoryFile) ?? []
        guard let previous = history.popLast() else { return false }
        save(history, to: themeHistoryFile)
        save(previous, to: themeFile)
        return true
    }

    func moduleFile(id: String) -> URL { modulesDirectory.appending(path: "\(id).js") }
    func storageFile(id: String) -> URL { storageDirectory.appending(path: "\(id).json") }
    func promptFile(id: String) -> URL { promptsDirectory.appending(path: "\(id).txt") }

    func loadStorage(id: String) -> JSONValue {
        load(JSONValue.self, from: storageFile(id: id)) ?? .object([:])
    }

    static func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

enum Resources {
    static let root: URL? = {
        let name = "Lintel_Lintel.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appending(path: name),
            Bundle.main.executableURL?.deletingLastPathComponent().appending(path: name),
            Bundle.main.bundleURL.appending(path: name),
        ]
        guard let bundle = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return nil }
        let nested = bundle.appending(path: "Contents/Resources")
        return FileManager.default.fileExists(atPath: nested.path) ? nested : bundle
    }()

    // Deleting or rebuilding the bundle this process was launched from (a removed worktree's build/Lintel.app, say)
    // takes these files away mid-run; without the snapshot the module watcher then drops every built-in module.
    private static let snapshot = root.map(FileSnapshot.init(of:))

    static func files(in folder: String, extension fileExtension: String) -> [URL] {
        guard let root, let snapshot else { return [] }
        return snapshot.files(in: folder, extension: fileExtension).map { root.appending(path: $0.path) }
    }

    static func text(_ path: String) -> String? {
        snapshot?.text(at: path)
    }

    static func bundled(_ file: URL) -> FileSnapshot.File? {
        guard let root, let snapshot else { return nil }
        let rootPath = root.standardizedFileURL.path + "/"
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        return snapshot.file(at: String(filePath.dropFirst(rootPath.count)))
    }

    static func source(of file: URL) -> String? {
        bundled(file)?.text ?? (try? String(contentsOf: file, encoding: .utf8))
    }
}

/// Keys the user typed in for modules and for the API engine. They live in the Keychain and are never shown to a model.
struct SecretStore {
    let home: AppHome
    private static let service = "app.lintel.secrets"

    func get(_ name: String) -> String? {
        if home.usesIsolatedStores {
            return home.load([String: String].self, from: home.secretsFile)?[name]
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ name: String, _ value: String?) {
        if home.usesIsolatedStores {
            var all = home.load([String: String].self, from: home.secretsFile) ?? [:]
            all[name] = value
            home.save(all, to: home.secretsFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.secretsFile.path)
            return
        }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: name,
        ]
        SecItemDelete(identity as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = identity
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
        var names = Set(self.names)
        names.insert(name)
        UserDefaults.standard.set(Array(names).sorted(), forKey: "secretNames")
    }

    var names: [String] {
        if home.usesIsolatedStores {
            return (home.load([String: String].self, from: home.secretsFile) ?? [:]).keys.sorted()
        }
        return (UserDefaults.standard.stringArray(forKey: "secretNames") ?? []).filter { get($0) != nil }
    }
}
