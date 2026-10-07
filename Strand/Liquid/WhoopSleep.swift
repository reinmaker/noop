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

    private var prior: [DailyMetric] { Array(days.dropLast().suffix(30)) }

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
        }
    }

    // MARK: Hours of sleep + stages

    private var hoursOfSleepCard: some View {
        let s = night.stages
        let asleep = s.asleep
        let inBed = max(s.total, 1)
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
                Text(Self.hm(s.total)).font(WhoopStyle.number(18)).foregroundStyle(StrandPalette.textPrimary)
            }
            stageRow(String(localized: "AWAKE"), minutes: s.awake, total: inBed, typical: awakeRange,
                     color: WhoopStyle.stageAwake, scale: maxStage)
            stageRow(String(localized: "LIGHT"), minutes: s.light, total: inBed, typical: typicalRange { $0.lightMin },
                     color: WhoopStyle.stageLight, scale: maxStage)
            stageRow(String(localized: "SWS (DEEP)"), minutes: s.deep, total: inBed, typical: typicalRange { $0.deepMin },
                     color: WhoopStyle.stageDeep, scale: maxStage)
            stageRow(String(localized: "REM"), minutes: s.rem, total: inBed, typical: typicalRange { $0.remMin },
                     color: WhoopStyle.stageREM, scale: maxStage)
            Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
            let restorative = s.deep + s.rem
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
            Chart(points) { p in
                LineMark(x: .value("Time", p.time), y: .value("BPM", p.bpm))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(StrandPalette.restColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
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
                    RoundedRectangle(cornerRadius: 3).fill(WhoopStyle.ringTrack)
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

    // MARK: Hours vs. Needed

    private var hoursVsNeededCard: some View {
        let asleep = night.stages.asleep
        // The same percentage the contributor row above shows, so the two never disagree.
        let pct = model.hoursVsNeeded.latest
        let needed = pct.map { $0 > 0 ? asleep / ($0 / 100) : asleep } ?? model.sleepDebtLedger.needMin
        let healthyMin = min(model.sleepDebtLedger.needMin, needed)
        let debt = max(0, needed - healthyMin)
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
