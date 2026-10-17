import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The one "within range" rule behind Home's HEALTH MONITOR card, the Health tab and the Health Monitor
/// screen: the range around the same 30 values as the 30-day normal, a verdict only from 14 nights, blood oxygen
/// by its own floor, and a reading that is not from the latest night shown but not counted.
final class HealthMonitorRuleTests: XCTestCase {

    // MARK: Interval

    /// The 97.5% points of Student's t from the table (df 13, 29), which the prediction interval uses.
    func testTQuantileMatchesTheTable() {
        XCTAssertEqual(HealthMonitorRule.tQuantile975(df: 13), 2.160, accuracy: 0.003)
        XCTAssertEqual(HealthMonitorRule.tQuantile975(df: 29), 2.045, accuracy: 0.002)
        XCTAssertEqual(HealthMonitorRule.tQuantile975(df: 9), 2.262, accuracy: 0.01)
        XCTAssertEqual(HealthMonitorRule.tQuantile975(df: 1_000), 1.962, accuracy: 0.001)
    }

    /// The range is mean +/- t x s x sqrt(1 + 1/n) over the last 30 values.
    func testIntervalIsThePredictionIntervalOfTheLastThirty() {
        // 40 values; only the last 30 count.
        let values = (0..<40).map { Double($0 % 2 == 0 ? 80 : 90) } + [85]
        let range = HealthMonitorRule.interval(of: Array(values.suffix(40)))!
        XCTAssertEqual(range.nights, 30)
        let last30 = Array(values.suffix(30))
        let mean = last30.reduce(0, +) / 30
        let sd = (last30.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 29).squareRoot()
        let reach = HealthMonitorRule.tQuantile975(df: 29) * sd * (1 + 1.0 / 30).squareRoot()
        XCTAssertEqual(range.mean, mean, accuracy: 1e-9)
        XCTAssertEqual(range.low, mean - reach, accuracy: 1e-9)
        XCTAssertEqual(range.high, mean + reach, accuracy: 1e-9)
    }

    func testNoRangeUnderFourteenNights() {
        XCTAssertNil(HealthMonitorRule.interval(of: Array(repeating: 50, count: 13)))
        XCTAssertNotNil(HealthMonitorRule.interval(of: (0..<14).map { Double(50 + $0 % 3) }))
    }

    /// A range that is right 19 times in 20 on data that really is normal: here a deterministic sample from a
    /// fixed generator, so the test cannot flake.
    func testCoverageIsCloseToNinetyFivePercent() {
        var state: UInt64 = 0x1234_5678_9ABC_DEF1
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        func normal() -> Double {   // Box-Muller
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        let nights = (0..<3_000).map { _ in 60 + 8 * normal() }
        var inside = 0, judged = 0
        for i in 30..<nights.count {
            guard let range = HealthMonitorRule.interval(of: Array(nights[(i - 30)..<i])) else { continue }
            judged += 1
            if nights[i] >= range.low && nights[i] <= range.high { inside += 1 }
        }
        XCTAssertEqual(Double(inside) / Double(judged), 0.95, accuracy: 0.015)
    }

    // MARK: Statuses

    private func row(_ day: String, hrv: Double? = nil, rhr: Int? = nil, resp: Double? = nil, spo2: Double? = nil,
                     skinDev: Double? = nil, skinAbs: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 90, deepMin: 80, remMin: 90, lightMin: 200,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: spo2, skinTempDevC: skinDev, respRateBpm: resp, skinTempC: skinAbs)
    }

    private func keys(_ end: String, _ count: Int) -> [String] { WhoopAge.dayKeys(endingOn: end, count: count) }

    /// 30 nights of a vital that alternates 70 / 90 around 80, then a latest night.
    private func hrvDays(latest: Double, latestDay: String = "2026-10-12") -> [DailyMetric] {
        let before = keys(latestDay, 31).dropLast()
        let prior = before.enumerated().map { i, k in row(k, hrv: i % 2 == 0 ? 70 : 90) }
        return prior + [row(latestDay, hrv: latest)]
    }

    func testWithinAndOutsideTheOwnRange() {
        let within = HealthMonitorRule.statuses(days: hrvDays(latest: 82), todayKey: "2026-10-12")
            .first { $0.vital == .hrv }!
        XCTAssertEqual(within.verdict, .within)
        XCTAssertTrue(within.counts)
        XCTAssertEqual(within.interval?.nights, 30)
        let high = HealthMonitorRule.statuses(days: hrvDays(latest: 130), todayKey: "2026-10-12").first { $0.vital == .hrv }!
        XCTAssertEqual(high.verdict, .above)
        let low = HealthMonitorRule.statuses(days: hrvDays(latest: 40), todayKey: "2026-10-12").first { $0.vital == .hrv }!
        XCTAssertEqual(low.verdict, .below)
        XCTAssertTrue(low.counts, "an out of range reading is still counted, as out of range")
    }

