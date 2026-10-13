import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopProtocol

/// Yoop's stress (`WhoopStressCurve`): an absolute reading of each 5-minute window, so a calm day reads
/// calm, a hard day reads hard and nothing is forced into a 50/40/10 split. Heart rate above the resting
/// rate, a heart rate variability term only where the window supports one, activities left unscored.
final class WhoopStressCurveTests: XCTestCase {

    /// A multiple of 300, so windows start where the arithmetic says they do.
    private let t0 = 1_800_000_000

    /// One reading every 30 s for `windows` 5-minute windows from window `first`, all at `bpm`.
    private func hr(_ bpm: Int, windows: Range<Int>) -> [HRSample] {
        var samples: [HRSample] = []
        for w in windows {
            for i in 0..<10 { samples.append(HRSample(ts: t0 + w * 300 + i * 30, bpm: bpm)) }
        }
        return samples
    }

    private func shares(_ result: DaytimeStress.Result) -> [Double] {
        let levels = result.timeline.compactMap(\.level)
        let n = Double(levels.count)
        return [levels.filter { $0 < 1 }.count, levels.filter { $0 >= 1 && $0 < 2 }.count,
                levels.filter { $0 >= 2 }.count].map { Double($0) / n }
    }

    // MARK: Heart rate term

    func testBandsAgainstRestingHeartRate() {
        XCTAssertLessThan(WhoopStressCurve.level(meanHR: 52, restingHR: 50), 1.0)
        XCTAssertEqual(WhoopStressCurve.level(meanHR: 74, restingHR: 50), 1.5, accuracy: 1e-9)
        XCTAssertLessThan(WhoopStressCurve.level(meanHR: 80, restingHR: 50), 2.0)
        XCTAssertGreaterThanOrEqual(WhoopStressCurve.level(meanHR: 90, restingHR: 50), 2.0)
        XCTAssertLessThanOrEqual(WhoopStressCurve.level(meanHR: 200, restingHR: 50), 3.0)
        XCTAssertGreaterThan(WhoopStressCurve.level(meanHR: 41, restingHR: 50), 0)
    }

    /// The level only goes up with heart rate.
    func testLevelRisesWithHeartRate() {
        var levels: [Double] = []
        for bpm in stride(from: 45, through: 130, by: 5) {
            levels.append(WhoopStressCurve.level(meanHR: Double(bpm), restingHR: 50))
        }
        XCTAssertEqual(levels, levels.sorted())
    }

    /// The point of the rebuild: a calm day reads calm. Every window 10 bpm over rest is low; a rank
    /// against the user's own history would have called half of them medium or high.
    func testACalmDayReadsCalm() {
        let result = WhoopStressCurve.analyze(hr: hr(60, windows: 0..<96), restingHR: 50)
        XCTAssertEqual(result.timeline.count, 96)
        XCTAssertEqual(shares(result), [1, 0, 0])
        XCTAssertEqual(result.highStressMinutes, 0)
        XCTAssertLessThan(result.dayMean ?? 9, 1.0)
    }

    /// And a hard day reads hard: all windows 45 bpm over rest are high.
    func testAHardDayReadsHard() {
        let result = WhoopStressCurve.analyze(hr: hr(95, windows: 0..<96), restingHR: 50)
        XCTAssertEqual(shares(result), [0, 0, 1])
        XCTAssertEqual(result.highStressMinutes, 96 * 5)
        XCTAssertGreaterThanOrEqual(result.dayMean ?? 0, 2.0)
    }

    /// Nothing forces the shares: moving the whole day's heart rate moves the level and the shares, which a
    /// rank within the day's own distribution cannot do.
    func testTheSameShapeShiftedMovesTheLevel() {
        func day(offset: Int) -> DaytimeStress.Result {
            var samples: [HRSample] = []
            for w in 0..<96 {
                let bpm = 55 + (w % 24) * 2 + offset
                for i in 0..<10 { samples.append(HRSample(ts: t0 + w * 300 + i * 30, bpm: bpm)) }
            }
            return WhoopStressCurve.analyze(hr: samples, restingHR: 50)
        }
        let calm = day(offset: -5), usual = day(offset: 5), hot = day(offset: 25)
        XCTAssertLessThan(calm.dayMean ?? 9, usual.dayMean ?? 0)
        XCTAssertLessThan(usual.dayMean ?? 9, hot.dayMean ?? 0)
        XCTAssertGreaterThan(shares(calm)[0], shares(usual)[0])
        XCTAssertGreaterThan(shares(hot)[2], shares(usual)[2])
        XCTAssertNotEqual(shares(calm), [0.5, 0.4, 0.1])
        XCTAssertNotEqual(shares(hot), [0.5, 0.4, 0.1])
    }

