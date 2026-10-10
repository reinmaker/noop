import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

/// WHOOP-style Stress Monitor: a 270-degree 0-3 gauge with the current level, the day's stress line with
/// sleep shaded, a one-line read of time in high stress, and WHOOP's three breakdown cards (Total Day,
/// Non Activity, Sleep), each a stacked bar of time in Low / Medium / High. The level is the line's
/// latest reading (the same value Home's Stress Monitor shows); the daily score stands in until the
/// first reading is scored.
struct WhoopStressHero: View {
    let daytime: DaytimeStress.Result?
    let dailyScore: Double?
    /// Today's sleep windows (unix seconds), shaded on the line and counted in the Sleep card.
    var sleepSpans: [ClosedRange<Int>] = []
    /// Today's workouts (unix seconds), left out of the Non Activity card.
    var activitySpans: [ClosedRange<Int>] = []
    let onBreathe: () -> Void

    /// The time under the reader's finger on the stress line.
    @State private var selection: Date?

    /// One scored reading on the stress line.
    struct Sample: Identifiable {
        let ts: Int
        let level: Double
        var time: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
        var id: Int { ts }
    }

    /// The scored readings of a day's stress, earliest first: what the line draws and the cards count.
    /// `nonisolated` so the Coach's context reads the day through the same steps as this screen.
    nonisolated static func scoredSamples(_ daytime: DaytimeStress.Result?) -> [Sample] {
        (daytime?.timeline ?? []).compactMap { p in p.level.map { Sample(ts: p.startTs, level: $0) } }
    }

    private var samples: [Sample] { Self.scoredSamples(daytime) }

    private static func word(_ level: Double) -> String {
        switch level {
        case ..<1: return String(localized: "LOW")
        case ..<2: return String(localized: "MEDIUM")
        default: return String(localized: "HIGH")
        }
    }

    /// The spacing between readings (5 minutes for WHOOP-style stress, longer for the hourly read).
    private nonisolated static func step(_ points: [Sample]) -> Int {
        let gaps = zip(points, points.dropFirst()).map { $1.ts - $0.ts }.filter { $0 > 0 }
        return min(3600, max(300, gaps.min() ?? 300))
    }

    /// Minutes in each band (0 low, 1 medium, 2 high) over the readings `include` keeps. Internal so the
    /// Coach quotes the TOTAL DAY card's figures rather than a count of its own.
    nonisolated static func minutesByBand(_ points: [Sample], include: (Int) -> Bool = { _ in true }) -> [Double] {
        let span = Double(step(points)) / 60
        var minutes = [0.0, 0.0, 0.0]
        for p in points where include(p.ts) {
            minutes[p.level < 1 ? 0 : (p.level < 2 ? 1 : 2)] += span
        }
        return minutes
    }

    /// "2:48", as WHOOP writes durations in its cards.
    private static func hm(_ minutes: Double) -> String {
        String(format: "%d:%02d", Int(minutes) / 60, Int(minutes) % 60)
    }

    /// "2 hr 48 min", as WHOOP writes them in a sentence.
    private static func hrMin(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return h > 0 ? String(localized: "\(h) hr \(m) min") : String(localized: "\(m) min")
    }

    private func inSleep(_ ts: Int) -> Bool { sleepSpans.contains { $0.contains(ts) } }
    private func inActivity(_ ts: Int) -> Bool { activitySpans.contains { $0.contains(ts) } }

