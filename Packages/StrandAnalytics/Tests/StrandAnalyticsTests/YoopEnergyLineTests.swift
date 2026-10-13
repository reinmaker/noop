import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// The Yoop energy: one heart-rate line, an empirical fit to the wearer's own WHOOP export
/// (`Calories.yoopActiveKcalPerBpm`), prices every minute of the day and every activity, and Mifflin-St Jeor
/// adds the basal rate where a total is shown. Off by default (`Calories.yoopEnergyEnabled`): the NOOP
/// estimators are held to the bit by `testNonYoopEnergyIsBitIdenticalToMain`.
final class YoopEnergyLineTests: XCTestCase {
    override func tearDown() {
        Calories.yoopEnergyEnabled = false
        super.tearDown()
    }

    private let man = UserProfile(weightKg: 82, heightCm: 183, age: 42, sex: "male")
    private let woman = UserProfile(weightKg: 61, heightCm: 168, age: 35, sex: "female")

    /// A flat heart rate, one reading a second, from `start` for `seconds`.
    private func flat(_ bpm: Int, from start: Int, seconds: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    // MARK: - The line

    func testTheLineIsWhoopsAndNeverBelowZero() {
        XCTAssertEqual(Calories.yoopActiveKcalPerMinute(meanHR: 100), 0.1988 * 100 - 16.43, accuracy: 1e-12)
        XCTAssertEqual(Calories.yoopActiveKcalPerMinute(meanHR: 170), 17.366, accuracy: 1e-9)
        // It reaches zero at 82.6 bpm and carries no energy below it.
        XCTAssertEqual(Calories.yoopActiveKcalPerMinute(meanHR: 82.64), 0.0, accuracy: 0.01)
        XCTAssertEqual(Calories.yoopActiveKcalPerMinute(meanHR: 82), 0)
        XCTAssertEqual(Calories.yoopActiveKcalPerMinute(meanHR: 40), 0)
        XCTAssertEqual(Calories.yoopActiveKcalPerMinute(meanHR: 0), 0)
    }

    /// A small synthetic set of workouts priced the way WHOOP prices them: a straight line in average heart
    /// rate with a deterministic scatter of up to 0.35 kcal a minute, as the member's 110 workouts have. An
    /// ordinary least-squares fit of energy per minute against average heart rate must recover the line, and
    /// Yoop's price for each workout must sit within the scatter of the energy WHOOP reported for it.
    func testALineFitToSyntheticWhoopWorkoutsIsTheLineYoopUses() {
        let workouts: [(avgHR: Int, minutes: Int)] = [
            (84, 40), (92, 30), (98, 60), (104, 45), (111, 25), (118, 90), (126, 35), (133, 50),
            (141, 20), (150, 40), (163, 30), (176, 38),
        ]
        let scatter: [Double] = [0.30, -0.22, 0.10, -0.35, 0.18, 0.05, -0.12, 0.33, -0.28, 0.20, -0.08, -0.15]
        let reported = workouts.indices.map { i -> Double in
            (-16.43 + 0.1988 * Double(workouts[i].avgHR) + scatter[i]) * Double(workouts[i].minutes)
        }
        // Ordinary least squares of kcal per minute on average heart rate.
        let xs = workouts.map { Double($0.avgHR) }
        let ys = workouts.indices.map { reported[$0] / Double(workouts[$0].minutes) }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let slope = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            / xs.reduce(0.0) { $0 + ($1 - mx) * ($1 - mx) }
        let intercept = my - slope * mx
        XCTAssertEqual(slope, Calories.yoopActiveKcalPerBpm, accuracy: 0.003)
        XCTAssertEqual(intercept, Calories.yoopActiveKcalIntercept, accuracy: 0.4)
        // Yoop's own price of each workout, from a flat heart rate for its length, against the reported energy.
        var squares = 0.0
        for (i, w) in workouts.enumerated() {
            let start = 1_800_000_000 - 1_800_000_000 % 60
            let kcal = Calories.yoopActivityKcal(flat(w.avgHR, from: start, seconds: w.minutes * 60),
                                                 from: start, to: start + w.minutes * 60 - 1)
            XCTAssertEqual(kcal, Calories.yoopActiveKcalPerMinute(meanHR: Double(w.avgHR)) * Double(w.minutes),
                           accuracy: 1e-9)
            let perMinute = (kcal - reported[i]) / Double(w.minutes)
            squares += perMinute * perMinute
        }
        let rmse = (squares / n).squareRoot()
        XCTAssertLessThan(rmse, 0.4)
    }

    // MARK: - The day

    func testMifflinStJeor() {
        XCTAssertEqual(Calories.mifflinStJeorKcalPerDay(man), 1_758.75, accuracy: 1e-9)
        let sameBodyWoman = UserProfile(weightKg: 82, heightCm: 183, age: 42, sex: "female")
        XCTAssertEqual(Calories.mifflinStJeorKcalPerDay(sameBodyWoman), 1_592.75, accuracy: 1e-9)
        let nonbinary = UserProfile(weightKg: 82, heightCm: 183, age: 42, sex: "nonbinary")
        XCTAssertEqual(Calories.mifflinStJeorKcalPerDay(nonbinary), 1_675.75, accuracy: 1e-9)
    }

    func testRestingCoversTheWholeWindowNotOnlyTheSamples() {
        let energy = Calories.estimateYoopDayEnergy([HRSample(ts: 0, bpm: 50)], windowSeconds: 43_200, profile: man)
        XCTAssertEqual(energy.restingKcal, 1_758.75 / 2, accuracy: 1e-9)
        XCTAssertEqual(energy.activeKcal, 0, accuracy: 1e-12)
    }

    func testAMinuteIsPricedByItsMeanHeartRateAlone() {
        // Walking, lifting and sitting at the same heart rate cost the same: there is no step term, no
        // flex point and no resting heart rate in the price.
        let hr = flat(95, from: 0, seconds: 60)
        let energy = Calories.estimateYoopDayEnergy(hr, windowSeconds: 60, profile: man)
        XCTAssertEqual(energy.activeKcal, 0.1988 * 95 - 16.43, accuracy: 1e-9)
        // The profile enters the basal only.
        let other = Calories.estimateYoopDayEnergy(hr, windowSeconds: 60, profile: woman)
        XCTAssertEqual(other.activeKcal.bitPattern, energy.activeKcal.bitPattern)
        XCTAssertNotEqual(other.restingKcal, energy.restingKcal)
    }

    func testMinuteIsPricedAtItsMeanNotAtEachReading() {
        // 30 s at 70 bpm and 30 s at 130 bpm: mean 100, priced once; readings priced one by one and clamped
        // at zero would give less.
        let hr = flat(70, from: 600, seconds: 30) + flat(130, from: 630, seconds: 30)
        let byMinute = Calories.yoopActiveKcalByMinute(hr)
        XCTAssertEqual(byMinute[10] ?? -1, 0.1988 * 100 - 16.43, accuracy: 1e-9)
    }

    func testAMinuteWithAnyReadingCountsWholeAtTheirMean() {
        // The strap drops readings inside a hard effort: 30 readings of the minute's 60 still price it whole,
        // and a lone reading prices its minute whole too.
        let line120 = 0.1988 * 120 - 16.43
        let hr = flat(120, from: 600, seconds: 30) + [HRSample(ts: 700, bpm: 120)]
        let byMinute = Calories.yoopActiveKcalByMinute(hr)
        XCTAssertEqual(byMinute[10] ?? -1, line120, accuracy: 1e-9)
        XCTAssertEqual(byMinute[11] ?? -1, line120, accuracy: 1e-9)
    }

    func testAMinuteWithNoReadingCarriesNothingAndAGapIsNeverFilled() {
        // Readings every 5 s for a minute, a ten-minute gap, then one more: three minutes priced, none between.
        let hr = stride(from: 600, to: 660, by: 5).map { HRSample(ts: $0, bpm: 120) } + [HRSample(ts: 1_260, bpm: 120)]
        let byMinute = Calories.yoopActiveKcalByMinute(hr)
        XCTAssertEqual(Set(byMinute.keys), [10, 21])
        XCTAssertEqual(byMinute.values.reduce(0, +), 2 * (0.1988 * 120 - 16.43), accuracy: 1e-9)
    }

    func testTiedReadingsOfTwoStrapsAreAveraged() {
        // Two straps read the same seconds at 100 and 140: the minute's mean is 120.
        let hr = (0..<60).flatMap { [HRSample(ts: 6_000 + $0, bpm: 100), HRSample(ts: 6_000 + $0, bpm: 140)] }
        let byMinute = Calories.yoopActiveKcalByMinute(hr)
        XCTAssertEqual(byMinute[100] ?? -1, 0.1988 * 120 - 16.43, accuracy: 1e-9)
    }

    func testMinutePricesSumToTheDaysActiveEnergyExactly() {
        // A mixed day: calm, easy, hard, and a dropout.
        var hr: [HRSample] = []
        for t in 0..<3_600 { hr.append(HRSample(ts: 10_000 + t, bpm: t < 1_200 ? 62 : (t < 2_400 ? 97 : 152))) }
        hr.append(HRSample(ts: 24_000, bpm: 110))
        let byMinute = Calories.yoopActiveKcalByMinute(hr)
        let day = Calories.estimateYoopDayEnergy(hr, windowSeconds: 86_400, profile: man)
        let summed = byMinute.keys.sorted().reduce(0.0) { $0 + (byMinute[$1] ?? 0) }
        XCTAssertEqual(summed.bitPattern, day.activeKcal.bitPattern)   // bit-for-bit, not within a tolerance
        XCTAssertGreaterThan(day.activeKcal, 0)
    }

    func testAnEmptyDayHasNoMinutes() {
        XCTAssertTrue(Calories.yoopActiveKcalByMinute([]).isEmpty)
        XCTAssertEqual(Calories.estimateYoopDayEnergy([], windowSeconds: 0, profile: man).activeKcal, 0)
    }

    // MARK: - An activity

    func testAnActivityIsTheMinutesItOverlaps() {
        // Minutes 10, 11, 12 hold 100, 120, 140 bpm.
        let hr = flat(100, from: 600, seconds: 60) + flat(120, from: 660, seconds: 60) + flat(140, from: 720, seconds: 60)
        let p100 = 0.1988 * 100 - 16.43, p120 = 0.1988 * 120 - 16.43, p140 = 0.1988 * 140 - 16.43
        // Inside minutes 10 and 11: both count whole, and the one it ends in does not.
        XCTAssertEqual(Calories.yoopActivityKcal(hr, from: 630, to: 690), p100 + p120, accuracy: 1e-9)
        // Ending exactly on a minute's start leaves that minute out; one second later takes it in.
        XCTAssertEqual(Calories.yoopActivityKcal(hr, from: 600, to: 720), p100 + p120, accuracy: 1e-9)
        XCTAssertEqual(Calories.yoopActivityKcal(hr, from: 600, to: 721), p100 + p120 + p140, accuracy: 1e-9)
        // A window shorter than a minute holds the minute it falls in.
        XCTAssertEqual(Calories.yoopActivityKcal(hr, from: 670, to: 670), p120, accuracy: 1e-9)
    }

    func testAnActivityIsTheSumOfItsMinutesOfTheDayExactly() {
        // The Calories page splits the day's minutes by the activity each overlaps; the activity's own figure
        // is the same sum, so the two agree to the bit.
        var hr: [HRSample] = []
        for t in 0..<7_200 { hr.append(HRSample(ts: 30_000 + t, bpm: 70 + (t / 40) % 60 + (t % 7))) }
        let byMinute = Calories.yoopActiveKcalByMinute(hr)
        let from = 30_000 + 1_234, to = 30_000 + 4_321
        let share = byMinute.keys.sorted().reduce(0.0) { sum, minute in
            minute * 60 + 60 > from && minute * 60 < to ? sum + (byMinute[minute] ?? 0) : sum
        }
        XCTAssertEqual(Calories.yoopActivityKcal(hr, from: from, to: to).bitPattern, share.bitPattern)
    }

    func testABoutIsPricedByTheLineOnlyWhileYoopEnergyIsOn() {
        let hr = flat(150, from: 1_200, seconds: 600)
        let neutral = Calories.estimateBoutCalories(hr, profile: man, hrmax: 178.6, restingHR: 51)
        Calories.yoopEnergyEnabled = true
        let yoop = Calories.estimateBoutCalories(hr, profile: man, hrmax: 178.6, restingHR: 51)
        Calories.yoopEnergyEnabled = false
        XCTAssertEqual(yoop.0, 10 * (0.1988 * 150 - 16.43), accuracy: 1e-9)
        XCTAssertEqual(yoop.1, yoop.0 * 4.184, accuracy: 1e-9)
        XCTAssertNotEqual(neutral.0, yoop.0)
        // A bout with no samples has no energy.
        Calories.yoopEnergyEnabled = true
        XCTAssertEqual(Calories.estimateBoutCalories([], profile: man, hrmax: nil, restingHR: nil).0, 0)
    }

    // MARK: - The NOOP path

    /// A deterministic synthetic day: 4 hours at 1 Hz with a slow swing in heart rate and a hard stretch.
    private func syntheticDay() -> [HRSample] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
        let base = 1_800_000_000 - 1_800_000_000 % 3_600
        var hr: [HRSample] = []
        for t in 0..<14_400 {
            let swing = 45.0 * sin(Double(t) / 420.0)
            let hard = (t >= 7_200 && t < 8_400) ? 55 : 0
            hr.append(HRSample(ts: base + t, bpm: max(40, min(185, 82 + Int(swing) + hard + next() % 7))))
        }
        return hr
    }

