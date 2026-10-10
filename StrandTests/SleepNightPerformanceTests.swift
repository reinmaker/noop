import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The Sleep screen's Rest hero must state the sleep performance Home shows for a night: the stored
/// `sleep_performance` series Home reads wins, and the screen's own figure fills in only when that series
/// has nothing for the night.
final class SleepNightPerformanceTests: XCTestCase {

    /// Unix seconds for a local wall-clock time.
    private func at(_ day: String, _ hour: Int, _ minute: Int) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        let midnight = f.date(from: day)!
        return Int(midnight.timeIntervalSince1970) + hour * 3_600 + minute * 60
    }

    private func day(_ key: String, asleep: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: asleep, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
    }

    func testStoredSeriesWinsOverTheScreensOwnFigure() {
        let wake = at("2026-10-09", 7, 30)
        XCTAssertEqual(SleepModel.nightPerformance(wakeTs: wake, stored: ["2026-10-09": 81],
                                                   byDay: ["2026-10-09": 74], days: []), 81)
    }

    func testFallsBackOnlyWhenTheSeriesHasNoValue() {
        let wake = at("2026-10-09", 7, 30)
        XCTAssertEqual(SleepModel.nightPerformance(wakeTs: wake, stored: ["2026-10-08": 90],
                                                   byDay: ["2026-10-09": 74], days: []), 74)
        XCTAssertNil(SleepModel.nightPerformance(wakeTs: wake, stored: [:], byDay: [:], days: []))
    }

    /// A wake before 04:00 is also looked up under its logical day, the day Home resolves to then.
    func testWakeBeforeFourAlsoTriesTheLogicalDay() {
        let wake = at("2026-10-09", 3, 10)
        XCTAssertEqual(SleepModel.nightDayKeys(wakeTs: wake, days: []), ["2026-10-09", "2026-10-08"])
        XCTAssertEqual(SleepModel.nightPerformance(wakeTs: wake, stored: ["2026-10-08": 66],
                                                   byDay: [:], days: []), 66)
        // The wake day still wins when it has the score.
        XCTAssertEqual(SleepModel.nightPerformance(wakeTs: wake, stored: ["2026-10-08": 66, "2026-10-09": 71],
                                                   byDay: [:], days: []), 71)
    }

    /// ...but never borrows the score of the night banked under that logical day.
    func testWakeBeforeFourNeverBorrowsThePreviousNight() {
        let wake = at("2026-10-09", 3, 10)
        let days = [day("2026-10-08", asleep: 430)]
        XCTAssertEqual(SleepModel.nightDayKeys(wakeTs: wake, days: days), ["2026-10-09"])
        XCTAssertNil(SleepModel.nightPerformance(wakeTs: wake, stored: ["2026-10-08": 66],
                                                 byDay: ["2026-10-08": 66], days: days))
    }

    func testAMorningWakeHasOneKey() {
        XCTAssertEqual(SleepModel.nightDayKeys(wakeTs: at("2026-10-09", 6, 45), days: []), ["2026-10-09"])
    }

    /// The per-day figures behind the Rest tile and the hero: stored first, then the imported WHOOP figure.
    func testPerformanceByDayPrefersStoredThenImported() {
        let days = [day("2026-10-08", asleep: 420), day("2026-10-09", asleep: 400)]
        let byDay = SleepModel.performanceByDay(
            days: days,
            importedSleep: [
                "2026-10-08": ImportedSleepFigures(performancePct: 70, consistencyPct: nil, needMin: nil, debtMin: nil),
                "2026-10-09": ImportedSleepFigures(performancePct: 60, consistencyPct: nil, needMin: nil, debtMin: nil),
            ],
            stored: ["2026-10-09": 81])
        XCTAssertEqual(byDay["2026-10-09"], 81)
        XCTAssertEqual(byDay["2026-10-08"], 70)
    }
}
