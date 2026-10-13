import Foundation
import StrandAnalytics
import WhoopProtocol

// WhoopStressCurve.swift: Yoop's estimate of WHOOP-style stress (0 to 3) across the whole day, sleep included.
//
// WHAT THIS IS, AND IS NOT. WHOOP publishes that its Stress Monitor compares live heart rate and heart
// rate variability with the member's own baseline from the past 14 days and their typical resting heart
// rate, takes motion into account so exercise does not read as stress, and reports 0 (low) to 3 (peak).
// It publishes no formula and no zone bands. This is Yoop's own estimate built to that description: heart
// rate above the user's resting rate and, where the beats are clean, heart rate variability against the
// user's own baseline. It was compared against WHOOP's published description and one user's WHOOP
// readouts. It is not WHOOP's algorithm and nothing here claims to reproduce it.
//
// THE MEASURE. Each 5-minute window is an ABSOLUTE function of that window's own data, so a calm day can
// read calm and a hard day can read hard. An earlier version placed each window's heart rate in the
// user's own recent distribution (bottom 50% low, next 40% medium, top 10% high), which made every day
// come out 50/40/10 by construction. Nothing here ranks a window against other windows.
//
//   1. Heart rate term. delta is the window's mean heart rate minus the resting heart rate (the nightly
//      resting rate of the daily rows), and level = 3 / (1 + exp(-(delta - midpointBPM) / slopeBPM)).
//      Midpoint and slope are the two numbers fitted (see their comments); the form is the older
//      absolute logistic.
//   2. Heart rate variability term, only for a window that supports one. RMSSD must come from at least
//      `minHRVBeats` beats with under `maxHRVArtifactShare` artifact beats (a successive difference over
//      `artifactJump` of the beat), and the wrist must have been still (mean dynamic acceleration under
//      `maxHRVMotionG`). Its natural log is compared with the median of the user's own clean windows of
//      the same state (awake against awake, asleep against asleep) over the last 14 days: lower than
//      that baseline raises the level, higher lowers it, by `hrvBPMPerLn` beats per minute for each unit
//      of natural log, capped at `hrvCapLn`. It enters as a shift of delta, so the level stays on 0 to
//      3 and a window without clean HRV is simply the heart rate term. The weight is set from the
//      reasoning on `hrvBPMPerLn`, not fitted.
//   3. Activity is left out. A window that overlaps a saved workout or a detected activity bout is not
//      scored (`maskedForActivity`, level nil): the activity is shown, not a stress level.
//
// ZONES. low is under 1.0, medium is 1.0 up to (not including) 2.0, high is 2.0 and over
// (`lowCeiling`, `DaytimeStress.highBandFloor`). WHOOP does not publish its bands; these are the
// thirds of the scale the app already used, and the validation in the pull request checks that the
// resulting shares are plausible against the user's WHOOP trends.
//
// The result is a `DaytimeStress.Result` so every surface that draws or counts stress reads it
// unchanged; its points are 5-minute windows, not hours.
enum WhoopStressCurve {

    /// Window width in seconds.
    static let bucketSeconds: Int = 300
    /// Samples a window needs before it is scored (a WHOOP 5/MG live stream sends about one per 30 s).
    static let minBucketSamples: Int = 3

    // MARK: Heart rate term

    /// Beats per minute above resting at which the heart rate term reads 1.5, the middle of the scale.
    /// FITTED (one of two): the first logistic used 20. On the 9 to 12 Oct 2026 backups it read the
    /// sleeping windows near 0.6 and put 19% of the time high where the user's WHOOP trends put 11%
    /// (47/42/11 over six months, 52/39/9 over 30 days); 24 puts sleep near 0.5 and the shares within a
    /// few points of both. Four days of one user, so a plausibility check and not a calibration.
    static let midpointBPM: Double = 24
    /// Logistic width in beats per minute. FITTED (two of two): the first logistic used 12.4. A wider
    /// curve spreads the middle of the day over more of the medium band, which is where WHOOP's trends
    /// put most of the user's awake time.
    static let slopeBPM: Double = 15

