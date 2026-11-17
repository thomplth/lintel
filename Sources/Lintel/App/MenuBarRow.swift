import AppKit
import SwiftUI

/// The bar's first row, drawn inside one system menu bar item while the menu bar always shows.
@MainActor
final class MenuBarRow {
    private let item: NSStatusItem
    private let host: MenuBarRowHostingView
    var onPress: (NSEvent) -> Void = { _ in }

    init(model: BarModel) {
        item = NSStatusBar.system.statusItem(withLength: 16)
        // Keeps the place the user ⌘-drags the item to among other apps' items across launches.
        item.autosaveName = "Lintel"
        item.behavior = []
        host = MenuBarRowHostingView(rootView: BarView(model: model, host: .menuBar))
        host.sizingOptions = []
        host.onPress = { [weak self] event in self?.onPress(event) }
        item.button?.addSubview(host)
        fit(width: 16)
    }

    func fit(width: CGFloat) {
        if item.length != width { item.length = width }
        guard let button = item.button else { return }
        host.frame = CGRect(x: 0, y: 0, width: width, height: button.bounds.height)
        host.layer?.masksToBounds = true
    }

    /// The row's frame on screen; nil while macOS keeps the item off screen, behind the notch or the overflow button.
    var screenFrame: CGRect? {
        guard let window = host.window, window.occlusionState.contains(.visible) || window.isVisible else { return nil }
        return window.convertToScreen(host.convert(host.bounds, to: nil))
    }

    func setHidden(_ isHidden: Bool) {
        item.isVisible = !isHidden
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }
}

final class MenuBarRowHostingView: NSHostingView<BarView> {
    var onPress: (NSEvent) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The status bar button would track the press in a loop of its own that SwiftUI's gestures never see, and
    // draw its own highlight; BarWindowController follows the press instead.
    override func mouseDown(with event: NSEvent) {
        onPress(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
