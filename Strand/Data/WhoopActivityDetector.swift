import Foundation
import StrandAnalytics

/// Yoop: WHOOP-style activity detection. WHOOP adds an "Activity" by itself when heart rate stays raised
/// for about a quarter of an hour, and keeps it through short breaks, so lifting or tennis with rests
/// between sets still counts. NOOP's detector ended a window at any 90-second dip below its threshold,
/// which a set break always is, so those sessions were never found.
///
/// Each minute's mean heart rate is "active" at 30 bpm or more over the resting reference. A bout runs
/// from an active minute through gaps of up to three inactive minutes, must last at least 12 minutes
/// with at least 70% of them active, and may not overlap a saved workout or a sleep.
enum WhoopActivityDetector {
    static let marginBPM = 30
    static let minMinutes = 12
    static let maxGapMinutes = 3
    static let minActiveShare = 0.7

    static func detect(hr: [(ts: Int, bpm: Int)], restingBpm: Int,
                       excluded: [ClosedRange<Int>]) -> [DetectedWorkout] {
        var sums: [Int: (total: Int, count: Int, peak: Int)] = [:]
        for s in hr where s.bpm >= 30 && s.bpm <= 220 {
            let minute = s.ts / 60
            let e = sums[minute] ?? (0, 0, 0)
            sums[minute] = (e.total + s.bpm, e.count + 1, max(e.peak, s.bpm))
        }
        let minutes = sums.keys.sorted()
        let threshold = Double(restingBpm + marginBPM)
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
            if length >= minMinutes, Double(active) / Double(length) >= minActiveShare,
               !excluded.contains(where: { $0.overlaps(span) }) {
                let inBout = minutes.filter { $0 >= first && $0 <= last }
                let avg = inBout.map(mean).reduce(0, +) / Double(max(1, inBout.count))
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