    /// The level (0 to 3) of a window with mean heart rate `meanHR` against `restingHR`. `hrvShiftLn` adds
    /// the heart rate variability term: the baseline's natural log of RMSSD minus the window's, positive
    /// when the variability is lower than usual. Nil leaves the heart rate term alone.
    static func level(meanHR: Double, restingHR: Double, hrvShiftLn: Double? = nil) -> Double {
        var delta = meanHR - restingHR
        if let hrvShiftLn {
            delta += hrvBPMPerLn * min(hrvCapLn, max(-hrvCapLn, hrvShiftLn))
        }
        return 3.0 / (1.0 + exp(-(delta - midpointBPM) / slopeBPM))
    }

    /// The zone floor between low and medium. The medium-to-high floor is `DaytimeStress.highBandFloor`.
    static let lowCeiling: Double = 1.0

    // MARK: Heart rate variability term

    /// Beats per minute of heart-rate shift for each unit of natural log between the window's RMSSD and
    /// the baseline's. NOT FITTED, set from three facts. (1) Off the wrist the R-R stream is noisy and
    /// only a minority of daytime windows pass the gates, so HRV is an adjustment to the heart rate term
    /// and not a co-equal driver. (2) In this user's clean still awake windows heart rate and ln RMSSD
    /// already move together (r about -0.8, 0.057 ln per bpm), so a full-weight HRV term would count
    /// the same autonomic shift twice. (3) One standard deviation of the user's own ln RMSSD in clean
    /// windows is 0.3 asleep and 0.5 awake, which at 6 bpm per ln is 2 to 3 bpm, against a 7 to 8 bpm
    /// standard deviation of their awake heart rate. So HRV carries roughly a third of the weight of
    /// heart rate. (Measured on the 9 to 12 Oct 2026 backups, 81 awake and 374 asleep clean windows.)
    static let hrvBPMPerLn: Double = 6
    /// The most natural log of RMSSD the term may count either way (6 bpm), so one odd window cannot
    /// swing a level by more than about a third of a zone.
    static let hrvCapLn: Double = 1.0
    /// Beats a window needs for its RMSSD to count (a full 5 minutes at 60 bpm is 300).
    static let minHRVBeats: Int = 100
    /// Largest share of successive differences that may exceed `artifactJump` for a window to count.
    /// Windows with 40 to 60% artifacts read 75 to 127 ms of RMSSD where clean still ones read 30 to 60.
    static let maxHRVArtifactShare: Double = 0.15
    /// A successive difference above this share of the earlier beat marks an artifact (the Malik 20% rule
    /// `HRVAnalyzer` also uses).
    static let artifactJump: Double = 0.20
    /// The wrist must have been still: mean gravity-removed motion over the window under this many g.
    static let maxHRVMotionG: Double = 0.05
    /// Motion samples a window needs to vouch that the wrist was still. A window with no motion record
    /// (WHOOP 4.0 has none) is scored by heart rate alone, never assumed still.
    static let minMotionSamples: Int = 30
    /// Clean windows of one state (awake or asleep) the baseline needs before the HRV term is used at
    /// all: 30 windows, two and a half hours of clean still R-R.
    static let minBaselineWindows: Int = 30
    /// Days of history the baseline reads (WHOOP's published 14).
    static let baselineDays: Int = 14

    /// One 5-minute window whose R-R supports a heart rate variability reading.
    struct HRVWindow: Equatable, Sendable {
        /// Start of the window (unix seconds, a multiple of `bucketSeconds`).
        let startTs: Int
        /// RMSSD in milliseconds, from `HRVAnalyzer` over the window's beats.
        let rmssd: Double
        /// Beats in the window before cleaning.
        let beats: Int
        /// Share of successive differences over `artifactJump`.
        let artifactShare: Double
        /// Mean gravity-removed motion over the window, in g.
        let motionG: Double

        /// Natural log of `rmssd`, the unit the baseline and the shift are in.
        var ln: Double { log(rmssd) }
    }

