import Foundation
import StrandAnalytics
import WhoopProtocol

/// The ONE place Yoop's stress is scored for a span of time. Today's card, the Stress screen, the Sleep
/// screen's night, the Health tab, the Coach and the widget all read their 0 to 3 line from here, so two
/// readouts of the same minutes cannot disagree.
///
/// Yoop's own estimate, not WHOOP's algorithm: heart rate above the resting rate and, where the beats are
/// clean and the wrist was still, heart rate variability against the user's own 14-day baseline, activities
/// scored like the rest of the day and flagged so the Non Activity card can leave them out (`WhoopStressCurve`
/// has the method, its two fitted numbers and the zone bands).
///
/// This type only gathers what the pure scoring needs: the span's heart rate (passed in by the caller,
/// which has already read it), the user's sleeps, the saved workouts and detected activity bouts to
/// flag, and the clean heart rate variability windows of the last 14 days for the baseline.
@MainActor
enum WhoopStressDay {

    /// How long a detected activity bout is looked for: `Repository.yoopActivityBouts` reads this many
    /// days back. A night older than this is scored without detected bouts, which cannot overlap a sleep
    /// anyway (the detector never spans one).
    private static let boutDaysBack = 2

    /// Scores `hr` (the span `from` to `to`, unix seconds) in 5-minute windows. Callers gate on
    /// `StressDayCurve.whoopRestingHR` first and pass its value, so the "is Yoop stress on and is there a
    /// resting rate" decision is made once, where each surface already makes it.
    static func score(repo: Repository, hr: [HRSample], from: Int, to: Int, restingHR: Double,
                      now: Date = Date()) async -> DaytimeStress.Result {
        guard !hr.isEmpty else { return .empty }
        let tz = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(to)))
        let sleepSpans = repo.sleeps.map { $0.effectiveStartTs...max($0.effectiveStartTs, $0.endTs) }
        let excluded = await activitySpans(repo: repo, from: from, now: now)
        let history = await HRVHistory.shared.windows(repo: repo, endingAt: to)
        let baseline = WhoopStressCurve.baseline(windows: history, sleepSpans: sleepSpans, excluded: excluded)
        let span = history.filter { $0.startTs >= from && $0.startTs <= to }
        return await runUnescalated(priority: .userInitiated) {
            WhoopStressCurve.analyze(hr: hr, restingHR: restingHR, tzOffsetSeconds: tz, hrv: span,
                                     baseline: baseline, sleepSpans: sleepSpans, excluded: excluded)
        }
    }

    /// The stretches to flag as activity: every saved workout from the baseline's days up to now, and
    /// the activity bouts `WhoopActivityDetector` finds in the last two days that were not saved. A
    /// bout still going is not in the list yet (`Repository.yoopActivityBouts` returns finished ones), so
    /// it is not flagged until it ends.
    private static func activitySpans(repo: Repository, from: Int, now: Date) async -> [ClosedRange<Int>] {
        let nowTs = Int(now.timeIntervalSince1970)
        let days = max(WhoopStressCurve.baselineDays + 1, (nowTs - from) / 86_400 + 2)
        var spans = await repo.workoutRows(days: days).map { $0.startTs...max($0.startTs, $0.endTs) }
        if nowTs - from <= boutDaysBack * 86_400 {
            spans += await repo.yoopActivityBouts(daysBack: boutDaysBack, ignoring: []).map { $0.startSec...$0.endSec }
        }
        return spans
    }

    /// The clean heart rate variability windows of each local day, kept in memory so the 14-day baseline
    /// reads each past day's R-R and motion once per run of the app instead of on every refresh.
    ///
    /// A day is keyed on the strap and its heart rate fingerprint (a COUNT and a MAX, the cheap check the
    /// stress card already uses), so a backfill that lands rows inside a past day re-reads that day and
    /// nothing else. In memory and per process: never persisted, never part of a backup.
    @MainActor
    final class HRVHistory {
        static let shared = HRVHistory()

        private var days: [Int: (key: String, windows: [WhoopStressCurve.HRVWindow])] = [:]
        /// Reads in progress, so cards that start together on a cold launch share one read of a day
        /// instead of each making its own (a MainActor method that awaits is reentrant).
        private var inFlight: [String: Task<[WhoopStressCurve.HRVWindow], Never>] = [:]

        /// The clean windows of the `WhoopStressCurve.baselineDays` local days ending with the day that
        /// holds `to`, oldest first.
        func windows(repo: Repository, endingAt to: Int,
                     calendar: Calendar = .current) async -> [WhoopStressCurve.HRVWindow] {
            let lastDay = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(to)))
            var out: [WhoopStressCurve.HRVWindow] = []
            for back in stride(from: WhoopStressCurve.baselineDays - 1, through: 0, by: -1) {
                // Re-anchored after the day arithmetic, because adding a day keeps the time of day and a
                // zone whose clocks shift at midnight would otherwise start a window an hour out.
                guard let raw = calendar.date(byAdding: .day, value: -back, to: lastDay) else { continue }
                let start = calendar.startOfDay(for: raw)
                guard let next = calendar.date(byAdding: .day, value: 1, to: start)
                    .map({ calendar.startOfDay(for: $0) }) else { continue }
                out += await dayWindows(repo: repo, from: Int(start.timeIntervalSince1970),
                                        to: Int(next.timeIntervalSince1970) - 1)
            }
            prune()
            return out
        }

        /// One day's clean windows, from memory when the day's heart rate has not changed.
        private func dayWindows(repo: Repository, from: Int, to: Int) async -> [WhoopStressCurve.HRVWindow] {
            let fingerprint = await repo.hrFingerprintUnion(from: from, to: to)
            let key = "\(repo.deviceId)|\(fingerprint)"
            if let hit = days[from], hit.key == key { return hit.windows }
            let flight = "\(from)|\(key)"
            if let reading = inFlight[flight] { return await reading.value }
            let reading = Task { @MainActor in await Self.read(repo: repo, from: from, to: to) }
            inFlight[flight] = reading
            let windows = await reading.value
            inFlight[flight] = nil
            days[from] = (key, windows)
            return windows
        }

        /// Reads one day's R-R and motion and keeps the windows that pass every gate. Motion is read only
        /// when the day has R-R at all.
        private static func read(repo: Repository, from: Int, to: Int) async -> [WhoopStressCurve.HRVWindow] {
            let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
            guard !rr.isEmpty else { return [] }
            let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
            return await runUnescalated { WhoopStressCurve.hrvWindows(rr: rr, gravity: gravity) }
        }

        /// Keeps the newest few weeks of days, so the memory stays at the 14 days the baseline serves (and
        /// a scroll back through older nights cannot grow it).
        private func prune() {
            let keep = 3 * WhoopStressCurve.baselineDays
            guard days.count > keep else { return }
            for oldest in days.keys.sorted().prefix(days.count - keep) { days[oldest] = nil }
        }

        /// For tests, and for any caller that needs to force a re-read.
        func clear() {
            days.removeAll()
            inFlight.removeAll()
        }
    }
}
