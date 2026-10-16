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
    /// The figure the screen's headline states, so a new figure writes a new headline rather than reusing
    /// one cached for the old number. Empty for the score screens, whose key already follows their scores.
    var figure: String = ""

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
        let strain: Double? = d.flatMap { repo.dayStrain($0) }.map { AICoachEngine.strain21($0) }
        parts.append(recovery.map { String(Int($0)) } ?? "")
        parts.append(sleep.map { String(Int($0)) } ?? "")
        parts.append(strain.map { String(Int($0)) } ?? "")
        if !figure.isEmpty { parts.append(figure) }
        return "whoopStyle.pill3." + screen.rawValue + "." + parts.joined(separator: "|")
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
    /// The stored `sleep_performance` series by day, the read Home's SLEEP ring makes, so this screen's
    /// SLEEP PERFORMANCE row states the same number.
    @State private var storedSleep: [String: Double] = [:]

    /// The mean of a 30-day history, nil with fewer than three days (as the contributor rows read it).
    private static func usual(_ values: [Double]) -> Double? {
        values.count < 3 ? nil : values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        // Each day's Strain as the Strain ring shows it, which a night's need reads (`SleepModel.nightNeed`).
        let shown = WhoopSelectedDay.split(repo.strainDays)
        let days = shown.upTo
        let today = shown.day
        let prior = shown.prior
        let sleepPerf = SleepModel.performanceSeries(days: days, importedSleep: repo.importedSleep,
                                                     sleeps: repo.sleeps, stored: storedSleep)
        let sleepHistory = Array(sleepPerf.series.dropLast().suffix(30))
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
                                      today: sleepPerf.latest, history: sleepHistory,
                                      suffix: "%", higherIsBetter: true),
        ]
        let recovery = today?.recovery
        let week = WhoopSelectedDay.lastWeek(days)
        // The sentence is about the latest day only: it speaks of today.
        let isLatest = today?.day != nil && today?.day == days.last?.day && today?.day == repo.strainDays.last?.day
        let readings: [WhoopScoreInsightText.Reading] = [
            .init(driver: .hrv, today: today?.avgHrv, usual: Self.usual(prior.compactMap(\.avgHrv))),
            .init(driver: .restingHr, today: today?.restingHr.map(Double.init),
                  usual: Self.usual(prior.compactMap { $0.restingHr.map(Double.init) })),
            .init(driver: .respiratory, today: today?.respRateBpm, usual: Self.usual(prior.compactMap(\.respRateBpm))),
            .init(driver: .sleep, today: sleepPerf.latest, usual: Self.usual(sleepHistory)),
        ]

        ScrollView {
            VStack(spacing: NoopMetrics.space4) {
                WhoopRingGauge(score: recovery,
                               tint: recovery.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.chargeColor,
                               diameter: 230, lineWidth: 16, caption: String(localized: "RECOVERY"))
                    .padding(.top, NoopMetrics.space4)
                WhoopContributorsCard(rows: rows)
                if isLatest, let recovery {
                    WhoopOutlineInsightCard(
                        text: WhoopScoreInsightText.recoverySentence(recovery: recovery, readings: readings),
                        linkTitle: String(localized: "EXPLORE RECOVERY INSIGHTS"),
                        prompt: "Explain today's Recovery of \(Int(recovery.rounded()))%: what is behind it in my HRV, "
                            + "resting heart rate, breathing rate and last night's sleep against my normal, and what "
                            + "I should do today.")
                }
                if let day = today?.day { WhoopRecoveryBehaviorsCard(day: day) }
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
                WhoopWeeklyBars(title: String(localized: "RESTING HEART RATE"),
                                points: week.compactMap { d in
                                    d.restingHr.map { r -> (day: String, value: Double, label: String, color: Color) in
                                        (WhoopDays.short(d.day), Double(r), "\(r)", WhoopStyle.stressLow)
                                    }
                                },
                                maxValue: max(1, week.compactMap { $0.restingHr.map(Double.init) }.max() ?? 1))
                WhoopWeeklyBars(title: String(localized: "RESPIRATORY RATE"),
                                points: week.compactMap { d in
                                    d.respRateBpm.map { r -> (day: String, value: Double, label: String, color: Color) in
                                        (WhoopDays.short(d.day), r, String(format: "%.1f", r), WhoopStyle.stressMedium)
                                    }
                                },
                                maxValue: max(1, week.compactMap(\.respRateBpm).max() ?? 1))
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
        .task(id: repo.refreshSeq) {
            let series = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            storedSleep = Dictionary(series.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }
}

// MARK: - Strain

struct WhoopStrainScreen: View {
    @EnvironmentObject private var repo: Repository
    /// The shown day's logged activities, newest last.
    @State private var workouts: [WorkoutRow] = []
    /// Time in zones and in strength activity for each of the last days (`WhoopStrainFigures`).
    @State private var figures: [String: WhoopDayActivityFigures] = [:]
    @State private var appleSteps: [String: Double] = [:]
    @State private var figuresSignature = ""

    /// One contributor row of a time figure (hours and minutes) against its 30-day usual.
    private static func timeRow(id: String, label: String, icon: String, minutes: Double,
                                usual: Double?) -> WhoopContributor {
        var direction = 0
        if let usual, abs(minutes - usual) > max(1, usual * 0.01) { direction = minutes > usual ? 1 : -1 }
        return WhoopContributor(id: id, label: label, icon: icon, value: WhoopStrainFigures.hoursAndMinutes(minutes),
                                average: usual.map(WhoopStrainFigures.hoursAndMinutes), direction: direction,
                                higherIsBetter: true)
    }

    /// What the Coach is asked from the Strain screen's link.
    private static func strainPrompt(strain: Double, band: ClosedRange<Int>?) -> String {
        var text = "Explain my Strain so far today (" + String(format: "%.1f", strain) + ") against my optimal range"
        if let band { text += " of \(band.lowerBound) to \(band.upperBound)" }
        return text + ": what drove it, and what should I do for the rest of the day?"
    }

    /// A compact count for a bar's label: 18762 as "18.8K".
    private static func thousands(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1fK", value / 1000) : "\(Int(value.rounded()))"
    }

    var body: some View {
        // Strain through the one funnel (`Repository.strainDays`): the ring, the contributor row and the
        // weekly bars read what Home reads, effort ratings included.
        let shown = WhoopSelectedDay.split(repo.strainDays)
        let days = shown.upTo
        let today = shown.day
        let prior = shown.prior
        let strain = today?.strain.map(AICoachEngine.strain21)
        let band = CoupledView.optimalStrainRange(recovery: today?.recovery)
        let key = today?.day ?? ""
        let figure = figures[key] ?? WhoopDayActivityFigures()
        let isLatest = !key.isEmpty && key == repo.strainDays.last?.day
        let rows = [
            Self.timeRow(id: "z13", label: String(localized: "HEART RATE ZONES 1-3"), icon: "heart",
                         minutes: figure.zones13Min,
                         usual: WhoopStrainFigures.usual(figures, before: key, knownDays: prior.count) { $0.zones13Min }),
            Self.timeRow(id: "z45", label: String(localized: "HEART RATE ZONES 4-5"), icon: "heart.fill",
                         minutes: figure.zones45Min,
                         usual: WhoopStrainFigures.usual(figures, before: key, knownDays: prior.count) { $0.zones45Min }),
            Self.timeRow(id: "strength", label: String(localized: "Strength Activity Time").uppercased(),
                         icon: "figure.strengthtraining.traditional", minutes: figure.strengthMin,
                         usual: WhoopStrainFigures.usual(figures, before: key, knownDays: prior.count) { $0.strengthMin }),
            // Steps: the strap's count first, else the iPhone's, as on Home.
            WhoopContributorMath.make(id: "steps", label: String(localized: "STEPS"), icon: "shoeprints.fill",
                                      today: today?.steps.map(Double.init) ?? today.flatMap { appleSteps[$0.day] },
                                      history: prior.compactMap { $0.steps.map(Double.init) ?? appleSteps[$0.day] },
                                      floor: 1000, higherIsBetter: true),
        ]
        let week = WhoopSelectedDay.lastWeek(days)

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
                if isLatest, let strain {
                    let state = WhoopScoreInsightText.strainState(
                        strain: strain, band: band.map { (Double($0.lowerBound), Double($0.upperBound)) })
                    WhoopOutlineInsightCard(
                        text: WhoopScoreInsightText.strainSentence(state),
                        linkTitle: String(localized: "EXPLORE YOUR STRAIN INSIGHTS"),
                        prompt: Self.strainPrompt(strain: strain, band: band))
                }
                if !workouts.isEmpty {
                    Text(isLatest ? String(localized: "Today's Activities")
                                  : String(localized: "ACTIVITIES").localizedCapitalized)
                        .font(WhoopStyle.sectionTitle)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, NoopMetrics.space2)
                    VStack(spacing: NoopMetrics.space2) {
                        ForEach(workouts, id: \.startTs) { w in
                            NavigationLink(value: TabRoute.activity(WhoopActivityRoute(row: w))) {
                                WhoopActivityRowView(
                                    icon: sportSymbol(w.sport),
                                    chip: repo.activityStrain(w).map { String(format: "%.1f", AICoachEngine.strain21($0)) } ?? "–",
                                    chipColor: StrandPalette.effortColor,
                                    name: WorkoutSource.displaySport(w.sport).uppercased(),
                                    start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                    end: Date(timeIntervalSince1970: TimeInterval(w.endTs)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Weekly Trends")
                    .font(WhoopStyle.sectionTitle)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, NoopMetrics.space2)
                WhoopWeeklyBars(title: String(localized: "STRAIN"),
                                points: week.compactMap { d in
                                    d.strain.map { s -> (day: String, value: Double, label: String, color: Color) in
                                        let v = AICoachEngine.strain21(s)
                                        return (WhoopDays.short(d.day), v, String(format: "%.1f", v), StrandPalette.effortColor)
                                    }
                                },
                                maxValue: 21)
                WhoopWeeklyBars(title: String(localized: "STEPS"),
                                points: week.compactMap { d in
                                    (d.steps.map(Double.init) ?? appleSteps[d.day]).map { v -> (day: String, value: Double, label: String, color: Color) in
                                        (WhoopDays.short(d.day), v, Self.thousands(v), StrandPalette.restColor)
                                    }
                                },
                                maxValue: max(1, week.compactMap { $0.steps.map(Double.init) ?? appleSteps[$0.day] }.max() ?? 1))
                // Yoop stores ACTIVE energy (`Calories.yoopEnergyEnabled`); NOOP stores the whole-day total.
                WhoopWeeklyBars(title: PuffinExperiment.whoopScoresEnabled
                                    ? String(localized: "ACTIVE CALORIES") : String(localized: "CALORIES"),
                                points: week.compactMap { d in
                                    d.activeKcalEst.map { v -> (day: String, value: Double, label: String, color: Color) in
                                        (WhoopDays.short(d.day), v, "\(Int(v.rounded()))", WhoopStyle.stressHigh)
                                    }
                                },
                                maxValue: max(1, week.compactMap(\.activeKcalEst).max() ?? 1))
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
        .task(id: "\(repo.refreshSeq)|\(key)") {
            // Activities on the shown day.
            let dayStart = (today.flatMap { WhoopDays.parser.date(from: $0.day) })
                .map { Calendar.current.startOfDay(for: $0) } ?? Calendar.current.startOfDay(for: Date())
            let start = dayStart.timeIntervalSince1970
            let end = start + 24 * 3600
            let all = await repo.workoutRows(days: 40)
            workouts = all
                .filter { TimeInterval($0.startTs) >= start && TimeInterval($0.startTs) < end }
                .sorted { $0.startTs < $1.startTs }
            appleSteps = Dictionary((await repo.appleDailyRows(days: 40)).compactMap { r in r.steps.map { (r.day, Double($0)) } },
                                    uniquingKeysWith: { a, b in max(a, b) })
            // The zone figures read heart rate for each activity, so they are worked out again only when the
            // activities themselves have changed, not on every data refresh.
            let signature = "\(all.count)|\(all.map(\.endTs).max() ?? 0)"
            if signature != figuresSignature {
                figures = await WhoopStrainFigures.load(repo: repo, rows: all)
                figuresSignature = signature
            }
        }
    }
}
