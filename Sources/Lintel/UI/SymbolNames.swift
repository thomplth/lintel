import AppKit
import os

/// Whether SF Symbols has a symbol by a name, remembered per name: every redraw of an icon asks, and each answer
/// otherwise loads the symbol's image.
enum SymbolNames {
    private static let known = OSAllocatedUnfairLock(initialState: [String: Bool]())

    static func exists(_ name: String) -> Bool {
        if let answer = known.withLock({ $0[name] }) { return answer }
        let answer = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        known.withLock { $0[name] = answer }
        return answer
    }
}
