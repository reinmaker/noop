import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

/// WHOOP-style "Last Night's Sleep" on the Sleep screen: hours asleep against the prior 30 nights with
/// the night's heart-rate line, each stage against its typical range, restorative sleep, and Hours vs.
/// Needed broken into the personal need and the sleep debt. All values are NOOP's own for that night;
/// "typical" is the middle half (25th to 75th percentile) of the prior 30 nights.
struct WhoopLastNightCards: View {
    let night: Night
    let model: SleepModel
    let nightHR: [HRBucket]
    let days: [DailyMetric]
    /// One session per night (`Repository.sleeps`), for the Sleep Consistency chart.
    var sleeps: [CachedSleepSession] = []

    /// The time under the reader's finger on the heart-rate graph, as in WHOOP.
    @State private var hrSelection: Date?

    private var prior: [DailyMetric] { Array(days.dropLast().suffix(30)) }

    /// The day summary for this night (keyed by its wake day): the actual sleep and its stages, the
    /// figure Home shows. The merged night (`night.stages`) also counts time lying in bed before falling
    /// asleep, so it stands for time in bed here, not sleep.
    private var summary: DailyMetric? {
        let wake = Date(timeIntervalSince1970: TimeInterval(night.session.endTs))
        let key = Repository.logicalDayKey(wake)
        return days.last(where: { $0.day == key })
    }

    /// Actual sleep: the summary's total, else the night's own asleep minutes.
    private var asleepMinutes: Double { summary?.totalSleepMin ?? night.stages.asleep }

    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    private func typicalRange(_ pick: (DailyMetric) -> Double?) -> ClosedRange<Double>? {
        let values = prior.compactMap(pick)
        guard values.count >= 3, let lo = Self.percentile(values, 0.25), let hi = Self.percentile(values, 0.75) else { return nil }
        return lo...max(lo, hi)
    }

    private func typicalMedian(_ pick: (DailyMetric) -> Double?) -> Double? {
        Self.percentile(prior.compactMap(pick), 0.5)
    }