    /// Asleep, heart rate sits near the resting rate and reads about a half.
    func testSleepNearRestingReadsAboutHalf() {
        let samples = hr(52, windows: 0..<96)
        let result = WhoopStressCurve.analyze(hr: samples, restingHR: 50, sleepSpans: [t0...(t0 + 96 * 300)])
        for p in result.timeline {
            XCTAssertGreaterThan(p.level ?? 0, 0.3)
            XCTAssertLessThan(p.level ?? 9, 0.7)
        }
    }

    /// One hour at rest, then an hour 45 bpm up: 12 low windows then 12 high, 60 minutes high.
    func testAnHourHighIsCountedAndTheRestIsNot() {
        let result = WhoopStressCurve.analyze(hr: hr(52, windows: 0..<12) + hr(95, windows: 12..<24), restingHR: 50)
        XCTAssertEqual(result.timeline.count, 24)
        XCTAssertEqual(result.highStressMinutes, 60)
        XCTAssertFalse(result.sustainedHigh)
        XCTAssertLessThan(result.timeline.first?.level ?? 3, 1.0)
    }

    /// Three hours high in a row is the sustained run, and a workout breaks it.
    func testSustainedHighNeedsThreeScoredHours() {
        let hard = hr(95, windows: 0..<36)
        XCTAssertTrue(WhoopStressCurve.analyze(hr: hard, restingHR: 50).sustainedHigh)
        let broken = WhoopStressCurve.analyze(hr: hard, restingHR: 50, excluded: [(t0 + 35 * 300)...(t0 + 36 * 300)])
        XCTAssertFalse(broken.sustainedHigh)
    }

    func testTooSparseOrNoRestingRateScoresNothing() {
        let sparse = [HRSample(ts: t0, bpm: 80), HRSample(ts: t0 + 30, bpm: 80)]
        XCTAssertTrue(WhoopStressCurve.analyze(hr: sparse, restingHR: 50).timeline.isEmpty)
        XCTAssertTrue(WhoopStressCurve.analyze(hr: hr(80, windows: 0..<4), restingHR: 0).timeline.isEmpty)
        XCTAssertTrue(WhoopStressCurve.analyze(hr: [], restingHR: 50).timeline.isEmpty)
    }

    // MARK: Heart rate variability term

    func testLowVariabilityRaisesTheLevelAndHighLowersIt() {
        let plain = WhoopStressCurve.level(meanHR: 74, restingHR: 50)
        XCTAssertGreaterThan(WhoopStressCurve.level(meanHR: 74, restingHR: 50, hrvShiftLn: 0.5), plain)
        XCTAssertLessThan(WhoopStressCurve.level(meanHR: 74, restingHR: 50, hrvShiftLn: -0.5), plain)
        XCTAssertEqual(WhoopStressCurve.level(meanHR: 74, restingHR: 50, hrvShiftLn: 0), plain, accuracy: 1e-12)
    }

    /// One odd window cannot swing the level past the cap.
    func testTheVariabilityShiftIsCapped() {
        let atCap = WhoopStressCurve.level(meanHR: 74, restingHR: 50, hrvShiftLn: WhoopStressCurve.hrvCapLn)
        XCTAssertEqual(WhoopStressCurve.level(meanHR: 74, restingHR: 50, hrvShiftLn: 5), atCap, accuracy: 1e-12)
        let below = WhoopStressCurve.level(meanHR: 74, restingHR: 50, hrvShiftLn: -WhoopStressCurve.hrvCapLn)
        XCTAssertEqual(WhoopStressCurve.level(meanHR: 74, restingHR: 50, hrvShiftLn: -5), below, accuracy: 1e-12)
        // 6 bpm is a third of a zone at the steepest part of the curve.
        XCTAssertLessThan(atCap - WhoopStressCurve.level(meanHR: 74, restingHR: 50), 0.45)
    }

