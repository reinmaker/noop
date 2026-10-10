import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// WHOOP-style fork: the Recovery and Strain score screens (the Home rings' tap-through) and the Coach
// pill that sits at the bottom of each score screen. Values are NOOP's own on-device numbers.

// MARK: - Coach pill

/// The pill at the bottom of a score screen: the Coach's one-line headline for that screen, cached for
/// the day. Tapping it opens the Coach with that headline as its first message, so the screen is not
/// analysed a second time; only a pill with no headline yet leaves the Coach to write its own opener.
struct WhoopCoachPill: View {
    let screen: AICoachEngine.CoachScreen

    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @State private var text: String?
    @State private var loading = false
    @State private var failed = false

    private var cacheKey: String {
        let d = repo.days.last
        var parts: [String] = [d?.day ?? ""]
        let recovery: Double? = d?.recovery
        let sleep: Double? = d?.totalSleepMin
        let strain: Double? = d?.strain.map { AICoachEngine.strain21($0) }
        parts.append(recovery.map { String(Int($0)) } ?? "")
        parts.append(sleep.map { String(Int($0)) } ?? "")
        parts.append(strain.map { String(Int($0)) } ?? "")
        return "whoopStyle.pill2." + screen.rawValue + "." + parts.joined(separator: "|")
    }

    var body: some View {
        Button(action: openCoach) {
            HStack(spacing: NoopMetrics.space3) {
                BrandMark(size: 34)
                Text(Self.inlineMarkdown(text ?? (loading ? String(localized: "Analyzing…")
                              : failed ? String(localized: "Couldn't reach your Coach. Tap to open it.")
                              : String(localized: "Ask your Coach about this"))))
                    .font(WhoopStyle.body)
                    .foregroundStyle(WhoopStyle.onGradient)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(WhoopStyle.detail)
                    .foregroundStyle(WhoopStyle.onGradient.opacity(0.7))
            }
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(WhoopStyle.coachButtonFill))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(WhoopStyle.cardStroke, lineWidth: 1))
            .shadow(color: WhoopStyle.coachButtonShadow, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space2)
        .task(id: cacheKey) { await load() }
    }

    /// Hand the shown headline to the Coach as its opener (`AICoachEngine.Opener.screenSummary`), then
    /// open it. With no headline yet the Coach writes its own opener about this screen.
    private func openCoach() {
        if let text, CoachBriefScheduler.coachMasterEnabled, coach.isConfigured {
            coach.nextOpener = .screenSummary(text, screen)
        }
        router.openCoach()
    }

    /// The reply's bold and italic marks rendered, not shown as asterisks.
    static func inlineMarkdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    private func load() async {
        let key = cacheKey
        if let cached = UserDefaults.standard.string(forKey: key) {
            text = cached
            return
        }
        text = nil
        guard coach.isConfigured, coach.dataConsent, !repo.days.isEmpty else { return }
        loading = true
        failed = false
        defer { loading = false }
        if let summary = await coach.screenSummary(screen) {
            text = summary
            UserDefaults.standard.set(summary, forKey: key)
        } else {
            failed = true
        }
    }
}

// MARK: - Shared score-screen pieces

/// One contributor row: icon, UPPERCASE name, today's value, the 30-day value under it, and an arrow
/// coloured by whether the move is good for that metric.
struct WhoopContributor: Identifiable {
    let id: String
    let label: String
    let icon: String
    let value: String
    let average: String?
    /// +1 when today is above normal, -1 below, 0 level or unknown.
    let direction: Int
    let higherIsBetter: Bool
}

struct WhoopContributorsCard: View {
    let rows: [WhoopContributor]
    var footer: String = String(localized: "Today vs. last 30 days")

