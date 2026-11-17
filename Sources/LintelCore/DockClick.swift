/// What clicking Lintel's Dock icon does: the first click opens the full bar, a second one while it is open shows Settings.
public enum DockClick: Equatable, Sendable {
    case openBar
    case openSettings

    public static func response(isBarOpen: Bool) -> DockClick {
        isBarOpen ? .openSettings : .openBar
    }
}
