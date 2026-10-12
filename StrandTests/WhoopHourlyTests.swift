import XCTest
import Foundation
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// The hour-by-hour split behind the Steps and Calories pages: the bars add up to the day's whole number,
/// the day's own counters feed them, and a figure the bars cannot hold is left out of them.
final class WhoopHourlyTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    // MARK: apportion

    func testApportionAddsUpToTheTotal() {
        XCTAssertEqual(WhoopHourly.apportion([1, 1, 1], total: 10), [4, 3, 3])
        XCTAssertEqual(WhoopHourly.apportion([0.4, 0.4, 0.2], total: 1), [1, 0, 0])
        XCTAssertEqual(WhoopHourly.apportion([10.2, 20.6, 9.2], total: 40), [10, 21, 9])
        for total in [0, 1, 7, 99, 10_767] {
            let shares = [3.3, 0, 1.7, 12.9, 0.4, 5.55]
            XCTAssertEqual(WhoopHourly.apportion(shares, total: total).reduce(0, +), shares.reduce(0, +) > 0 ? total : 0)
        }
    }

    func testApportionKeepsAnEmptyHourEmpty() {
        let parts = WhoopHourly.apportion([0, 5, 0, 5], total: 11)
        XCTAssertEqual(parts[0], 0)
        XCTAssertEqual(parts[2], 0)
        XCTAssertEqual(parts.reduce(0, +), 11)
    }

    func testApportionOfNothingIsZeros() {
        XCTAssertEqual(WhoopHourly.apportion([0, 0, 0], total: 5), [0, 0, 0])
        XCTAssertEqual(WhoopHourly.apportion([], total: 5), [])
        XCTAssertEqual(WhoopHourly.apportion([2, 3], total: 0), [0, 0])
        XCTAssertEqual(WhoopHourly.apportion([.nan, 2, -4], total: 3), [0, 3, 0])
    }

    // MARK: hours

    func testHourStartFollowsTheLocalClock() {
        // 01:55:32 UTC+3 on 11 Oct 2026 is 22:55:32 UTC the day before; its local hour starts at 01:00 +03.
        let ist = TimeZone(secondsFromGMT: 3 * 3_600)!
        let ts = 1_791_672_932
        XCTAssertEqual(WhoopHourly.hourStart(ts, timeZone: ist), ts - (55 * 60 + 32))
        // A zone half an hour off UTC has hours half an hour off the epoch's.
        let india = TimeZone(secondsFromGMT: 5 * 3_600 + 1_800)!
        XCTAssertEqual(WhoopHourly.hourStart(1_800_000_000 + 3_600, timeZone: india) % 3_600, 1_800)
        XCTAssertEqual(WhoopHourly.hourStart(1_800_000_000 + 3_600, timeZone: utc) % 3_600, 0)
    }

    func testSplitCoversEveryHourOfAWindowAndSumsToTheTotal() {
        // 00:30 to 03:10 UTC: four clock hours, the first and last partial.
        let from = 1_800_000_000 - 1_800_000_000 % 86_400 + 1_800, to = from + 2 * 3_600 + 40 * 60
        let byMinute: [Int: Double] = [from / 60 + 2: 100, from / 60 + 45: 50, from / 60 + 100: 150, from / 60 + 150: 30]
        let split = WhoopHourly.split(valueByMinute: byMinute, from: from, toExclusive: to, total: 330,
                                      asleep: [], timeZone: utc)
        XCTAssertEqual(split.bars.count, 4)
        XCTAssertEqual(split.bars.map(\.value), [100, 50, 150, 30])
        XCTAssertEqual(split.placed, 330)
        XCTAssertEqual(split.bars.map(\.start), [from - 1_800, from + 1_800, from + 5_400, from + 9_000])
    }

    func testMinutesOutsideTheWindowAreInNoHour() {
        let from = 1_800_000_000 - 1_800_000_000 % 3_600
        let split = WhoopHourly.split(valueByMinute: [from / 60 - 5: 9, from / 60 + 10: 4, from / 60 + 200: 7],
                                      from: from, toExclusive: from + 3_600, total: 4, asleep: [], timeZone: utc)
        XCTAssertEqual(split.bars.map(\.value), [4])
    }

    func testAnEmptyWindowHasNoBars() {
        XCTAssertTrue(WhoopHourly.split(valueByMinute: [1: 1], from: 100, toExclusive: 100, total: 1,
                                        asleep: [], timeZone: utc).bars.isEmpty)
    }

    func testAnHourIsAsleepWhenHalfOfItIsInASleep() {
        let from = 1_800_000_000 - 1_800_000_000 % 3_600
        let split = WhoopHourly.split(valueByMinute: [:], from: from, toExclusive: from + 3 * 3_600, total: 0,
                                      asleep: [(start: from - 600, end: from + 3_600 + 1_800)], timeZone: utc)
        // Hour 0 wholly asleep, hour 1 exactly half asleep, hour 2 awake.
        XCTAssertEqual(split.bars.map(\.asleep), [true, true, false])
    }

    // MARK: shares

    func testSharesGiveEachMinuteToTheFirstActivityAndAddUp() {
        let byMinute: [Int: Double] = [10: 5, 11: 5, 12: 10, 20: 30, 30: 1]
        let windows = [(start: 11 * 60, end: 13 * 60), (start: 12 * 60, end: 21 * 60)]
        let result = WhoopHourly.shares(valueByMinute: byMinute, windows: windows, total: 51)
        // Minutes 11 and 12 belong to the first window, 20 to the second, 10 and 30 to the rest.
        XCTAssertEqual(result.windows, [15, 30])
        XCTAssertEqual(result.rest, 6)
        XCTAssertEqual(result.windows.reduce(0, +) + result.rest, 51)
    }

    func testAShortActivityStillHoldsItsMinute() {
        // 13:29:00 to 13:30:00, a one-minute activity, holds the 13:29 minute.
        let start = 1_800_000_000 - 1_800_000_000 % 60 + 29 * 60
        let result = WhoopHourly.shares(valueByMinute: [start / 60: 9.2],
                                        windows: [(start: start, end: start + 60)], total: 9)
        XCTAssertEqual(result.windows, [9])
        XCTAssertEqual(result.rest, 0)
    }

    // MARK: the day's own counters

    private func step(_ ts: Int, _ counter: Int, _ cls: Int? = 1) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: cls)
    }

    func testHoursOfTheStepCounterAddUpToTheDaysSteps() {
        let wasOn = StepsCounter.yoopCountingEnabled
        StepsCounter.yoopCountingEnabled = true
        defer { StepsCounter.yoopCountingEnabled = wasOn }
        // A morning walk and an evening walk, with a still stretch between them.
        let base = 1_800_000_000 - 1_800_000_000 % 3_600
        var samples: [StepSample] = []
        var counter = 100
        for t in 0..<7_200 {
            if t < 1_500 || t > 5_400 { counter += 2 }
            samples.append(step(base + t, counter, t < 1_500 || t > 5_400 ? 1 : 0))
        }
        let accumulator = SleepAwareStepCounter.Accumulator(sleepSessions: [], hasActivityClasses: true,
                                                           recordsMinutes: true)
        accumulator.acceptPage(samples)
        let counted = accumulator.finish()
        let steps = Int((Double(counted.totalTicks) / 1.7).rounded())
        let split = WhoopHourly.split(valueByMinute: accumulator.acceptedTicksByMinute.mapValues { Double($0) / 1.7 },
                                      from: base, toExclusive: base + 7_200, total: steps, asleep: [], timeZone: utc)
        XCTAssertGreaterThan(steps, 0)
        XCTAssertEqual(accumulator.acceptedTicksByMinute.values.reduce(0, +), counted.totalTicks)
        XCTAssertEqual(split.placed, steps)
        XCTAssertEqual(split.bars.count, 2)
    }

    func testHoursOfTheActiveEnergyAddUpToTheDaysActiveEnergy() {
        let man = UserProfile(weightKg: 82, heightCm: 183, age: 42, sex: "male")
        let base = 1_800_000_000 - 1_800_000_000 % 3_600
        let hr = (0..<10_800).map { HRSample(ts: base + $0, bpm: $0 < 3_000 ? 60 : ($0 < 7_000 ? 112 : 150)) }
        let steps: [Int: Double] = [(base + 3_600) / 60: 110, (base + 3_660) / 60: 118.5]
        let byMinute = Calories.yoopActiveKcalByMinute(hr, stepsByMinute: steps, profile: man, hrmax: 178.6,
                                                       restingHR: 56.243)
        let day = Calories.estimateYoopDayEnergy(hr, stepsByMinute: steps, windowSeconds: 10_800, profile: man,
                                                 hrmax: 178.6, restingHR: 56.243)
        let counted = Int(byMinute.keys.sorted().reduce(0.0) { $0 + (byMinute[$1] ?? 0) }.rounded())
        let split = WhoopHourly.split(valueByMinute: byMinute, from: base, toExclusive: base + 10_800,
                                      total: counted, asleep: [], timeZone: utc)
        XCTAssertEqual(counted, Int(day.activeKcal.rounded()))
        XCTAssertEqual(split.placed, Int(day.activeKcal.rounded()))
        XCTAssertEqual(split.bars.count, 3)
    }
}