    /// The windows of `rr` that pass every gate: enough beats, few artifacts, the wrist still, and an
    /// RMSSD the shared cleaner accepts. `rr` and `gravity` may span any range; windows are 5-minute
    /// buckets on the unix clock, the same buckets the heart rate is scored in.
    static func hrvWindows(rr: [RRInterval], gravity: [GravitySample]) -> [HRVWindow] {
        guard !rr.isEmpty, !gravity.isEmpty else { return [] }
        var motion: [Int: (total: Double, count: Int)] = [:]
        for g in gravity {
            guard let d = g.dynAccel else { continue }
            let bucket = bucketStart(g.ts)
            let e = motion[bucket] ?? (0, 0)
            motion[bucket] = (e.total + d, e.count + 1)
        }
        var beats: [Int: [Double]] = [:]
        for b in rr.sortedByTsStable() { beats[bucketStart(b.ts), default: []].append(Double(b.rrMs)) }
        var out: [HRVWindow] = []
        for bucket in beats.keys.sorted() {
            guard let values = beats[bucket], values.count >= minHRVBeats,
                  let m = motion[bucket], m.count >= minMotionSamples else { continue }
            let still = m.total / Double(m.count)
            guard still < maxHRVMotionG else { continue }
            let share = artifactShare(values)
            guard share < maxHRVArtifactShare,
                  let rmssd = HRVAnalyzer.analyze(rawRR: values).rmssd, rmssd > 0 else { continue }
            out.append(HRVWindow(startTs: bucket, rmssd: rmssd, beats: values.count,
                                 artifactShare: share, motionG: still))
        }
        return out
    }

    /// Share of successive differences in `rr` (milliseconds, in beat order) that exceed `artifactJump`
    /// of the earlier beat.
    static func artifactShare(_ rr: [Double]) -> Double {
        guard rr.count >= 2 else { return 1 }
        var artifacts = 0
        for i in 1..<rr.count where abs(rr[i] - rr[i - 1]) > artifactJump * rr[i - 1] { artifacts += 1 }
        return Double(artifacts) / Double(rr.count - 1)
    }

    /// The user's own reference for the HRV term: the median natural log of RMSSD over their clean still
    /// windows, one for awake windows and one for asleep ones (sleeping RMSSD is far higher, so each state
    /// is compared with its own). Nil for a state with fewer than `minBaselineWindows` windows.
    struct HRVBaseline: Equatable, Sendable {
        let awake: Double?
        let asleep: Double?

        /// No baseline: every window is scored by heart rate alone.
        static let none = HRVBaseline(awake: nil, asleep: nil)
    }

    /// The baseline over `windows` (the last `baselineDays` days of clean windows). A window that overlaps
    /// `excluded` (an activity) is left out, so the minutes after a workout cannot drag the baseline down.
    static func baseline(windows: [HRVWindow], sleepSpans: [ClosedRange<Int>],
                         excluded: [ClosedRange<Int>] = []) -> HRVBaseline {
        var awake: [Double] = [], asleep: [Double] = []
        for w in windows where !overlaps(w.startTs, excluded) {
            if isAsleep(w.startTs, sleepSpans) { asleep.append(w.ln) } else { awake.append(w.ln) }
        }
        return HRVBaseline(awake: median(awake, atLeast: minBaselineWindows),
                           asleep: median(asleep, atLeast: minBaselineWindows))
    }

    // MARK: The day