    /// The range's mean is the 30-day normal Home prints under the same row.
    func testRangeMeanIsHomesThirtyDayNormal() {
        let days = hrvDays(latest: 82)
        let status = HealthMonitorRule.statuses(days: days, todayKey: "2026-10-12").first { $0.vital == .hrv }!
        let normal = WhoopDayFigures.normal(days: days, excluding: "2026-10-12") { $0.avgHrv }
        XCTAssertEqual(status.interval?.mean ?? -1, normal ?? -2, accuracy: 1e-9)
    }

    /// Under 14 nights there is no verdict, only the count, and the vital is not in the tally.
    func testTooFewNightsIsLearningNotAVerdict() {
        let days = keys("2026-10-11", 9).map { row($0, rhr: 50) } + [row("2026-10-12", rhr: 80)]
        let status = HealthMonitorRule.statuses(days: days, todayKey: "2026-10-12").first { $0.vital == .restingHr }!
        XCTAssertEqual(status.verdict, .learning(nights: 9))
        XCTAssertFalse(status.counts)
        XCTAssertNil(status.interval)
    }

    /// A vital with no reading at all, or only one older than a week, is "no data".
    func testNothingRecentIsNoData() {
        let none = HealthMonitorRule.statuses(days: [row("2026-09-20", hrv: 80)], todayKey: "2026-10-12")
            .first { $0.vital == .hrv }!
        XCTAssertEqual(none.verdict, .noData)
        XCTAssertNil(none.value)
    }

    /// A reading from the night before still counts (the latest a wearer can have before the strap syncs), one from
    /// three days ago is shown with its day but is not part of the tally.
    func testOnlyTheLatestNightCounts() {
        let yesterday = HealthMonitorRule.statuses(days: hrvDays(latest: 80, latestDay: "2026-10-11"), todayKey: "2026-10-12")
            .first { $0.vital == .hrv }!
        XCTAssertTrue(yesterday.isCurrent)
        XCTAssertTrue(yesterday.counts)
        let older = HealthMonitorRule.statuses(days: hrvDays(latest: 80, latestDay: "2026-10-09"), todayKey: "2026-10-12")
            .first { $0.vital == .hrv }!
        XCTAssertFalse(older.isCurrent)
        XCTAssertFalse(older.counts)
        XCTAssertEqual(older.day, "2026-10-09")
        XCTAssertEqual(older.value, 80)
    }

    /// Blood oxygen is judged by the 95% floor, not a personal range, and a stale import is not counted. This is
    /// the case that read "5/5 within range" on 12 Oct: 95.3% from 6 Oct, imported.
    func testBloodOxygenFloorAndStaleImport() {
        let stale = HealthMonitorRule.statuses(days: [row("2026-10-06", spo2: 95.3)], todayKey: "2026-10-12")
            .first { $0.vital == .bloodOxygen }!
        XCTAssertEqual(stale.verdict, .within)
        XCTAssertFalse(stale.counts)
        XCTAssertEqual(stale.day, "2026-10-06")
        let fresh = HealthMonitorRule.statuses(days: [row("2026-10-12", spo2: 94.0)], todayKey: "2026-10-12")
            .first { $0.vital == .bloodOxygen }!
        XCTAssertEqual(fresh.verdict, .below)
        XCTAssertTrue(fresh.counts)
        XCTAssertNil(fresh.interval)
    }

