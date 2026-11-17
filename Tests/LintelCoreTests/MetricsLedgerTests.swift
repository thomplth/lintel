import Foundation
import Testing
@testable import LintelCore

@Suite struct MetricsLedgerSummaries {
    @Test func countsReportTheirTotalAndRatePerSecond() {
        var ledger = MetricsLedger()
        ledger.count("view.chip", by: 30)
        ledger.count("view.chip", by: 10)
        let summary = ledger.summary(over: 4)
        #expect(summary.counts["view.chip"] == MetricsSummary.Count(total: 40, perSecond: 10))
    }

    @Test func timingsReportCountMedianNinetyFifthPercentileMaximumAndTotalInMilliseconds() {
        var ledger = MetricsLedger()
        for milliseconds in 1...100 { ledger.record("drag.carry", seconds: Double(milliseconds) / 1000) }
        let timing = ledger.summary(over: 1).timings["drag.carry"]
        #expect(timing?.count == 100)
        #expect(timing?.p50 == 50)
        #expect(timing?.p95 == 95)
        #expect(timing?.max == 100)
        #expect(timing?.total == 5050)
    }

    @Test func percentilesComeFromTheLatestSamplesWhileCountMaximumAndTotalCoverEverySample() {
        var ledger = MetricsLedger(samplesKept: 10)
        ledger.record("scan", seconds: 1)
        for _ in 0..<10 { ledger.record("scan", seconds: 0.002) }
        let timing = ledger.summary(over: 1).timings["scan"]
        #expect(timing?.count == 11)
        #expect(timing?.p95 == 2)
        #expect(timing?.max == 1000)
        #expect(timing?.total == 1020)
    }

    @Test func aResetLedgerStartsAnEmptyWindow() {
        var ledger = MetricsLedger()
        ledger.count("view.bar")
        ledger.record("scan", seconds: 0.01)
        ledger.reset()
        let summary = ledger.summary(over: 1)
        #expect(summary.counts.isEmpty)
        #expect(summary.timings.isEmpty)
    }

    @Test func anEmptyIntervalReportsNoRateRatherThanInfinity() {
        var ledger = MetricsLedger()
        ledger.count("view.bar")
        #expect(ledger.summary(over: 0).counts["view.bar"]?.perSecond == 0)
    }
}

@Suite struct MetricsRecordLines {
    @Test func aRecordIsOneJSONLineTaggedWithItsBuild() throws {
        var ledger = MetricsLedger()
        ledger.count("view.chip", by: 6)
        let record = MetricsRecord(
            time: Date(timeIntervalSince1970: 0), build: "abc1234", process: MetricsRecord.Process(appCPU: 12.5, runnerCPU: 1, memoryMB: 180),
            summary: ledger.summary(over: 2)
        )
        let line = try record.line()
        #expect(!line.contains("\n"))
        let decoded = try JSONDecoder.metrics.decode(MetricsRecord.self, from: Data(line.utf8))
        #expect(decoded == record)
        #expect(line.contains("\"build\":\"abc1234\""))
    }
}
