import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Yoop: resting HR, HRV, respiratory rate and skin temperature over the asleep spans
/// (`SleepStager.asleepVitalsEnabled`). Every vector here is synthetic and says so.
final class SleepStagerAsleepVitalsTests: XCTestCase {
    /// 2026-10-09 00:00 UTC, so a night built from here ends on that day.
    private let start = 1_791_504_000

    override func tearDown() {
        SleepStager.asleepVitalsEnabled = false
        super.tearDown()
    }

    /// 60 min awake, 300 min of light/deep/REM with a 20-min awakening at 150 min, then 60 min awake.
    private func hypnogram() -> [StageSegment] {
        var t = start
        func seg(_ minutes: Int, _ stage: String) -> StageSegment {
            defer { t += minutes * 60 }
            return StageSegment(start: t, end: t + minutes * 60, stage: stage)
        }
        return [seg(60, "wake"), seg(90, "light"), seg(20, "wake"), seg(60, "deep"), seg(90, "rem"),
                seg(60, "light"), seg(60, "wake")]
    }

    private var end: Int { start + 440 * 60 }

    /// 1 Hz HR: 62 bpm awake; asleep, 5-min blocks alternating 45 and 51 (mean 48, 5-min floor 45).
    private func heartRate(_ stages: [StageSegment]) -> [HRSample] {
        (start..<end).map { t in
            let stage = stages.first { t >= $0.start && t < $0.end }?.stage ?? "wake"
            if stage == "wake" { return HRSample(ts: t, bpm: 62) }
            return HRSample(ts: t, bpm: ((t - start) / 300).isMultiple(of: 2) ? 45 : 51)
        }
    }

    /// Deterministic standard normal draws (LCG + Box-Muller), so every fixture is reproducible.
    private struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        mutating func normal() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    /// Beat-accurate R-R from `from` to `to`: about 1000 ms, a breathing rhythm of `breathsPerMin` with a
    /// 50 ms swing (`rateAt` may vary it over time), and 15 ms of white noise. `amplitudeMs` 0 gives noise.
    private func rr(from: Int, to: Int, breathsPerMin: Double, amplitudeMs: Double = 50, seed: UInt64 = 1,
                    rateAt: ((Double) -> Double)? = nil) -> [RRInterval] {
        var noise = Noise(state: seed)
        var rows: [RRInterval] = []
        var t = Double(from)
        while t < Double(to) {
            let bpm = rateAt?(t) ?? breathsPerMin
            let ms = 1000 + amplitudeMs * sin(2 * Double.pi * bpm / 60 * t) + 15 * noise.normal()
            t += ms / 1000
            rows.append(RRInterval(ts: Int(t), rrMs: Int(ms.rounded())))
        }
        return rows
    }

    private let allAsleep = { (s: Int, e: Int) in [StageSegment(start: s, end: e, stage: "light")] }

    // MARK: - Asleep spans

    func testAsleepSpansKeepSleepStagesMergedAndClipped() {
        let spans = SleepStager.asleepSpans(hypnogram(), start: start + 30 * 60, end: start + 400 * 60)
        XCTAssertEqual(spans.map { $0.start - start }, [60 * 60, 170 * 60])
        XCTAssertEqual(spans.map { $0.end - start }, [150 * 60, 380 * 60])
        XCTAssertTrue(SleepStager.asleepSpans([StageSegment(start: start, end: end, stage: "wake")],
                                              start: start, end: end).isEmpty)
    }

    // MARK: - Resting HR

    /// The awake hour either side and the awakening in the middle do not lift it, and the 5-min floor does
    /// not pull it down: it is the mean while asleep.
    func testRestingHRIsTheMeanWhileAsleep() {
        let stages = hypnogram()
        let hr = heartRate(stages)
        XCTAssertEqual(SleepStager.asleepRestingHR(start: start, end: end, hr: hr, stages: stages), 48)
        XCTAssertEqual(SleepStager.sessionRestingHR(start: start, end: end, hr: hr), 45)
        let inBedMean = Double(hr.reduce(0) { $0 + $1.bpm }) / Double(hr.count)
        XCTAssertGreaterThan(inBedMean, 51)
    }

    func testRestingHRNeedsEnoughAsleepSamples() {
        let stages = [StageSegment(start: start, end: start + 29, stage: "light"),
                      StageSegment(start: start + 29, end: end, stage: "wake")]
        XCTAssertNil(SleepStager.asleepRestingHR(start: start, end: end, hr: heartRate(stages), stages: stages))
        XCTAssertNil(SleepStager.asleepRestingHR(start: start, end: end, hr: [], stages: hypnogram()))
    }

    // MARK: - HRV

