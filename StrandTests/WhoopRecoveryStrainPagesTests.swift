import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopStore

/// The pieces behind the Recovery and Strain screens' lower halves: the drivers named beside the journal
/// behaviours, the page title, the stacked zone figures and the week chart's value axis.
@MainActor
final class WhoopRecoveryStrainPagesTests: XCTestCase {

    private func day(_ key: String, recovery: Double?, strain21: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 420, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: recovery,
                    strain: strain21.map { StrainScorer.effortValue(fromWhoopStrain: $0) }, exerciseCount: nil)
    }

    // MARK: Drivers

    /// Forty days in which every hard day (Strain 14) is followed by a low Recovery, and every light one (4) by a high one.
    private var hardDaysCostRecovery: [DailyMetric] {
        (0..<41).map { i in
            let key = WeeklyDigestEngine.addDays("2026-08-01", i)
            let yesterdayHard = i > 0 && (i - 1) % 2 == 0
            let recovery = (yesterdayHard ? 40.0 : 75.0) + Double(i % 5)
            return day(key, recovery: recovery, strain21: i % 2 == 0 ? 14 : 4)
        }
    }

    func testAHardYesterdayThatCostsRecoveryIsNamedWithADownArrow() {
        let days = hardDaysCostRecovery
        let shown = WeeklyDigestEngine.addDays("2026-08-01", 41)
        let chips = WhoopBehaviorDrivers.chips(days: days, sleepPerformance: [:], shownDay: shown)
        XCTAssertEqual(chips.count, 1)
        XCTAssertTrue(chips[0].name.hasSuffix("+ Strain"), chips[0].name)
        XCTAssertEqual(chips[0].direction, -1)
    }

    func testAnEasyYesterdayNamesNoStrainDriver() {
        let days = hardDaysCostRecovery
        // 41 Aug was after a hard day (i = 40); the day after that, yesterday was an easy one.
        let shown = WeeklyDigestEngine.addDays("2026-08-01", 42)
        let withEasyYesterday = days + [day(WeeklyDigestEngine.addDays("2026-08-01", 41), recovery: 80, strain21: 4)]
        XCTAssertTrue(WhoopBehaviorDrivers.chips(days: withEasyYesterday, sleepPerformance: [:], shownDay: shown).isEmpty)
    }

    func testWithTooLittleHistoryThereAreNoDrivers() {
        let days = Array(hardDaysCostRecovery.prefix(6))
        XCTAssertTrue(WhoopBehaviorDrivers.chips(days: days, sleepPerformance: [:], shownDay: "2026-08-08").isEmpty)
    }

    // MARK: The title

    func testTheTitleNamesTheDateTheCycleBeganOn() {
        let days = [day("2026-10-16", recovery: 59, strain21: 11), day("2026-10-17", recovery: 66, strain21: 5)]
        let latest = days[1]
        var calendar = Calendar.current
        calendar.timeZone = .current
        let night = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 23, minute: 30))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 1, minute: 3))!
        XCTAssertEqual(WhoopSelectedDay.title(latest, days: days, cycleStart: Int(night.timeIntervalSince1970)),
                       "\(night.formatted(.dateTime.month(.abbreviated).day()).uppercased()) TO TODAY")
        XCTAssertEqual(WhoopSelectedDay.title(latest, days: days, cycleStart: Int(after.timeIntervalSince1970)), "TODAY",
                       "a night that began after midnight is today's")
        XCTAssertEqual(WhoopSelectedDay.title(latest, days: days, cycleStart: nil), "TODAY")
    }

    func testTheCycleStartIsTheLongestSleepThatEndedOnTheDay() {
        func session(_ startTs: Int, _ endTs: Int) -> CachedSleepSession {
            CachedSleepSession(startTs: startTs, endTs: endTs, efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
        }
        var calendar = Calendar.current
        calendar.timeZone = .current
        func at(_ d: Int, _ h: Int) -> Int { Int(calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))!.timeIntervalSince1970) }
        let night = session(at(16, 23), at(17, 8))
        let nap = session(at(17, 14), at(17, 15))
        XCTAssertEqual(WhoopSelectedDay.cycleStart([nap, night], dayKey: "2026-10-17"), at(16, 23))
        XCTAssertNil(WhoopSelectedDay.cycleStart([night], dayKey: "2026-10-18"))
    }

    // MARK: The week chart's value axis

    func testALineKeepsRoomAroundItsPointsAndNeverFlattensToNothing() {
        let wide = WhoopWeekChartCard.lineDomain([53, 51, 48, 54], minSpan: 12)
        XCTAssertGreaterThanOrEqual(wide.upperBound - wide.lowerBound, 12)
        XCTAssertLessThan(wide.lowerBound, 48)
        XCTAssertGreaterThan(wide.upperBound, 54)
        let flat = WhoopWeekChartCard.lineDomain([14.9, 14.9], minSpan: 3)
        XCTAssertEqual(flat.upperBound - flat.lowerBound, 3, accuracy: 1e-9)
        XCTAssertEqual(WhoopWeekChartCard.lineDomain([], minSpan: 3), 0...3)
    }
}
