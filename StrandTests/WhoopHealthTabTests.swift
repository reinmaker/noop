import XCTest
import Foundation
@testable import Strand
import WhoopStore

/// The pure parts of the WHOOP-style Health tab and Healthspan page: the Pace of Aging trend, the Advanced Labs
/// count and the ruler of each Healthspan row.
@MainActor
final class WhoopHealthTabTests: XCTestCase {

    // MARK: Pace of Aging against last week

    func testThePaceTrendReadsTheMoveSinceLastWeek() {
        XCTAssertEqual(WhoopPaceTrend(now: 0.3, lastWeek: 0.1), .faster)
        XCTAssertEqual(WhoopPaceTrend(now: 0.1, lastWeek: 0.3), .slower)
        XCTAssertEqual(WhoopPaceTrend(now: 0.3, lastWeek: 0.27), .steady, "a move under 0.05 is no move")
        XCTAssertNil(WhoopPaceTrend(now: nil, lastWeek: 0.3))
        XCTAssertNil(WhoopPaceTrend(now: 0.3, lastWeek: nil))
    }

    // MARK: Advanced Labs

    private func marker(_ key: String, taken: Int, note: String?) -> LabMarkerRow {
        LabMarkerRow(id: "\(key)-\(taken)", deviceId: "d", markerKey: key, category: "bloodPanel", day: "2026-08-08",
                     takenAt: taken, value: 1, valueText: nil, unit: "", source: "whoop-biomarkers", note: note,
                     referenceText: nil)
    }

    func testAMarkersStatusIsOnlyWhatWhoopWroteInItsNote() {
        XCTAssertEqual(WhoopLabSummary.status(ofNote: "WHOOP: Optimal"), .optimal)
        XCTAssertEqual(WhoopLabSummary.status(ofNote: "WHOOP: Sufficient"), .sufficient)
        XCTAssertEqual(WhoopLabSummary.status(ofNote: "WHOOP: Out of Range"), .outOfRange)
        XCTAssertNil(WhoopLabSummary.status(ofNote: "Optimal"), "Yoop judges no value: only WHOOP's own word counts")
        XCTAssertNil(WhoopLabSummary.status(ofNote: "fasting sample"))
        XCTAssertNil(WhoopLabSummary.status(ofNote: nil))
    }

    func testTheLabSummaryCountsTheLatestReadingOfEachMarker() {
        let rows = [marker("ferritin", taken: 100, note: "WHOOP: Optimal"),
                    marker("ferritin", taken: 200, note: "WHOOP: Out of Range"),
                    marker("tsh", taken: 150, note: "WHOOP: Sufficient"),
                    marker("cortisol", taken: 120, note: nil)]
        let summary = WhoopLabSummary.make(rows)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.optimal, 0, "the older Optimal reading of ferritin is superseded")
        XCTAssertEqual(summary.outOfRange, 1)
        XCTAssertEqual(summary.sufficient, 1)
        XCTAssertEqual(summary.judged, 2)
        XCTAssertEqual(summary.lastTakenAt, 200)
        XCTAssertEqual(WhoopLabSummary.make([]), WhoopLabSummary())
    }

    // MARK: The Healthspan rulers

    func testARowsRulerPlacesValuesAndMarksTheHealthyEnd() {
        let consistency = WhoopHealthspanScale.scale(.sleepConsistency)
        XCTAssertEqual(consistency.fraction(70), 0.5, accuracy: 1e-12)
        XCTAssertEqual(consistency.fraction(30), 0, "below the bar clamps to its start")
        XCTAssertEqual(consistency.fraction(120), 1, "above it clamps to its end")
        XCTAssertEqual(consistency.goodness(step: 0), 0)
        XCTAssertEqual(consistency.goodness(step: 9), 1)
        let rhr = WhoopHealthspanScale.scale(.restingHr)
        XCTAssertTrue(rhr.reversed)
        XCTAssertEqual(rhr.goodness(step: 0), 1, "for resting heart rate the low end is the healthy one")
        XCTAssertEqual(rhr.goodness(step: 9), 0)
    }

    func testARowsValueReadsAsWhoopPrintsIt() {
        XCTAssertEqual(WhoopHealthspanScale.scale(.sleepConsistency).valueText(71), "71%")
        XCTAssertEqual(WhoopHealthspanScale.scale(.sleepDuration).valueText(433.0 / 60.0), "7:13 h")
        XCTAssertEqual(WhoopHealthspanScale.scale(.zones13).valueText(180), "3:00 h")
        XCTAssertEqual(WhoopHealthspanScale.scale(.zones45).valueText(20), "0:20 h")
        XCTAssertEqual(WhoopHealthspanScale.scale(.vo2max).valueText(48), "48 ml/kg/min")
        XCTAssertEqual(WhoopHealthspanScale.scale(.restingHr).valueText(51), "51 bpm")
    }

    func testTheYearsAndTheSentenceFollowTheSign() {
        XCTAssertTrue(WhoopHealthspanWords.sentence(years: -0.2).hasPrefix("Outperforming"))
        XCTAssertTrue(WhoopHealthspanWords.sentence(years: 0.0).hasPrefix("On target"))
        XCTAssertTrue(WhoopHealthspanWords.sentence(years: 0.3).hasPrefix("Holding you back"))
        XCTAssertEqual(WhoopHealthspanWords.years(-0.2), "-0.2")
        XCTAssertEqual(WhoopHealthspanWords.years(0.04), "0.0", "under 0.05 is level")
        XCTAssertEqual(WhoopHealthspanWords.years(0.6), "0.6")
    }
}