    /// Awake windows with a large beat-to-beat swing are left out; asleep windows alone set the value.
    func testHRVUsesOnlyAsleepWindows() {
        let stages = hypnogram()
        var rows: [RRInterval] = []
        var t = start
        var i = 0
        while t < end {
            let awake = stages.first { t >= $0.start && t < $0.end }?.stage == "wake"
            let swing = awake ? 60 : 20
            rows.append(RRInterval(ts: t, rrMs: 1000 + (i.isMultiple(of: 2) ? swing : -swing) / 2))
            t += 1
            i += 1
        }
        XCTAssertEqual(SleepStager.asleepAvgHRV(start: start, end: end, rr: rows, stages: stages) ?? 0, 20,
                       accuracy: 0.01)
        let inBed = SleepStager.sessionAvgHRV(start: start, end: end, rr: rows) ?? 0
        XCTAssertGreaterThan(inBed, 25)
        // Everything asleep: identical to the whole-session value.
        XCTAssertEqual(SleepStager.asleepAvgHRV(start: start, end: end, rr: rows, stages: allAsleep(start, end)),
                       SleepStager.sessionAvgHRV(start: start, end: end, rr: rows))
    }

    // MARK: - Respiratory rate

    /// It tracks the breathing rate rather than landing on a grid: five injected rates, each recovered
    /// within 0.2 breaths/min. The old peak-picker can only return 60 / (k / 4) (15.0, 16.0, ...), so
    /// 15.3 is out of its reach.
    func testRespRateRecoversSeveralInjectedRates() {
        let e = start + 3600
        for bpm in [10.0, 12.7, 15.3, 18.4, 22.0] {
            let rows = rr(from: start, to: e, breathsPerMin: bpm, seed: UInt64(bpm * 10))
            let rate = SleepStager.asleepRespRate(rows, start: start, end: e, stages: allAsleep(start, e))
            XCTAssertNotNil(rate, "\(bpm) breaths/min")
            XCTAssertEqual(rate ?? 0, bpm, accuracy: 0.2, "\(bpm) breaths/min")
        }
    }

    /// White noise, and a breathing night with its beat order shuffled, carry no breathing rhythm: nil,
    /// not a plausible number.
    func testRespRateRefusesNoiseAndShuffledBeats() {
        let e = start + 90 * 60
        let noise = rr(from: start, to: e, breathsPerMin: 15, amplitudeMs: 0, seed: 7)
        XCTAssertNil(SleepStager.asleepRespRate(noise, start: start, end: e, stages: allAsleep(start, e)))
        let breathing = rr(from: start, to: e, breathsPerMin: 15, seed: 8)
        var values = breathing.map { $0.rrMs }
        var g = Noise(state: 9)
        for i in stride(from: values.count - 1, to: 0, by: -1) {
            values.swapAt(i, Int(g.uniform() * Double(i + 1)))
        }
        let shuffled = zip(breathing, values).map { RRInterval(ts: $0.0.ts, rrMs: $0.1) }
        XCTAssertNil(SleepStager.asleepRespRate(shuffled, start: start, end: e, stages: allAsleep(start, e)))
    }

    /// Only the asleep spans count: 20 breaths/min while awake, 12 while asleep, reads 12; all awake is nil.
    func testRespRateReadsOnlyAsleepSpans() {
        let mid = start + 3600, e = start + 2 * 3600
        let rows = rr(from: start, to: e, breathsPerMin: 0, seed: 3,
                      rateAt: { $0 < Double(mid) ? 20 : 12 })
        let stages = [StageSegment(start: start, end: mid, stage: "wake"),
                      StageSegment(start: mid, end: e, stage: "deep")]
        XCTAssertEqual(SleepStager.asleepRespRate(rows, start: start, end: e, stages: stages) ?? 0, 12, accuracy: 0.2)
        XCTAssertNil(SleepStager.asleepRespRate(rows, start: start, end: e,
                                                stages: [StageSegment(start: start, end: e, stage: "wake")]))
    }

    /// The shuffled control is seeded, so the same input gives the same answer every time.
    func testRespRateIsDeterministic() {
        let e = start + 3600
        let rows = rr(from: start, to: e, breathsPerMin: 14.2, seed: 11)
        let a = SleepStager.asleepRespRate(rows, start: start, end: e, stages: allAsleep(start, e))
        XCTAssertNotNil(a)
        XCTAssertEqual(a, SleepStager.asleepRespRate(rows, start: start, end: e, stages: allAsleep(start, e)))
    }

    /// Too little asleep R-R for ten clear windows: nil.
    func testRespRateNeedsEnoughWindows() {
        let e = start + 8 * 60
        let rows = rr(from: start, to: e, breathsPerMin: 15, seed: 5)
        XCTAssertNil(SleepStager.asleepRespRate(rows, start: start, end: e, stages: allAsleep(start, e)))
    }

