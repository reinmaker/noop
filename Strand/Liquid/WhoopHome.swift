import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// WHOOP-style fork: the Home screen pieces modelled on the WHOOP app: thin score rings, the daily
// insight card, the Health / Stress Monitor overview cards and the "My Day" Day in Review row. All data
// is NOOP's own on-device data; the insight and the review are written by the user's own AI Coach
// (bring-your-own-key) and fall back to NOOP's local text when the Coach is not set up.

private struct WhoopCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: WhoopStyle.cardRadius, style: .continuous).fill(WhoopStyle.cardFill))
            .overlay(RoundedRectangle(cornerRadius: WhoopStyle.cardRadius, style: .continuous)
                .strokeBorder(WhoopStyle.cardStroke, lineWidth: 1))
    }
}

extension View {
    func whoopCard() -> some View { modifier(WhoopCardBackground()) }
}

// MARK: - Score ring

/// A WHOOP-style score ring: a dim full track, a round-capped progress arc from 12 o'clock, and the
/// number in the middle (with a small "%" for Recovery and Sleep). Animates the arc when data lands.
struct WhoopRingGauge: View {
    let score: Double?
    var maxValue: Double = 100
    var decimals: Int = 0
    var showsPercent: Bool = true
    let tint: Color
    var diameter: CGFloat = 96
    var lineWidth: CGFloat = 7
    var animated: Bool = true
    /// Optional label inside the ring under the number (the Sleep screen's "SLEEP PERFORMANCE").
    var caption: String? = nil
    /// Optional band drawn on the track (the Strain ring's optimal range), in `maxValue` units.
    var band: ClosedRange<Double>? = nil

    @State private var shown: Double = 0

    private var fraction: Double {
        guard let score, maxValue > 0 else { return 0 }
        return min(1, max(0, score / maxValue))
    }

    /// Side of the square inscribed in the ring's inner edge, less a small gap.
    private var innerBox: CGFloat {
        max(0, (diameter - 2 * lineWidth) / 2.squareRoot() - 4)
    }

    private var valueText: String {
        guard let score else { return "—" }
        return decimals > 0 ? String(format: "%.\(decimals)f", score) : String(Int(score.rounded()))
    }

    var body: some View {
        ZStack {
            Circle().stroke(WhoopStyle.ringTrack, lineWidth: lineWidth)
            if let band, maxValue > 0 {
                Circle()
                    .trim(from: min(1, band.lowerBound / maxValue), to: min(1, band.upperBound / maxValue))
                    .stroke(StrandPalette.textTertiary.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth))
                    .rotationEffect(.degrees(-90))
            }
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Number and caption stacked inside the ring's inner circle. The frame is the largest box
            // that fits inside the inner edge, and both lines shrink to fit it, so they can never touch
            // each other or the ring, at any number width or text size.
            VStack(spacing: diameter * 0.03) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(valueText)
                        .font(WhoopStyle.number(diameter * (caption == nil ? 0.28 : 0.24)))
                        .monospacedDigit()
                    if showsPercent && score != nil {
                        Text("%").font(WhoopStyle.number(diameter * (caption == nil ? 0.16 : 0.13)))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                if let caption {
                    Text(caption)
                        .font(WhoopStyle.smallLabel)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: innerBox, height: innerBox)
        }
        .frame(width: diameter, height: diameter)
        .onAppear { update() }
        .onChangeCompat(of: fraction) { _ in update() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(valueText))
    }

    private func update() {
        if animated {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)) { shown = fraction }
        } else {
            shown = fraction
        }
    }
}

// MARK: - Daily insight card

/// The card under the rings ("Your Body is Recovering…"). The Coach writes it once per new morning
/// reading (keyed on today's Recovery + sleep, so a sync that changes them refreshes it); otherwise it
/// shows NOOP's own local readiness line. Tapping it continues the conversation in Coach.
struct WhoopInsightCard: View {
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter

    let fallbackTitle: String
    let fallbackBody: String

    @State private var insight: AICoachEngine.HomeInsight?
    @State private var loading = false

    private static let cacheKey = "whoopStyle.homeInsight"

    private var fingerprint: String {
        guard let d = repo.days.last else { return "none" }
        let rec = d.recovery.map { String(Int($0.rounded())) } ?? "-"
        let sleep = d.totalSleepMin.map { String(Int($0.rounded())) } ?? "-"
        return "v2|\(d.day)|\(rec)|\(sleep)|\(coach.isConfigured)|\(coach.dataConsent)"
    }

