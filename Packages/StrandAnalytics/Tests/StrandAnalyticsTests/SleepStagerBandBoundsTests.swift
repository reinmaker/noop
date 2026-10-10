import XCTest
@testable import StrandAnalytics

/// Yoop: the band's own asleep span bounds the night (`SleepStager.applyBandStateBounds`).
final class SleepStagerBandBoundsTests: XCTestCase {
    private let start = 1_791_500_000

    /// One band reading per minute: `minutes` of each state in order.
    private func band(_ runs: [(state: Int, minutes: Int)]) -> [(ts: Int, state: Int)] {
        var out: [(ts: Int, state: Int)] = []
        var t = start
        for run in runs {
            for _ in 0..<run.minutes { out.append((ts: t, state: run.state)); t += 60 }
        }
        return out
    }

    private func asleepMinutes(_ stages: [StageSegment]) -> Int {
        stages.filter { !SleepStageVocabulary.isWake($0.stage) }.reduce(0) { $0 + ($1.end - $1.start) } / 60
    }

    /// Lying still before sleep and awake in bed after it: the stager called both sleep, the band did not.
    func testLeadingAndTrailingSleepOutsideTheBandBecomeWake() {
        let end = start + 120 * 60
        let stages = [StageSegment(start: start, end: start + 100 * 60, stage: "light"),
                      StageSegment(start: start + 100 * 60, end: end, stage: "rem")]
        let bands = band([(1, 20), (2, 80), (3, 20)])
        let out = SleepStager.applyBandStateBounds(stages, start: start, end: end, bandSleepState: bands, enabled: true)
        XCTAssertEqual(asleepMinutes(out), 80)
        XCTAssertEqual(out.first?.stage, "wake")
        XCTAssertEqual(out.last?.stage, "wake")
        XCTAssertEqual(out.first?.start, start)
        XCTAssertEqual(out.last?.end, end)
    }

    /// An awakening in the middle of the night is left to the stager.
    func testInteriorIsUntouched() {
        let end = start + 90 * 60
        let stages = [StageSegment(start: start, end: end, stage: "light")]
        let bands = band([(2, 30), (3, 30), (2, 30)])
        let out = SleepStager.applyBandStateBounds(stages, start: start, end: end, bandSleepState: bands, enabled: true)
        XCTAssertEqual(out, stages)
    }

    /// Off, no band, or a band that never says asleep: nothing changes.
    func testNoChangeWithoutTheFlagOrAnAsleepBand() {
        let end = start + 60 * 60
        let stages = [StageSegment(start: start, end: end, stage: "deep")]
        let bands = band([(1, 10), (2, 40), (0, 10)])
        XCTAssertEqual(SleepStager.applyBandStateBounds(stages, start: start, end: end, bandSleepState: bands,
                                                        enabled: false), stages)
        XCTAssertEqual(SleepStager.applyBandStateBounds(stages, start: start, end: end, bandSleepState: [],
                                                        enabled: true), stages)
        XCTAssertEqual(SleepStager.applyBandStateBounds(stages, start: start, end: end,
                                                        bandSleepState: band([(1, 60)]), enabled: true), stages)
    }
}
