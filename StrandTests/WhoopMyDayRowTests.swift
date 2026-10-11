import XCTest
@testable import Strand

/// Home's My Day row: the Daily Outlook in the morning, the Day In Review from 17:00 (`WhoopMyDaySection`).
final class WhoopMyDayRowTests: XCTestCase {

    func testOutlookUntilFiveThenReview() {
        XCTAssertTrue(WhoopMyDaySection.isOutlookHour(0))
        XCTAssertTrue(WhoopMyDaySection.isOutlookHour(7))
        XCTAssertTrue(WhoopMyDaySection.isOutlookHour(16))
        XCTAssertFalse(WhoopMyDaySection.isOutlookHour(17))
        XCTAssertFalse(WhoopMyDaySection.isOutlookHour(23))
    }

    func testOutlookTitleUsesTheNameWhenKnown() {
        XCTAssertEqual(WhoopMyDaySection.outlookTitle("Daniel"), "Daniel's Daily Outlook")
        XCTAssertEqual(WhoopMyDaySection.outlookTitle("  "), "Your Daily Outlook")
    }
}
