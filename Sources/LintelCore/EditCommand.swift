import AppKit

public struct EditCommand: Sendable {
    public let title: String
    public let action: String
    public let key: String
    public let modifiers: NSEvent.ModifierFlags
    public let startsGroup: Bool

    public static let standard: [EditCommand] = [
        EditCommand(title: "Undo", action: "undo:", key: "z", modifiers: .command, startsGroup: false),
        EditCommand(title: "Redo", action: "redo:", key: "z", modifiers: [.command, .shift], startsGroup: false),
        EditCommand(title: "Cut", action: "cut:", key: "x", modifiers: .command, startsGroup: true),
        EditCommand(title: "Copy", action: "copy:", key: "c", modifiers: .command, startsGroup: false),
        EditCommand(title: "Paste", action: "paste:", key: "v", modifiers: .command, startsGroup: false),
        EditCommand(title: "Paste and Match Style", action: "pasteAsPlainText:", key: "v", modifiers: [.command, .shift, .option], startsGroup: false),
        EditCommand(title: "Select All", action: "selectAll:", key: "a", modifiers: .command, startsGroup: false),
    ]

    // An accessory app shows no menu bar, yet AppKit still routes key equivalents through the main
    // menu; without one, text fields and web views never receive ⌘C, ⌘V and friends.
    @MainActor
    public static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        for command in standard {
            if command.startsGroup { edit.addItem(.separator()) }
            let item = NSMenuItem(title: command.title, action: NSSelectorFromString(command.action), keyEquivalent: command.key)
            item.keyEquivalentModifierMask = command.modifiers
            edit.addItem(item)
        }
        let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        holder.submenu = edit
        let main = NSMenu(title: "Main")
        main.addItem(holding(menu("Lintel", [
            ("Settings…", "showSettings:", ",", .command),
            nil,
            ("Hide Lintel", "hide:", "h", .command),
            ("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
            ("Show All", "unhideAllApplications:", "", .command),
            nil,
            ("Quit Lintel", "terminate:", "q", .command),
        ])))
        main.addItem(holder)
        main.addItem(holding(menu("Window", [
            ("Close", "performClose:", "w", .command),
            ("Minimize", "performMiniaturize:", "m", .command),
            ("Zoom", "performZoom:", "", .command),
            nil,
            ("Enter Full Screen", "toggleFullScreen:", "f", [.command, .control]),
            nil,
            ("Bring All to Front", "arrangeInFront:", "", .command),
        ])))
        return main
    }

    /// The menu to hand `NSApp.windowsMenu`, so AppKit lists open windows under it and retitles Enter/Exit Full Screen.
    @MainActor
    public static func windowsMenu(in main: NSMenu) -> NSMenu? {
        main.items.first { $0.submenu?.title == "Window" }?.submenu
    }

    @MainActor
    private static func menu(_ title: String, _ entries: [(title: String, action: String, key: String, modifiers: NSEvent.ModifierFlags)?]) -> NSMenu {
        let menu = NSMenu(title: title)
        for entry in entries {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: NSSelectorFromString(entry.action), keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.modifiers
            menu.addItem(item)
        }
        return menu
    }

    @MainActor
    private static func holding(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
