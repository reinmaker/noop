import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

/// WHOOP-style top of the Stress Monitor screen: a 0-3 half-circle gauge with the current level, today's
/// stress line, a one-line read of time in high stress, and the Total Day card (time in Low / Medium /
/// High as a stacked bar). The level is the chart's latest reading (the same value Home's Stress Monitor
/// shows); the daily score stands in until the first hour is scored.
struct WhoopStressHero: View {
    let daytime: DaytimeStress.Result?
    let dailyScore: Double?
    let onBreathe: () -> Void

    private struct Sample: Identifiable {
        let time: Date
        let level: Double
        var id: Date { time }
    }

    private var samples: [Sample] {
        (daytime?.timeline ?? []).compactMap { p in
            p.level.map { Sample(time: Date(timeIntervalSince1970: TimeInterval(p.startTs)), level: $0) }
        }
    }

    private static func word(_ level: Double) -> String {
        switch level {
        case ..<1: return String(localized: "LOW")
        case ..<2: return String(localized: "MEDIUM")
        default: return String(localized: "HIGH")
        }
    }

    /// Minutes in each band (0 low, 1 medium, 2 high): each scored point stands for the span until the
    /// next one (an hour for the last).
    private static func minutesByBand(_ points: [Sample]) -> [Double] {
        var minutes = [0.0, 0.0, 0.0]
        for (i, p) in points.enumerated() {
            let next = i + 1 < points.count ? points[i + 1].time : p.time.addingTimeInterval(3600)
            let span = max(0, min(next.timeIntervalSince(p.time), 3 * 3600)) / 60
            minutes[p.level < 1 ? 0 : (p.level < 2 ? 1 : 2)] += span
        }
        return minutes
    }

    private static func hm(_ minutes: Double) -> String {
        String(format: "%d:%02d", Int(minutes) / 60, Int(minutes) % 60)
    }

    var body: some View {
        let points = samples
        let current = points.last?.level ?? dailyScore
        let minutes = Self.minutesByBand(points)
        VStack(spacing: NoopMetrics.space4) {
            gauge(current, at: points.last?.time)
            if points.count >= 2 {
                stressLine(points)
                Text("You spent \(Self.hm(minutes[2])) in the high stress zone today.")
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                totalDayCard(minutes)
            } else {
                Text("Your stress line fills in as the day's heart rate syncs.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Button(action: onBreathe) {
                WhoopActionButtonLabel(title: String(localized: "START BREATHWORK"), systemImage: "wind")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Gauge

    private func gauge(_ level: Double?, at time: Date?) -> some View {
        let fraction = min(1, max(0, (level ?? 0) / 3))
        return ZStack {
            // Half circle from 0 (left) to 3 (right), blue -> green -> orange.
            Circle()
                .trim(from: 0.5, to: 1.0)
                .stroke(AngularGradient(colors: [WhoopStyle.stressLow, WhoopStyle.stressMedium, WhoopStyle.stressHigh],
                                        center: .center, startAngle: .degrees(180), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
            // Marker at the current level.
            if level != nil {
                Capsule()
                    .fill(StrandPalette.textPrimary)
                    .frame(width: 4, height: 22)
                    .offset(y: -100)
                    .rotationEffect(.degrees(-90 + 180 * fraction))
            }
            VStack(spacing: NoopMetrics.space1) {
                Text(level.map { String(format: "%.1f", $0) } ?? "—")
                    .font(WhoopStyle.number(56))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let level {
                    Text(Self.word(level)).font(WhoopStyle.label).foregroundStyle(WhoopStyle.stressBand(level).color)
                }
                if let time {
                    Text(time, format: .dateTime.hour().minute())
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .offset(y: -10)
            HStack {
                Text("0.0")
                Spacer()
                Text("3.0")
            }
            .font(WhoopStyle.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(width: 230)
            .offset(y: 24)
        }
        .frame(width: 200, height: 200)
        .padding(.bottom, -70)
        .padding(.top, NoopMetrics.space2)
    }

    // MARK: Line

    private func stressLine(_ points: [Sample]) -> some View {
        Chart(points) { p in
            LineMark(x: .value("Time", p.time), y: .value("Stress", p.level))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [WhoopStyle.stressLow, WhoopStyle.stressMedium, WhoopStyle.stressHigh],
                                                startPoint: .bottom, endPoint: .top))
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { _ in
                AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(height: 170)
    }

    // MARK: Total Day

    private func totalDayCard(_ minutes: [Double]) -> some View {
        let total = max(1, minutes.reduce(0, +))
        let bands: [(name: String, color: Color, minutes: Double)] = [
            (String(localized: "LOW"), WhoopStyle.stressLow, minutes[0]),
            (String(localized: "MEDIUM"), WhoopStyle.stressMedium, minutes[1]),
            (String(localized: "HIGH"), WhoopStyle.stressHigh, minutes[2]),
        ]
        return WhoopTitledCard(title: String(localized: "TOTAL DAY"), showsChevron: false) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(bands.indices, id: \.self) { i in
                        Rectangle()
                            .fill(bands[i].color)
                            .frame(width: max(0, geo.size.width * CGFloat(bands[i].minutes / total) - 2))
                    }
                }
            }
            .frame(height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(alignment: .top) {
                ForEach(bands.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text(Self.hm(bands[i].minutes)).font(WhoopStyle.number(22)).foregroundStyle(StrandPalette.textPrimary)
                        HStack(spacing: NoopMetrics.space1) {
                            RoundedRectangle(cornerRadius: 2).fill(bands[i].color).frame(width: 10, height: 10)
                            Text(bands[i].name).font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Stress across the waking hours your strap scored today.")
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}
