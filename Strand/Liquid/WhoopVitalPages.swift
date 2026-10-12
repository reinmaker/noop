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

/// The VO₂ max page. Its headline is the row's own number, `Vo2Choice.used`, the one figure Home, this page and
/// WHOOP Age state; what stands behind it (which readings there are, which was chosen, the range) is the same card
/// WHOOP Age shows.
struct WhoopVo2MaxScreen: View {
    let figures: WhoopRowFigures

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var trend: [(day: String, value: Double)] = []
    @State private var choice: Vo2Choice?
    @State private var loaded = false
    @State private var showSettings = false

    /// The window of the trend, in days.
    private static let trendDays = 90

    var body: some View {
        WhoopDayPage(title: whoopPageTitle(day: figures.day, isToday: figures.isToday)) {
            WhoopPageHero(icon: "lungs", label: String(localized: "VO₂ MAX"),
                          value: figures.value.map { Int($0.rounded()).formatted() } ?? "--",
                          unit: "ml/kg/min", caption: rangeLine)
            WhoopPageSentence(text: String(localized: "VO₂ max is how much oxygen your body can use at full effort. A higher number means a fitter heart and lungs."))
            WhoopTrendCard(title: String(localized: "LAST 90 DAYS"), points: trend, tint: StrandPalette.chargeColor,
                           hint: choice?.source == .appleHealth
                               ? String(localized: "Apple Health's own readings, before the adjustment")
                               : String(localized: "Hold and drag to read a day"),
                           readout: { day, value in "\(dateText(day)): \(Int(value.rounded()).formatted())" })
            if let choice {
                WhoopAgeVo2Card(vo2: choice, onAddWaist: choice.source == .nes || profile.waistCm > 0 ? nil : { showSettings = true })
            }
            WhoopPageNote(title: String(localized: "HOW YOUR ESTIMATE IS MADE"),
                          lines: [String(localized: "It is an estimate, not a lab test, and VO₂ max is shown as the range it could be.")])
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
        .sheet(isPresented: $showSettings, onDismiss: { Task { await repo.refresh() } }) {
            NavigationStack { SettingsView() }
                #if os(macOS)
                .frame(width: 900, height: 820)
                #endif
        }
    }

    private func dateText(_ day: String) -> String {
        WhoopDayFigures.date(of: day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day
    }

    /// The range the headline stands in, under the number.
    private var rangeLine: String? {
        choice.map { String(localized: "Range \(WhoopAgeText.vo2Range($0))") }
    }

    private func load() async {
        let resolved = await Vo2Resolver.load(repo: repo, sex: profile.sex)
        choice = resolved
        let since = WhoopAge.dayKeys(endingOn: Repository.localDayKey(Date()), count: Self.trendDays).first ?? ""
        // The trend is the chosen source's own series, so the line and the headline come from the same place.
        if resolved?.source == .appleHealth {
            let health = await repo.exploreSeries(key: "vo2max", source: Repository.appleHealthSource)
            trend = health.filter { $0.day >= since }.map { (day: $0.day, value: $0.value) }
        } else {
            let all = await repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
            trend = all.filter { $0.day >= since }.map { (day: $0.day, value: $0.value) }
        }
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
