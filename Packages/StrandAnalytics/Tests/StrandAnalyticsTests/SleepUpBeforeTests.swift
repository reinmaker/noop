import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Yoop: two sleeps with a walk in the gap between them are not folded into one night
/// (`SleepStager.upBeforeStarts`, `SleepStageTotals.registerUpBefore`). The nights are the wearer's own, 31 Oct to
/// 1 Nov 2026 (three sleeps and two gaps with 299 and 297 counter ticks) and 19 and 20 Oct (43 and 220 ticks), laid
/// at far-away times because the registry only ever grows for the life of the test process.
final class SleepUpBeforeTests: XCTestCase {
    private let t0 = 9_000_000_000
    private func m(_ minutes: Int) -> Int { t0 + minutes * 60 }

    /// A step stream over `[from, to]`: `ticks` counter ticks as walking, spread over the span.
    private func walk(from: Int, to: Int, ticks: Int) -> [StepSample] {
        guard ticks > 0 else {
            return stride(from: from, through: to, by: 60).map { StepSample(ts: $0, counter: 1000, activityClass: 0) }
        }
        var out = [StepSample(ts: from, counter: 1000, activityClass: 0)]
        var counter = 1000
        let seconds = max(1, ticks / 2)
        let step = max(1, (to - from) / (seconds + 1))
        var ts = from
        for _ in 0..<seconds {
            counter += 2
            ts += step
            out.append(StepSample(ts: ts, counter: counter, activityClass: 1))
        }
        return out
    }

    /// 23:15 to 00:18, 01:31 to 02:03, 02:50 to 09:32 on the minute scale of this test (the first at minute 0).
    private var nightOfThreeSleeps: [(start: Int, end: Int)] {
        [(start: m(0), end: m(63)), (start: m(136), end: m(168)), (start: m(215), end: m(617))]
    }

    func testAWalkInTheGapMarksTheSleepAfterIt() {
        let s = nightOfThreeSleeps
        let steps = walk(from: s[0].end, to: s[1].start, ticks: 299) + walk(from: s[1].end, to: s[2].start, ticks: 297)
        let up = SleepStager.upBeforeStarts(sessions: s, steps: steps, enabled: true)
        XCTAssertEqual(up, [s[1].start, s[2].start])
    }

    func testAWakeInBedDoesNotMarkIt() {
        let s = [(start: m(0), end: m(269)), (start: m(329), end: m(500))]   // a 59 min gap with 43 ticks
        let steps = walk(from: s[0].end, to: s[1].start, ticks: 43)
        XCTAssertTrue(SleepStager.upBeforeStarts(sessions: s, steps: steps, enabled: true).isEmpty)
    }

    /// Two long sleeps with a walk between them are one night with a wake in the middle (2 to 3 Nov 2026: 02:07 to
    /// 05:16, up for about 40 min with 340 ticks, then 06:04 to 08:59), and stay bridged.
    func testAWalkBetweenTwoLongSleepsIsOneNight() {
        let s = [(start: m(0), end: m(189)), (start: m(237), end: m(412))]
        let steps = walk(from: s[0].end, to: s[1].start, ticks: 340)
        XCTAssertTrue(SleepStager.upBeforeStarts(sessions: s, steps: steps, enabled: true).isEmpty)
        // A doze of under two hours before the same walk is apart from the night.
        let doze = [(start: m(0), end: m(119)), (start: m(167), end: m(342))]
        XCTAssertEqual(SleepStager.upBeforeStarts(sessions: doze, steps: walk(from: doze[0].end, to: doze[1].start, ticks: 340),
                                                  enabled: true), [doze[1].start])
    }

    func testAGapOfNinetyMinutesOrMoreIsNotLookedAt() {
        let s = [(start: m(0), end: m(60)), (start: m(150), end: m(400))]
        let steps = walk(from: s[0].end, to: s[1].start, ticks: 400)
        XCTAssertTrue(SleepStager.upBeforeStarts(sessions: s, steps: steps, enabled: true).isEmpty)
    }

    func testOffOrWithNoStepsItIsEmpty() {
        let s = nightOfThreeSleeps
        let steps = walk(from: s[0].end, to: s[1].start, ticks: 299)
        XCTAssertTrue(SleepStager.upBeforeStarts(sessions: s, steps: steps).isEmpty, "off by default")
        XCTAssertTrue(SleepStager.upBeforeStarts(sessions: s, steps: [], enabled: true).isEmpty)
        XCTAssertTrue(SleepStager.upBeforeStarts(sessions: [s[0]], steps: steps, enabled: true).isEmpty)
    }

    /// The grouping follows the registry: bridged until the sleep after the gap is registered, then apart.
    func testARegisteredStartIsNotBridged() {
        let blocks = nightOfThreeSleeps.map { SleepStageTotals.NightBlock(start: $0.start, end: $0.end) }
        let offset = 7_200
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: offset)?.count, 3,
                       "folded into one night while nothing is registered")
        SleepStageTotals.registerUpBefore([m(136), m(215)])
        XCTAssertTrue(SleepStageTotals.upBeforeStarts.isSuperset(of: [m(136), m(215)]))
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: offset), [2],
                       "the longest sleep is the night and the two before it stand apart")
    }

    /// A start nobody registered still bridges when the gap is short, so a wake in bed is unchanged.
    func testAnUnregisteredShortGapStillBridges() {
        let a = SleepStageTotals.NightBlock(start: m(2_000), end: m(2_269))
        let b = SleepStageTotals.NightBlock(start: m(2_329), end: m(2_500))
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices([a, b], offsetSec: 7_200)?.count, 2)
        SleepStageTotals.registerUpBefore([])
        XCTAssertEqual(SleepStageTotals.mainNightGroupIndices([a, b], offsetSec: 7_200)?.count, 2)
    }
}