    /// 150 beats in a window, alternating 800 and 830 ms: RMSSD 30 ms.
    private func beats(window w: Int, count: Int = 150, artifactEvery: Int? = nil) -> [RRInterval] {
        (0..<count).map { i in
            var ms = i % 2 == 0 ? 800 : 830
            if let every = artifactEvery, i % every == every - 1 { ms = 1_300 }
            return RRInterval(ts: t0 + w * 300 + i * 2, rrMs: ms)
        }
    }

    /// 60 motion samples a window, 0.01 g unless told otherwise.
    private func motion(window w: Int, g: Double = 0.01, count: Int = 60) -> [GravitySample] {
        (0..<count).map { GravitySample(ts: t0 + w * 300 + $0 * 5, x: 0, y: 0, z: 1, dynAccel: g) }
    }

    func testACleanStillWindowSupportsHeartRateVariability() {
        let windows = WhoopStressCurve.hrvWindows(rr: beats(window: 2), gravity: motion(window: 2))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.startTs, t0 + 2 * 300)
        XCTAssertEqual(windows.first?.rmssd ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(windows.first?.ln ?? 0, log(30), accuracy: 0.02)
    }

    func testTooFewBeatsDoNotSupportHeartRateVariability() {
        XCTAssertEqual(WhoopStressCurve.hrvWindows(rr: beats(window: 0, count: 100), gravity: motion(window: 0)).count, 1)
        XCTAssertTrue(WhoopStressCurve.hrvWindows(rr: beats(window: 0, count: 99), gravity: motion(window: 0)).isEmpty)
    }

    /// A tenth of the differences over 20% passes, a fifth does not.
    func testArtifactsGateTheWindow() {
        XCTAssertEqual(WhoopStressCurve.hrvWindows(rr: beats(window: 0, artifactEvery: 20), gravity: motion(window: 0)).count, 1)
        XCTAssertTrue(WhoopStressCurve.hrvWindows(rr: beats(window: 0, artifactEvery: 10), gravity: motion(window: 0)).isEmpty)
    }

    func testMotionGatesTheWindow() {
        XCTAssertTrue(WhoopStressCurve.hrvWindows(rr: beats(window: 0), gravity: motion(window: 0, g: 0.2)).isEmpty)
        XCTAssertEqual(WhoopStressCurve.hrvWindows(rr: beats(window: 0), gravity: motion(window: 0, g: 0.04)).count, 1)
        // No motion record, or too few samples to vouch for stillness: scored by heart rate alone.
        XCTAssertTrue(WhoopStressCurve.hrvWindows(rr: beats(window: 0), gravity: []).isEmpty)
        XCTAssertTrue(WhoopStressCurve.hrvWindows(rr: beats(window: 0), gravity: motion(window: 0, count: 29)).isEmpty)
        let noDyn = (0..<60).map { GravitySample(ts: t0 + $0 * 5, x: 0, y: 0, z: 1, dynAccel: nil) }
        XCTAssertTrue(WhoopStressCurve.hrvWindows(rr: beats(window: 0), gravity: noDyn).isEmpty)
    }

