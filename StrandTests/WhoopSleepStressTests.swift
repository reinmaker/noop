import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

/// The Sleep screen's stress: the HIGH SLEEP STRESS percent and its bands (lower is better), the stress
/// level under the heart-rate readout, and the stage the readout names.
final class WhoopSleepStressTests: XCTestCase {

    private typealias Band = WhoopSleepContributors.Band

    private func stressBand(_ percent: Double) -> Band {
        Band.classify(percent, sufficient: SleepStressNight.sufficientMaxPercent,
                      optimal: SleepStressNight.optimalMaxPercent, lowerIsBetter: true)
    }

    func testHighPercentIsTheHighShareOfScoredSleep() {
        XCTAssertEqual(SleepStressNight.highStressPercent(bandMinutes: [300, 120, 0]), 0)
        XCTAssertEqual(SleepStressNight.highStressPercent(bandMinutes: [60, 30, 10]) ?? -1, 10, accuracy: 1e-9)
        XCTAssertNil(SleepStressNight.highStressPercent(bandMinutes: [0, 0, 0]))
        XCTAssertNil(SleepStressNight.highStressPercent(bandMinutes: []))
    }

    /// WHOOP: 0 to 5% optimal, 5 to 15% sufficient, above 15% poor.
    func testHighSleepStressBandsLowerIsBetter() {
        XCTAssertEqual(stressBand(0), .optimal)
        XCTAssertEqual(stressBand(5), .optimal)
        XCTAssertEqual(stressBand(5.1), .sufficient)
        XCTAssertEqual(stressBand(15), .sufficient)
        XCTAssertEqual(stressBand(15.1), .poor)
        XCTAssertEqual(stressBand(60), .poor)
    }

    /// The other three rows keep their higher-is-better floors.
    func testHigherIsBetterRowsUnchanged() {
        XCTAssertEqual(Band.classify(85, sufficient: 70, optimal: 85), .optimal)
        XCTAssertEqual(Band.classify(84.9, sufficient: 70, optimal: 85), .sufficient)
        XCTAssertEqual(Band.classify(70, sufficient: 70, optimal: 85), .sufficient)
        XCTAssertEqual(Band.classify(69.9, sufficient: 70, optimal: 85), .poor)
    }

    /// Five-minute points: ten low, one medium, one high is an hour with 5 minutes high.
    func testMakeCountsFiveMinutesPerReading() {
        let start = 1_800_000_000
        let levels = Array(repeating: 0.5, count: 10) + [1.5, 2.5]
        let points = levels.enumerated().map { i, level in
            DaytimeStress.HourPoint(hour: 0, startTs: start + i * 300, level: level, meanHR: 55, rmssd: nil)
        }
        let result = DaytimeStress.Result(hours: points, sustainedHigh: false, sustainedRun: 0,
                                          dayMean: nil, peak: nil, timeline: points)
        let night = SleepStressNight.make(result)
        XCTAssertEqual(night?.bandMinutes, [50, 5, 5])
        XCTAssertEqual(night?.highPercent ?? -1, 5.0 / 60.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(night?.level(at: start + 11 * 300 + 120), 2.5)
        XCTAssertEqual(night?.level(at: start + 10 * 300), 1.5)
        XCTAssertNil(night?.level(at: start + 12 * 300))
        XCTAssertNil(night?.level(at: start - 1))
        XCTAssertNil(SleepStressNight.make(.empty))
    }

    /// A calm night reads 0% high (optimal, as WHOOP shows on a normal night); an hour 35 bpm over rest
    /// in an 8-hour night reads 12.5% (sufficient).
    func testNightFromHeartRate() throws {
        let start = 1_800_000_000
        // Eight hours, one reading every 30 s, the last `highMinutes` of it 35 bpm over rest.
        func night(highMinutes: Int) -> SleepStressNight? {
            let hr = (0..<960).map { i in
                HRSample(ts: start + i * 30, bpm: i * 30 >= (480 - highMinutes) * 60 ? 85 : 52)
            }
            return SleepStressNight.make(WhoopStressCurve.analyze(hr: hr, restingHR: 50))
        }
        let calm = try XCTUnwrap(night(highMinutes: 0)?.highPercent)
        XCTAssertEqual(calm, 0)
        XCTAssertEqual(stressBand(calm), .optimal)
        let restless = try XCTUnwrap(night(highMinutes: 60))
        XCTAssertEqual(restless.bandMinutes, [420, 0, 60])
        let restlessPercent = try XCTUnwrap(restless.highPercent)
        XCTAssertEqual(restlessPercent, 12.5, accuracy: 1e-9)
        XCTAssertEqual(stressBand(restlessPercent), .sufficient)
    }

    func testRecordedStageReadsTheRealTimeline() {
        let start = 1_000_000
        let session = CachedSleepSession(startTs: start, endTs: start + 2_400, efficiency: nil,
                                         restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let staged = Night(session: session, stages: Stages(awake: 0, light: 10, deep: 20, rem: 10),
                           realSegments: [SleepInterval(stage: .light, start: 0, end: 600),
                                          SleepInterval(stage: .deep, start: 600, end: 1_800),
                                          SleepInterval(stage: .rem, start: 1_800, end: 2_400)])
        XCTAssertEqual(staged.recordedStage(at: start + 120), .light)
        XCTAssertEqual(staged.recordedStage(at: start + 600), .deep)
        XCTAssertEqual(staged.recordedStage(at: start + 2_399), .rem)
        XCTAssertNil(staged.recordedStage(at: start + 2_400))
        XCTAssertNil(staged.recordedStage(at: start - 60))
        // Totals only (an import): the moment's stage is not known, so none is named.
        let totalsOnly = Night(session: session, stages: Stages(awake: 0, light: 10, deep: 20, rem: 10))
        XCTAssertNil(totalsOnly.recordedStage(at: start + 120))
    }
}