    var body: some View {
        let points = samples
        let current = points.last?.level ?? dailyScore
        let total = Self.minutesByBand(points)
        VStack(spacing: NoopMetrics.space4) {
            gauge(current, at: points.last?.time)
            if points.count >= 2 {
                stressLine(points)
                Text(sentence(current: current, highMinutes: total[2]))
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                bandCard(title: String(localized: "TOTAL DAY"), icon: "circle.dashed", minutes: total,
                         note: String(localized: "Stress experienced throughout the day including sleep and activities."))
                bandCard(title: String(localized: "NON ACTIVITY"), icon: "figure.stand",
                         minutes: Self.minutesByBand(points) { !inSleep($0) && !inActivity($0) },
                         note: String(localized: "Stress experienced outside of Strain activities and sleep."))
                if !sleepSpans.isEmpty {
                    bandCard(title: String(localized: "SLEEP"), icon: "moon",
                             minutes: Self.minutesByBand(points) { inSleep($0) },
                             note: String(localized: "Stress experienced during sleep."))
                }
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

    private func sentence(current: Double?, highMinutes: Double) -> String {
        if highMinutes >= 1 {
            return String(localized: "You spent \(Self.hrMin(highMinutes)) in the high stress zone today.")
        }
        switch current ?? 0 {
        case ..<1:
            return String(localized: "Your body is signaling low stress. This indicates your cardiovascular system is stable, calm, and near its resting state.")
        case ..<2:
            return String(localized: "Your body is signaling medium stress. Your heart rate is running above its resting state.")
        default:
            return String(localized: "Your body is signaling high stress. Your heart rate is well above its resting state.")
        }
    }

    // MARK: Gauge

    private func gauge(_ level: Double?, at time: Date?) -> some View {
        let fraction = min(1, max(0, (level ?? 0) / 3))
        let diameter: CGFloat = 210
        return ZStack {
            // 270 degrees, open at the bottom: from bottom-left (0) clockwise to bottom-right (3).
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(AngularGradient(colors: [WhoopStyle.stressLow, WhoopStyle.stressMedium, WhoopStyle.stressHigh],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(135))
                .frame(width: diameter, height: diameter)
            if level != nil {
                Capsule()
                    .fill(StrandPalette.textPrimary)
                    .frame(width: 5, height: 24)
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
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
            HStack {
                Text("0.0")
                Spacer()
                Text("3.0")
            }
            .font(WhoopStyle.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(width: diameter * 0.78)
            .offset(y: diameter * 0.43)
        }
        .frame(width: diameter, height: diameter)
        .padding(.top, NoopMetrics.space2)
    }

    // MARK: Line

    private func stressLine(_ points: [Sample]) -> some View {
        let first = points.first?.ts ?? 0
        let last = points.last?.ts ?? 0
        let shaded = sleepSpans.compactMap { span -> ClosedRange<Int>? in
            let lo = max(span.lowerBound, first), hi = min(span.upperBound, last)
            return lo < hi ? lo...hi : nil
        }
        let picked = selection.flatMap { sel in
            points.min { abs($0.time.timeIntervalSince(sel)) < abs($1.time.timeIntervalSince(sel)) }
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            readout(picked)
            stressChart(points, shaded: shaded, picked: picked)
        }
    }

    /// The held reading: level, band and time. Empty, at the same height, when nothing is held.
    private func readout(_ picked: Sample?) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            if let picked {
                Text(String(format: "%.1f", picked.level))
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Self.word(picked.level))
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(WhoopStyle.stressBand(picked.level).color)
                Text(picked.time, format: .dateTime.hour().minute())
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
        }
        .frame(height: 16)
    }

    private func stressChart(_ points: [Sample], shaded: [ClosedRange<Int>], picked: Sample?) -> some View {
        Chart {
            ForEach(shaded.indices, id: \.self) { i in
                RectangleMark(xStart: .value("Sleep start", Date(timeIntervalSince1970: TimeInterval(shaded[i].lowerBound))),
                              xEnd: .value("Sleep end", Date(timeIntervalSince1970: TimeInterval(shaded[i].upperBound))),
                              yStart: .value("Bottom", 0.0), yEnd: .value("Top", 3.0))
                    .foregroundStyle(WhoopStyle.ringTrack.opacity(0.7))
                    .annotation(position: .top, alignment: .trailing) {
                        Image(systemName: "moon.fill").font(WhoopStyle.chevron).foregroundStyle(StrandPalette.textPrimary)
                    }
            }
            ForEach(points) { p in
                LineMark(x: .value("Time", p.time), y: .value("Stress", p.level))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [WhoopStyle.stressLow, WhoopStyle.stressMedium, WhoopStyle.stressHigh],
                                                    startPoint: .bottom, endPoint: .top))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let picked {
                RuleMark(x: .value("Time", picked.time))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", picked.time), y: .value("Stress", picked.level))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .symbolSize(36)
            }
        }
        .whoopScrub($selection)
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

    // MARK: Breakdown cards

    private func bandCard(title: String, icon: String, minutes: [Double], note: String) -> some View {
        let total = max(1, minutes.reduce(0, +))
        let bands: [(name: String, color: Color, minutes: Double)] = [
            (String(localized: "LOW"), WhoopStyle.stressLow, minutes[0]),
            (String(localized: "MEDIUM"), WhoopStyle.stressMedium, minutes[1]),
            (String(localized: "HIGH"), WhoopStyle.stressHigh, minutes[2]),
        ]
        let dayLabel = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: icon).font(WhoopStyle.chevron).foregroundStyle(StrandPalette.textSecondary)
                Text(title).font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(String(localized: "\(dayLabel) STRESS"))
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textSecondary)
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
            Text(note)
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(WhoopStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .whoopCard()
    }
}
