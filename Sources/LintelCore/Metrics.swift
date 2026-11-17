import Foundation

/// Counts and durations gathered over one window of time.
public struct MetricsLedger: Sendable {
    private struct Samples: Sendable {
        var count = 0
        var total = 0.0
        var max = 0.0
        var recent: [Double] = []
        var next = 0

        mutating func add(_ seconds: Double, keeping limit: Int) {
            count += 1
            total += seconds
            max = Swift.max(max, seconds)
            if recent.count < limit {
                recent.append(seconds)
            } else {
                recent[next] = seconds
                next = (next + 1) % limit
            }
        }
    }

    private let samplesKept: Int
    private var counts: [String: Int] = [:]
    private var timings: [String: Samples] = [:]

    public init(samplesKept: Int = 2048) {
        self.samplesKept = Swift.max(samplesKept, 1)
    }

    public mutating func count(_ name: String, by amount: Int = 1) {
        counts[name, default: 0] += amount
    }

    public mutating func record(_ name: String, seconds: Double) {
        timings[name, default: Samples()].add(seconds, keeping: samplesKept)
    }

    public mutating func reset() {
        counts = [:]
        timings = [:]
    }

    public func summary(over interval: TimeInterval) -> MetricsSummary {
        MetricsSummary(
            seconds: interval,
            counts: counts.mapValues { MetricsSummary.Count(total: $0, perSecond: interval > 0 ? Double($0) / interval : 0) },
            timings: timings.mapValues { samples in
                let sorted = samples.recent.sorted()
                return MetricsSummary.Timing(
                    count: samples.count, p50: Self.milliseconds(Self.percentile(0.5, of: sorted)),
                    p95: Self.milliseconds(Self.percentile(0.95, of: sorted)), max: Self.milliseconds(samples.max),
                    total: Self.milliseconds(samples.total)
                )
            }
        )
    }

    /// Nearest rank: the smallest sample at or above the given share of all samples.
    private static func percentile(_ share: Double, of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((share * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func milliseconds(_ seconds: Double) -> Double {
        (seconds * 1_000_000).rounded() / 1000
    }
}

public struct MetricsSummary: Codable, Equatable, Sendable {
    public struct Count: Codable, Equatable, Sendable {
        public var total: Int
        public var perSecond: Double
    }

    /// Durations in milliseconds.
    public struct Timing: Codable, Equatable, Sendable {
        public var count: Int
        public var p50: Double
        public var p95: Double
        public var max: Double
        public var total: Double
    }

    public var seconds: Double
    public var counts: [String: Count]
    public var timings: [String: Timing]
}

/// One line of the metrics log: a window's summary, the process's cost over it, and the build that produced both.
public struct MetricsRecord: Codable, Equatable, Sendable {
    public struct Process: Codable, Equatable, Sendable {
        /// Percent of one core, averaged over the window.
        public var appCPU: Double
        public var runnerCPU: Double
        public var memoryMB: Double

        public init(appCPU: Double, runnerCPU: Double, memoryMB: Double) {
            self.appCPU = appCPU
            self.runnerCPU = runnerCPU
            self.memoryMB = memoryMB
        }
    }

    public var time: Date
    public var build: String
    public var process: Process
    public var summary: MetricsSummary

    public init(time: Date, build: String, process: Process, summary: MetricsSummary) {
        self.time = time
        self.build = build
        self.process = process
        self.summary = summary
    }

    public func line() throws -> String {
        String(decoding: try JSONEncoder.metrics.encode(self), as: UTF8.self)
    }
}

extension JSONEncoder {
    public static var metrics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var metrics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
