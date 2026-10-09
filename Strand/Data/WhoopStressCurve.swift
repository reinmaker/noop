import Foundation
import StrandAnalytics
import WhoopProtocol

// WhoopStressCurve.swift — WHOOP-style stress across the whole day, sleep included.
//
// Each 5-minute bucket's mean heart rate is placed in the user's own last 14 days of 5-minute heart
// rates: the bottom 50% reads low, the next 40% medium, the top 10% high. Those are this user's shares
// in WHOOP's Stress Monitor trends (read 9 Oct 2026): 47/42/11 averaged over Jun to Oct, 52/39/9 over
// the last 30 days. The first fit used the shares of one day, 6 Oct (35/52/13), which WHOOP itself
// called 41 min above a typical day, and read every day too stressed.
// Until there is a day of history it falls back to the nightly resting heart rate: rest about 0.6
// (low), +20 bpm 1.5, +30 bpm high. Reading against resting heart rate alone still put 7 hours of a day
// high, because one low resting figure moves every bucket; `DaytimeStress`, which scores each hour
// against the day's own calmest hours and puts that calm at 1.5, read 8 hours high.
//
// Heart rate only: daytime R-R off the wrist is too noisy to score (see
// `DaytimeStress.daytimeRMSSDScoringEnabled`). The result is a `DaytimeStress.Result` so every surface
// that draws or counts stress reads it unchanged; its points are 5-minute buckets, not hours.
enum WhoopStressCurve {

    /// Bucket width in seconds.
    static let bucketSeconds: Int = 300
    /// Samples a bucket needs before it is scored (a WHOOP 5/MG live stream sends about one per 30 s).
    static let minBucketSamples: Int = 3
    /// Beats per minute above resting at which the level reaches 1.5.
    static let midpointBPM: Double = 20
    /// Logistic width in beats per minute: resting reads about 0.6, +30 bpm about 2.1.
    static let slopeBPM: Double = 12.4

    /// WHOOP-scale stress (0-3) for a mean heart rate against the resting heart rate.
    static func level(meanHR: Double, restingHR: Double) -> Double {
        let delta = meanHR - restingHR
        return 3.0 / (1.0 + exp(-(delta - midpointBPM) / slopeBPM))
    }

    /// Minimum 5-minute history (12 hours) before stress is read against the user's own heart-rate history.
    /// Twelve hours, not a full day, so the first day with the strap (which includes its night) already
    /// qualifies; under that, the resting-rate curve put 7 of that day's hours high.
    static let minReferenceBuckets: Int = 144

    /// Share of the reference that reads low, and the share below the high band.
    static let lowShare = 0.50
    static let highFloorShare = 0.90

    /// WHOOP-scale stress (0-3) for a mean heart rate placed in the user's own recent 5-minute heart
    /// rates (`reference`, sorted ascending): the bottom 50% reads low, the next 40% medium and the top
    /// 10% high, this user's typical shares in WHOOP's trends, so a typical day comes out like WHOOP's
    /// and a day running hotter than usual spends more of itself high.
    static func level(meanHR: Double, reference sorted: [Double]) -> Double {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < meanHR { lo = mid + 1 } else { hi = mid }
        }
        let p = Double(lo) / Double(max(1, sorted.count))
        if p < lowShare { return p / lowShare }
        if p < highFloorShare { return 1 + (p - lowShare) / (highFloorShare - lowShare) }
        return min(3, 2 + (p - highFloorShare) / (1 - highFloorShare))
    }

    /// The day's stress, one point per scored 5-minute bucket, earliest first. With at least a day of
    /// `reference` (recent 5-minute mean heart rates) each bucket is read against the user's own history;
    /// otherwise against the resting heart rate.
    static func analyze(hr: [HRSample], restingHR: Double,
                               tzOffsetSeconds: Int = 0, reference: [Double] = []) -> DaytimeStress.Result {
        guard !hr.isEmpty, restingHR > 0 else { return .empty }
        let sortedReference = reference.count >= minReferenceBuckets ? reference.sorted() : []
        var sums: [Int: (total: Double, count: Int)] = [:]
        for s in hr {
            let bucket = Int((Double(s.ts) / Double(bucketSeconds)).rounded(.down)) * bucketSeconds
            let e = sums[bucket] ?? (0, 0)
            sums[bucket] = (e.total + Double(s.bpm), e.count + 1)
        }
        var points: [DaytimeStress.HourPoint] = []
        for bucket in sums.keys.sorted() {
            guard let e = sums[bucket], e.count >= minBucketSamples else { continue }
            let mean = e.total / Double(e.count)
            let localSeconds = ((bucket + tzOffsetSeconds) % 86_400 + 86_400) % 86_400
            points.append(DaytimeStress.HourPoint(hour: localSeconds / 3600, startTs: bucket,
                                                  level: sortedReference.isEmpty
                                                      ? level(meanHR: mean, restingHR: restingHR)
                                                      : level(meanHR: mean, reference: sortedReference),
                                                  meanHR: mean, rmssd: nil))
        }
        guard !points.isEmpty else { return .empty }

        let levels = points.compactMap(\.level)
        let highCount = levels.filter { $0 >= DaytimeStress.highBandFloor }.count
        // Sustained: the last three hours of buckets all high.
        let need = DaytimeStress.sustainedHours * 3600 / bucketSeconds
        let tail = points.suffix(need)
        let sustained = tail.count == need && tail.allSatisfy { ($0.level ?? 0) >= DaytimeStress.highBandFloor }
        let peak = points.max { ($0.level ?? 0) < ($1.level ?? 0) }
        return DaytimeStress.Result(hours: points,
                                    sustainedHigh: sustained,
                                    sustainedRun: sustained ? DaytimeStress.sustainedHours : 0,
                                    dayMean: levels.reduce(0, +) / Double(levels.count),
                                    peak: peak,
                                    activityMaskedHours: 0,
                                    highStressMinutes: highCount * bucketSeconds / 60,
                                    hrOnlyFallback: true,
                                    timeline: points)
    }
}