    var body: some View {
        Button(action: openCoach) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(insight?.title ?? fallbackTitle)
                        .font(WhoopStyle.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if loading && insight == nil {
                        Text("Analyzing…")
                            .font(WhoopStyle.body)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        Text(insight?.body ?? fallbackBody)
                            .font(WhoopStyle.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                BrandMark(size: 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WhoopStyle.cardPadding)
            .whoopCard()
        }
        .buttonStyle(.plain)
        .task(id: fingerprint) { await load() }
    }

    /// Ask the Coach for more on the card. A Coach-written card goes into the chat as the Coach's message
    /// first, so the answer builds on it rather than writing the same analysis again; if it cannot be
    /// added, the question quotes it instead.
    private func openCoach() {
        guard coach.isConfigured else { router.openCoach(); return }
        let title = insight?.title ?? fallbackTitle
        if let insight {
            if coach.seedInsight(insight) {
                coach.pendingPrompt = "Tell me more about today's insight, \"\(title)\": go deeper than what you "
                    + "just said rather than repeating it. What's behind it in my data, and what should I do today?"
            } else {
                coach.pendingPrompt = "Tell me more about today's insight, \"\(title)\", which said: \"\(insight.body)\" "
                    + "Go deeper than that rather than repeating it. What's behind it in my data, and what should I "
                    + "do today?"
            }
        } else {
            coach.pendingPrompt = "Tell me more about today's insight, \"\(title)\": what's behind it and what should I do today?"
        }
        router.openCoach()
    }

    private func load() async {
        let key = fingerprint
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(CachedInsight.self, from: data),
           cached.fingerprint == key {
            insight = cached.insight
            return
        }
        insight = nil
        guard coach.isConfigured, coach.dataConsent, !repo.days.isEmpty else { return }
        loading = true
        defer { loading = false }
        guard let fresh = await coach.generateHomeInsight() else { return }
        insight = fresh
        if let data = try? JSONEncoder().encode(CachedInsight(fingerprint: key, insight: fresh)) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    private struct CachedInsight: Codable {
        let fingerprint: String
        let insight: AICoachEngine.HomeInsight
    }
}

// MARK: - Overview cards

/// "HEALTH MONITOR: WITHIN RANGE n/n Metrics": the same personal-baseline banding the Health screen's
/// vital-signs tiles use (HRV, resting HR, respiration, SpO2, skin temperature).
struct HealthMonitorCard: View {
    @EnvironmentObject private var repo: Repository

    var body: some View {
        let readings = BodyVitalSigns.readings(days: repo.days, today: nil, temperatureUnit: .celsius,
                                               skinTempPreferred: .deviation)
        let measured = readings.filter { $0.banding.band != .noData }
        let inRange = measured.filter { $0.banding.band == .inRange }.count
        let allGood = !measured.isEmpty && inRange == measured.count

        NavigationLink(value: TabRoute.healthMonitor) {
            WhoopOverviewCard(title: String(localized: "HEALTH MONITOR")) {
                HStack(spacing: 10) {
                    Image(systemName: measured.isEmpty ? "hourglass" : (allGood ? "checkmark" : "exclamationmark"))
                        .font(WhoopStyle.detail)
                        .foregroundStyle(allGood ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill((allGood ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber).opacity(0.18)))
                    VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                        Text(measured.isEmpty ? String(localized: "CALIBRATING")
                             : (allGood ? String(localized: "WITHIN RANGE") : String(localized: "OUT OF RANGE")))
                            .font(WhoopStyle.smallLabel)
                            .foregroundStyle(allGood ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                        Text(measured.isEmpty ? String(localized: "Wear it tonight")
                             : "\(inRange)/\(measured.count) " + String(localized: "Metrics"))
                            .font(WhoopStyle.detail)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// "STRESS MONITOR: 2.8 HIGH". NOOP's 0-3 stress score, banded the way WHOOP bands its own 0-3 scale.
struct StressMonitorCard: View {
    let dailyScore: Double?

    @EnvironmentObject private var repo: Repository
    @State private var latest: (level: Double, at: Date)?

    /// The latest hourly reading (what the Stress chart ends on), else the daily score.
    private var stress: Double? { latest?.level ?? dailyScore }

    private var level: (word: String, color: Color) {
        guard let s = stress else { return (String(localized: "CALIBRATING"), StrandPalette.textTertiary) }
        switch s {
        case ..<1: return (String(localized: "LOW"), WhoopStyle.stressLow)
        case ..<2: return (String(localized: "MEDIUM"), WhoopStyle.stressMedium)
        default: return (String(localized: "HIGH"), WhoopStyle.stressHigh)
        }
    }

    var body: some View {
        NavigationLink(value: TabRoute.stress) {
            WhoopOverviewCard(title: String(localized: "STRESS MONITOR")) {
                HStack(spacing: 10) {
                    Text(stress.map { String(format: "%.1f", $0) } ?? "—")
                        .font(WhoopStyle.number(14))
                        .monospacedDigit()
                        .foregroundStyle(level.color)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 7).fill(level.color.opacity(0.18)))
                    VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                        Text(level.word)
                            .font(WhoopStyle.smallLabel)
                            .foregroundStyle(level.color)
                        Text(latest?.at ?? Date(), format: .dateTime.hour().minute())
                            .font(WhoopStyle.detail)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: repo.refreshSeq) {
            let result = await StressDayCurve.today(
                repo: repo, personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?.result
            if let p = result?.timeline.last(where: { $0.level != nil }), let lvl = p.level {
                latest = (lvl, Date(timeIntervalSince1970: TimeInterval(p.startTs)))
            }
            // Tonight's Daily Stress Summary carries the latest numbers.
            if let result {
                // Each scored point is 5 minutes under WHOOP-style stress, an hour under the hourly read.
                let perPoint = PuffinExperiment.whoopStressEnabled ? WhoopStressCurve.bucketSeconds / 60 : 60
                let scored = result.hours.filter { $0.level != nil }.count * perPoint
                WhoopNotifications.updateStressSummary(highMinutes: result.highStressMinutes, scoredMinutes: scored)
            }
        }
    }
}

private struct WhoopOverviewCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(WhoopStyle.detail)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }
}

// MARK: - My Day

/// "My Day" header + the gradient "Day In Review" row, which opens the Coach-written review.
struct WhoopMyDaySection: View {
    @EnvironmentObject private var router: NavRouter
    @EnvironmentObject private var coach: AICoachEngine
    @State private var showReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text("My Day")
                    .font(WhoopStyle.sectionTitle)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                // WHOOP's white "+" (log something). Opens NOOP's quick actions: workout, journal, breathe.
                Button { router.requestQuickActions() } label: {
                    Image(systemName: "plus")
                        .font(WhoopStyle.headline)
                        .foregroundStyle(StrandPalette.surfaceBase)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(StrandPalette.textPrimary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add"))
            }
            .padding(.top, NoopMetrics.space2)
            // WHOOP-style: the Day In Review is a Coach conversation. With the Coach set up, open it and
            // let the Coach write the review as its first message; otherwise show the setup page.
            Button {
                if coach.isConfigured && coach.dataConsent {
                    coach.nextOpener = .dayReview
                    router.openCoach()
                } else {
                    showReview = true
                }
            } label: {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: "moon")
                        .font(WhoopStyle.iconLarge)
                    Text("Your Day In Review")
                        .font(WhoopStyle.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(WhoopStyle.icon)
                        .foregroundStyle(WhoopStyle.reviewAccent)
                }
                .foregroundStyle(WhoopStyle.onGradient)
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.vertical, NoopMetrics.space4)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WhoopStyle.reviewGradient))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showReview) { DayInReviewSheet() }
    }
}

/// The Day in Review: the Coach's recap of today (Sleep, Recovery, Strain & activity, Stress, Tonight),
/// written from the same on-device context the Coach chat gets. Cached per day; Refresh rewrites it.
struct DayInReviewSheet: View {
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter
    @Environment(\.dismiss) private var dismiss

    @State private var text: String?
    @State private var loading = false
    @State private var failed = false

    private static let cacheKey = "whoopStyle.dayReview"
    private var today: String { Repository.logicalDayKey(Date()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    if let text {
                        Text(Self.markdown(text))
                            .font(WhoopStyle.reading)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Analyzing your day…").foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(.top, NoopMetrics.space10)
                        .frame(maxWidth: .infinity)
                    } else if !coach.isConfigured || !coach.dataConsent {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Text("Your Day in Review is written by the Coach.")
                                .font(WhoopStyle.headline)
                            Text("Open Coach, add your Anthropic API key and allow it to read your data. Then come back here for a recap of your sleep, recovery, strain and stress.")
                                .foregroundStyle(StrandPalette.textSecondary)
                            Button("Open Coach") { dismiss(); router.openCoach() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if failed {
                        Text("Couldn't write your review right now. Check your connection and try Refresh.")
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .padding(NoopMetrics.space5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text("Day In Review"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await generate() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading || !coach.isConfigured || !coach.dataConsent)
                        .accessibilityLabel(Text("Refresh"))
                }
            }
        }
        .task { await loadCachedOrGenerate() }
    }

    private func loadCachedOrGenerate() async {
        if let stored = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String],
           stored["day"] == today, let cached = stored["text"] {
            text = cached
            return
        }
        await generate()
    }

    private func generate() async {
        guard coach.isConfigured, coach.dataConsent, !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        if let fresh = await coach.generateDayReview() {
            text = fresh
            UserDefaults.standard.set(["day": today, "text": fresh], forKey: Self.cacheKey)
        } else if text == nil {
            failed = true
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - Sleep contributors

/// WHOOP-style rows under the Sleep Performance ring: Hours vs. Needed, Sleep Consistency, Sleep
/// Efficiency and Restorative Sleep, each with a Poor / Sufficient / Optimal three-segment bar. Values
/// come straight from `SleepModel` (NOOP's own on-device sleep scoring; imported WHOOP figures win when
/// present, exactly as the Sleep tiles do).
struct WhoopSleepContributors: View {
    let model: SleepModel
    /// The shown night's efficiency (actual sleep over time in bed), so this row matches the Sleep
    /// Efficiency card below. Falls back to the model's figure.
    var efficiency: Double? = nil

    enum Band: Int { case poor = 0, sufficient = 1, optimal = 2 }

    private struct Row: Identifiable {
        let id: String
        let label: String
        let icon: String
        let value: Double?
        let sufficientFrom: Double
        let optimalFrom: Double

        var band: Band? {
            guard let value else { return nil }
            if value >= optimalFrom { return .optimal }
            if value >= sufficientFrom { return .sufficient }
            return .poor
        }
    }

    private var rows: [Row] {
        [
            Row(id: "hours", label: String(localized: "HOURS VS. NEEDED"), icon: "moon.zzz",
                value: model.hoursVsNeeded.latest, sufficientFrom: 70, optimalFrom: 85),
            Row(id: "consistency", label: String(localized: "SLEEP CONSISTENCY"), icon: "calendar",
                value: model.consistency.latest, sufficientFrom: 70, optimalFrom: 80),
            Row(id: "efficiency", label: String(localized: "SLEEP EFFICIENCY"), icon: "bed.double",
                value: efficiency ?? model.efficiency.latest, sufficientFrom: 85, optimalFrom: 90),
            Row(id: "restorative", label: String(localized: "RESTORATIVE SLEEP"), icon: "sparkles",
                value: model.restorative.latest, sufficientFrom: 30, optimalFrom: 40),
        ]
    }

    static func color(_ band: Band) -> Color {
        switch band {
        case .poor: return WhoopStyle.rangeAmber
        case .sufficient: return WhoopStyle.sufficientGray
        case .optimal: return WhoopStyle.rangeGreen
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: row.icon)
                        .font(WhoopStyle.iconMedium)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 26)
                    Text(row.label)
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    segments(row.band)
                    Text(row.value.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(WhoopStyle.number(20))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .padding(.vertical, 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibility(row)))
                if index < rows.count - 1 {
                    Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
                }
            }
            legend.padding(.top, 10)
        }
        .padding(.horizontal, WhoopStyle.compactPadding)
        .padding(.vertical, 6)
        .padding(.bottom, NoopMetrics.space2)
        .whoopCard()
    }

    private func segments(_ band: Band?) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(band?.rawValue == i ? Self.color(band ?? .sufficient) : WhoopStyle.ringTrack)
                    .frame(width: 18, height: 4)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.poor, String(localized: "Poor"))
            legendItem(.sufficient, String(localized: "Sufficient"))
            legendItem(.optimal, String(localized: "Optimal"))
            Spacer(minLength: 0)
        }
        .font(WhoopStyle.caption)
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(WhoopStyle.ringTrack.opacity(0.5)))
    }

    private func legendItem(_ band: Band, _ text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(Self.color(band)).frame(width: 14, height: 4)
            Text(text)
        }
    }

    private func accessibility(_ row: Row) -> String {
        guard let value = row.value, let band = row.band else { return "\(row.label), no data" }
        let word: String
        switch band {
        case .poor: word = String(localized: "Poor")
        case .sufficient: word = String(localized: "Sufficient")
        case .optimal: word = String(localized: "Optimal")
        }
        return "\(row.label), \(Int(value.rounded())) percent, \(word)"
    }
}
