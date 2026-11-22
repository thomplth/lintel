import Foundation

/// Pure scheduling policy for deciding when a loaded module should run periodic surface renders.
public enum ModuleRenderPolicy {
    public struct Target: Equatable, Sendable {
        public var isHiddenInLayout: Bool
        public var isWidget: Bool
        public var isVisibleWhileIdle: Bool
        public var usesAttention: Bool
        public var isBarActive: Bool
        public var isBarHidden: Bool

        public init(
            isHiddenInLayout: Bool,
            isWidget: Bool,
            isVisibleWhileIdle: Bool,
            usesAttention: Bool,
            isBarActive: Bool,
            isBarHidden: Bool
        ) {
            self.isHiddenInLayout = isHiddenInLayout
            self.isWidget = isWidget
            self.isVisibleWhileIdle = isVisibleWhileIdle
            self.usesAttention = usesAttention
            self.isBarActive = isBarActive
            self.isBarHidden = isBarHidden
        }
    }

    /// True when the module should keep its periodic render timer running.
    /// Hidden modules never appear in the bar (even with attention); unpinned chips that never call
    /// `host.attention(...)` pause while the bar is closed and refresh immediately when the bar opens.
    public static func shouldRenderPeriodically(_ target: Target) -> Bool {
        guard !target.isHiddenInLayout, !target.isBarHidden else { return false }
        if target.isWidget { return true }
        return target.isBarActive || target.isVisibleWhileIdle || target.usesAttention
    }

    /// Static check for whether a module's JavaScript source invokes `host.attention(...)`.
    public static func usesAttention(source: String) -> Bool {
        source.contains("host.attention(")
    }
}

/// Demand-driven subsystem requirements for `SystemSampler`, derived only from actively rendering modules.
public struct SamplerDemand: Equatable, Sendable {
    public struct ActiveModule: Equatable, Sendable {
        public var source: String
        public var refreshSeconds: TimeInterval
        public var hasExpandedSurface: Bool

        public init(source: String, refreshSeconds: TimeInterval, hasExpandedSurface: Bool) {
            self.source = source
            self.refreshSeconds = refreshSeconds
            self.hasExpandedSurface = hasExpandedSurface
        }
    }

    public var systemMetrics = false
    public var battery = false
    public var network = false
    public var disk = false
    public var audio = false
    public var bluetooth = false
    public var processes = false
    public var recommendedInterval: TimeInterval?

    public init(
        systemMetrics: Bool = false,
        battery: Bool = false,
        network: Bool = false,
        disk: Bool = false,
        audio: Bool = false,
        bluetooth: Bool = false,
        processes: Bool = false,
        recommendedInterval: TimeInterval? = nil
    ) {
        self.systemMetrics = systemMetrics
        self.battery = battery
        self.network = network
        self.disk = disk
        self.audio = audio
        self.bluetooth = bluetooth
        self.processes = processes
        self.recommendedInterval = recommendedInterval
    }

    public static let all = SamplerDemand(
        systemMetrics: true,
        battery: true,
        network: true,
        disk: true,
        audio: true,
        bluetooth: true,
        processes: true,
        recommendedInterval: 1
    )

    public var isEmpty: Bool {
        !systemMetrics && !battery && !network && !disk && !audio && !bluetooth && !processes
    }

    public var needsFastSampling: Bool {
        systemMetrics || network || disk || audio || processes
    }

    public static func resolve(modules: [ActiveModule]) -> SamplerDemand {
        var demand = SamplerDemand()
        var minFastRefresh: TimeInterval?

        for module in modules {
            let source = module.source
            let system = systemAccess(in: source)
            let usesNetwork = source.contains("host.network")
            let usesDisk = source.contains("host.disk")
            let usesAudio = source.contains("host.audio")
            let usesBluetooth = source.contains("host.bluetooth")
            let usesProcesses = module.hasExpandedSurface && source.contains("host.processes")

            if system.metrics { demand.systemMetrics = true }
            if system.battery { demand.battery = true }
            if usesNetwork { demand.network = true }
            if usesDisk { demand.disk = true }
            if usesAudio { demand.audio = true }
            if usesBluetooth { demand.bluetooth = true }
            if usesProcesses { demand.processes = true }

            if system.metrics || usesNetwork || usesDisk || usesAudio || usesProcesses {
                let candidate = max(module.refreshSeconds, 1)
                minFastRefresh = minFastRefresh.map { min($0, candidate) } ?? candidate
            }
        }

        if demand.isEmpty {
            demand.recommendedInterval = nil
        } else if let minFastRefresh {
            demand.recommendedInterval = min(max(minFastRefresh, 1), 2)
        } else {
            demand.recommendedInterval = 15
        }

        return demand
    }

    /// Distinguishes modules that only read `host.system().battery` (e.g. Battery) from modules
    /// that read CPU/memory/GPU metrics from `host.system()`.
    private static func systemAccess(in source: String) -> (metrics: Bool, battery: Bool) {
        let needle = "host.system"
        var searchStart = source.startIndex
        var foundAny = false
        var needsFullMetrics = false

        while let range = source.range(of: needle, range: searchStart..<source.endIndex) {
            foundAny = true
            let after = source[range.upperBound...]
            if !after.hasPrefix("().battery") {
                needsFullMetrics = true
                break
            }
            searchStart = range.upperBound
        }

        guard foundAny else { return (false, false) }
        return (metrics: needsFullMetrics, battery: true)
    }
}

/// Cadence for `BarWindowController`'s pointer and housekeeping timer.
public enum PointerPollingMode: Equatable, Sendable {
    case fast
    case idle

    public var interval: TimeInterval {
        switch self {
        case .fast: 0.1
        case .idle: 3.0
        }
    }

    public var tolerance: TimeInterval {
        switch self {
        case .fast: 0.02
        case .idle: 0.5
        }
    }

    public static func resolve(
        isActivationBusy: Bool,
        hasTemporaryExpandedWidget: Bool,
        hasSteppedAside: Bool,
        isPointerInHotZone: Bool,
        isDraggingOrResizing: Bool
    ) -> PointerPollingMode {
        if isActivationBusy || hasTemporaryExpandedWidget || hasSteppedAside || isPointerInHotZone || isDraggingOrResizing {
            return .fast
        }
        return .idle
    }
}
