import Foundation
import WhoopProtocol

/// Wrap-aware step derivation from the strap's cumulative `step_motion_counter@57`, shared by the daily
/// total (`AnalyticsEngine.analyzeDay`) and any windowed total (a manual workout's `[start, end]`, #398).
///
/// `step_motion_counter@57` is a CUMULATIVE u16 motion counter: it climbs for both locomotion and some
/// non-step wrist motion, and wraps at 65536. On classed WHOOP 5/MG records, the increment ending at each
/// sample is counted only when the strap labels that sample walk (1) or run (2); still (0) and unknown are
/// rejected. A wholly unclassed legacy window retains the old counter-only estimate so pre-migration history
/// remains readable. The caller applies its per-user `stepTicksPerStep` calibration afterwards. The result is
/// still an estimate, not cloud/clinical parity.
///
/// Kept byte-for-byte in lockstep with the Kotlin twin `StepsCounter.stepsInWindow`.
public enum StepsCounter {
    private static let locomotionActivityClasses: Set<Int> = [1, 2]

    static func hasActivityClasses(_ samples: [StepSample]) -> Bool {
        samples.contains { $0.activityClass != nil }
    }

    /// Kotlin twin: `StepsCounter.shouldCountDelta`.
    static func shouldCountDelta(activityClass: Int?, hasActivityClasses: Bool) -> Bool {
        !hasActivityClasses || activityClass.map(locomotionActivityClasses.contains) == true
    }

    /// Absolute reboot/wrap guard, independent from the per-second plausibility gate below.
    public static let maxStepDelta = 512
    public static let maxTicksPerSecond = 4

    /// Yoop: count the counter the way the strap's pedometer releases it (rules in
    /// `SleepAwareStepCounter.Accumulator`). Set by the app; off keeps the NOOP rules above unchanged.
    ///
    /// On the user's raw data (9 Oct 2026) the u16 counter advanced 19,049 with no wrap or reset while the
    /// NOOP rules stored 12,678. The pedometer holds the first steps of a walk until it has confirmed one,
    /// then releases them in one second: over 41 hours, 708 one-second batches of exactly 6 or 7 ticks
    /// carried a "still" label, and still seconds carried no other ticks at all. Under the walk label the
    /// same release shows as 7 to 9 ticks in one second, which the 4 per second cap rejected, and the 512
    /// cap rejected the 1,543 steps the counter banked across a 37 minute dropout while the strap was worn.
    public static var yoopCountingEnabled = false
    /// Yoop: size of one pedometer release, in ticks within at most two seconds.
    public static var yoopReleaseTicks = 5...9
    /// Yoop: a still-labelled release counts when a walk or run second lies within this many seconds of it.
    /// On the user's 41 hours, 3,354 released ticks sat within 2 s of a walk label, 880 more within 60 s
    /// (with the wrist moving as in walking) and 99 beyond that, so a minute keeps the short walks.
    public static var yoopReleaseWindowSeconds = 60
    /// Yoop: an interval longer than this is a dropout, whose closing label does not describe it.
    public static var yoopDropoutSeconds = 2
    /// Yoop: the most steps credited per elapsed second, above any sustained human cadence (210 a minute).
    public static var yoopMaxStepsPerSecond = 3.5

    /// Kotlin twin: `StepsCounter.isPlausibleDelta`.
    static func isPlausibleDelta(previousTs: Int, currentTs: Int, delta: Int) -> Bool {
        guard delta >= 1, delta < maxStepDelta else { return false }
        let elapsed = currentTs - previousTs
        guard elapsed > 0 else { return false }
        let rateAllowance = elapsed >= maxStepDelta / maxTicksPerSecond
            ? maxStepDelta - 1
            : elapsed * maxTicksPerSecond
        return delta <= rateAllowance
    }

    /// Raw wrap-aware locomotion-tick total across `samples`. When any sample carries `activityClass`, each
    /// positive increment is attributed to the later sample and retained only for walk/run. When the whole
    /// window is legacy-unclassed, all valid increments retain the historical counter-only fallback. Sorts
    /// by `ts` internally and returns `nil` for fewer than two samples or no retained movement.
    public static func stepsInWindow(_ samples: [StepSample]) -> Int? {
        if yoopCountingEnabled {
            // One implementation of the Yoop rules: the accumulator, with no sleep to gate.
            let total = SleepAwareStepCounter.count(samples, sleepSessions: []).totalTicks
            return total > 0 ? total : nil
        }
        let sorted = samples.sorted { $0.ts < $1.ts }
        if sorted.count < 2 { return nil }
        let hasActivityClasses = hasActivityClasses(sorted)
        var total = 0
        for i in 1..<sorted.count {
            let delta = (sorted[i].counter - sorted[i - 1].counter) & 0xFFFF  // wrap-aware u16 increment
            let isLocomotion = shouldCountDelta(
                activityClass: sorted[i].activityClass,
                hasActivityClasses: hasActivityClasses)
            if isLocomotion && isPlausibleDelta(
                previousTs: sorted[i - 1].ts, currentTs: sorted[i].ts, delta: delta) {
                total += delta
            }
        }
        return total > 0 ? total : nil
    }
}
