/// What clicking Lintel's Dock icon does: brings an open main window forward,
/// otherwise the first click opens the full bar and a second one while it is open opens the main window.
public enum DockClick: Equatable, Sendable {
    case openBar
    case openWindow
    case focusWindow

    public static func response(isBarOpen: Bool, hasMainWindow: Bool = false) -> DockClick {
        if hasMainWindow { return .focusWindow }
        return isBarOpen ? .openWindow : .openBar
    }
}
