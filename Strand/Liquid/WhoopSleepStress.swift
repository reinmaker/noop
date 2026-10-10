import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

/// One night's stress the WHOOP way (`WhoopStressCurve`): each 5-minute bucket of the night's heart rate
/// read against the user's own last 14 days, as the Stress screen reads a day. The Sleep screen's SLEEP
/// STRESS card, its HIGH SLEEP STRESS contributor row and the heart-rate graph's readout all read this one
/// curve, so the three cannot disagree.
struct SleepStressNight {
    /// The night's scored 5-minute readings, earliest first.
    let points: [WhoopStressHero.Sample]
    /// Minutes in low, medium and high stress over `points` (`WhoopStressHero.minutesByBand`).
    let bandMinutes: [Double]

    /// HIGH SLEEP STRESS bands, where lower is better: up to 5% of the night in high stress is optimal
    /// (WHOOP reads 0% on a normal night), up to 15% sufficient, more than that poor.
    static let optimalMaxPercent: Double = 5
    static let sufficientMaxPercent: Double = 15

    /// Percent of the night's scored sleep spent in high stress, for the HIGH SLEEP STRESS row.
    var highPercent: Double? { Self.highStressPercent(bandMinutes: bandMinutes) }

    /// The high share of `bandMinutes` (low, medium, high), in percent; nil when nothing was scored.
    static func highStressPercent(bandMinutes: [Double]) -> Double? {
        guard bandMinutes.count == 3 else { return nil }
        let total = bandMinutes.reduce(0, +)
        guard total > 0 else { return nil }
        return bandMinutes[2] / total * 100
    }

    /// The night's readings from a scored stress result; nil when it scored nothing.
    static func make(_ result: DaytimeStress.Result) -> SleepStressNight? {
        let points = WhoopStressHero.scoredSamples(result.timeline)
        guard !points.isEmpty else { return nil }
        return SleepStressNight(points: points, bandMinutes: WhoopStressHero.minutesByBand(points))
    }

    /// The level of the 5-minute reading holding `ts`, or nil when that bucket was not scored.
    func level(at ts: Int) -> Double? {
        points.last(where: { $0.ts <= ts && ts < $0.ts + WhoopStressCurve.bucketSeconds })?.level
    }

    /// Scores the night of `session`, from falling asleep to waking: its heart rate against the resting
    /// rate and the 14 days before it ended. Nil when WHOOP-style stress is off
    /// (`StressDayCurve.whoopRestingHR`) or the night has no heart rate. Not `StressDayCurve.today`, which
    /// is memoized and covers today only.
    @MainActor
    static func load(repo: Repository, session: CachedSleepSession) async -> SleepStressNight? {
        guard let restHR = StressDayCurve.whoopRestingHR(repo) else { return nil }
        let from = session.effectiveStartTs, to = session.endTs
        guard to > from else { return nil }
        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        guard !hr.isEmpty else { return nil }
        let reference = await StressDayCurve.whoopStressReference(repo, to: to)
        let tz = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(to)))
        let result = await runUnescalated(priority: .userInitiated) {
            WhoopStressCurve.analyze(hr: hr, restingHR: restHR, tzOffsetSeconds: tz, reference: reference)
        }
        return make(result)
    }
}

extension Night {
    /// The recorded sleep stage at `ts`, from the night's real per-epoch timeline. Nil outside the night,
    /// and for a night whose timeline is rebuilt from stage totals (an import), where the stage at any one
    /// moment would be made up.
    func recordedStage(at ts: Int) -> SleepStage? {
        guard let segments = realSegments, segments.count >= 2 else { return nil }
        let offset = TimeInterval(ts - session.effectiveStartTs)
        return segments.first(where: { offset >= $0.start && offset < $0.end })?.stage
    }
}

/// WHOOP-style SLEEP STRESS card on the Sleep screen: the night's stress line (0 to 3) and the time asleep
/// in low, medium and high stress, from the same curve as the HIGH SLEEP STRESS row.
struct WhoopSleepStressCard: View {
    let stress: SleepStressNight
    /// The night's span (unix seconds), labelled on the time axis.
    let start: Int
    let end: Int

    var body: some View {
        let bands: [(name: String, color: Color, minutes: Double)] = [
            (String(localized: "LOW"), WhoopStyle.stressLow, stress.bandMinutes[0]),
            (String(localized: "MEDIUM"), WhoopStyle.stressMedium, stress.bandMinutes[1]),
            (String(localized: "HIGH"), WhoopStyle.stressHigh, stress.bandMinutes[2]),
        ]
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("SLEEP STRESS").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
            if stress.points.count >= 2 {
                stressLine
            }
            HStack(alignment: .top) {
                ForEach(bands.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text(WhoopLastNightCards.hm(bands[i].minutes))
                            .font(WhoopStyle.number(22))
                            .foregroundStyle(StrandPalette.textPrimary)
                        HStack(spacing: NoopMetrics.space1) {
                            RoundedRectangle(cornerRadius: 2).fill(bands[i].color).frame(width: 10, height: 10)
                            Text(bands[i].name).font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Stress experienced during sleep.")
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WhoopStyle.compactPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .whoopCard()
    }

    /// The night's stress line on WHOOP's 0 to 3 scale, labelled at falling asleep and waking.
    private var stressLine: some View {
        let points = stress.points
        let startDate = Date(timeIntervalSince1970: TimeInterval(start))
        let endDate = Date(timeIntervalSince1970: TimeInterval(end))
        // A bucket starts on a 5-minute boundary, so the first can sit just before falling asleep.
        let lo = min(startDate, points.first?.time ?? startDate)
        let hi = max(endDate, points.last?.time ?? endDate)
        return Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.time), y: .value("Stress", p.level))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [WhoopStyle.stressLow, WhoopStyle.stressMedium, WhoopStyle.stressHigh],
                                                    startPoint: .bottom, endPoint: .top))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXScale(domain: lo...hi)
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { _ in
                AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: [startDate, endDate]) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(height: 120)
    }
}
