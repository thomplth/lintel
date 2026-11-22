import Foundation

/// A lightweight projection of a module listing used to decide which modules appear in the main window's sidebar.
public struct SidebarModuleEntry: Equatable, Sendable {
    public let id: String
    public let isEnabled: Bool
    public let isUser: Bool
    public let isHidden: Bool
    public let needsAttention: Bool

    public init(id: String, isEnabled: Bool, isUser: Bool, isHidden: Bool = false, needsAttention: Bool = false) {
        self.id = id
        self.isEnabled = isEnabled
        self.isUser = isUser
        self.isHidden = isHidden
        self.needsAttention = needsAttention
    }
}

/// Every top-level destination in Lintel's unified main window.
public enum MainWindowSection: Hashable, Sendable {
    case welcome
    case dashboard
    case modules
    case barLayout
    case module(String)
    case general
    case appearance
    case keyboard
    case assistant
    case browser

    public static let workspaceSections: [MainWindowSection] = [
        .dashboard, .modules, .barLayout,
    ]

    public static let settingsSections: [MainWindowSection] = [
        .general, .appearance, .keyboard, .assistant, .browser,
    ]

    public var moduleID: String? {
        if case .module(let id) = self { return id }
        return nil
    }

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .dashboard: "Dashboard"
        case .modules: "Modules"
        case .barLayout: "Bar Layout"
        case .module(let id): id
        case .general: "General"
        case .appearance: "Appearance"
        case .keyboard: "Keyboard"
        case .assistant: "Assistant"
        case .browser: "Browser & Secrets"
        }
    }

    public var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .dashboard: "square.grid.2x2"
        case .modules: "puzzlepiece.extension"
        case .barLayout: "rectangle.3.group"
        case .module: "puzzlepiece.extension"
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .keyboard: "keyboard"
        case .assistant: "sparkles"
        case .browser: "safari"
        }
    }

    public var isSettingsSection: Bool {
        switch self {
        case .welcome, .general, .appearance, .keyboard, .assistant, .browser:
            true
        case .dashboard, .modules, .barLayout, .module:
            false
        }
    }

    /// Only scan system menu bar items while viewing Bar Layout.
    public var wantsMenuBarListing: Bool {
        self == .barLayout
    }

    /// Only run the periodic live-preview/status tick on live workspace views.
    public var wantsLivePreviewTimer: Bool {
        switch self {
        case .dashboard, .module:
            true
        default:
            false
        }
    }

    /// Keep onboarding uncluttered by collapsing the assistant inspector by default during Welcome.
    public var showsAssistantByDefault: Bool {
        self != .welcome
    }

    public static func shouldShowWelcomeInSidebar(hasOnboarded: Bool, selection: MainWindowSection) -> Bool {
        !hasOnboarded || selection == .welcome
    }

    /// Sidebar lists user modules, enabled modules shown in the bar, modules needing attention, plus any module currently inspected.
    public static func sidebarModuleIDs(from entries: [SidebarModuleEntry], selection: MainWindowSection) -> [String] {
        let selectedID = selection.moduleID
        return entries.compactMap { entry in
            if entry.isUser || (entry.isEnabled && !entry.isHidden) || entry.needsAttention || entry.id == selectedID {
                return entry.id
            }
            return nil
        }
    }

    /// Maps both legacy Settings/Studio tab names and new unified route names to a section.
    public static func fromRoute(_ raw: String) -> MainWindowSection? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("module:") {
            let id = String(trimmed.dropFirst("module:".count))
            return id.isEmpty ? nil : .module(id)
        }
        switch trimmed.lowercased() {
        case "welcome": return .welcome
        case "dashboard", "overview", "studio": return .dashboard
        case "modules": return .modules
        case "items", "bar", "bar-layout", "barlayout", "layout": return .barLayout
        case "general": return .general
        case "appearance", "theme": return .appearance
        case "keyboard", "shortcuts": return .keyboard
        case "assistant", "chat": return .assistant
        case "browser", "secrets": return .browser
        default: return nil
        }
    }
}

/// Sub-tabs inside a module's inspector pane.
public enum ModuleInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case overview, logs, code

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .logs: "Logs"
        case .code: "Code"
        }
    }

    public static func fromRoute(_ raw: String) -> ModuleInspectorTab? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "overview", "configure", "config", "settings": .overview
        case "logs": .logs
        case "code": .code
        default: nil
        }
    }
}
