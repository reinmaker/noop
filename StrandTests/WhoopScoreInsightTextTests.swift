import XCTest
import Foundation
@testable import Strand

/// The words and figures behind the outlined cards of the Recovery and Strain screens
/// (`WhoopScoreInsightText`, `WhoopStrainFigures`).
@MainActor
final class WhoopScoreInsightTextTests: XCTestCase {

    // MARK: Strain against its range

    func testStrainStandsAgainstItsRange() {
        let band = (lower: 10.0, upper: 14.0)
        XCTAssertEqual(WhoopScoreInsightText.strainState(strain: 15, band: band), .above)
        XCTAssertEqual(WhoopScoreInsightText.strainState(strain: 14, band: band), .inside, "the top edge is inside")
        XCTAssertEqual(WhoopScoreInsightText.strainState(strain: 12, band: band), .inside)
        XCTAssertEqual(WhoopScoreInsightText.strainState(strain: 10, band: band), .inside, "the bottom edge is inside")
        XCTAssertEqual(WhoopScoreInsightText.strainState(strain: 7.5, band: band), .closeBelow, "2.5 under is still close")
        XCTAssertEqual(WhoopScoreInsightText.strainState(strain: 7.4, band: band), .farBelow)
        XCTAssertEqual(WhoopScoreInsightText.strainState(strain: 12, band: nil), .noRange)
    }

    func testEveryStrainStateHasItsOwnSentence() {
        let states: [WhoopScoreInsightText.StrainState] = [.noRange, .farBelow, .closeBelow, .inside, .above]
        let sentences = Set(states.map(WhoopScoreInsightText.strainSentence))
        XCTAssertEqual(sentences.count, states.count)
        XCTAssertTrue(sentences.allSatisfy { !$0.isEmpty })
    }

    // MARK: Behaviours

    func testABehaviourChipDropsTheFramingWords() {
        XCTAssertEqual(WhoopScoreInsightText.behaviourName("Did you have any alcohol?"), "Alcohol")
        XCTAssertEqual(WhoopScoreInsightText.behaviourName("Did you take magnesium?"), "Magnesium")
        XCTAssertEqual(WhoopScoreInsightText.behaviourName("  Did you eat late?  "), "Eat late")
        XCTAssertEqual(WhoopScoreInsightText.behaviourName("Any caffeine?"), "Caffeine")
        XCTAssertEqual(WhoopScoreInsightText.behaviourName("Alcohol"), "Alcohol")
        XCTAssertEqual(WhoopScoreInsightText.behaviourName("?"), "?", "nothing left keeps the question")
    }

    // MARK: The Strain screen's figures

    func testHoursAndMinutes() {
        XCTAssertEqual(WhoopStrainFigures.hoursAndMinutes(97.1), "1:37")
        XCTAssertEqual(WhoopStrainFigures.hoursAndMinutes(0), "0:00")
        XCTAssertEqual(WhoopStrainFigures.hoursAndMinutes(59.6), "1:00")
        XCTAssertEqual(WhoopStrainFigures.hoursAndMinutes(605), "10:05")
    }

    func testTheUsualCountsEveryDayAndNeedsAWeekOfHistory() {
        var figures: [String: WhoopDayActivityFigures] = [:]
        for day in ["2026-10-02", "2026-10-05", "2026-10-09"] {
            figures[day] = WhoopDayActivityFigures(zones13Min: 30, zones45Min: 0, strengthMin: 0)
        }
        figures["2026-10-11"] = WhoopDayActivityFigures(zones13Min: 500, zones45Min: 0, strengthMin: 0)
        let usual = WhoopStrainFigures.usual(figures, before: "2026-10-11", knownDays: 10) { $0.zones13Min }
        XCTAssertEqual(usual ?? -1, 90.0 / 30.0, accuracy: 1e-9, "30 days before the shown one, rest days as zero, the day itself left out")
        XCTAssertNil(WhoopStrainFigures.usual(figures, before: "2026-10-11", knownDays: 6) { $0.zones13Min })
    }
}
