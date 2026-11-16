import AppKit
import Testing
@testable import LintelCore

@Suite struct EditCommandsMenu {
    @Test func everyStandardTextShortcutIsOfferedWithItsResponderAction() {
        let commands = EditCommand.standard.map { "\($0.action) \($0.modifiers.rawValue) \($0.key)" }
        let command = NSEvent.ModifierFlags.command
        #expect(commands == [
            "undo: \(command.rawValue) z",
            "redo: \(command.union(.shift).rawValue) z",
            "cut: \(command.rawValue) x",
            "copy: \(command.rawValue) c",
            "paste: \(command.rawValue) v",
            "pasteAsPlainText: \(command.union([.shift, .option]).rawValue) v",
            "selectAll: \(command.rawValue) a",
        ])
    }

    @MainActor @Test func theEditMenuHoldsOneItemPerCommandUnderAnEditTitle() {
        let menu = EditCommand.makeMainMenu()
        let edit = menu.items.first { $0.submenu?.title == "Edit" }?.submenu
        #expect(edit?.items.filter { !$0.isSeparatorItem }.map { $0.action.map(NSStringFromSelector) } ==
            EditCommand.standard.map(\.action))
    }
}
