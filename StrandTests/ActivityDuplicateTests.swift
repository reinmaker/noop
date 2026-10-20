import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// One session saved under two types (20 Oct 2026: Weightlifting and Jump rope, 21:01 to 22:28) must not be
/// added again behind another writer's back, and a list must tell the two rows apart.
final class ActivityDuplicateTests: XCTestCase {

    private func row(_ start: Int, _ end: Int, _ sport: String) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: "manual", durationS: Double(end - start),
                   energyKcal: nil, avgHr: 111, maxHr: 171, strain: nil, distanceM: nil, zonesJSON: nil,
                   notes: nil, steps: nil)
    }

    private let start = 1_792_519_260, end = 1_792_524_480

    /// Two rows with one start have two list identities.
    func testListIDTellsTwoTypesOfOneStartApart() {
        let a = row(start, end, "Weightlifting"), b = row(start, end, "Jump rope")
        XCTAssertNotEqual(a.listID, b.listID)
        XCTAssertEqual(a.listID, row(start, end, "Weightlifting").listID)
    }

    /// A saved row with the bout's start, or over most of its span, covers it.
    func testSavedActivityCoversABout() {
        XCTAssertTrue(Repository.savedActivityCovers(startSec: start, endSec: end,
                                                     saved: [row(start, end, "Weightlifting")]))
        XCTAssertTrue(Repository.savedActivityCovers(startSec: start + 60, endSec: end + 180,
                                                     saved: [row(start, end, "Weightlifting")]), "a moved span")
        XCTAssertTrue(Repository.savedActivityCovers(startSec: start, endSec: end,
                                                     saved: [row(start + 600, end - 600, "Weightlifting")]),
                      "a saved row inside the bout is most of the shorter span")
    }

    /// A row elsewhere in the day, or one that only touches the bout, does not.
    func testOtherRowsDoNotCoverIt() {
        XCTAssertFalse(Repository.savedActivityCovers(startSec: start, endSec: end, saved: []))
        XCTAssertFalse(Repository.savedActivityCovers(startSec: start, endSec: end,
                                                      saved: [row(start - 7_200, start - 3_600, "Tennis")]))
        XCTAssertFalse(Repository.savedActivityCovers(startSec: start, endSec: end,
                                                      saved: [row(end - 60, end + 3_600, "Tennis")]),
                       "a minute of overlap with a long row")
    }
}
