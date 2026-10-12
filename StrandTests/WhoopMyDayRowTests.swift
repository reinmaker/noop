import XCTest
@testable import Strand

/// Home's My Day row: the Daily Outlook in the morning, the Day In Review from 17:00 (`WhoopMyDaySection`).
final class WhoopMyDayRowTests: XCTestCase {

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// The Outlook runs until the training cutoff (bed 00:55 gives 21:55), then the Review, through the night.
    func testOutlookUntilTheTrainingCutoffThenReview() {
        let cutoff = date(12, 21, 55)
        XCTAssertTrue(WhoopMyDaySection.isOutlook(now: date(12, 7), cutoff: cutoff))
        XCTAssertTrue(WhoopMyDaySection.isOutlook(now: date(12, 18), cutoff: cutoff))
        XCTAssertTrue(WhoopMyDaySection.isOutlook(now: date(12, 21, 54), cutoff: cutoff))
        XCTAssertFalse(WhoopMyDaySection.isOutlook(now: date(12, 21, 55), cutoff: cutoff))
        XCTAssertFalse(WhoopMyDaySection.isOutlook(now: date(12, 23, 30), cutoff: cutoff))
    }

    /// After midnight, before bed, the plan is still the night just starting: its cutoff is yesterday evening.
    func testReviewStaysAfterMidnightUntilTheNextNightIsPlanned() {
        XCTAssertFalse(WhoopMyDaySection.isOutlook(now: date(13, 0, 30), cutoff: date(12, 21, 55)))
        XCTAssertTrue(WhoopMyDaySection.isOutlook(now: date(13, 10), cutoff: date(13, 22, 10)))
    }

    /// With no plan the fixed hours stand in.
    func testWithoutAPlanTheFixedHoursStandIn() {
        XCTAssertFalse(WhoopMyDaySection.isOutlook(now: date(12, 2), cutoff: nil))
        XCTAssertTrue(WhoopMyDaySection.isOutlook(now: date(12, 4), cutoff: nil))
        XCTAssertTrue(WhoopMyDaySection.isOutlook(now: date(12, 18, 59), cutoff: nil))
        XCTAssertFalse(WhoopMyDaySection.isOutlook(now: date(12, 19), cutoff: nil))
    }

    func testOutlookTitleUsesTheNameWhenKnown() {
        XCTAssertEqual(WhoopMyDaySection.outlookTitle("Daniel"), "Daniel's Daily Outlook")
        XCTAssertEqual(WhoopMyDaySection.outlookTitle("  "), "Your Daily Outlook")
    }
}
