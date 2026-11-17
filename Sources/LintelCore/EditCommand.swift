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
        let application = NSMenu(title: "Lintel")
        application.addItem(NSMenuItem(title: "Settings…", action: NSSelectorFromString("showSettings:"), keyEquivalent: ","))
        application.addItem(.separator())
        application.addItem(NSMenuItem(title: "Quit Lintel", action: NSSelectorFromString("terminate:"), keyEquivalent: "q"))
        let applicationHolder = NSMenuItem(title: "Lintel", action: nil, keyEquivalent: "")
        applicationHolder.submenu = application
        main.addItem(applicationHolder)
        main.addItem(holder)
        return main
    }
}