    /// With the Yoop switch off, which is its default and the NOOP path, every estimator is the one on main
    /// to the bit. The literals were taken from `estimateBoutCalories`, `estimateDayEnergy`,
    /// `estimateDayCalories` and `ManualWorkoutRescore.scored` on main (release 12.2.41), before the Yoop
    /// line existed.
    func testNonYoopEnergyIsBitIdenticalToMain() {
        XCTAssertFalse(Calories.yoopEnergyEnabled)
        let hr = syntheticDay()
        let bout = Calories.estimateBoutCalories(hr, profile: man, hrmax: 178.6, restingHR: 56.243)
        XCTAssertEqual(bout.0.bitPattern, 0x4096fc2107553d01)
        XCTAssertEqual(bout.1.bitPattern, 0x40b80acc882ea9cc)
        let slice = Calories.estimateBoutCalories(Array(hr[7_000..<9_000]), profile: woman, hrmax: nil, restingHR: nil)
        XCTAssertEqual(slice.0.bitPattern, 0x406a73a6579eee32)
        XCTAssertEqual(slice.1.bitPattern, 0x408bab254a3e4e25)
        let day = Calories.estimateDayEnergy(hr, profile: man, hrmax: 178.6, restingHR: 56.243)
        XCTAssertEqual(day.restingKcal.bitPattern, 0x40730732846ff515)
        XCTAssertEqual(day.activeKcal.bitPattern, 0x40880ee765e172c1)
        XCTAssertEqual(day.observedSeconds.bitPattern, 0x40cc200000000000)
        let part = Calories.estimateDayEnergy(Array(hr[0..<6_000]), profile: woman, hrmax: 190, restingHR: nil)
        XCTAssertEqual(part.restingKcal.bitPattern, 0x4057f7e26af37c06)
        XCTAssertEqual(part.activeKcal.bitPattern, 0x405c7ce87d7c8fb9)
        XCTAssertEqual(part.observedSeconds.bitPattern, 0x40b7700000000000)
        XCTAssertEqual(Calories.estimateDayCalories(hr, profile: man, hrmax: 178.6, restingHR: 56.243).bitPattern,
                       0x4090c940540cb6a6)
        let scored = ManualWorkoutRescore.scored(windowSamples: Array(hr[7_000..<9_000]), profile: man,
                                                 hrMax: 178.6, restingHR: 56.243)
        XCTAssertEqual(scored?.avgHr, 120)
        XCTAssertEqual(scored?.maxHr, 183)
        XCTAssertEqual(scored?.strain?.bitPattern, 0x4046000000000000)
        XCTAssertEqual(scored?.kcal?.bitPattern, 0x40765b8db5db187c)
    }
}