    func testArtifactShareCountsJumpsOverTwentyPercent() {
        XCTAssertEqual(WhoopStressCurve.artifactShare([800, 810, 1_200, 810]), 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(WhoopStressCurve.artifactShare([800, 800, 800]), 0)
        XCTAssertEqual(WhoopStressCurve.artifactShare([800]), 1, "one beat has no differences to vouch for it")
    }

    // MARK: The baseline

    private func windows(count: Int, from first: Int = 0, ln: Double) -> [WhoopStressCurve.HRVWindow] {
        (first..<(first + count)).map {
            WhoopStressCurve.HRVWindow(startTs: t0 + $0 * 300, rmssd: exp(ln), beats: 200, artifactShare: 0, motionG: 0.01)
        }
    }

    func testTheBaselineNeedsEnoughCleanWindowsOfEachState() {
        XCTAssertNil(WhoopStressCurve.baseline(windows: windows(count: 29, ln: 3.8), sleepSpans: []).awake)
        XCTAssertEqual(WhoopStressCurve.baseline(windows: windows(count: 30, ln: 3.8), sleepSpans: []).awake ?? 0, 3.8, accuracy: 1e-9)
        // Sleeping windows are compared with sleeping ones: 30 asleep windows give no awake baseline.
        let asleepOnly = WhoopStressCurve.baseline(windows: windows(count: 30, ln: 4.4), sleepSpans: [t0...(t0 + 40 * 300)])
        XCTAssertNil(asleepOnly.awake)
        XCTAssertEqual(asleepOnly.asleep ?? 0, 4.4, accuracy: 1e-9)
    }

    func testTheBaselineIsTheMedianAndLeavesActivitiesOut() {
        let calm = windows(count: 31, ln: 3.8)
        let afterWorkout = windows(count: 10, from: 40, ln: 2.5)
        let medianAll = WhoopStressCurve.baseline(windows: calm + afterWorkout, sleepSpans: [])
        XCTAssertEqual(medianAll.awake ?? 0, 3.8, accuracy: 1e-9)
        let skewed = windows(count: 20, ln: 3.8) + windows(count: 25, from: 20, ln: 2.5)
        XCTAssertEqual(WhoopStressCurve.baseline(windows: skewed, sleepSpans: []).awake ?? 0, 2.5, accuracy: 1e-9)
        let excluded = [(t0 + 20 * 300)...(t0 + 45 * 300)]
        XCTAssertNil(WhoopStressCurve.baseline(windows: skewed, sleepSpans: [], excluded: excluded).awake,
                     "the 25 windows inside the activity are left out, leaving 20, under the minimum")
    }

    // MARK: Scoring with variability

    /// Twelve windows 24 bpm over rest (level 1.5); window 5 has clean variability.
    private func flatDay(hrvWindow: Int?, rmssd: Double, baseline: WhoopStressCurve.HRVBaseline,
                         sleepSpans: [ClosedRange<Int>] = []) -> DaytimeStress.Result {
        let hrv = hrvWindow.map {
            [WhoopStressCurve.HRVWindow(startTs: t0 + $0 * 300, rmssd: rmssd, beats: 200, artifactShare: 0, motionG: 0.01)]
        } ?? []
        return WhoopStressCurve.analyze(hr: hr(74, windows: 0..<12), restingHR: 50, hrv: hrv, baseline: baseline,
                                        sleepSpans: sleepSpans)
    }

    func testVariabilityMovesOnlyTheWindowThatHasIt() {
        let baseline = WhoopStressCurve.HRVBaseline(awake: log(40), asleep: log(80))
        let low = flatDay(hrvWindow: 5, rmssd: 25, baseline: baseline)
        let high = flatDay(hrvWindow: 5, rmssd: 64, baseline: baseline)
        let plain = flatDay(hrvWindow: nil, rmssd: 0, baseline: baseline)
        for (i, p) in low.timeline.enumerated() {
            if i == 5 {
                XCTAssertGreaterThan(p.level ?? 0, 1.5)
                XCTAssertEqual(p.rmssd ?? 0, 25, accuracy: 1e-9)
            } else {
                XCTAssertEqual(p.level ?? 0, 1.5, accuracy: 1e-9)
                XCTAssertNil(p.rmssd)
            }
        }
        XCTAssertLessThan(high.timeline[5].level ?? 9, 1.5)
        XCTAssertFalse(low.hrOnlyFallback)
        XCTAssertTrue(plain.hrOnlyFallback, "no clean window: the page must not claim variability was used")
    }

    func testNoBaselineMeansHeartRateAlone() {
        let day = flatDay(hrvWindow: 5, rmssd: 25, baseline: .none)
        XCTAssertEqual(day.timeline[5].level ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertNil(day.timeline[5].rmssd)
        XCTAssertTrue(day.hrOnlyFallback)
    }

    /// A sleeping window is compared with the sleeping baseline, not the waking one.
    func testAsleepWindowsUseTheAsleepBaseline() {
        let awakeOnly = WhoopStressCurve.HRVBaseline(awake: log(40), asleep: nil)
        let asleep = flatDay(hrvWindow: 5, rmssd: 25, baseline: awakeOnly, sleepSpans: [t0...(t0 + 12 * 300)])
        XCTAssertNil(asleep.timeline[5].rmssd)
        XCTAssertEqual(asleep.timeline[5].level ?? 0, 1.5, accuracy: 1e-9)
        let both = WhoopStressCurve.HRVBaseline(awake: log(40), asleep: log(80))
        let compared = flatDay(hrvWindow: 5, rmssd: 25, baseline: both, sleepSpans: [t0...(t0 + 12 * 300)])
        let waking = flatDay(hrvWindow: 5, rmssd: 25, baseline: both)
        XCTAssertGreaterThan(compared.timeline[5].level ?? 0, waking.timeline[5].level ?? 9,
                             "25 ms is further below an 80 ms sleeping baseline than below a 40 ms waking one")
    }

    // MARK: Activities

    func testAnActivityIsShownNotScored() {
        // Windows 4 to 7 overlap the activity (it starts partway into window 4 and ends inside window 7).
        let span = (t0 + 4 * 300 + 120)...(t0 + 7 * 300 + 60)
        let result = WhoopStressCurve.analyze(hr: hr(95, windows: 0..<12), restingHR: 50, excluded: [span])
        XCTAssertEqual(result.timeline.count, 12)
        let masked = result.timeline.enumerated().filter { $0.element.maskedForActivity }.map(\.offset)
        XCTAssertEqual(masked, [4, 5, 6, 7])
        XCTAssertTrue(result.timeline.filter(\.maskedForActivity).allSatisfy { $0.level == nil && $0.meanHR != nil })
        XCTAssertEqual(result.highStressMinutes, 8 * 5, "only the eight scored windows count")
        XCTAssertEqual(shares(result), [0, 0, 1])
        XCTAssertEqual(result.activityMaskedHours, 0, "20 minutes rounds to no whole hour")
        XCTAssertEqual(WhoopStressCurve.activitySpans(result), [(t0 + 4 * 300)...(t0 + 8 * 300 - 1)])
    }

    func testActivityHoursAreCountedAsWholeHours() {
        let result = WhoopStressCurve.analyze(hr: hr(95, windows: 0..<24), restingHR: 50,
                                              excluded: [t0...(t0 + 12 * 300)])
        XCTAssertEqual(result.activityMaskedHours, 1)
        XCTAssertEqual(result.scored.count, 12)
    }

    func testSeparateActivitiesStaySeparateSpans() {
        let result = WhoopStressCurve.analyze(hr: hr(60, windows: 0..<12), restingHR: 50,
                                              excluded: [(t0 + 1 * 300)...(t0 + 2 * 300 + 1), (t0 + 6 * 300)...(t0 + 6 * 300 + 30)])
        XCTAssertEqual(WhoopStressCurve.activitySpans(result),
                       [(t0 + 300)...(t0 + 3 * 300 - 1), (t0 + 6 * 300)...(t0 + 7 * 300 - 1)])
    }

    /// An all-activity span leaves a result with its points but no level: not an empty day, and not scored.
    func testADayOfNothingButActivityHasNoMeanAndNoPeak() {
        let result = WhoopStressCurve.analyze(hr: hr(120, windows: 0..<4), restingHR: 50, excluded: [t0...(t0 + 4 * 300)])
        XCTAssertEqual(result.timeline.count, 4)
        XCTAssertNil(result.dayMean)
        XCTAssertNil(result.peak)
        XCTAssertEqual(result.highStressMinutes, 0)
    }

    // MARK: Windows and zones

    func testWindowsAreFiveMinutesOnTheUnixClockAndNeedThreeReadings() {
        var samples = hr(60, windows: 0..<2)
        samples += [HRSample(ts: t0 + 2 * 300, bpm: 60), HRSample(ts: t0 + 2 * 300 + 30, bpm: 60)]
        let result = WhoopStressCurve.analyze(hr: samples, restingHR: 50)
        XCTAssertEqual(result.timeline.map(\.startTs), [t0, t0 + 300])
        XCTAssertEqual(WhoopStressCurve.bucketStart(t0 + 299), t0)
        XCTAssertEqual(WhoopStressCurve.bucketStart(t0 + 300), t0 + 300)
    }

    func testZoneBands() {
        XCTAssertEqual(WhoopStressCurve.lowCeiling, 1.0)
        XCTAssertEqual(DaytimeStress.highBandFloor, 2.0)
    }
}
