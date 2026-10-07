import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// The WHOOP-calibrated curve (`StrainScorer.Method.whoop`), pinned on the cases it was fitted to.
final class StrainWhoopCurveTests: XCTestCase {

    /// One reading a minute at `bpm` for `minutes`, starting at `start` (unix seconds).
    private func block(_ bpm: Int, minutes: Int, start: Int) -> [HRSample] {
        (0..<minutes).map { HRSample(ts: start + $0 * 60, bpm: bpm) }
    }

    private func whoopScale(_ effort: Double?) -> Double? {
        effort.map { $0 * StrainScorer.whoopMaxStrain / StrainScorer.maxStrain }
    }

    /// Sixteen waking hours sat at 68 bpm add nothing: below the sitting floor, as in WHOOP.
    func testADeskDayScoresZero() {
        let hr = block(68, minutes: 960, start: 0)
        XCTAssertEqual(StrainScorer.strain(hr, restingHR: 50, method: .whoop), 0)
    }

    /// A 38 minute run with WHOOP's own zone split for it (Activity Strain 16.8) lands within the fit's error.
    func testARunMatchesWhoopsActivityStrain() {
        var hr = block(130, minutes: 2, start: 0)
        hr += block(150, minutes: 2, start: 120)
        hr += block(170, minutes: 19, start: 240)
        hr += block(185, minutes: 15, start: 1380)
        let strain = whoopScale(StrainScorer.strain(hr, restingHR: 51, method: .whoop))
        XCTAssertNotNil(strain)
        XCTAssertEqual(strain ?? 0, 16.8, accuracy: 1.5)
    }

    /// More time at a higher heart rate never scores lower, and the axis tops out at 21.
    func testTheCurveRisesAndCapsAtTwentyOne() {
        let easy = whoopScale(StrainScorer.strain(block(100, minutes: 30, start: 0), restingHR: 50, method: .whoop)) ?? 0
        let hard = whoopScale(StrainScorer.strain(block(160, minutes: 30, start: 0), restingHR: 50, method: .whoop)) ?? 0
        XCTAssertGreaterThan(easy, 0)
        XCTAssertGreaterThan(hard, easy)
        let extreme = StrainScorer.strain(block(185, minutes: 180, start: 0), restingHR: 50, method: .whoop)
        XCTAssertEqual(extreme, StrainScorer.maxStrain)
    }

    /// The curve uses its own HRmax yardstick, so a profile max does not move it.
    func testTheProfileMaxDoesNotMoveTheCurve() {
        let hr = block(150, minutes: 40, start: 0)
        XCTAssertEqual(StrainScorer.strain(hr, maxHR: 175, restingHR: 50, method: .whoop),
                       StrainScorer.strain(hr, maxHR: 205, restingHR: 50, method: .whoop))
    }
}