    /// Runs `body` with the Yoop switch set, then puts back what was there, an absent key included.
    private func withYoop(_ on: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PuffinExperiment.whoopScoresKey)
        defaults.set(on, forKey: PuffinExperiment.whoopScoresKey)
        defer {
            if let saved { defaults.set(saved, forKey: PuffinExperiment.whoopScoresKey) }
            else { defaults.removeObject(forKey: PuffinExperiment.whoopScoresKey) }
        }
        body()
    }

    /// Yoop: once today's night is scored, a reading from the night before is an old one (shown with its date, not
    /// counted), so a vital that night did not produce no longer passes as current. Before the night is scored it
    /// still counts, and with the switch off nothing changes.
    func testYesterdaysReadingIsOldOnceTonightIsScored() {
        let before = keys("2026-10-11", 30).map { row($0, resp: 15) }
        let withTonight = before + [row("2026-10-12", hrv: 80)]
        func resp(_ days: [DailyMetric]) -> HealthMonitorRule.Status {
            HealthMonitorRule.statuses(days: days, todayKey: "2026-10-12").first { $0.vital == .respiratoryRate }!
        }
        withYoop(true) {
            XCTAssertTrue(resp(before).isCurrent, "tonight is not scored yet, so the latest is yesterday's")
            let late = resp(withTonight)
            XCTAssertEqual(late.day, "2026-10-11")
            XCTAssertFalse(late.isCurrent)
            XCTAssertFalse(late.counts)
            let nap = before + [DailyMetric(day: "2026-10-12", totalSleepMin: 60, efficiency: nil, deepMin: nil, remMin: nil,
                                           lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                                           strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil,
                                           respRateBpm: nil, skinTempC: nil)]
            XCTAssertTrue(resp(nap).isCurrent, "a nap is not tonight's night")
        }
        withYoop(false) { XCTAssertTrue(resp(withTonight).isCurrent) }
    }

    /// Yoop: blood oxygen is shown as a whole percent, so it is judged as one: 94.6 reads 95% and is not "below 95%".
    func testBloodOxygenShownWholeIsJudgedWhole() {
        func verdict(_ value: Double) -> HealthMonitorRule.Verdict {
            HealthMonitorRule.statuses(days: [row("2026-10-12", spo2: value)], todayKey: "2026-10-12")
                .first { $0.vital == .bloodOxygen }!.verdict
        }
        withYoop(true) {
            XCTAssertEqual(verdict(94.6), .within)
            XCTAssertEqual(verdict(94.4), .below)
        }
        withYoop(false) { XCTAssertEqual(verdict(94.6), .below) }
    }

    // MARK: Skin temperature

    /// A change from the usual temperature (Yoop's own nights) is judged on the longer absolute history, and the
    /// range is shown around zero.
    func testSkinChangeIsJudgedOnTheAbsoluteHistory() {
        var days = keys("2026-10-11", 30).enumerated().map { i, k in row(k, skinDev: 32 + (i % 2 == 0 ? 0.3 : -0.3)) }
        days.append(row("2026-10-12", skinDev: 0.2, skinAbs: 32.2))
        let status = HealthMonitorRule.statuses(days: days, todayKey: "2026-10-12").first { $0.vital == .skinTemperature }!
        XCTAssertTrue(status.isDeviation)
        XCTAssertEqual(status.value ?? 99, 0.2, accuracy: 1e-9)
        XCTAssertEqual(status.verdict, .within)
        XCTAssertEqual(status.interval?.mean ?? 99, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(status.interval?.high ?? 0, 0.5)
        days[days.count - 1] = row("2026-10-12", skinDev: 2.0, skinAbs: 34.0)
        let hot = HealthMonitorRule.statuses(days: days, todayKey: "2026-10-12").first { $0.vital == .skinTemperature }!
        XCTAssertEqual(hot.verdict, .above)
    }

    /// An import stores the absolute temperature in the same column; it is judged as an absolute.
    func testSkinAbsoluteImportIsJudgedAsAnAbsolute() {
        var days = keys("2026-10-11", 20).enumerated().map { i, k in row(k, skinDev: 32.2 + (i % 2 == 0 ? 0.3 : -0.3)) }
        days.append(row("2026-10-12", skinDev: 32.3))
        let status = HealthMonitorRule.statuses(days: days, todayKey: "2026-10-12").first { $0.vital == .skinTemperature }!
        XCTAssertFalse(status.isDeviation)
        XCTAssertEqual(status.value ?? 0, 32.3, accuracy: 1e-9)
        XCTAssertEqual(status.verdict, .within)
    }

    /// A night with only a change and fewer than 14 of them has no verdict yet.
    func testSkinChangeWithoutHistoryIsLearning() {
        let days = keys("2026-10-11", 4).map { row($0, skinDev: 0.1) } + [row("2026-10-12", skinDev: 0.2)]
        let status = HealthMonitorRule.statuses(days: days, todayKey: "2026-10-12").first { $0.vital == .skinTemperature }!
        XCTAssertEqual(status.verdict, .learning(nights: 4))
        XCTAssertFalse(status.counts)
    }

    // MARK: Tally

    func testSummaryCountsOnlyJudgedLatestNights() {
        let prior = keys("2026-10-11", 30).enumerated().map { i, k in
            row(k, hrv: i % 2 == 0 ? 70 : 90, rhr: i % 2 == 0 ? 48 : 52, resp: i % 2 == 0 ? 14.8 : 15.4)
        }
        let latest = row("2026-10-12", hrv: 80, rhr: 50, resp: 15.1)
        let oldSpo2 = row("2026-10-08", spo2: 96)
        let summary = HealthMonitorRule.summary(
            HealthMonitorRule.statuses(days: prior + [oldSpo2, latest], todayKey: "2026-10-12"))
        XCTAssertEqual(summary.counted, 3, "HRV, resting heart rate, respiratory rate; skin has no reading, blood oxygen is old")
        XCTAssertEqual(summary.within, 3)
        XCTAssertTrue(summary.allWithin)
        XCTAssertEqual(summary.notCounted, 1, "the old blood oxygen reading")
        XCTAssertTrue(HealthMonitorRule.summary([]).isEmpty)
    }
}