    // MARK: - Through the day's analysis

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

    /// A provided night with no stored resting HR: the day's resting HR is the asleep mean with the switch
    /// on, and Strain is scored against that same value; off, NOOP's 5-min floor is unchanged. Banister,
    /// because it scores the low heart rates of a night at all.
    func testDayRestingHRAndStrainUseTheAsleepMean() throws {
        let stages = hypnogram()
        let hr = heartRate(stages)
        let session = SleepSession(start: start, end: end, efficiency: 0.7, stages: stages,
                                   restingHR: nil, avgHRV: nil)
        let day = AnalyticsEngine.dayString(end, offsetSec: 0)

        SleepStager.asleepVitalsEnabled = false
        let off = AnalyticsEngine.analyzeDay(day: day, hr: hr, profile: profile, providedSleep: [session],
                                             effortMethod: .banister)
        XCTAssertEqual(off.daily.restingHr, 45)

        SleepStager.asleepVitalsEnabled = true
        let on = AnalyticsEngine.analyzeDay(day: day, hr: hr, profile: profile, providedSleep: [session],
                                            effortMethod: .banister)
        XCTAssertEqual(on.daily.restingHr, 48)
        let hrmax = StrainScorer.tanakaHRmax(age: 30)
        let at48 = try XCTUnwrap(StrainScorer.strain(hr, maxHR: hrmax, restingHR: 48, method: .banister, sex: "male"))
        let at45 = try XCTUnwrap(StrainScorer.strain(hr, maxHR: hrmax, restingHR: 45, method: .banister, sex: "male"))
        XCTAssertEqual(try XCTUnwrap(on.strain), at48, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(off.strain), at45, accuracy: 1e-9)
        XCTAssertGreaterThan(at45, at48)
    }

    /// The night's respiratory rate and skin temperature come from the asleep spans with the switch on.
    func testDayRespAndSkinUseTheAsleepSpans() throws {
        let stages = hypnogram()
        let hr = heartRate(stages)
        let session = SleepSession(start: start, end: end, efficiency: 0.7, stages: stages,
                                   restingHR: nil, avgHRV: nil)
        let day = AnalyticsEngine.dayString(end, offsetSec: 0)
        // 16.4 breaths/min asleep, 22 awake.
        let rows = rr(from: start, to: end, breathsPerMin: 0, seed: 21, rateAt: { t in
            stages.first { Int(t) >= $0.start && Int(t) < $0.end }?.stage == "wake" ? 22 : 16.4
        })
        // 34.00 °C asleep, 31.00 °C awake (centidegrees on a 5/MG).
        let skin = hr.map { h in
            SkinTempSample(ts: h.ts, raw: stages.first { h.ts >= $0.start && h.ts < $0.end }?.stage == "wake" ? 3100 : 3400)
        }

        SleepStager.asleepVitalsEnabled = true
        let on = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rows, skinTemp: skin, profile: profile,
                                            providedSleep: [session])
        XCTAssertEqual(try XCTUnwrap(on.daily.respRateBpm), 16.4, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(on.nightlySkinTempC), 34.0, accuracy: 0.01)

        SleepStager.asleepVitalsEnabled = false
        let off = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rows, skinTemp: skin, profile: profile,
                                             providedSleep: [session])
        XCTAssertLessThan(try XCTUnwrap(off.nightlySkinTempC), 33.5)
    }

    /// The switch is part of the detection memo: flipping it on the same streams re-computes the session
    /// instead of serving the cached one.
    func testDetectSleepMemoKeysOnTheSwitch() {
        let s = start + 2 * 3600, duration = 120 * 60
        let gravity = (0..<duration).map { GravitySample(ts: s + $0, x: 0, y: 0, z: 1) }
        // 5-min blocks of 46 and 54 bpm: floor 46, mean 50.
        let hr = (0..<duration).map { HRSample(ts: s + $0, bpm: ($0 / 300).isMultiple(of: 2) ? 46 : 54) }

        SleepStager.asleepVitalsEnabled = false
        let cachedOff = SleepStager.detectSleep(hr: hr, gravity: gravity)
        SleepStager.asleepVitalsEnabled = true
        let cachedOn = SleepStager.detectSleep(hr: hr, gravity: gravity)
        let controlOn = SleepStager.detectSleep(hr: hr, gravity: gravity, traceSink: { _ in })
        XCTAssertFalse(controlOn.isEmpty, "the fixture must be a detected still night")
        XCTAssertEqual(cachedOn, controlOn)
        XCTAssertEqual(cachedOff.first?.restingHR, 46)
        XCTAssertNotEqual(cachedOff.first?.restingHR, cachedOn.first?.restingHR)
    }
}
