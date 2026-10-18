import XCTest
import Foundation
import StrandAnalytics
@testable import Strand

/// Yoop's skin-temperature baseline: the plain mean of the last 30 days of nights before today, not the Charge fold
/// of a 21-day window (12 nights on 18 Oct 2026) that leaned on the window's first nights.
final class YoopSkinBaselineTests: XCTestCase {

    private let cfg = Baselines.metricCfg["skin_temp"]!

    /// WHOOP's own nightly skin temperatures for 19 Sep to 16 Oct 2026 (the 7 to 13 Oct nights were on Yoop's strap).
    private let whoopNights: [(day: String, value: Double?)] = [
        ("2026-09-19", 31.92), ("2026-09-20", 32.32), ("2026-09-21", 32.27), ("2026-09-22", 32.0),
        ("2026-09-23", 31.18), ("2026-09-24", 32.25), ("2026-09-25", 33.06), ("2026-09-26", 31.65),
        ("2026-09-27", 32.5), ("2026-09-28", 32.64), ("2026-09-29", 32.57), ("2026-09-30", 31.77),
        ("2026-10-01", 31.51), ("2026-10-02", 32.42), ("2026-10-03", 31.28), ("2026-10-04", 31.2),
        ("2026-10-05", 31.06), ("2026-10-06", 32.94), ("2026-10-14", 32.5), ("2026-10-15", 32.07),
        ("2026-10-16", 32.88)]

    private func history(own: [(day: String, value: Double?)], anchor: String) -> ChargeBaselines.History {
        ChargeBaselines.history(imported: whoopNights, own: own, anchorDay: anchor, cfg: cfg, baselineEpoch: 0,
                                windowDays: IntelligenceEngine.skinBaselineDays)
    }

    /// 18 Oct 2026 as it happened: the fold read 31.88 and showed -0.03 for a 31.85 night; the mean of the 30 days
    /// before that night is 32.18, a change of -0.33.
    func testTheBaselineIsTheMeanOfTheNightsBeforeToday() {
        let own: [(day: String, value: Double?)] = [("2026-10-17", 34.01), ("2026-10-18", 31.85)]
        let h = history(own: own, anchor: "2026-10-18")
        let base = IntelligenceEngine.yoopSkinBaseline(h, before: "2026-10-18", epoch: 0, cfg: cfg)
        XCTAssertEqual(base.baseline, 32.1818, accuracy: 0.001)
        XCTAssertTrue(base.usable)
        XCTAssertEqual(31.85 - base.baseline, -0.33, accuracy: 0.005)
        // The Charge baseline the engine read before: the 21-day window of that day, 12 nights, folded from its
        // first night (31.88).
        let old = ChargeBaselines.history(imported: whoopNights, own: own, anchorDay: "2026-10-18", cfg: cfg,
                                          baselineEpoch: 0)
        let fold = Baselines.foldHistory(old.values, dayKeys: old.dayKeys, cfg: cfg, baselineEpoch: 0)
        XCTAssertEqual(fold.baseline, 31.875, accuracy: 0.001)
        XCTAssertGreaterThan(base.baseline - fold.baseline, 0.25)
    }

    /// The night being scored is not part of its own baseline.
    func testTheNightBeingScoredIsLeftOut() {
        let without = IntelligenceEngine.yoopSkinBaseline(
            history(own: [("2026-10-17", 34.01)], anchor: "2026-10-18"), before: "2026-10-18", epoch: 0, cfg: cfg)
        let with = IntelligenceEngine.yoopSkinBaseline(
            history(own: [("2026-10-17", 34.01), ("2026-10-18", 36.0)], anchor: "2026-10-18"),
            before: "2026-10-18", epoch: 0, cfg: cfg)
        XCTAssertEqual(with.baseline, without.baseline, accuracy: 1e-12)
    }

    /// Nights older than 30 days do not count.
    func testNightsOlderThanThirtyDaysAreOutsideTheWindow() {
        var nights = whoopNights
        nights.append(("2026-08-01", 25.0))
        let h = ChargeBaselines.history(imported: nights, own: [], anchorDay: "2026-10-17", cfg: cfg,
                                        baselineEpoch: 0, windowDays: IntelligenceEngine.skinBaselineDays)
        let base = IntelligenceEngine.yoopSkinBaseline(h, before: "2026-10-17", epoch: 0, cfg: cfg)
        XCTAssertGreaterThan(base.baseline, 31.9)
    }

    /// Recalibrate drops the nights before its epoch.
    func testRecalibrationDropsEarlierNights() {
        let h = history(own: [], anchor: "2026-10-17")
        let epoch = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!.timeIntervalSince1970
        let base = IntelligenceEngine.yoopSkinBaseline(h, before: "2026-10-17", epoch: epoch, cfg: cfg)
        XCTAssertEqual(base.baseline, (32.5 + 32.07 + 32.88) / 3, accuracy: 1e-9)
        XCTAssertEqual(base.nValid, 3)
        XCTAssertFalse(base.usable, "three nights are under the four a baseline needs")
    }
}
