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

    // MARK: Recovery

    /// 12 Oct style readout: HRV 74 against 85 and resting heart rate 54 against 50, breathing and sleep fine.
    private var lowReadings: [WhoopScoreInsightText.Reading] {
        [.init(driver: .hrv, today: 74, usual: 85), .init(driver: .restingHr, today: 54, usual: 50),
         .init(driver: .respiratory, today: 14.9, usual: 15.1), .init(driver: .sleep, today: 88, usual: 84)]
    }

    func testTheReadingScoreIsTheMoveThatHelpsAsAShareOfWhatIsNotable() throws {
        let hrv = try XCTUnwrap(lowReadings[0].score)
        XCTAssertEqual(hrv, (74.0 - 85.0) / 85.0 / 0.05, accuracy: 1e-9)
        let rhr = try XCTUnwrap(lowReadings[1].score)
        XCTAssertEqual(rhr, (50.0 - 54.0) / 50.0 / 0.03, accuracy: 1e-9, "a higher resting rate hurts")
        let sleep = try XCTUnwrap(lowReadings[3].score)
        XCTAssertEqual(sleep, 4.0 / 100.0 / 0.06, accuracy: 1e-9, "sleep moves in points of 100")
        XCTAssertNil(WhoopScoreInsightText.Reading(driver: .hrv, today: nil, usual: 85).score)
        XCTAssertNil(WhoopScoreInsightText.Reading(driver: .hrv, today: 74, usual: nil).score)
    }

    func testTheStrongestDragAndLead() {
        XCTAssertEqual(WhoopScoreInsightText.strongest(lowReadings, drag: true), .restingHr)
        XCTAssertNil(WhoopScoreInsightText.strongest(lowReadings, drag: false), "no move reaches what is notable")
        let good: [WhoopScoreInsightText.Reading] = [.init(driver: .hrv, today: 97, usual: 86),
                                                     .init(driver: .restingHr, today: 48, usual: 50)]
        XCTAssertEqual(WhoopScoreInsightText.strongest(good, drag: false), .hrv)
        XCTAssertNil(WhoopScoreInsightText.strongest(good, drag: true))
        XCTAssertNil(WhoopScoreInsightText.strongest([], drag: true))
    }

    func testTheRecoverySentenceFollowsTheBandAndNamesTheSignal() {
        XCTAssertEqual(WhoopScoreInsightText.recoverySentence(recovery: 80, readings: []),
                       "Your body is well recovered and ready for a hard day.")
        XCTAssertEqual(WhoopScoreInsightText.recoverySentence(recovery: 67, readings: []),
                       "Your body is well recovered and ready for a hard day.", "67 is green")
        XCTAssertEqual(WhoopScoreInsightText.recoverySentence(recovery: 66, readings: []),
                       "Your recovery is moderate. Keep today's effort steady and listen to your body.")
        XCTAssertEqual(WhoopScoreInsightText.recoverySentence(recovery: 20, readings: []),
                       "Your recovery is low. Prioritize rest, fluids and an early night.")
        let moderate = WhoopScoreInsightText.recoverySentence(recovery: 50, readings: lowReadings)
        XCTAssertTrue(moderate.hasSuffix("Resting Heart Rate is the biggest drag on today's Recovery."), moderate)
        let green = WhoopScoreInsightText.recoverySentence(
            recovery: 91, readings: [.init(driver: .hrv, today: 97, usual: 86)])
        XCTAssertTrue(green.hasSuffix("Heart Rate Variability is helping your Recovery the most."), green)
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
