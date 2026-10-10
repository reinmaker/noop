import XCTest
import WhoopStore
@testable import Strand

/// The personal patterns the Coach backs its advice with (`CoachPatterns`).
final class CoachPatternsTests: XCTestCase {

    func testComparisonNeedsDaysOnBothSides() {
        XCTAssertNil(CoachPatterns.compare("A", [60, 70], "B", [50, 50, 50], unit: "%"))
        XCTAssertEqual(CoachPatterns.compare("Recovery after 7.5 h of sleep or more", [60, 70, 80],
                                             "after under 6.5 h", [50, 52, 54], unit: "%"),
                       "Recovery after 7.5 h of sleep or more: 70% on average (3 days), against 52% after under "
                       + "6.5 h (3 days).")
    }

    func testNextDayIsCalendarConsecutive() {
        XCTAssertTrue(CoachPatterns.isNextDay("2026-10-08", "2026-10-09"))
        XCTAssertTrue(CoachPatterns.isNextDay("2026-10-31", "2026-11-01"))
        XCTAssertFalse(CoachPatterns.isNextDay("2026-10-06", "2026-10-08"))
    }

    func testNoBlockWithoutEnoughHistory() {
        XCTAssertNil(CoachPatterns.block(days: []))
    }

    private func day(_ key: String, sleep: Double?, recovery: Double?, strain: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: recovery, strain: strain,
                    exerciseCount: nil)
    }

    /// Stored Strain is 0-100; 2 is about 0.4 on the 0-21 scale, a day off the wrist.
    func testWornDayNeedsStrainAndSleep() {
        XCTAssertTrue(CoachPatterns.isWornDay(day("2026-10-01", sleep: 400, recovery: nil, strain: 50)))
        XCTAssertFalse(CoachPatterns.isWornDay(day("2026-10-01", sleep: 400, recovery: nil, strain: 2)))
        XCTAssertFalse(CoachPatterns.isWornDay(day("2026-10-01", sleep: 400, recovery: nil, strain: nil)))
        XCTAssertFalse(CoachPatterns.isWornDay(day("2026-10-01", sleep: nil, recovery: nil, strain: 50)))
        XCTAssertFalse(CoachPatterns.isWornDay(day("2026-10-01", sleep: 0, recovery: nil, strain: 50)))
    }

    /// Days off the wrist read as almost no Strain and used to be counted as easy days.
    func testNonWearDaysAreNotEasyDays() {
        let days = [
            day("2026-10-01", sleep: 400, recovery: 60, strain: 80),
            day("2026-10-02", sleep: 400, recovery: 50, strain: 80),
            day("2026-10-03", sleep: 400, recovery: 50, strain: 80),
            day("2026-10-04", sleep: 400, recovery: 50, strain: 20),
            day("2026-10-05", sleep: 400, recovery: 70, strain: 20),
            day("2026-10-06", sleep: 400, recovery: 70, strain: 20),
            day("2026-10-07", sleep: nil, recovery: 70, strain: 0),
            day("2026-10-08", sleep: 400, recovery: 90, strain: 3),
            day("2026-10-09", sleep: 400, recovery: 95, strain: nil),
        ]
        let block = CoachPatterns.block(days: days) ?? ""
        XCTAssertTrue(block.contains("Recovery the morning after a day of Strain 14 or more: 50% on average (3 days), "
                                     + "against 70% after Strain under 10 (3 days)."), block)
    }

    func testHeaderCountsCalendarDaysNotRows() {
        let days = [
            day("2026-10-01", sleep: 480, recovery: 80), day("2026-10-02", sleep: 480, recovery: 75),
            day("2026-10-04", sleep: 480, recovery: 70), day("2026-10-06", sleep: 300, recovery: 50),
            day("2026-10-08", sleep: 300, recovery: 45), day("2026-10-10", sleep: 300, recovery: 40),
        ]
        let block = CoachPatterns.block(days: days) ?? ""
        XCTAssertTrue(block.contains("last 10 calendar days, 6 of them with data"), block)
    }

    func testCalendarDayArithmetic() {
        XCTAssertEqual(CoachPatterns.calendarDays(from: "2026-10-01", to: "2026-10-10"), 10)
        XCTAssertEqual(CoachPatterns.calendarDays(from: "2026-10-10", to: "2026-10-10"), 1)
        XCTAssertNil(CoachPatterns.calendarDays(from: nil, to: "2026-10-10"))
        XCTAssertNil(CoachPatterns.calendarDays(from: "2026-10-10", to: "2026-10-01"))
        XCTAssertEqual(CoachPatterns.dayKey("2026-10-10", minusDays: CoachPatterns.lookbackDays - 1), "2026-06-13")
    }
}
