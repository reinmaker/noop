import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopProtocol

/// WHOOP-style stress: resting reads low, about 20 bpm over rest medium, 30 and up high.
final class WhoopStressCurveTests: XCTestCase {

    func testBandsAgainstRestingHeartRate() {
        XCTAssertLessThan(WhoopStressCurve.level(meanHR: 52, restingHR: 50), 1.0)
        XCTAssertEqual(WhoopStressCurve.level(meanHR: 70, restingHR: 50), 1.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(WhoopStressCurve.level(meanHR: 80, restingHR: 50), 2.0)
        XCTAssertLessThanOrEqual(WhoopStressCurve.level(meanHR: 200, restingHR: 50), 3.0)
    }

    /// One reading every 30 s: an hour at rest, then an hour 35 bpm up.
    func testAnHourHighIsCountedAndTheRestIsNot() {
        var hr: [HRSample] = []
        for i in 0..<120 { hr.append(HRSample(ts: 1_800_000_000 + i * 30, bpm: 52)) }
        for i in 120..<240 { hr.append(HRSample(ts: 1_800_000_000 + i * 30, bpm: 85)) }
        let result = WhoopStressCurve.analyze(hr: hr, restingHR: 50)
        XCTAssertEqual(result.timeline.count, 24)
        XCTAssertEqual(result.highStressMinutes, 60)
        XCTAssertFalse(result.sustainedHigh)
        XCTAssertLessThan(result.timeline.first?.level ?? 3, 1.0)
    }

    /// With a day of history the level is the bucket's place in it: 35% low, 52% medium, 13% high.
    func testHistoryPlacesTheBucket() {
        let reference = (0..<300).map { Double(50 + $0 / 10) }   // 50...79 bpm
        let sorted = reference.sorted()
        XCTAssertLessThan(WhoopStressCurve.level(meanHR: 52, reference: sorted), 1.0)
        let middle = WhoopStressCurve.level(meanHR: 65, reference: sorted)
        XCTAssertTrue((1.0..<2.0).contains(middle))
        XCTAssertGreaterThanOrEqual(WhoopStressCurve.level(meanHR: 78, reference: sorted), 2.0)
        XCTAssertEqual(WhoopStressCurve.level(meanHR: 120, reference: sorted), 3.0, accuracy: 1e-9)
    }

    func testTooSparseOrNoRestingRateScoresNothing() {
        let hr = [HRSample(ts: 1_800_000_000, bpm: 80), HRSample(ts: 1_800_000_030, bpm: 80)]
        XCTAssertTrue(WhoopStressCurve.analyze(hr: hr, restingHR: 50).timeline.isEmpty)
        XCTAssertTrue(WhoopStressCurve.analyze(hr: hr, restingHR: 0).timeline.isEmpty)
    }
}
