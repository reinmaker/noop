import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The Yoop step rules (`StepsCounter.yoopCountingEnabled`) and the Yoop active / resting energy split
/// (`Calories.estimateYoopDayEnergy`). Both switches are off by default; each test turns them on and
/// `tearDown` puts them back, so the NOOP tests elsewhere keep their default path.
final class YoopStepsEnergyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StepsCounter.yoopCountingEnabled = true
        Calories.yoopEnergyEnabled = true
    }

    override func tearDown() {
        StepsCounter.yoopCountingEnabled = false
        Calories.yoopEnergyEnabled = false
        super.tearDown()
    }

    private func s(_ ts: Int, _ counter: Int, _ cls: Int? = 1) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: cls)
    }

    private func count(_ samples: [StepSample], sleeps: [SleepSession] = []) -> SleepAwareStepCounter.Count {
        SleepAwareStepCounter.count(samples, sleepSessions: sleeps)
    }

    // MARK: - Steps

    func testStillReleaseBatchJustBeforeTheWalkCounts() {
        // The pedometer releases the 6 steps it held, labelled still, one second before the walk label.
        let samples = [s(9, 100, 0), s(10, 106, 0), s(11, 108, 1), s(12, 110, 1)]
        XCTAssertEqual(count(samples).totalTicks, 10)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(count(samples).totalTicks, 4)
    }

    func testStillReleaseBatchJustAfterAWalkCounts() {
        let samples = [s(9, 100, 1), s(10, 102, 1), s(12, 109, 0)]
        XCTAssertEqual(count(samples).totalTicks, 9)
    }

    func testStillReleaseBatchFarFromAnyWalkIsRejected() {
        let result = count([s(9, 100, 0), s(10, 106, 0), s(100, 106, 0), s(101, 108, 1)])
        XCTAssertEqual(result.totalTicks, 2)
        XCTAssertEqual(result.rejectedActivityClassTicks, 6)
    }

    func testStillTicksOutsideTheReleaseSizeAreRejected() {
        let result = count([s(9, 100, 0), s(10, 103, 0), s(11, 105, 1)])
        XCTAssertEqual(result.totalTicks, 2)
        XCTAssertEqual(result.rejectedActivityClassTicks, 3)
    }

    func testHeldReleaseSettlesAcrossPages() {
        let accumulator = SleepAwareStepCounter.Accumulator(sleepSessions: [], hasActivityClasses: true)
        accumulator.acceptPage([s(9, 100, 0), s(10, 107, 0)])
        accumulator.acceptPage([s(11, 109, 1)])
        XCTAssertEqual(accumulator.finish().totalTicks, 9)
    }

    func testReleaseStillHeldAtTheEndIsRejected() {
        let result = count([s(9, 100, 1), s(100, 100, 0), s(101, 106, 0)])
        XCTAssertEqual(result.totalTicks, 0)
        XCTAssertEqual(result.rejectedActivityClassTicks, 6)
    }

    func testWalkReleaseOfNineInOneSecondCounts() {
        XCTAssertEqual(count([s(0, 100), s(1, 109)]).totalTicks, 9)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(count([s(0, 100), s(1, 109)]).totalTicks, 0)
    }

    func testAbsurdOneSecondJumpIsRejected() {
        // A release plus 3.5 steps a second allows 12 in one second.
        XCTAssertEqual(count([s(0, 100), s(1, 112)]).totalTicks, 12)
        let result = count([s(0, 100), s(1, 113)])
        XCTAssertEqual(result.totalTicks, 0)
        XCTAssertEqual(result.rejectedImplausibleTicks, 13)
    }

    func testDropoutTicksCountWhateverTheClosingLabel() {
        // 1,543 steps across a 2,192 s dropout while worn, closed by a still second (9 Oct 2026).
        let samples = [s(0, 31_055, 0), s(2_192, 32_598, 0)]
        XCTAssertEqual(count(samples).totalTicks, 1_543)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(count(samples).totalTicks, 0)
    }

    func testDropoutFasterThanAnyCadenceIsRejected() {
        // 100 s allow 9 + 350 = 359.
        XCTAssertEqual(count([s(0, 1_000), s(100, 1_359)]).totalTicks, 359)
        XCTAssertEqual(count([s(0, 1_000), s(100, 1_360)]).rejectedImplausibleTicks, 360)
    }

    func testCounterDecreaseIsAResetNotAWrap() {
        // 3 h dropout, counter 30,000 then 5: the wrapped 35,541 would pass the cadence limit, but a
        // decrease counts only as a wrap under the old 512 guard. Counting resumes from the new value.
        let result = count([s(0, 30_000), s(10_800, 5), s(10_801, 7)])
        XCTAssertEqual(result.totalTicks, 2)
        XCTAssertEqual(result.rejectedImplausibleTicks, 35_541)
    }

    func testU16WrapStillCounts() {
        XCTAssertEqual(count([s(0, 65_534), s(1, 2)]).totalTicks, 4)
    }

    func testStepsInWindowFollowsTheSwitch() {
        let samples = [s(9, 100, 0), s(10, 106, 0), s(11, 108, 1), s(12, 110, 1)]
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 10)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 4)
    }

    func testMinuteTicksHoldExactlyTheAcceptedTicks() {
        // Two minutes awake, then a night with one isolated bed tick and one coherent walk.
        let night = SleepSession(start: 1_000, end: 2_000, efficiency: 1, stages: [], restingHR: nil, avgHRV: nil)
        let samples = [s(50, 100), s(59, 102), s(61, 105), s(62, 106, 0),
                       s(1_100, 106), s(1_101, 107),
                       s(1_500, 107), s(1_501, 109), s(1_502, 111), s(1_503, 113), s(1_504, 115), s(1_505, 117)]
        let accumulator = SleepAwareStepCounter.Accumulator(sleepSessions: [night], hasActivityClasses: true,
                                                            recordsMinutes: true)
        let result = accumulator.acceptPage(samples).finish()
        XCTAssertEqual(result.totalTicks, 15)
        XCTAssertEqual(result.rejectedIsolatedSleepTicks, 1)
        XCTAssertEqual(accumulator.acceptedTicksByMinute, [0: 2, 1: 3, 25: 10])
    }

    // MARK: - Energy

    private let man = UserProfile(weightKg: 82, heightCm: 183, age: 42, sex: "male")

    func testMifflinStJeor() {
        XCTAssertEqual(Calories.mifflinStJeorKcalPerDay(man), 1_758.75, accuracy: 1e-9)
        let woman = UserProfile(weightKg: 82, heightCm: 183, age: 42, sex: "female")
        XCTAssertEqual(Calories.mifflinStJeorKcalPerDay(woman), 1_592.75, accuracy: 1e-9)
        let nonbinary = UserProfile(weightKg: 82, heightCm: 183, age: 42, sex: "nonbinary")
        XCTAssertEqual(Calories.mifflinStJeorKcalPerDay(nonbinary), 1_675.75, accuracy: 1e-9)
    }

    func testRestingCoversTheWholeWindowNotOnlyTheSamples() {
        let energy = Calories.estimateYoopDayEnergy([HRSample(ts: 0, bpm: 50)], stepsByMinute: [:],
                                                    windowSeconds: 43_200, profile: man, hrmax: 178.6,
                                                    restingHR: 51)
        XCTAssertEqual(energy.restingKcal, 1_758.75 / 2, accuracy: 1e-9)
        XCTAssertEqual(energy.activeKcal, 0, accuracy: 1e-12)
    }

    func testWalkingMinuteIsPricedByItsSteps() {
        // 120 steps at 95 bpm, below half the reserve: the ACSM walking cost, not Keytel.
        let hr = (0..<60).map { HRSample(ts: $0, bpm: 95) }
        let energy = Calories.estimateYoopDayEnergy(hr, stepsByMinute: [0: 120], windowSeconds: 60,
                                                    profile: man, hrmax: 178.6, restingHR: 51)
        let kcalPerStep = 0.0005 * 82 * 0.415 * 1.83
        XCTAssertEqual(energy.activeKcal, 120 * kcalPerStep, accuracy: 1e-9)
    }

    func testMinuteWithoutStepsAboveTheFlexPointIsPricedByHeartRate() {
        let hr = (0..<60).map { HRSample(ts: $0, bpm: 100) }
        let energy = Calories.estimateYoopDayEnergy(hr, stepsByMinute: [:], windowSeconds: 60,
                                                    profile: man, hrmax: 178.6, restingHR: 51)
        // Keytel 2005 fitness-adjusted (male), Uth VO2max, less Mifflin BMR, for 60 one-second samples.
        let vo2max = 15.3 * 178.6 / 51
        let grossKcalPerS = (0.634 * 100 + 0.404 * vo2max + 0.394 * 82 + 0.271 * 42 - 95.7735) / 251.04
        XCTAssertEqual(energy.activeKcal, 60 * (grossKcalPerS - 1_758.75 / 86_400), accuracy: 1e-9)
    }

    func testHeartRateBelowTheFlexPointCarriesNoActiveEnergy() {
        // Flex = 51 + 40 = 91 bpm.
        let hr = (0..<60).map { HRSample(ts: $0, bpm: 90) }
        let energy = Calories.estimateYoopDayEnergy(hr, stepsByMinute: [:], windowSeconds: 60,
                                                    profile: man, hrmax: 178.6, restingHR: 51)
        XCTAssertEqual(energy.activeKcal, 0, accuracy: 1e-12)
    }

    func testVigorousStepMinuteTakesTheHigherHeartRatePrice() {
        // 150 bpm is above half the reserve (114.8 bpm): running, where steps at walking cost undercount.
        let hr = (0..<60).map { HRSample(ts: $0, bpm: 150) }
        let withSteps = Calories.estimateYoopDayEnergy(hr, stepsByMinute: [0: 160], windowSeconds: 60,
                                                       profile: man, hrmax: 178.6, restingHR: 51)
        let heartOnly = Calories.estimateYoopDayEnergy(hr, stepsByMinute: [:], windowSeconds: 60,
                                                       profile: man, hrmax: 178.6, restingHR: 51)
        XCTAssertGreaterThan(heartOnly.activeKcal, 160 * 0.0005 * 82 * 0.415 * 1.83)
        XCTAssertEqual(withSteps.activeKcal, heartOnly.activeKcal, accuracy: 1e-9)
    }

    func testStepsWithoutHeartRateStillCount() {
        // Steps banked across a heart-rate dropout are priced by their walking cost.
        let energy = Calories.estimateYoopDayEnergy([HRSample(ts: 0, bpm: 60)], stepsByMinute: [36: 1_543],
                                                    windowSeconds: 3_600, profile: man, hrmax: 178.6,
                                                    restingHR: 51)
        XCTAssertEqual(energy.activeKcal, 1_543 * 0.0005 * 82 * 0.415 * 1.83, accuracy: 1e-9)
    }

    func testMinutePricesSumToTheDaysActiveEnergyExactly() {
        // A mixed day: a calm stretch, a walk with steps, a hard effort and a heart-rate dropout with steps.
        var hr: [HRSample] = []
        for t in 0..<3_600 { hr.append(HRSample(ts: 10_000 + t, bpm: t < 1_200 ? 62 : (t < 2_400 ? 97 : 152))) }
        let steps: [Int: Double] = [Int(10_000 / 60) + 21: 118, Int(10_000 / 60) + 22: 121.5,
                                    Int(10_000 / 60) + 45: 160, 400: 37]
        let byMinute = Calories.yoopActiveKcalByMinute(hr, stepsByMinute: steps, profile: man, hrmax: 178.6,
                                                       restingHR: 56.243)
        let day = Calories.estimateYoopDayEnergy(hr, stepsByMinute: steps, windowSeconds: 86_400,
                                                 profile: man, hrmax: 178.6, restingHR: 56.243)
        let summed = byMinute.keys.sorted().reduce(0.0) { $0 + (byMinute[$1] ?? 0) }
        XCTAssertEqual(summed, day.activeKcal)   // bit-for-bit, not within a tolerance
        XCTAssertGreaterThan(day.activeKcal, 0)
        XCTAssertGreaterThan(byMinute[400] ?? 0, 0)   // steps with no heart rate still price a minute
    }

    func testMinutePricesAreEmptyForAnEmptyDay() {
        XCTAssertTrue(Calories.yoopActiveKcalByMinute([], stepsByMinute: [:], profile: man, hrmax: 178.6,
                                                      restingHR: 56).isEmpty)
    }

    // MARK: - Minutes priced by heart rate alone (strength sessions)

    /// A deterministic synthetic day: 4 hours at 1 Hz with a slow swing in heart rate and a hard stretch, and
    /// ticks in most minutes. The literals below were taken from `yoopActiveKcalByMinute` as it stood before
    /// `heartPricedMinutes` existed, so a day with none is held to the same bits.
    private func syntheticDay() -> (hr: [HRSample], steps: [Int: Double], base: Int) {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let base = 1_800_000_000 - 1_800_000_000 % 3_600
        var hr: [HRSample] = []
        for t in 0..<14_400 {
            let swing = 45.0 * sin(Double(t) / 420.0)
            let hard = (t >= 7_200 && t < 8_400) ? 55 : 0
            hr.append(HRSample(ts: base + t, bpm: max(40, min(185, 82 + Int(swing) + hard + next() % 7))))
        }
        var steps: [Int: Double] = [:]
        for m in 0..<240 where next() % 5 != 0 { steps[base / 60 + m] = Double(next() % 140) / (next() % 3 == 0 ? 1.7 : 1.0) }
        return (hr, steps, base)
    }

    func testADayWithNoHeartPricedMinutesIsPricedExactlyAsBefore() {
        let day = syntheticDay()
        let byMinute = Calories.yoopActiveKcalByMinute(day.hr, stepsByMinute: day.steps, profile: man,
                                                       hrmax: 178.6, restingHR: 56.243)
        let energy = Calories.estimateYoopDayEnergy(day.hr, stepsByMinute: day.steps, windowSeconds: 14_400,
                                                    profile: man, hrmax: 178.6, restingHR: 56.243)
        XCTAssertEqual(energy.activeKcal.bitPattern, 0x4090f3208a6d0d1f)
        XCTAssertEqual(energy.restingKcal.bitPattern, 0x4072520000000000)
        XCTAssertEqual(byMinute.count, 216)
        for (offset, bits) in [(3, 0x3ff66b413986338b), (60, 0x4021393954a856b6), (125, 0x3ff26ef15ccf0def),
                               (200, 0x3fec2233bba363d1)] as [(Int, UInt64)] {
            XCTAssertEqual((byMinute[day.base / 60 + offset] ?? -1).bitPattern, bits)
        }
        // An empty set is the same call, written out.
        let explicit = Calories.estimateYoopDayEnergy(day.hr, stepsByMinute: day.steps, windowSeconds: 14_400,
                                                      profile: man, hrmax: 178.6, restingHR: 56.243,
                                                      heartPricedMinutes: [])
        XCTAssertEqual(explicit.activeKcal.bitPattern, energy.activeKcal.bitPattern)
    }

    func testAHeartPricedMinuteIsNeverPricedAsWalking() {
        // 100 bpm for a minute with 120 ticks: walking's price by default, the heart price when the minute is
        // a strength session's.
        let hr = (0..<60).map { HRSample(ts: $0, bpm: 100) }
        let walking = Calories.yoopActiveKcalByMinute(hr, stepsByMinute: [0: 120], profile: man, hrmax: 178.6,
                                                      restingHR: 51)
        let heart = Calories.yoopActiveKcalByMinute(hr, stepsByMinute: [0: 120], profile: man, hrmax: 178.6,
                                                    restingHR: 51, heartPricedMinutes: [0])
        XCTAssertEqual(walking[0] ?? 0, 120 * 0.0005 * 82 * 0.415 * 1.83, accuracy: 1e-9)
        let vo2max = 15.3 * 178.6 / 51
        let grossKcalPerS = (0.634 * 100 + 0.404 * vo2max + 0.394 * 82 + 0.271 * 42 - 95.7735) / 251.04
        XCTAssertEqual(heart[0] ?? 0, 60 * (grossKcalPerS - 1_758.75 / 86_400), accuracy: 1e-9)
        XCTAssertGreaterThan(heart[0] ?? 0, walking[0] ?? 0)
        // Ticks with no heart rate at all carry nothing in such a minute.
        let bare = Calories.yoopActiveKcalByMinute([], stepsByMinute: [5: 90], profile: man, hrmax: 178.6,
                                                   restingHR: 51, heartPricedMinutes: [5])
        XCTAssertEqual(bare[5] ?? -1, 0)
    }

    func testHeartPricingAMinuteLeavesEveryOtherMinuteAlone() {
        let day = syntheticDay()
        let plain = Calories.yoopActiveKcalByMinute(day.hr, stepsByMinute: day.steps, profile: man, hrmax: 178.6,
                                                    restingHR: 56.243)
        let strength = Set((day.base / 60 + 100)..<(day.base / 60 + 130))
        let priced = Calories.yoopActiveKcalByMinute(day.hr, stepsByMinute: day.steps, profile: man, hrmax: 178.6,
                                                     restingHR: 56.243, heartPricedMinutes: strength)
        XCTAssertEqual(Set(priced.keys), Set(plain.keys))
        for (minute, value) in plain where !strength.contains(minute) {
            XCTAssertEqual((priced[minute] ?? -1).bitPattern, value.bitPattern)
        }
        // The day's figure is still exactly its minutes summed in order.
        let energy = Calories.estimateYoopDayEnergy(day.hr, stepsByMinute: day.steps, windowSeconds: 14_400,
                                                    profile: man, hrmax: 178.6, restingHR: 56.243,
                                                    heartPricedMinutes: strength)
        XCTAssertEqual(energy.activeKcal.bitPattern,
                       priced.keys.sorted().reduce(0.0) { $0 + (priced[$1] ?? 0) }.bitPattern)
    }
}
