import AppKit
import Testing
@testable import LintelCore

@MainActor @Suite struct WindowCommandsMenu {
    func shortcuts(in title: String) -> [String] {
        let menu = EditCommand.makeMainMenu().items.first { $0.submenu?.title == title }?.submenu
        return (menu?.items ?? []).filter { !$0.isSeparatorItem }.map { item in
            "\(item.action.map(NSStringFromSelector) ?? "-") \(item.keyEquivalentModifierMask.rawValue) \(item.keyEquivalent)"
        }
    }

    @Test func theWindowMenuOffersTheStandardWindowCommands() {
        let command = NSEvent.ModifierFlags.command
        #expect(shortcuts(in: "Window") == [
            "performClose: \(command.rawValue) w",
            "performMiniaturize: \(command.rawValue) m",
            "performZoom: \(command.rawValue) ",
            "toggleFullScreen: \(command.union(.control).rawValue) f",
            "arrangeInFront: \(command.rawValue) ",
        ])
    }

    @Test func theWindowMenuIsTheOneAppKitListsOpenWindowsIn() {
        let menu = EditCommand.makeMainMenu()
        #expect(EditCommand.windowsMenu(in: menu)?.title == "Window")
    }

    @Test func theLintelMenuOffersSettingsHidingAndQuitting() {
        let command = NSEvent.ModifierFlags.command
        #expect(shortcuts(in: "Lintel") == [
            "showSettings: \(command.rawValue) ,",
            "hide: \(command.rawValue) h",
            "hideOtherApplications: \(command.union(.option).rawValue) h",
            "unhideAllApplications: \(command.rawValue) ",
            "terminate: \(command.rawValue) q",
        ])
    }
}