    var body: some View {
        VStack(spacing: 0) {
            // The notch pointing up at the ring, as in WHOOP's score screens.
            Image(systemName: "triangle.fill")
                .font(WhoopStyle.detail)
                .foregroundStyle(WhoopStyle.cardFill)
                .offset(y: 4)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: NoopMetrics.space3) {
                        Image(systemName: row.icon)
                            .font(WhoopStyle.icon)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 24)
                        Text(row.label)
                            .font(WhoopStyle.smallLabel)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: NoopMetrics.space1)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(row.value)
                                .font(WhoopStyle.number(20))
                                .foregroundStyle(StrandPalette.textPrimary)
                            if let avg = row.average {
                                Text(avg)
                                    .font(WhoopStyle.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        arrow(row)
                    }
                    .padding(.vertical, NoopMetrics.space3)
                    if index < rows.count - 1 {
                        Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
                    }
                }
                HStack(spacing: NoopMetrics.space2) {
                    HStack(spacing: 1) {
                        Image(systemName: "arrowtriangle.up.fill").foregroundStyle(WhoopStyle.rangeGreen)
                        Image(systemName: "arrowtriangle.down.fill").foregroundStyle(WhoopStyle.rangeAmber)
                    }
                    .font(WhoopStyle.chevron)
                    Text(footer).font(WhoopStyle.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                }
                .padding(NoopMetrics.space3)
                .background(RoundedRectangle(cornerRadius: 10).fill(WhoopStyle.ringTrack.opacity(0.6)))
                .padding(.vertical, NoopMetrics.space3)
            }
            .padding(.horizontal, WhoopStyle.compactPadding)
            .whoopCard()
        }
    }

    @ViewBuilder private func arrow(_ row: WhoopContributor) -> some View {
        if row.direction != 0 {
            let good = (row.direction > 0) == row.higherIsBetter
            Image(systemName: row.direction > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(WhoopStyle.chevron)
                .foregroundStyle(good ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                .frame(width: 10)
        } else {
            Color.clear.frame(width: 10)
        }
    }
}

/// Builds a contributor from today's value and the prior 30 days.
enum WhoopContributorMath {
    static func make(id: String, label: String, icon: String, today: Double?, history: [Double],
                     decimals: Int = 0, suffix: String = "", floor: Double = -Double.infinity,
                     higherIsBetter: Bool) -> WhoopContributor {
        // Skip days below `floor` (barely recorded) so they cannot drag the 30-day normal to nothing.
        let history = history.filter { $0 > floor }
        func fmt(_ v: Double) -> String {
            (decimals > 0 ? String(format: "%.\(decimals)f", v) : Int(v.rounded()).formatted()) + suffix
        }
        let avg = history.count < 3 ? nil : history.reduce(0, +) / Double(history.count)
        var direction = 0
        if let t = today, let a = avg, abs(t - a) > max(0.0001, abs(a) * 0.01) { direction = t > a ? 1 : -1 }
        return WhoopContributor(id: id, label: label, icon: icon, value: today.map(fmt) ?? "—",
                                average: avg.map(fmt), direction: direction, higherIsBetter: higherIsBetter)
    }
}

/// A "Weekly Trends" bar chart card.
struct WhoopWeeklyBars: View {
    let title: String
    let points: [(day: String, value: Double, label: String, color: Color)]
    let maxValue: Double

    /// The bar under the reader's finger: the other bars dim and the day's value is read out.
    @State private var selected: String?

    /// Keyed by position, not by weekday: seven entries with a missing day among them span eight days,
    /// so two share a weekday, and a weekday key stacked them into one bar taller than the card.
    private struct Bar: Identifiable {
        let id: Int
        let day: String
        let value: Double
        let label: String
        let color: Color
        var key: String { String(id) }
    }

    var body: some View {
        WhoopTitledCard(title: title, showsChevron: false) {
            let bars = points.enumerated().map { Bar(id: $0.offset, day: $0.element.day, value: $0.element.value,
                                                     label: $0.element.label, color: $0.element.color) }
            if bars.isEmpty {
                Text("Fills in as days are scored.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Chart(bars) { bar in
                    let dimmed = selected != nil && selected != bar.key
                    BarMark(x: .value("Day", bar.key), y: .value("Value", bar.value), width: .ratio(0.5))
                        .foregroundStyle(bar.color.opacity(dimmed ? 0.3 : 1))
                        .annotation(position: .top, spacing: 2) {
                            Text(bar.label)
                                .font(selected == bar.key ? WhoopStyle.smallLabel : WhoopStyle.chevron)
                                .foregroundStyle(bar.color.opacity(dimmed ? 0.4 : 1))
                        }
                }
                // Room for the tallest bar and its label even when it passes the usual top.
                .chartYScale(domain: 0...(max(maxValue, bars.map(\.value).max() ?? 0) * 1.1))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            Text(value.as(String.self).flatMap { k in bars.first { $0.key == k }?.day } ?? "")
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .whoopScrub($selected)
                .frame(height: 170)
            }
        }
    }
}

/// The day Home is showing (set by Home's rings), so the Recovery and Strain screens open on that day.
@MainActor
enum WhoopSelectedDay {
    static var key: String?

    /// The shown day, the days up to and including it, and the 30 days before it.
    static func split(_ days: [DailyMetric]) -> (day: DailyMetric?, upTo: [DailyMetric], prior: [DailyMetric]) {
        guard !days.isEmpty else { return (nil, [], []) }
        let index = key.flatMap { k in days.lastIndex(where: { $0.day == k }) } ?? days.count - 1
        let upTo = Array(days[...index])
        return (days[index], upTo, Array(upTo.dropLast().suffix(30)))
    }

    /// The days within the seven calendar days ending on the last one. `suffix(7)` alone reaches back past
    /// a missing day, so a weekly chart showed eight days with one weekday twice.
    nonisolated static func lastWeek(_ days: [DailyMetric]) -> [DailyMetric] {
        guard let last = days.last, let end = WhoopDays.parser.date(from: last.day),
              let start = Calendar.current.date(byAdding: .day, value: -6, to: end) else { return Array(days.suffix(7)) }
        let from = WhoopDays.parser.string(from: start)
        return days.suffix(7).filter { $0.day >= from }
    }

    /// "TODAY" for the latest day, otherwise the weekday and date.
    static func title(_ day: DailyMetric?, days: [DailyMetric]) -> String {
        guard let day, day.day != days.last?.day,
              let date = WhoopDays.parser.date(from: day.day) else { return String(localized: "TODAY") }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }
}

private enum WhoopDays {
    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func short(_ key: String) -> String {
        guard let d = parser.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    /// The prior 30 days (excluding the latest day).
    static func prior(_ days: [DailyMetric]) -> ArraySlice<DailyMetric> {
        days.dropLast().suffix(30)
    }
}

// MARK: - Recovery

struct WhoopRecoveryScreen: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        let shown = WhoopSelectedDay.split(repo.days)
        let days = shown.upTo
        let today = shown.day
        let prior = shown.prior
        let sleepPerf = SleepModel.performanceSeries(days: days, importedSleep: repo.importedSleep,
                                                     sleeps: repo.sleeps)
        let rows = [
            WhoopContributorMath.make(id: "hrv", label: String(localized: "HEART RATE VARIABILITY"),
                                      icon: "waveform.path.ecg", today: today?.avgHrv,
                                      history: prior.compactMap(\.avgHrv), higherIsBetter: true),
            WhoopContributorMath.make(id: "rhr", label: String(localized: "RESTING HEART RATE"), icon: "heart",
                                      today: today?.restingHr.map(Double.init),
                                      history: prior.compactMap { $0.restingHr.map(Double.init) }, higherIsBetter: false),
            WhoopContributorMath.make(id: "resp", label: String(localized: "RESPIRATORY RATE"), icon: "lungs",
                                      today: today?.respRateBpm, history: prior.compactMap(\.respRateBpm),
                                      decimals: 1, higherIsBetter: false),
            WhoopContributorMath.make(id: "sleep", label: String(localized: "SLEEP PERFORMANCE"), icon: "moon",
                                      today: sleepPerf.latest, history: Array(sleepPerf.series.dropLast().suffix(30)),
                                      suffix: "%", higherIsBetter: true),
        ]
        let recovery = today?.recovery
        let week = WhoopSelectedDay.lastWeek(days)

        ScrollView {
            VStack(spacing: NoopMetrics.space4) {
                WhoopRingGauge(score: recovery,
                               tint: recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.chargeColor,
                               diameter: 230, lineWidth: 16, caption: String(localized: "RECOVERY"))
                    .padding(.top, NoopMetrics.space4)
                WhoopContributorsCard(rows: rows)
                Text("Weekly Trends")
                    .font(WhoopStyle.sectionTitle)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, NoopMetrics.space2)
                WhoopWeeklyBars(title: String(localized: "RECOVERY"),
                                points: week.compactMap { d in
                                    d.recovery.map { r -> (day: String, value: Double, label: String, color: Color) in
                                        (WhoopDays.short(d.day), r, "\(Int(r.rounded()))%", StrandPalette.recoveryColor(r))
                                    }
                                },
                                maxValue: 100)
                WhoopWeeklyBars(title: String(localized: "HEART RATE VARIABILITY"),
                                points: week.compactMap { d in
                                    d.avgHrv.map { h -> (day: String, value: Double, label: String, color: Color) in
                                        (WhoopDays.short(d.day), h, "\(Int(h.rounded()))", StrandPalette.restColor)
                                    }
                                },
                                maxValue: max(1, week.compactMap(\.avgHrv).max() ?? 1))
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space10)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text(WhoopSelectedDay.title(today, days: repo.days)))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) { WhoopCoachPill(screen: .recovery) }
    }
}

