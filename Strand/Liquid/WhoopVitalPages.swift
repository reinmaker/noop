import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

// WHOOP-style fork: the pages behind My Dashboard's VO₂ MAX and BLOOD OXYGEN rows. Each headline is the
// row's own number, passed in from Home; the trend is the series that number is the latest point of. Both
// pages say what the number is and is not: neither is a lab or clinical measurement.

// MARK: - A trend line

/// A short trend: points joined by a line, the latest one marked, with a hold-and-drag readout.
private struct WhoopTrendCard: View {
    let title: String
    let points: [(day: String, value: Double)]
    let tint: Color
    /// The hint line when no point is held.
    let hint: String
    /// How a held point reads: "10 Oct: 54".
    let readout: (String, Double) -> String
    var upperBound: Double?

    @State private var selected: Date?

    private struct Point: Identifiable {
        let date: Date
        let day: String
        let value: Double
        var id: String { day }
    }

    private var series: [Point] {
        points.compactMap { item in
            WhoopDayFigures.date(of: item.day).map { Point(date: $0, day: item.day, value: item.value) }
        }
    }

    private var held: Point? {
        guard let selected else { return nil }
        return series.min { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }
    }

    var body: some View {
        let series = series
        WhoopTitledCard(title: title, showsChevron: false) {
            if series.count < 2 {
                Text("A trend appears once there are two readings.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text(held.map { readout($0.day, $0.value) } ?? hint)
                    .font(WhoopStyle.detail)
                    .foregroundStyle(held == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                let values = series.map(\.value)
                let low = (values.min() ?? 0) - 2
                let high = min(upperBound ?? .infinity, (values.max() ?? 0) + 2)
                Chart(series) { point in
                    LineMark(x: .value("Day", point.date), y: .value("Value", point.value))
                        .foregroundStyle(tint.opacity(0.7))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Day", point.date), y: .value("Value", point.value))
                        .foregroundStyle(tint)
                        .symbolSize(held?.id == point.id || point.id == series.last?.id ? 70 : 28)
                }
                .chartYScale(domain: low...max(high, low + 1))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(WhoopStyle.cardStroke)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel().foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .whoopScrub($selected)
                .frame(height: 170)
            }
        }
    }
}

// MARK: - VO₂ Max

struct WhoopVo2MaxScreen: View {
    let figures: WhoopRowFigures

    @EnvironmentObject private var repo: Repository

    @State private var trend: [(day: String, value: Double)] = []
    @State private var estimator: Vo2MaxEstimator?
    @State private var apple: (day: String, value: Double)?
    @State private var loaded = false

    /// The window of the trend, in days.
    private static let trendDays = 90

    private var latest: (day: String, value: Double)? { trend.last }

    var body: some View {
        WhoopDayPage(title: whoopPageTitle(day: figures.day, isToday: figures.isToday)) {
            WhoopPageHero(icon: "lungs", label: String(localized: "VO₂ MAX"),
                          value: figures.value.map { Int($0.rounded()).formatted() } ?? "--",
                          unit: "ml/kg/min", caption: latestLine)
            WhoopPageSentence(text: String(localized: "VO₂ max is how much oxygen your body can use at full effort. A higher number means a fitter heart and lungs."))
            WhoopTrendCard(title: String(localized: "LAST 90 DAYS"), points: trend, tint: StrandPalette.chargeColor,
                           hint: String(localized: "Hold and drag to read a day"),
                           readout: { day, value in "\(dateText(day)): \(Int(value.rounded()).formatted())" })
            if let apple {
                WhoopPageFigureCard(title: String(localized: "APPLE HEALTH READING"),
                                    value: Int(apple.value.rounded()).formatted(), unit: "ml/kg/min",
                                    detail: String(localized: "\(dateText(apple.day)). From your Health data, which measures it a different way, so the two can differ."))
            }
            WhoopPageNote(title: String(localized: "HOW YOUR ESTIMATE IS MADE"), lines: methodLines)
            NavigationLink(value: TabRoute.metric("fitness_age")) {
                WhoopActionButtonLabel(title: String(localized: "SEE FITNESS AGE TREND"),
                                       systemImage: "chart.line.uptrend.xyaxis")
            }
            .buttonStyle(.plain)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WhoopCoachPill(screen: .vo2max, figure: figures.value.map { String(Int($0.rounded())) } ?? "")
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private func dateText(_ day: String) -> String {
        WhoopDayFigures.date(of: day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day
    }

    /// Which night the row's number is from: the series' newest point, which can be after the shown day.
    private var latestLine: String? {
        latest.map { String(localized: "Latest estimate, \(dateText($0.day))") }
    }

    private var methodLines: [String] {
        var lines: [String]
        switch estimator {
        case .uth:
            lines = [String(localized: "Yoop estimates it from your heart rate alone: 15.3 times your estimated maximum heart rate, divided by your resting heart rate. It moves with your resting heart rate, so a lower resting heart rate reads as fitter.")]
        case .nes:
            lines = [String(localized: "Yoop estimates it from your age, sex, waist, resting heart rate and how active you are. The model it comes from is typically within 5 to 6 ml/kg/min of a lab test.")]
        case nil:
            lines = [String(localized: "Yoop estimates it from your heart rate and your profile.")]
        }
        lines.append(String(localized: "It is an estimate, not a lab test. A new one is made each week."))
        return lines
    }

    private func load() async {
        let all = await repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        let since = WhoopDayFigures.dayKeys(endingOn: Repository.localDayKey(Date()), count: Self.trendDays).first ?? ""
        trend = all.filter { $0.day >= since }.map { (day: $0.day, value: $0.value) }
        if let last = all.last {
            let resolved = await repo.resolvedSeries(key: "vo2max_est", source: "my-whoop")
            let point = resolved.points.last { $0.day == last.day } ?? resolved.points.last
            if let point {
                let tag = await repo.scoreProvenanceTag(resolvedSource: point.source, day: point.day,
                                                        metricKey: "vo2max_est")
                estimator = tag.flatMap { Vo2MaxEstimator(rawValue: $0) }
            }
        }
        let health = await repo.exploreSeries(key: "vo2max", source: Repository.appleHealthSource)
        apple = health.last.flatMap { $0.day >= since ? (day: $0.day, value: $0.value) : nil }
        loaded = true
    }
}

// MARK: - Blood oxygen

struct WhoopBloodOxygenScreen: View {
    let figures: WhoopRowFigures

    @EnvironmentObject private var repo: Repository

    /// The nights with a reading up to the shown day, newest last: the row's own number for the shown day.
    private var nights: [(day: String, value: Double)] {
        WhoopDayFigures.recent(days: repo.days.filter { $0.day <= figures.day }, endingOn: figures.day, count: 30,
                               shown: figures.value) { $0.spo2Pct }
    }

    /// Where the shown night's reading came from, by the source the merged day took it from.
    private var sourceLine: String? {
        let rows = repo.vitalRows.filter { $0.metric.day == figures.day && $0.metric.spo2Pct != nil }
        guard let source = rows.min(by: { $0.source.vitalPriority < $1.source.vitalPriority })?.source else { return nil }
        switch source {
        case .whoopImport: return String(localized: "From your WHOOP export")
        case .appleHealth: return String(localized: "From your Apple Health data")
        case .noopComputed, .localCache: return String(localized: "Saved on this device")
        }
    }

    var body: some View {
        let nights = nights
        let range = nights.count >= 3 ? nights.map(\.value) : []
        WhoopDayPage(title: whoopPageTitle(day: figures.day, isToday: figures.isToday)) {
            WhoopPageHero(icon: "drop", label: String(localized: "BLOOD OXYGEN"),
                          value: figures.value.map { Int($0.rounded()).formatted() } ?? "--", unit: "%",
                          normal: figures.average.map { Int($0.rounded()).formatted() },
                          direction: WhoopDayFigures.direction(value: figures.value, normal: figures.average),
                          caption: sourceLine)
            if let low = range.min(), let high = range.max() {
                WhoopPageFigureCard(title: String(localized: "30-DAY RANGE"),
                                    value: "\(Int(low.rounded()))-\(Int(high.rounded()))", unit: "%",
                                    detail: String(localized: "Nights counted: \(range.count.formatted())."))
            }
            WhoopTrendCard(title: String(localized: "LAST 30 NIGHTS"), points: nights, tint: StrandPalette.metricCyan,
                           hint: String(localized: "Hold and drag to read a night"),
                           readout: { day, value in "\(dateText(day)): \(Int(value.rounded()))%" }, upperBound: 100)
            WhoopPageNote(title: String(localized: "ABOUT THIS READING"), lines: [
                String(localized: "Your strap does not measure blood oxygen as a percentage. This reading comes from data you imported, a WHOOP export or Apple Health, so it only reaches as far as that import."),
                String(localized: "It is not a medical measurement. The unverified strap estimate in Settings is shown separately and is never used here."),
            ])
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WhoopCoachPill(screen: .bloodOxygen, figure: figures.value.map { String(Int($0.rounded())) } ?? "")
        }
    }

    private func dateText(_ day: String) -> String {
        WhoopDayFigures.date(of: day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day
    }
}
