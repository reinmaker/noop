import Foundation
import StrandAnalytics
import WhoopProtocol

// WhoopStressCurve.swift — WHOOP-style stress across the whole day, sleep included.
//
// Each 5-minute bucket's mean heart rate is read against the nightly resting heart rate and placed on
// WHOOP's 0-3 scale with a logistic: at rest it reads low (about 0.6), a body running about 20 bpm
// above rest reads the middle of medium (1.5), and about 30 bpm above reads high (2.0 and up). This is
// what WHOOP's Stress Monitor shows for this user: sleep low, an ordinary waking day medium, and a few
// hours high on an active day (2 h 48 min on 6 Oct 2026), where `DaytimeStress`, which scores each hour
// against the day's own calmest hours and puts that calm at 1.5, read most of a quiet day as high.
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

    /// The day's stress, one point per scored 5-minute bucket, earliest first.
    static func analyze(hr: [HRSample], restingHR: Double,
                               tzOffsetSeconds: Int = 0) -> DaytimeStress.Result {
        guard !hr.isEmpty, restingHR > 0 else { return .empty }
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
                                                  level: level(meanHR: mean, restingHR: restingHR),
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
