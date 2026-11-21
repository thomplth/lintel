import Testing
@testable import LintelCore

@Suite struct MainWindowNavigationTests {
    @Test func legacyAndNewRouteStringsMapToUnifiedSections() {
        #expect(MainWindowSection.fromRoute("welcome") == .welcome)
        #expect(MainWindowSection.fromRoute("dashboard") == .dashboard)
        #expect(MainWindowSection.fromRoute("modules") == .modules)
        #expect(MainWindowSection.fromRoute("items") == .barLayout)
        #expect(MainWindowSection.fromRoute("bar-layout") == .barLayout)
        #expect(MainWindowSection.fromRoute("barLayout") == .barLayout)
        #expect(MainWindowSection.fromRoute("general") == .general)
        #expect(MainWindowSection.fromRoute("appearance") == .appearance)
        #expect(MainWindowSection.fromRoute("keyboard") == .keyboard)
        #expect(MainWindowSection.fromRoute("assistant") == .assistant)
        #expect(MainWindowSection.fromRoute("browser") == .browser)
        #expect(MainWindowSection.fromRoute("module:system") == .module("system"))
        #expect(MainWindowSection.fromRoute("module:") == nil)
        #expect(MainWindowSection.fromRoute("unknown") == nil)
    }

    @Test func sidebarShowsWelcomeOnlyBeforeOnboardingOrWhileSelected() {
        #expect(MainWindowSection.shouldShowWelcomeInSidebar(hasOnboarded: false, selection: .dashboard))
        #expect(MainWindowSection.shouldShowWelcomeInSidebar(hasOnboarded: false, selection: .welcome))
        #expect(!MainWindowSection.shouldShowWelcomeInSidebar(hasOnboarded: true, selection: .dashboard))
        #expect(!MainWindowSection.shouldShowWelcomeInSidebar(hasOnboarded: true, selection: .general))
        #expect(MainWindowSection.shouldShowWelcomeInSidebar(hasOnboarded: true, selection: .welcome))
    }

    @Test func menuBarListingAndLiveTimersOnlyRunOnRelevantSections() {
        #expect(MainWindowSection.barLayout.wantsMenuBarListing)
        #expect(!MainWindowSection.dashboard.wantsMenuBarListing)
        #expect(!MainWindowSection.general.wantsMenuBarListing)
        #expect(!MainWindowSection.module("system").wantsMenuBarListing)

        #expect(MainWindowSection.dashboard.wantsLivePreviewTimer)
        #expect(MainWindowSection.module("system").wantsLivePreviewTimer)
        #expect(!MainWindowSection.general.wantsLivePreviewTimer)
        #expect(!MainWindowSection.appearance.wantsLivePreviewTimer)
        #expect(!MainWindowSection.barLayout.wantsLivePreviewTimer)
    }

    @Test func sidebarModulesIncludeUserVisibleAlertingAndSelectedModules() {
        let entries = [
            SidebarModuleEntry(id: "custom-off", isEnabled: false, isUser: true),
            SidebarModuleEntry(id: "system", isEnabled: true, isUser: false),
            SidebarModuleEntry(id: "bluetooth", isEnabled: true, isUser: false, isHidden: true),
            SidebarModuleEntry(id: "broken-hidden", isEnabled: true, isUser: false, isHidden: true, needsAttention: true),
            SidebarModuleEntry(id: "weather", isEnabled: false, isUser: false),
            SidebarModuleEntry(id: "timer", isEnabled: false, isUser: false),
        ]

        let defaultSidebar = MainWindowSection.sidebarModuleIDs(from: entries, selection: .dashboard)
        #expect(defaultSidebar == ["custom-off", "system", "broken-hidden"])

        let inspectingDisabled = MainWindowSection.sidebarModuleIDs(from: entries, selection: .module("weather"))
        #expect(inspectingDisabled == ["custom-off", "system", "broken-hidden", "weather"])

        let inspectingHidden = MainWindowSection.sidebarModuleIDs(from: entries, selection: .module("bluetooth"))
        #expect(inspectingHidden == ["custom-off", "system", "bluetooth", "broken-hidden"])
    }

    @Test func workspaceAndSettingsSectionsDoNotOverlapOrDuplicateModules() {
        #expect(MainWindowSection.workspaceSections == [.dashboard, .modules, .barLayout])
        #expect(MainWindowSection.settingsSections == [.general, .appearance, .keyboard, .assistant, .browser])
        let overlap = Set(MainWindowSection.workspaceSections).intersection(MainWindowSection.settingsSections)
        #expect(overlap.isEmpty)
        #expect(!MainWindowSection.settingsSections.contains(.modules))
        #expect(!MainWindowSection.settingsSections.contains(.welcome))
    }

    @Test func assistantIsCollapsedByDefaultOnlyDuringWelcome() {
        #expect(!MainWindowSection.welcome.showsAssistantByDefault)
        #expect(MainWindowSection.dashboard.showsAssistantByDefault)
        #expect(MainWindowSection.general.showsAssistantByDefault)
        #expect(MainWindowSection.module("clock").showsAssistantByDefault)
    }
}
