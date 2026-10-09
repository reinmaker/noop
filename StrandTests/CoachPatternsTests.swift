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
}