    static func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Last Night's Sleep")
                    .font(WhoopStyle.sectionTitle)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("vs. prior 30 nights")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            hoursOfSleepCard
            hoursVsNeededCard
            consistencyCard
            efficiencyCard
        }
    }

    // MARK: Hours of sleep + stages

    private var hoursOfSleepCard: some View {
        let s = night.stages
        let asleep = asleepMinutes
        // Time in bed is the whole night; never shorter than the sleep inside it.
        let inBed = max(s.total, asleep, 1)
        // Stages from the same summary as the hours, so Awake + Light + Deep + REM add up to time in bed.
        let light = summary?.lightMin ?? s.light
        let deep = summary?.deepMin ?? s.deep
        let rem = summary?.remMin ?? s.rem
        let awake = max(0, inBed - (light + deep + rem))
        let typicalAsleep = typicalMedian { $0.totalSleepMin }
        let awakeRange = typicalRange { d in
            guard let a = d.totalSleepMin, var e = d.efficiency, e > 0 else { return nil }
            if e > 1.5 { e /= 100 }
            return max(0, a / e - a)
        }
        let maxStage = max(inBed * 0.6, 60)

        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("HOURS OF SLEEP").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(Self.hm(asleep)).font(WhoopStyle.number(32)).foregroundStyle(StrandPalette.textPrimary)
                trendArrow(asleep, typicalAsleep, higherIsBetter: true)
            }
            if let typicalAsleep {
                Text(Self.hm(typicalAsleep)).font(WhoopStyle.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            heartRateLine
            Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(WhoopStyle.typicalBand).frame(width: 14, height: 10)
                Text("TYPICAL RANGE").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("DURATION").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                Text(Self.hm(inBed)).font(WhoopStyle.number(18)).foregroundStyle(StrandPalette.textPrimary)
            }
            stageRow(String(localized: "AWAKE"), minutes: awake, total: inBed, typical: awakeRange,
                     color: WhoopStyle.stageAwake, scale: maxStage)
            stageRow(String(localized: "LIGHT"), minutes: light, total: inBed, typical: typicalRange { $0.lightMin },
                     color: WhoopStyle.stageLight, scale: maxStage)
            stageRow(String(localized: "SWS (DEEP)"), minutes: deep, total: inBed, typical: typicalRange { $0.deepMin },
                     color: WhoopStyle.stageDeep, scale: maxStage)
            stageRow(String(localized: "REM"), minutes: rem, total: inBed, typical: typicalRange { $0.remMin },
                     color: WhoopStyle.stageREM, scale: maxStage)
            Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
            let restorative = deep + rem
            let typicalRestorative = typicalMedian { d in
                guard let deep = d.deepMin, let rem = d.remMin else { return nil }
                return deep + rem
            }
            HStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [WhoopStyle.stageREM, WhoopStyle.stageDeep],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                    .frame(width: 16, height: 16)
                Text("RESTORATIVE SLEEP").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: NoopMetrics.space1) {
                        Text(Self.hm(restorative)).font(WhoopStyle.number(20)).foregroundStyle(StrandPalette.textPrimary)
                        trendArrow(restorative, typicalRestorative, higherIsBetter: true)
                    }
                    if let typicalRestorative {
                        Text(Self.hm(typicalRestorative)).font(WhoopStyle.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }

    private struct HRPoint: Identifiable {
        let id: Int
        let time: Date
        let bpm: Double
    }

    @ViewBuilder private var heartRateLine: some View {
        let start = night.session.effectiveStartTs
        let end = night.session.endTs
        let points = nightHR
            .filter { $0.ts >= start - 60 && $0.ts <= end + 60 }
            .map { HRPoint(id: $0.ts, time: Date(timeIntervalSince1970: TimeInterval($0.ts)), bpm: $0.bpm) }
        if points.count >= 2 {
            let lo = (points.map(\.bpm).min() ?? 40) - 5
            let hi = (points.map(\.bpm).max() ?? 100) + 5
            let picked = hrSelection.flatMap { sel in
                points.min { abs($0.time.timeIntervalSince(sel)) < abs($1.time.timeIntervalSince(sel)) }
            }
            HStack(spacing: NoopMetrics.space2) {
                if let picked {
                    Text("\(Int(picked.bpm.rounded())) bpm")
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(picked.time, format: .dateTime.hour().minute())
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Text("Touch the graph to see your heart rate")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
            let chart = Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.time), y: .value("BPM", p.bpm))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StrandPalette.restColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                if let picked {
                    RuleMark(x: .value("Time", picked.time))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", picked.time), y: .value("BPM", picked.bpm))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .symbolSize(36)
                }
            }
            hrSelectable(chart)
            .chartYScale(domain: lo...hi)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
                    AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: [Date(timeIntervalSince1970: TimeInterval(start)),
                                   Date(timeIntervalSince1970: TimeInterval(end))]) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(height: 120)
        }
    }

    /// Drag across the graph to read the heart rate at a moment (iOS 17 and macOS 14 and later).
    @ViewBuilder private func hrSelectable<C: View>(_ chart: C) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            chart.chartXSelection(value: $hrSelection)
        } else {
            chart
        }
    }

    private func stageRow(_ name: String, minutes: Double, total: Double, typical: ClosedRange<Double>?,
                          color: Color, scale: Double) -> some View {
        let pct = Int((minutes / total * 100).rounded())
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Circle().strokeBorder(StrandPalette.textSecondary, lineWidth: 1.5).frame(width: 18, height: 18)
                Text(name).font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
                Text("\(pct)%").font(WhoopStyle.caption).foregroundStyle(color)
                Spacer()
                Text(Self.hm(minutes)).font(WhoopStyle.number(18)).foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    WhoopHatch().clipShape(RoundedRectangle(cornerRadius: 3))
                    if let typical {
                        Rectangle()
                            .fill(WhoopStyle.typicalBand)
                            .frame(width: max(2, w * CGFloat((typical.upperBound - typical.lowerBound) / scale)))
                            .offset(x: w * CGFloat(min(typical.lowerBound, scale) / scale))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: w * CGFloat(min(minutes, scale) / scale))
                }
            }
            .frame(height: 12)
        }
    }

    // MARK: Sleep Consistency (WHOOP: a bar per night from bedtime to wake, dashed usual times)

    private struct NightBar: Identifiable {
        let id: Int
        let label: String
        let bed: Double     // minutes after 18:00
        let wake: Double
        let latest: Bool
    }

    /// Minutes after 18:00 local, so an evening bedtime and a morning wake sit on one axis.
    private static func minutesAfterSix(_ ts: Int) -> Double {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        let m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        return (m - 18 * 60 + 24 * 60).truncatingRemainder(dividingBy: 24 * 60)
    }

    private static func clockLabel(_ minutesAfterSix: Double) -> String {
        let m = Int((minutesAfterSix + 18 * 60).truncatingRemainder(dividingBy: 24 * 60))
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    private var consistencyBars: [NightBar] {
        // One bar per night, the same nights the consistency score is computed over.
        let recent = Array(SleepModel.nightWindows(sleeps).suffix(5))
        return recent.enumerated().map { i, s in
            let bed = Self.minutesAfterSix(s.start)
            let duration = Double(s.end - s.start) / 60
            let day = Date(timeIntervalSince1970: TimeInterval(s.end))
            return NightBar(id: i, label: day.formatted(.dateTime.weekday(.abbreviated)), bed: bed,
                            wake: min(bed + max(0, duration), 20 * 60), latest: i == recent.count - 1)
        }
    }

    @ViewBuilder private var consistencyCard: some View {
        let bars = consistencyBars
        if bars.count >= 2 {
            let usualBed = bars.map(\.bed).reduce(0, +) / Double(bars.count)
            let usualWake = bars.map(\.wake).reduce(0, +) / Double(bars.count)
            let lo = max(0, (bars.map(\.bed).min() ?? 0) - 60)
            let hi = min(20 * 60, (bars.map(\.wake).max() ?? 20 * 60) + 60)
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("SLEEP CONSISTENCY").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(model.consistency.latest.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(WhoopStyle.number(32)).foregroundStyle(StrandPalette.textPrimary)
                    trendArrow(model.consistency.latest, model.consistency.typical, higherIsBetter: true)
                    Spacer()
                    Text("- - USUAL BED/WAKE TIME").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textTertiary)
                }
                if let typical = model.consistency.typical {
                    Text("\(Int(typical.rounded()))%").font(WhoopStyle.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Chart {
                    ForEach(bars) { b in
                        BarMark(x: .value("Night", b.label), yStart: .value("Bed", -b.bed), yEnd: .value("Wake", -b.wake),
                                width: .ratio(0.35))
                            .foregroundStyle(b.latest ? StrandPalette.restColor : StrandPalette.textTertiary.opacity(0.6))
                            .annotation(position: .top, spacing: 2) {
                                if b.latest {
                                    Text(Self.clockLabel(b.bed)).font(WhoopStyle.chevron).foregroundStyle(StrandPalette.textPrimary)
                                }
                            }
                            .annotation(position: .bottom, spacing: 2) {
                                if b.latest {
                                    Text(Self.clockLabel(b.wake)).font(WhoopStyle.chevron).foregroundStyle(StrandPalette.textPrimary)
                                }
                            }
                    }
                    RuleMark(y: .value("Usual bed", -usualBed))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    RuleMark(y: .value("Usual wake", -usualWake))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYScale(domain: (-hi)...(-lo))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .stride(by: 180)) { value in
                        AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Self.clockLabel(-v)).font(WhoopStyle.chevron).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().foregroundStyle(StrandPalette.textSecondary) }
                }
                .frame(height: 180)
            }
            .padding(WhoopStyle.compactPadding)
            .whoopCard()
        }
    }

    // MARK: Sleep Efficiency (WHOOP: asleep and awake across the night, wake events)

    @ViewBuilder private var efficiencyCard: some View {
        let figures = WhoopNightFigures.make(night: night, days: days)
        let segments = night.intervals
        let span = max(1, segments.map(\.end).max() ?? 1)
        let wakeEvents = segments.enumerated().filter { i, seg in
            seg.stage == .awake && i > 0 && i < segments.count - 1
        }.count
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("SLEEP EFFICIENCY").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
            Text("\(Int(figures.efficiency.rounded()))%").font(WhoopStyle.number(32)).foregroundStyle(StrandPalette.textPrimary)
            HStack {
                Text("ASLEEP").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(Self.hm(figures.asleep)).font(WhoopStyle.number(18)).foregroundStyle(StrandPalette.textPrimary)
            }
            timelineRow(segments, span: span, awake: false)
            timelineRow(segments, span: span, awake: true)
            HStack {
                Text("AWAKE").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(Self.hm(figures.awake)).font(WhoopStyle.number(18)).foregroundStyle(StrandPalette.textPrimary)
            }
            Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
            HStack {
                RoundedRectangle(cornerRadius: 2).fill(StrandPalette.textPrimary).frame(width: 12, height: 12)
                Text("WAKE EVENTS").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("\(wakeEvents)").font(WhoopStyle.number(20)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }

    /// One row of the night: asleep segments in blue, or awake segments in white on a striped track.
    private func timelineRow(_ segments: [SleepInterval], span: TimeInterval, awake: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                if awake {
                    WhoopHatch()
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(WhoopStyle.ringTrack)
                }
                ForEach(segments.filter { ($0.stage == .awake) == awake }) { seg in
                    Rectangle()
                        .fill(awake ? StrandPalette.textPrimary : StrandPalette.restColor)
                        .frame(width: max(1, w * CGFloat((seg.end - seg.start) / span)))
                        .offset(x: w * CGFloat(seg.start / span))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 14)
    }

    // MARK: Hours vs. Needed

    private var hoursVsNeededCard: some View {
        let asleep = asleepMinutes
        // The same percentage the contributor row above shows (both from the day summary's sleep).
        let pct = model.hoursVsNeeded.latest
        let needed = pct.map { $0 > 0 ? asleep / ($0 / 100) : asleep } ?? model.sleepDebtLedger.needMin
        // WHOOP splits Sleep Needed into a healthy minimum plus sleep debt. The debt is the same figure
        // the Night detail Sleep Debt tile shows, so the two never disagree.
        let debt = min(needed, max(0, model.sleepDebt.latest ?? 0))
        let healthyMin = needed - debt
        let scale = max(asleep, needed, 1)

        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("HOURS VS. NEEDED").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(WhoopStyle.number(32)).foregroundStyle(StrandPalette.textPrimary)
                trendArrow(pct, model.hoursVsNeeded.typical, higherIsBetter: true)
            }
            if let typical = model.hoursVsNeeded.typical {
                Text("\(Int(typical.rounded()))%").font(WhoopStyle.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            barRow(String(localized: "HOURS OF SLEEP"), Self.hm(asleep)) { w in
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [StrandPalette.restColor.opacity(0.5), StrandPalette.restColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w * CGFloat(asleep / scale))
            }
            barRow(String(localized: "SLEEP NEEDED"), Self.hm(needed)) { w in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 4).fill(StrandPalette.textTertiary)
                        .frame(width: w * CGFloat(healthyMin / scale))
                    if debt > 0 {
                        RoundedRectangle(cornerRadius: 4).fill(StrandPalette.textPrimary)
                            .frame(width: max(2, w * CGFloat(debt / scale) - 2))
                    }
                }
            }
            VStack(spacing: NoopMetrics.space2) {
                legendRow(StrandPalette.textTertiary, String(localized: "Healthy Minimum"), Self.hm(healthyMin))
                legendRow(StrandPalette.textPrimary, String(localized: "Sleep Debt"), "+" + Self.hm(debt))
            }
            .padding(NoopMetrics.space3)
            .background(RoundedRectangle(cornerRadius: 10).fill(WhoopStyle.ringTrack.opacity(0.6)))
        }
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }

    private func barRow<Bar: View>(_ label: String, _ value: String, @ViewBuilder bar: @escaping (CGFloat) -> Bar) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text(label).font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(value).font(WhoopStyle.number(18)).foregroundStyle(StrandPalette.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(WhoopStyle.ringTrack)
                    bar(geo.size.width)
                }
            }
            .frame(height: 14)
        }
    }

    private func legendRow(_ color: Color, _ label: String, _ value: String) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(label).font(WhoopStyle.body).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(value).font(WhoopStyle.detail).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    @ViewBuilder private func trendArrow(_ value: Double?, _ typical: Double?, higherIsBetter: Bool) -> some View {
        if let value, let typical, abs(value - typical) > max(1, typical * 0.02) {
            let up = value > typical
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(WhoopStyle.chevron)
                .foregroundStyle(up == higherIsBetter ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
        }
    }
}