// MARK: - Strain

struct WhoopStrainScreen: View {
    @EnvironmentObject private var repo: Repository
    @State private var activityMinutes: Double?
    @State private var workoutCount = 0
    @State private var appleSteps: [String: Double] = [:]

    var body: some View {
        let shown = WhoopSelectedDay.split(repo.days)
        let days = shown.upTo
        let today = shown.day
        let prior = shown.prior
        let strain = today?.strain.map(AICoachEngine.strain21)
        let band = CoupledView.optimalStrainRange(recovery: today?.recovery)
        let rows = [
            WhoopContributor(id: "activity", label: String(localized: "ACTIVITY TIME"), icon: "stopwatch",
                             value: activityMinutes.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "0:00",
                             average: workoutCount == 1 ? String(localized: "1 activity")
                                                        : String(localized: "\(workoutCount) activities"),
                             direction: 0, higherIsBetter: true),
            // Steps: the iPhone's count first (the strap's reads low), as on Home.
            WhoopContributorMath.make(id: "steps", label: String(localized: "STEPS"), icon: "shoeprints.fill",
                                      today: today.flatMap { appleSteps[$0.day] } ?? today?.steps.map(Double.init),
                                      history: prior.compactMap { appleSteps[$0.day] ?? $0.steps.map(Double.init) },
                                      floor: 1000, higherIsBetter: true),
            WhoopContributorMath.make(id: "kcal", label: String(localized: "CALORIES"), icon: "flame",
                                      today: today?.activeKcalEst, history: prior.compactMap(\.activeKcalEst),
                                      floor: 100, higherIsBetter: true),
            WhoopContributorMath.make(id: "strain", label: String(localized: "DAY STRAIN"), icon: "bolt",
                                      today: strain, history: prior.compactMap { $0.strain.map(AICoachEngine.strain21) },
                                      decimals: 1, higherIsBetter: true),
        ]

        ScrollView {
            VStack(spacing: NoopMetrics.space4) {
                WhoopRingGauge(score: strain, maxValue: 21, decimals: 1, showsPercent: false,
                               tint: StrandPalette.effortColor, diameter: 230, lineWidth: 16,
                               caption: String(localized: "STRAIN"),
                               band: band.map { Double($0.lowerBound)...Double($0.upperBound) })
                    .padding(.top, NoopMetrics.space4)
                if let band {
                    Text("Optimal Strain today: \(band.lowerBound)-\(band.upperBound)")
                        .font(WhoopStyle.detail)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                WhoopContributorsCard(rows: rows)
                Text("Weekly Trends")
                    .font(WhoopStyle.sectionTitle)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, NoopMetrics.space2)
                WhoopWeeklyBars(title: String(localized: "STRAIN"),
                                points: WhoopSelectedDay.lastWeek(days).compactMap { d in
                                    d.strain.map { s -> (day: String, value: Double, label: String, color: Color) in
                                        let v = AICoachEngine.strain21(s)
                                        return (WhoopDays.short(d.day), v, String(format: "%.1f", v), StrandPalette.effortColor)
                                    }
                                },
                                maxValue: 21)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space10)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text(WhoopSelectedDay.title(today, days: repo.days)))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) { WhoopCoachPill(screen: .strain) }
        .task {
            // Activities on the shown day.
            let dayStart = (today.flatMap { WhoopDays.parser.date(from: $0.day) })
                .map { Calendar.current.startOfDay(for: $0) } ?? Calendar.current.startOfDay(for: Date())
            let start = dayStart.timeIntervalSince1970
            let end = start + 24 * 3600
            let rows = await repo.workoutRows(days: 40).filter {
                TimeInterval($0.startTs) >= start && TimeInterval($0.startTs) < end
            }
            workoutCount = rows.count
            appleSteps = Dictionary((await repo.appleDailyRows(days: 40)).compactMap { r in r.steps.map { (r.day, Double($0)) } },
                                    uniquingKeysWith: { a, b in max(a, b) })
            activityMinutes = rows.reduce(0) { $0 + Double($1.endTs - $1.startTs) / 60 }
        }
    }
}
