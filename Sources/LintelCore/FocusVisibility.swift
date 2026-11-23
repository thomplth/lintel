/// Shows the focus ring only while the keyboard is driving focus, like the web's `:focus-visible`: a click focuses a
/// control without ringing it, and the next Tab or arrow press brings the ring back.
public struct FocusVisibility: Equatable, Sendable {
    public enum Input: Equatable, Sendable {
        case keyboardNavigation
        case otherKey
        case pointer

        private static let navigationKeyCodes: Set<UInt16> = [48, 123, 124, 125, 126, 49, 36, 76]

        public init(keyCode: UInt16) {
            self = Self.navigationKeyCodes.contains(keyCode) ? .keyboardNavigation : .otherKey
        }
    }

    public private(set) var showsRing = false

    public init() {}

    public mutating func record(_ input: Input) {
        switch input {
        case .keyboardNavigation: showsRing = true
        case .pointer: showsRing = false
        case .otherKey: break
        }
    }
}
