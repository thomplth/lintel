import Foundation
import Testing
@testable import LintelCore

@Suite struct IdlePowerPolicyTests {
    // MARK: - Module render scheduling policy

    @Test func hiddenModulesNeverRunPeriodicRenders() {
        #expect(!ModuleRenderPolicy.shouldRenderPeriodically(
            ModuleRenderPolicy.Target(
                isHiddenInLayout: true,
                isWidget: false,
                isVisibleWhileIdle: true,
                usesAttention: true,
                isBarActive: true,
                isBarHidden: false
            )
        ))
        #expect(!ModuleRenderPolicy.shouldRenderPeriodically(
            ModuleRenderPolicy.Target(
                isHiddenInLayout: true,
                isWidget: true,
                isVisibleWhileIdle: true,
                usesAttention: true,
                isBarActive: true,
                isBarHidden: false
            )
        ))
    }

    @Test func barHiddenPausesPeriodicRenders() {
        #expect(!ModuleRenderPolicy.shouldRenderPeriodically(
            ModuleRenderPolicy.Target(
                isHiddenInLayout: false,
                isWidget: false,
                isVisibleWhileIdle: true,
                usesAttention: true,
                isBarActive: false,
                isBarHidden: true
            )
        ))
        #expect(!ModuleRenderPolicy.shouldRenderPeriodically(
            ModuleRenderPolicy.Target(
                isHiddenInLayout: false,
                isWidget: true,
                isVisibleWhileIdle: true,
                usesAttention: false,
                isBarActive: false,
                isBarHidden: true
            )
        ))
    }

    @Test func unpinnedNonAttentionChipsPauseWhileBarIsIdleAndResumeWhenActive() {
        let idle = ModuleRenderPolicy.Target(
            isHiddenInLayout: false,
            isWidget: false,
            isVisibleWhileIdle: false,
            usesAttention: false,
            isBarActive: false,
            isBarHidden: false
        )
        #expect(!ModuleRenderPolicy.shouldRenderPeriodically(idle))

        var active = idle
        active.isBarActive = true
        #expect(ModuleRenderPolicy.shouldRenderPeriodically(active))
    }

    @Test func unpinnedAttentionChipsStillPollWhileBarIsIdle() {
        #expect(ModuleRenderPolicy.shouldRenderPeriodically(
            ModuleRenderPolicy.Target(
                isHiddenInLayout: false,
                isWidget: false,
                isVisibleWhileIdle: false,
                usesAttention: true,
                isBarActive: false,
                isBarHidden: false
            )
        ))
    }

    @Test func visibleIdleChipsAndDesktopWidgetsRunWhileBarIsIdle() {
        #expect(ModuleRenderPolicy.shouldRenderPeriodically(
            ModuleRenderPolicy.Target(
                isHiddenInLayout: false,
                isWidget: false,
                isVisibleWhileIdle: true,
                usesAttention: false,
                isBarActive: false,
                isBarHidden: false
            )
        ))
        #expect(ModuleRenderPolicy.shouldRenderPeriodically(
            ModuleRenderPolicy.Target(
                isHiddenInLayout: false,
                isWidget: true,
                isVisibleWhileIdle: false,
                usesAttention: false,
                isBarActive: false,
                isBarHidden: false
            )
        ))
    }

    @Test func detectsAttentionUsageInModuleSource() {
        #expect(ModuleRenderPolicy.usesAttention(source: "host.attention(true);"))
        #expect(ModuleRenderPolicy.usesAttention(source: "if (x) host.attention(false)"))
        #expect(!ModuleRenderPolicy.usesAttention(source: "segmented(MODES, cfg.attentionMode, 'setAttentionMode')"))
        #expect(!ModuleRenderPolicy.usesAttention(source: "return text(host.system().cpu)"))
    }

    // MARK: - Demand-driven system sampling policy

    @Test func emptyActiveModulesRequireNoSampling() {
        let demand = SamplerDemand.resolve(modules: [])
        #expect(demand.isEmpty)
        #expect(demand.recommendedInterval == nil)
    }

    @Test func batteryOnlyModuleDoesNotTriggerFastCPUGPUSampling() {
        let batterySource = """
        chip(host) {
          const battery = host.system().battery;
          host.attention(battery.percent <= 10);
          return text(battery.percent + '%');
        }
        """
        let demand = SamplerDemand.resolve(modules: [
            SamplerDemand.ActiveModule(source: batterySource, refreshSeconds: 30, hasExpandedSurface: false),
        ])
        #expect(!demand.systemMetrics)
        #expect(demand.battery)
        #expect(!demand.network)
        #expect(!demand.disk)
        #expect(!demand.audio)
        #expect(!demand.bluetooth)
        #expect(!demand.processes)
        #expect(demand.recommendedInterval == 15)
    }

    @Test func fullSystemModuleEnablesSystemMetricsAndOnlySamplesProcessesWhenExpanded() {
        let systemSource = """
        chip(host) {
          const s = host.system();
          return text(s.cpu);
        }
        widget(host) {
          const procs = host.processes();
          return list(procs);
        }
        """
        let chipOnly = SamplerDemand.resolve(modules: [
            SamplerDemand.ActiveModule(source: systemSource, refreshSeconds: 2, hasExpandedSurface: false),
            SamplerDemand.ActiveModule(source: "widget(host) { return text('custom'); }", refreshSeconds: 5, hasExpandedSurface: true),
        ])
        #expect(chipOnly.systemMetrics)
        #expect(chipOnly.battery)
        #expect(!chipOnly.processes)
        #expect(chipOnly.recommendedInterval == 2)

        let expanded = SamplerDemand.resolve(modules: [
            SamplerDemand.ActiveModule(source: systemSource, refreshSeconds: 2, hasExpandedSurface: true),
        ])
        #expect(expanded.systemMetrics)
        #expect(expanded.processes)
        #expect(expanded.recommendedInterval == 2)
    }

    @Test func nonSystemModulesAndUnrelatedWidgetsProduceZeroSamplerDemand() {
        let demand = SamplerDemand.resolve(modules: [
            SamplerDemand.ActiveModule(source: "chip(host) { return text(host.format.time(new Date())); }", refreshSeconds: 1, hasExpandedSurface: false),
            SamplerDemand.ActiveModule(source: "widget(host) { return text('usage'); }", refreshSeconds: 5, hasExpandedSurface: true),
        ])
        #expect(demand.isEmpty)
        #expect(demand.recommendedInterval == nil)
    }

    @Test func fastSubsystemIntervalClampsBetweenOneAndTwoSeconds() {
        let fast = SamplerDemand.resolve(modules: [
            SamplerDemand.ActiveModule(source: "chip(host) { return text(host.audio().volume); }", refreshSeconds: 1, hasExpandedSurface: false),
        ])
        #expect(fast.audio)
        #expect(fast.recommendedInterval == 1)

        let moderate = SamplerDemand.resolve(modules: [
            SamplerDemand.ActiveModule(source: "chip(host) { return text(host.disk().readRate); }", refreshSeconds: 5, hasExpandedSurface: false),
        ])
        #expect(moderate.disk)
        #expect(moderate.recommendedInterval == 2)
    }

    // MARK: - Pointer polling cadence policy

    @Test func pointerPollingDropsToIdleWhenNoInteractionIsInFlight() {
        let mode = PointerPollingMode.resolve(
            isActivationBusy: false,
            hasTemporaryExpandedWidget: false,
            hasSteppedAside: false,
            isPointerInHotZone: false,
            isDraggingOrResizing: false
        )
        #expect(mode == .idle)
    }

    @Test func pointerPollingStaysFastDuringHoverDwellActiveOrTopEdge() {
        #expect(PointerPollingMode.resolve(
            isActivationBusy: true,
            hasTemporaryExpandedWidget: false,
            hasSteppedAside: false,
            isPointerInHotZone: false,
            isDraggingOrResizing: false
        ) == .fast)

        #expect(PointerPollingMode.resolve(
            isActivationBusy: false,
            hasTemporaryExpandedWidget: false,
            hasSteppedAside: false,
            isPointerInHotZone: true,
            isDraggingOrResizing: false
        ) == .fast)

        #expect(PointerPollingMode.resolve(
            isActivationBusy: false,
            hasTemporaryExpandedWidget: true,
            hasSteppedAside: false,
            isPointerInHotZone: false,
            isDraggingOrResizing: false
        ) == .fast)

        #expect(PointerPollingMode.resolve(
            isActivationBusy: false,
            hasTemporaryExpandedWidget: false,
            hasSteppedAside: true,
            isPointerInHotZone: false,
            isDraggingOrResizing: false
        ) == .fast)

        #expect(PointerPollingMode.resolve(
            isActivationBusy: false,
            hasTemporaryExpandedWidget: false,
            hasSteppedAside: false,
            isPointerInHotZone: false,
            isDraggingOrResizing: true
        ) == .fast)
    }
}
