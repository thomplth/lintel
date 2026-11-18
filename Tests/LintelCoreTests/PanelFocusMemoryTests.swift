import Testing
@testable import LintelCore

@Suite struct PanelFocus {
    @Test func aPanelOpenedWithThePointerTakesNoFocus() {
        let memory = PanelFocusMemory()
        #expect(!memory.claims("toggle", in: "wifi", isContent: true))
    }

    @Test func aPanelOpenedFromTheKeyboardFocusesItsFirstContentControl() {
        let memory = PanelFocusMemory()
        memory.arm("wifi")
        #expect(!memory.claims("header.settings", in: "wifi", isContent: false))
        #expect(memory.claims("toggle", in: "wifi", isContent: true))
        #expect(!memory.claims("slider", in: "wifi", isContent: true))
    }

    @Test func reopeningAPanelFocusesTheControlLastUsedInIt() {
        let memory = PanelFocusMemory()
        memory.focused("slider", in: "wifi")
        memory.arm("wifi")
        #expect(memory.claims("toggle", in: "wifi", isContent: true))
        #expect(memory.claims("slider", in: "wifi", isContent: true))
        #expect(!memory.claims("slider", in: "wifi", isContent: true))
    }

    @Test func eachModuleRemembersItsOwnControl() {
        let memory = PanelFocusMemory()
        memory.focused("slider", in: "wifi")
        memory.focused("refresh", in: "weather")
        memory.arm("weather")
        #expect(!memory.claims("slider", in: "weather", isContent: false))
        #expect(memory.claims("refresh", in: "weather", isContent: false))
    }

    @Test func anotherModulesPanelTakesNoFocusMeantForThisOne() {
        let memory = PanelFocusMemory()
        memory.arm("wifi")
        #expect(!memory.claims("toggle", in: "weather", isContent: true))
    }

    @Test func closingThePanelStopsItsControlsTakingFocus() {
        let memory = PanelFocusMemory()
        memory.focused("slider", in: "wifi")
        memory.arm("wifi")
        memory.disarm()
        #expect(!memory.claims("slider", in: "wifi", isContent: true))
    }
}
