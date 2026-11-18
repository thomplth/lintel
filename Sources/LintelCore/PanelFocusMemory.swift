/// Which control takes focus as a panel opened from the keyboard appears: the one last used in that module's panel,
/// and until it shows up, the first control of the panel's content.
public final class PanelFocusMemory {
    private var lastFocused: [String: String] = [:]
    private var armedModule: String?
    private var hasFocusedFirst = false

    public init() {}

    public func arm(_ module: String) {
        armedModule = module
        hasFocusedFirst = false
    }

    public func disarm() {
        armedModule = nil
    }

    public func focused(_ control: String, in module: String) {
        lastFocused[module] = control
    }

    /// `isContent` is false for the panel's header buttons, which are never the first control focused.
    public func claims(_ control: String, in module: String, isContent: Bool) -> Bool {
        guard armedModule == module else { return false }
        if lastFocused[module] == control {
            armedModule = nil
            return true
        }
        guard isContent, !hasFocusedFirst else { return false }
        hasFocusedFirst = true
        if lastFocused[module] == nil { armedModule = nil }
        return true
    }
}
