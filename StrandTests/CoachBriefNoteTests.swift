import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The morning Outlook note (`CoachBriefScheduler`): its text in plain words, and when there is anything to write
/// about. Notes seen on 1 Nov 2026 showed raw "**74%**", cut a sentence short, arrived at 18:58 and said "nothing
/// has synced".
final class CoachBriefNoteTests: XCTestCase {

    /// The markdown marks are dropped, so a banner does not show "**74%**".
    func testTheBodyHasNoMarkdown() {
        let brief = "Your last scored read is a solid **74%** from Thursday. Take it easy."
        let body = CoachBriefScheduler.oneLineSummary(from: brief)
        XCTAssertEqual(body, "Your last scored read is a solid 74% from Thursday. Take it easy.")
        XCTAssertFalse(body.contains("*"))
        XCTAssertEqual(CoachBriefScheduler.plainText("## **Heads up**"), "Heads up")
        XCTAssertEqual(CoachBriefScheduler.plainText("- a `code` bullet"), "a code bullet")
    }

    /// A short headline alone says nothing, so the first sentence of the next line follows it.
    func testAShortHeadlineIsFollowedByTheFirstSentence() {
        let brief = "Steady and strong, Daniel\n\nYou backed up a **93%** green Recovery after a yellow day. That is a big deal.\n\nToday's activity picks"
        XCTAssertEqual(CoachBriefScheduler.oneLineSummary(from: brief),
                       "Steady and strong, Daniel You backed up a 93% green Recovery after a yellow day.")
        XCTAssertEqual(CoachBriefScheduler.firstSentence(of: "One. Two."), "One.")
        XCTAssertEqual(CoachBriefScheduler.firstSentence(of: "No stop here"), "No stop here")
    }

    /// A long body is cut at a word with an ellipsis, not through one.
    func testALongBodyIsCutAtAWord() {
        let long = String(repeating: "readiness ", count: 30)
        let body = CoachBriefScheduler.oneLineSummary(from: long, maxLength: 40)
        XCTAssertTrue(body.hasSuffix("\u{2026}"), body)
        XCTAssertLessThanOrEqual(body.count, 41)
        XCTAssertFalse(body.dropLast().hasSuffix(" "), body)
        XCTAssertEqual(CoachBriefScheduler.oneLineSummary(from: "", maxLength: 40), "")
    }

    private func metric(_ day: String, recovery: Double?, sleep: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: recovery, strain: nil, exerciseCount: nil)
    }

    /// There is something to write about once today's row holds a Recovery or a night; yesterday's does not count.
    func testABriefNeedsTodaysNight() {
        XCTAssertFalse(AICoachEngine.briefHasData(days: [], todayKey: "2026-11-01"))
        XCTAssertFalse(AICoachEngine.briefHasData(days: [metric("2026-10-31", recovery: 80, sleep: 400)], todayKey: "2026-11-01"))
        XCTAssertFalse(AICoachEngine.briefHasData(days: [metric("2026-11-01", recovery: nil, sleep: nil)], todayKey: "2026-11-01"))
        XCTAssertTrue(AICoachEngine.briefHasData(days: [metric("2026-11-01", recovery: 77, sleep: nil)], todayKey: "2026-11-01"))
        XCTAssertTrue(AICoachEngine.briefHasData(days: [metric("2026-11-01", recovery: nil, sleep: 410)], todayKey: "2026-11-01"))
    }

    /// The morning window is five hours from the chosen time.
    func testTheMorningWindowIsFiveHours() {
        XCTAssertEqual(CoachBriefScheduler.windowMinutes, 300)
    }
}
