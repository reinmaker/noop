import XCTest
@testable import Strand
import WhoopStore

/// WHOOP-fitted Recovery and Sleep Performance (`WhoopScores`).
final class WhoopScoresTests: XCTestCase {

    private func history(_ hrv: [Double]) -> [WhoopScores.Inputs] {
        hrv.enumerated().map { i, v in
            WhoopScores.Inputs(day: String(format: "2026-09-%02d", i + 1), hrv: v, rhr: 50, resp: 15)
        }
    }

    /// A night at baseline reads 67.5%; HRV well above reads green, well below red.
    func testRecoveryFollowsHrvAgainstTheLastFourteenDays() {
        let past = history([80, 82, 78, 81, 79, 80, 83, 77, 80, 81, 79, 80, 82, 78])
        let atBaseline = WhoopScores.recovery(day: "2026-10-01", hrv: 80, rhr: 50, resp: 15, history: past)
        XCTAssertEqual(atBaseline ?? 0, 100 / (1 + exp(-0.7325)), accuracy: 1)
        XCTAssertGreaterThan(WhoopScores.recovery(day: "2026-10-01", hrv: 90, rhr: 50, resp: 15, history: past) ?? 0, 67)
        XCTAssertLessThan(WhoopScores.recovery(day: "2026-10-01", hrv: 65, rhr: 50, resp: 15, history: past) ?? 100, 34)
    }

    func testRecoveryNeedsHrvAndHistory() {
        XCTAssertNil(WhoopScores.recovery(day: "2026-10-01", hrv: nil, rhr: 50, resp: 15, history: history([80, 80, 80, 80, 80])))
        XCTAssertNil(WhoopScores.recovery(day: "2026-10-01", hrv: 80, rhr: 50, resp: 15, history: history([80, 80])))
    }

    /// WHOOP's 6 Oct 2026: 542 min asleep of a 548 min need, consistency 64%, efficiency 89%: WHOOP said 77%, the fit gives about 81.
    func testSleepPerformanceMatchesWhoopsNight() {
        let night = DailyMetric(day: "2026-10-06", totalSleepMin: 542, efficiency: 0.89, deepMin: nil, remMin: nil,
                                lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                                strain: nil, exerciseCount: nil)
        let score = WhoopScores.sleepPerformance(daily: night, needMin: 548, consistency: 64)
        XCTAssertEqual(score ?? 0, 77, accuracy: 5)
    }
}