    /// The stress of `hr` in 5-minute windows, earliest first, as a `DaytimeStress.Result`.
    ///
    /// `hrv` are the clean windows (`hrvWindows`) for the span and `baseline` the user's reference for
    /// them; where either is missing a window is scored by heart rate alone. `sleepSpans` say which
    /// baseline a window is compared with. `excluded` are saved workouts and detected activity bouts:
    /// a window overlapping one is returned unscored and marked `maskedForActivity`.
    static func analyze(hr: [HRSample], restingHR: Double, tzOffsetSeconds: Int = 0,
                        hrv: [HRVWindow] = [], baseline: HRVBaseline = .none,
                        sleepSpans: [ClosedRange<Int>] = [],
                        excluded: [ClosedRange<Int>] = []) -> DaytimeStress.Result {
        guard !hr.isEmpty, restingHR > 0 else { return .empty }
        var sums: [Int: (total: Double, count: Int)] = [:]
        for s in hr {
            let bucket = bucketStart(s.ts)
            let e = sums[bucket] ?? (0, 0)
            sums[bucket] = (e.total + Double(s.bpm), e.count + 1)
        }
        let hrvByWindow = Dictionary(hrv.map { ($0.startTs, $0) }, uniquingKeysWith: { first, _ in first })
        var points: [DaytimeStress.HourPoint] = []
        var maskedWindows = 0
        for bucket in sums.keys.sorted() {
            guard let e = sums[bucket], e.count >= minBucketSamples else { continue }
            let mean = e.total / Double(e.count)
            let localSeconds = ((bucket + tzOffsetSeconds) % 86_400 + 86_400) % 86_400
            if overlaps(bucket, excluded) {
                maskedWindows += 1
                points.append(DaytimeStress.HourPoint(hour: localSeconds / 3600, startTs: bucket, level: nil,
                                                      meanHR: mean, rmssd: nil, maskedForActivity: true))
                continue
            }
            var shift: Double?
            var rmssd: Double?
            if let w = hrvByWindow[bucket],
               let reference = isAsleep(bucket, sleepSpans) ? baseline.asleep : baseline.awake {
                shift = reference - w.ln
                rmssd = w.rmssd
            }
            points.append(DaytimeStress.HourPoint(hour: localSeconds / 3600, startTs: bucket,
                                                  level: level(meanHR: mean, restingHR: restingHR, hrvShiftLn: shift),
                                                  meanHR: mean, rmssd: rmssd))
        }
        let levels = points.compactMap(\.level)
        guard !levels.isEmpty || maskedWindows > 0 else { return .empty }

        let highCount = levels.filter { $0 >= DaytimeStress.highBandFloor }.count
        // Sustained: the last three hours of windows all high.
        let need = DaytimeStress.sustainedHours * 3600 / bucketSeconds
        let tail = points.suffix(need)
        let sustained = tail.count == need && tail.allSatisfy { ($0.level ?? 0) >= DaytimeStress.highBandFloor }
        let peak = points.max { ($0.level ?? -1) < ($1.level ?? -1) }
        return DaytimeStress.Result(hours: points,
                                    sustainedHigh: sustained,
                                    sustainedRun: sustained ? DaytimeStress.sustainedHours : 0,
                                    dayMean: levels.isEmpty ? nil : levels.reduce(0, +) / Double(levels.count),
                                    peak: peak?.level == nil ? nil : peak,
                                    activityMaskedHours: Int((Double(maskedWindows) * Double(bucketSeconds) / 3600).rounded()),
                                    highStressMinutes: highCount * bucketSeconds / 60,
                                    hrOnlyFallback: !points.contains { $0.rmssd != nil },
                                    timeline: points)
    }

    /// The stretches of the day left out as activity, from a scored result: consecutive masked windows
    /// merged, each as unix seconds from the first window's start to the last window's end.
    static func activitySpans(_ result: DaytimeStress.Result) -> [ClosedRange<Int>] {
        var spans: [ClosedRange<Int>] = []
        for p in result.timeline where p.maskedForActivity {
            if let last = spans.last, last.upperBound + 1 >= p.startTs {
                spans[spans.count - 1] = last.lowerBound...(p.startTs + bucketSeconds - 1)
            } else {
                spans.append(p.startTs...(p.startTs + bucketSeconds - 1))
            }
        }
        return spans
    }

    // MARK: Helpers

    /// Start of the 5-minute window holding `ts`.
    static func bucketStart(_ ts: Int) -> Int {
        Int((Double(ts) / Double(bucketSeconds)).rounded(.down)) * bucketSeconds
    }

    /// Whether the window starting at `start` overlaps any of `spans` (unix seconds, an activity's start
    /// and end). An activity that ends the very second a window starts shares no time with it.
    static func overlaps(_ start: Int, _ spans: [ClosedRange<Int>]) -> Bool {
        spans.contains { $0.lowerBound < start + bucketSeconds && $0.upperBound > start }
    }

    /// Whether the middle of the window starting at `start` falls inside a sleep.
    static func isAsleep(_ start: Int, _ sleepSpans: [ClosedRange<Int>]) -> Bool {
        let middle = start + bucketSeconds / 2
        return sleepSpans.contains { $0.contains(middle) }
    }

    /// Median of `values`, or nil when there are fewer than `atLeast`.
    static func median(_ values: [Double], atLeast: Int) -> Double? {
        guard values.count >= max(1, atLeast) else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