// MARK: - Shared night figures

/// One night's sleep as the WHOOP-style Sleep screen shows it: actual sleep and stages from the day
/// summary (what Home shows), time in bed from the whole night, awake as the difference. The Last
/// Night's Sleep card, the efficiency card and the contributor rows all read this, so they agree.
struct WhoopNightFigures {
    let asleep: Double
    let inBed: Double
    let light: Double
    let deep: Double
    let rem: Double
    let awake: Double
    var efficiency: Double { inBed > 0 ? Swift.min(100, asleep / inBed * 100) : 0 }

    @MainActor
    static func make(night: Night, days: [DailyMetric]) -> WhoopNightFigures {
        let wake = Date(timeIntervalSince1970: TimeInterval(night.session.endTs))
        let summary = days.last(where: { $0.day == Repository.logicalDayKey(wake) })
        let s = night.stages
        let asleep = summary?.totalSleepMin ?? s.asleep
        let inBed = Swift.max(s.total, asleep, 1)
        let light = summary?.lightMin ?? s.light
        let deep = summary?.deepMin ?? s.deep
        let rem = summary?.remMin ?? s.rem
        return WhoopNightFigures(asleep: asleep, inBed: inBed, light: light, deep: deep, rem: rem,
                                 awake: Swift.max(0, inBed - (light + deep + rem)))
    }
}

/// WHOOP's diagonal-striped track (behind stage bars and the awake row).
struct WhoopHatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(WhoopStyle.ringTrack.opacity(0.5)))
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(WhoopStyle.ringTrack), lineWidth: 2)
                x += 6
            }
        }
    }
}
