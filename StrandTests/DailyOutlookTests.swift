import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The Daily Outlook's prompt and the two lines it leans on: yesterday's Recovery colour and the wearer's
/// routine for the weekday (`AICoachEngine`), after WHOOP's Outlook of 31 Oct 2026.
final class DailyOutlookTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func at(_ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func ts(_ month: Int, _ day: Int, _ hour: Int = 9) -> Int { Int(at(month, day, hour).timeIntervalSince1970) }

    private func metric(_ day: String, recovery: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90, lightMin: 250,
                    disturbances: nil, restingHr: 50, avgHrv: 80, recovery: recovery, strain: nil, exerciseCount: nil)
    }

    /// The row of the day before today, with its colour, so the Coach can call today a rebound or a dip.
    func testYesterdayRecoveryNamesItsColour() {
        let days = [metric("2026-10-29", recovery: 90), metric("2026-10-30", recovery: 58), metric("2026-10-31", recovery: 93)]
        XCTAssertEqual(AICoachEngine.yesterdayRecoveryLine(days: days, todayKey: "2026-10-31"),
                       "Yesterday's Recovery: 58% (yellow).")
        for (value, band) in [(67.0, "green"), (66.0, "yellow"), (34.0, "yellow"), (33.0, "red")] {
            let line = AICoachEngine.yesterdayRecoveryLine(days: [metric("2026-10-30", recovery: value)],
                                                           todayKey: "2026-10-31")
            XCTAssertEqual(line, "Yesterday's Recovery: \(Int(value))% (\(band)).")
        }
    }

    /// Nothing is said when yesterday has no row or no Recovery; an older row is not called yesterday's.
    func testYesterdayRecoveryIsSilentWithoutThatRow() {
        XCTAssertNil(AICoachEngine.yesterdayRecoveryLine(days: [], todayKey: "2026-10-31"))
        XCTAssertNil(AICoachEngine.yesterdayRecoveryLine(days: [metric("2026-10-30", recovery: nil)], todayKey: "2026-10-31"))
        XCTAssertNil(AICoachEngine.yesterdayRecoveryLine(days: [metric("2026-10-28", recovery: 80)], todayKey: "2026-10-31"))
        XCTAssertNil(AICoachEngine.yesterdayRecoveryLine(days: [metric("2026-10-30", recovery: 80)], todayKey: "not a day"))
    }

    /// The same weekday's activities in the last 12 weeks, by type, most common first; other weekdays, today and
    /// anything older than the window are left out.
    func testRoutineCountsTheSameWeekdayOnly() {
        let rows: [(startTs: Int, sport: String)] = [
            (ts(10, 24), "Tennis"), (ts(10, 17), "Tennis"), (ts(10, 10), "Tennis"),
            (ts(10, 3), "Walking"),
            (ts(10, 25), "Running"),          // a Sunday
            (ts(10, 31, 7), "Tennis"),        // today, still being lived
            (ts(7, 4), "Tennis"),             // a Saturday more than 12 weeks back
        ]
        XCTAssertEqual(AICoachEngine.weekdayRoutineLine(rows: rows, now: at(10, 31, 12), calendar: utc),
                       "ROUTINE (Saturdays, last 12 weeks): Tennis 3 of 12, Walking 1 of 12. A habit to weigh, not a rule.")
    }

    /// A weekday with nothing on it says nothing, and only the three most common are listed.
    func testRoutineIsSilentWithNothingAndKeepsTheTopThree() {
        XCTAssertNil(AICoachEngine.weekdayRoutineLine(rows: [(ts(10, 25), "Running")], now: at(10, 31, 12), calendar: utc))
        XCTAssertNil(AICoachEngine.weekdayRoutineLine(rows: [], now: at(10, 31, 12), calendar: utc))
        let many: [(startTs: Int, sport: String)] = [
            (ts(10, 24), "Tennis"), (ts(10, 17), "Tennis"), (ts(10, 10), "Walking"), (ts(10, 3), "Cycling"),
            (ts(9, 26), "Yoga"),
        ]
        let line = AICoachEngine.weekdayRoutineLine(rows: many, now: at(10, 31, 12), calendar: utc) ?? ""
        XCTAssertTrue(line.contains("Tennis 2 of 12"), line)
        XCTAssertEqual(line.components(separatedBy: " of 12").count - 1, 3, line)
    }

    /// The prompt asks for the parts WHOOP's Outlook has, leaves out the bedtime and uses no dashes.
    func testTheOutlookPromptAsksForTheWhoopShape() {
        let text = AICoachEngine.dailyOutlookInstruction
        for part in ["headline", "Recovery", "HRV", "resting heart rate", "yesterday's colour", "Today's activity picks",
                     "three bullets", "ROUTINE", "optimal Strain", "which pick I lean toward"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertTrue(text.contains("Leave out my bedtime"))
        XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), "no em or en dash")
    }
}
