import Foundation
import StrandAnalytics

/// Yoop: WHOOP-style activity detection. WHOOP adds an "Activity" by itself when heart rate stays raised
/// for about a quarter of an hour, and keeps it through short breaks, so lifting or tennis with rests
/// between sets still counts. NOOP's detector ended a window at any 90-second dip below its threshold,
/// which a set break always is, so those sessions were never found.
///
/// What counts is set by exercise intensity as a share of heart-rate reserve (resting to the 190 bpm
/// maximum Strain uses), the ACSM bands: light 30-39 %, moderate 40-59 %. A minute is "active" at 30 %
/// or more; a bout runs from an active minute through gaps of up to three inactive minutes, lasts at
/// least 12 minutes with at least 65 % of them active, averages at least 30 %, reaches 50 % in at least
/// one minute, and may not overlap a saved workout or a sleep. The first cut (+22 / +30 bpm over rest)
/// added 9 activities in 41 hours, 8 of them everyday walking at 80-91 bpm; this keeps only the one real
/// session (Thursday's weightlifting, peak 124) and on the user's WHOOP history still finds running
/// 11/11, tennis 21/22 and weightlifting 30/34 while dog walks (0/3) and yoga (0/2) drop out.
enum WhoopActivityDetector {
    /// Share of heart-rate reserve for an active minute and for the bout's average.
    static let activeReserveShare = 0.30
    /// Share of heart-rate reserve at least one minute of the bout must reach.
    static let peakReserveShare = 0.50
    static let minMinutes = 12
    static let maxGapMinutes = 3
    static let minActiveShare = 0.65

    static func detect(hr: [(ts: Int, bpm: Int)], restingBpm: Int,
                       excluded: [ClosedRange<Int>]) -> [DetectedWorkout] {
        var sums: [Int: (total: Int, count: Int, peak: Int)] = [:]
        for s in hr where s.bpm >= 30 && s.bpm <= 220 {
            let minute = s.ts / 60
            let e = sums[minute] ?? (0, 0, 0)
            sums[minute] = (e.total + s.bpm, e.count + 1, max(e.peak, s.bpm))
        }
        let minutes = sums.keys.sorted()
        let rest = Double(restingBpm)
        let reserve = max(1, StrainScorer.whoopCurveMaxHR - rest)
        let threshold = rest + activeReserveShare * reserve
        func mean(_ m: Int) -> Double { sums[m].map { Double($0.total) / Double($0.count) } ?? 0 }

        var out: [DetectedWorkout] = []
        var i = 0
        while i < minutes.count {
            guard mean(minutes[i]) >= threshold else { i += 1; continue }
            let first = minutes[i]
            var last = first
            var active = 1
            var j = i + 1
            while j < minutes.count, minutes[j] - last <= maxGapMinutes + 1 {
                if mean(minutes[j]) >= threshold {
                    last = minutes[j]
                    active += 1
                }
                j += 1
            }
            let length = last - first + 1
            let span = (first * 60)...(last * 60 + 59)
            let inBout = minutes.filter { $0 >= first && $0 <= last }
            let avg = inBout.map(mean).reduce(0, +) / Double(max(1, inBout.count))
            let peakMinute = inBout.map(mean).max() ?? 0
            if length >= minMinutes, Double(active) / Double(length) >= minActiveShare,
               avg >= threshold, peakMinute >= rest + peakReserveShare * reserve,
               !excluded.contains(where: { $0.overlaps(span) }) {
                let peak = inBout.compactMap { sums[$0]?.peak }.max() ?? Int(avg)
                out.append(DetectedWorkout(startSec: span.lowerBound, endSec: span.upperBound,
                                           avgBpm: Int(avg.rounded()), peakBpm: peak, durationMin: length))
            }
            // Continue after the bout's last minute.
            i = minutes.firstIndex(where: { $0 > last }) ?? minutes.count
        }
        return out
    }
}
