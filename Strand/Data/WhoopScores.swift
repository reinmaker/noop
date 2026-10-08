import Foundation
import WhoopStore

/// Yoop: Recovery and Sleep Performance computed the way WHOOP computes them, fitted to the user's WHOOP
/// export (121 days, June to October 2026). Each fit was checked on the last 40% of days it was not fitted on.
///
/// Recovery: WHOOP's number is almost entirely HRV against the last 14 days, with a little resting HR
/// and respiratory rate; sleep and skin temperature carry no weight. Each input is a z-score against
/// the previous 14 days (mean, and 1.253 x the mean absolute deviation), and
/// Recovery = 100 / (1 + e^-(0.7325 + 0.5978 z_HRV + 0.0877 z_RHR + 0.0582 z_resp)), with lower resting
/// HR and respiratory rate counting as better. RMSE 6 points against WHOOP (Yoop's Charge formula: 14),
/// colour band right 82% of the time (74%). A night at baseline reads 67.5%.
///
/// Sleep Performance: 0.272 x hours vs needed (capped at 100) + 0.327 x consistency + 0.368 x
/// efficiency, all in percent. RMSE 3 points against WHOOP; hours vs needed alone, which is what Yoop
/// showed before, was 11 points off.
enum WhoopScores {
    static let recoveryWindow = 14
    static let minBaselineDays = 5

    struct Inputs {
        let day: String
        let hrv: Double?
        let rhr: Double?
        let resp: Double?
    }

    private static func baseline(_ xs: [Double]) -> (mean: Double, spread: Double)? {
        guard xs.count >= minBaselineDays else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let mad = xs.reduce(0) { $0 + abs($1 - mean) } / Double(xs.count)
        return (mean, max(1.253 * mad, 1e-6))
    }

    /// WHOOP-style Recovery (0-100) for `day` from its HRV, resting HR and respiratory rate, against the
    /// 14 days before it in `history` (sorted by day, oldest first). Nil without HRV or enough history.
    static func recovery(day: String, hrv: Double?, rhr: Double?, resp: Double?, history: [Inputs]) -> Double? {
        guard let hrv else { return nil }
        let prior = Array(history.filter { $0.day < day }.suffix(recoveryWindow))
        guard let h = baseline(prior.compactMap(\.hrv)) else { return nil }
        var z = 0.7325 + 0.5978 * (hrv - h.mean) / h.spread
        if let rhr, let r = baseline(prior.compactMap(\.rhr)) { z += 0.0877 * (r.mean - rhr) / r.spread }
        if let resp, let p = baseline(prior.compactMap(\.resp)) { z += 0.0582 * (p.mean - resp) / p.spread }
        return min(100, max(0, 100 / (1 + exp(-z))))
    }

    /// WHOOP-style Sleep Performance (0-100). Without a consistency figure the other two parts are scaled
    /// up to the same total weight.
    static func sleepPerformance(daily d: DailyMetric, needMin: Double, consistency: Double?) -> Double? {
        guard let asleep = d.totalSleepMin, asleep > 0, let eff = d.efficiency, needMin > 0 else { return nil }
        let hoursVsNeeded = min(100, asleep / needMin * 100)
        let efficiency = eff <= 1 ? eff * 100 : eff
        if let consistency {
            return min(100, 0.272 * hoursVsNeeded + 0.327 * consistency + 0.368 * efficiency)
        }
        return min(100, (0.272 * hoursVsNeeded + 0.368 * efficiency) * (0.967 / 0.640))
    }
}
