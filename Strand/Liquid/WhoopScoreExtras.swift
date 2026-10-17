import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// Yoop: what a WHOOP-style Recovery or Strain screen carries below its contributors card. The sentence in the
// outlined card is worked out from the day's own figures, so it needs no Coach and reads the same offline; its
// link hands the question to the Coach. The Strain screen's activity figures (time in zones 1 to 3 and 4 to 5,
// strength time) come from the day's logged activities, as WHOOP counts them.

// MARK: - The sentences

/// The words of the outlined insight cards. Pure, so tests pin every branch.
enum WhoopScoreInsightText {

    /// Where a day's Strain stands against its optimal range.
    enum StrainState: Equatable {
        /// No range to stand against (no Recovery yet).
        case noRange
        /// More than `closeBelow` points under the range.
        case farBelow
        /// Under the range by `closeBelow` points or less.
        case closeBelow
        case inside
        case above
    }

    /// How near the range counts as close, in Strain points.
    static let closeBelow = 2.5

    static func strainState(strain: Double, band: (lower: Double, upper: Double)?) -> StrainState {
        guard let band else { return .noRange }
        if strain > band.upper { return .above }
        if strain >= band.lower { return .inside }
        return band.lower - strain <= closeBelow ? .closeBelow : .farBelow
    }

    static func strainSentence(_ state: StrainState) -> String {
        switch state {
        case .noRange:
            return String(localized: "Your Strain builds as your heart rate stays up. Ask your Coach what it means for today.")
        case .farBelow:
            return String(localized: "You are well under your optimal Strain range for today. A workout or a long walk would bring you into it.")
        case .closeBelow:
            return String(localized: "You are close to your optimal Strain range. A brisk walk or some light activity can take you the rest of the way.")
        case .inside:
            return String(localized: "You are in your optimal Strain range for today. Anything more is optional, so keep the evening easy.")
        case .above:
            return String(localized: "You have gone past your optimal Strain range for today. Prioritize rest and an early night to recover.")
        }
    }

    /// "Did you have any alcohol?" as a chip: the question without its framing words and question mark.
    static func behaviourName(_ question: String) -> String {
        var text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("?") || text.hasSuffix(".") { text.removeLast() }
        for prefix in ["did you have any ", "did you have a ", "did you have ", "did you take any ", "did you take ",
                       "did you ", "have you ", "any "] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        guard let first = text.first else { return question }
        return first.uppercased() + text.dropFirst()
    }
}

// MARK: - The outlined card

/// WHOOP's outlined insight card: a sentence and a link that takes the question to the Coach.
struct WhoopOutlineInsightCard: View {
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter

    let text: String
    let linkTitle: String
    /// What the Coach is asked when the link is tapped.
    let prompt: String

    var body: some View {
        Button {
            if coach.isConfigured { coach.pendingPrompt = prompt }
            router.openCoach()
        } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text(text)
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: NoopMetrics.space1) {
                    Text(linkTitle).font(WhoopStyle.smallLabel)
                    Image(systemName: "arrow.right").font(WhoopStyle.chevron)
                }
                .foregroundStyle(WhoopStyle.reviewAccent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WhoopStyle.cardPadding)
            .background(RoundedRectangle(cornerRadius: WhoopStyle.cardRadius, style: .continuous)
                .fill(WhoopStyle.cardFill.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: WhoopStyle.cardRadius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [WhoopStyle.stageLight, WhoopStyle.reviewAccent],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Behavior insights

/// The drivers WHOOP names beside the journal behaviours on the Recovery screen ("10+ Strain", "83%+ Sleep
/// Performance"): for each, the threshold at which this wearer's own Recovery differs most from the days under it,
/// kept only when the difference is significant and today is on the over-the-threshold side. Pure.
enum WhoopBehaviorDrivers {
    struct Chip: Equatable {
        let name: String
        /// +1 when Recovery ran higher on those days, -1 lower.
        let direction: Int
    }

    static let strainThresholds: [Double] = [8, 10, 12, 14]
    static let sleepThresholds: [Double] = [70, 75, 80, 83, 85, 90]

    /// The best threshold of `values` (day to figure) against `outcome` (day to Recovery), as the signed effect.
    private static func best(_ values: [String: Double], thresholds: [Double], outcome: [String: Double],
                             label: String) -> (threshold: Double, delta: Double)? {
        var chosen: (threshold: Double, delta: Double, size: Double)?
        for t in thresholds {
            let withDays = Set(values.filter { $0.value >= t && outcome[$0.key] != nil }.keys)
            let without = Set(values.filter { $0.value < t && outcome[$0.key] != nil }.keys)
            guard let e = BehaviorInsights.effect(behaviorDays: withDays, controlDays: without, outcomeByDay: outcome,
                                                  behavior: label, outcome: "Recovery"),
                  e.significant else { continue }
            if chosen == nil || abs(e.cohensD) > chosen!.size { chosen = (t, e.delta, abs(e.cohensD)) }
        }
        return chosen.map { (threshold: $0.threshold, delta: $0.delta) }
    }

    static func chips(days: [DailyMetric], sleepPerformance: [String: Double], shownDay: String) -> [Chip] {
        let recovery = Dictionary(days.compactMap { d in d.recovery.map { (d.day, $0) } }, uniquingKeysWith: { _, last in last })
        var out: [Chip] = []

        // Yesterday's Strain against this morning's Recovery: a day's outcome is the next day's Recovery.
        let strain = Dictionary(days.compactMap { d in d.strain.map { (d.day, AICoachEngine.strain21($0)) } },
                                uniquingKeysWith: { _, last in last })
        var nextMorning: [String: Double] = [:]
        for day in strain.keys {
            if let r = recovery[WeeklyDigestEngine.addDays(day, 1)] { nextMorning[day] = r }
        }
        if let pick = best(strain, thresholds: strainThresholds, outcome: nextMorning, label: "Strain"),
           let yesterday = strain[WeeklyDigestEngine.addDays(shownDay, -1)], yesterday >= pick.threshold {
            out.append(Chip(name: "\(Int(pick.threshold))+ " + String(localized: "Strain"), direction: pick.delta > 0 ? 1 : -1))
        }

        // Last night's Sleep Performance against this morning's Recovery.
        if let pick = best(sleepPerformance, thresholds: sleepThresholds, outcome: recovery, label: "Sleep Performance"),
           let tonight = sleepPerformance[shownDay], tonight >= pick.threshold {
            out.append(Chip(name: "\(Int(pick.threshold))%+ " + String(localized: "Sleep Performance"),
                            direction: pick.delta > 0 ? 1 : -1))
        }
        return out
    }
}

/// "BEHAVIOR INSIGHTS" on the Recovery screen, as WHOOP sets it: a lightbulb and an arrow on the title, a line about
/// yesterday, and chips for what may have moved today's Recovery, each marked up or down: the drivers
/// (`WhoopBehaviorDrivers`) and yesterday's Yes journal answers marked by the lag-aware ranker over the whole
/// journal. Three show and the rest sit behind "+N more". It opens the Behavior Insights hub, or the journal when
/// yesterday has none and there is nothing else to show.
struct WhoopRecoveryBehaviorsCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter

    /// The stored journal day of the Recovery shown: the morning after the behaviours, which is the day itself.
    let day: String
    let days: [DailyMetric]
    /// Each day's Sleep Performance, the figure the screen's own row states.
    let sleepPerformance: [String: Double]

    private struct Chip: Identifiable {
        let id: String
        let name: String
        /// +1 when Recovery ran higher on the days it was logged, -1 lower, 0 no clear effect.
        let direction: Int
    }

    @State private var chips: [Chip] = []
    @State private var answered = false
    @State private var loaded = false

    private static let shown = 3

    var body: some View {
        Button {
            if answered || !chips.isEmpty { router.openInsightsHub() } else { router.openJournal(day: 1) }
        } label: {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "lightbulb")
                        .font(WhoopStyle.icon)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("BEHAVIOR INSIGHTS")
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: "chevron.right")
                        .font(WhoopStyle.detail)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if loaded && !answered && chips.isEmpty {
                    Text("Log yesterday's journal to see how your behaviors moved your Recovery.")
                        .font(WhoopStyle.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Some of your behaviors from yesterday may have moved today's Recovery.")
                        .font(WhoopStyle.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !chips.isEmpty {
                        FlowLayout(spacing: NoopMetrics.space2) {
                            ForEach(chips.prefix(Self.shown)) { chip in chipView(chip) }
                            if chips.count > Self.shown { moreView(chips.count - Self.shown) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WhoopStyle.compactPadding)
            .whoopCard()
        }
        .buttonStyle(.plain)
        .task(id: "\(repo.refreshSeq)|\(repo.journalSeq)|\(day)") { await load() }
    }

    private func chipView(_ chip: Chip) -> some View {
        let tint: Color = chip.direction > 0 ? WhoopStyle.rangeGreen : (chip.direction < 0 ? WhoopStyle.rangeAmber : StrandPalette.textPrimary)
        return HStack(spacing: 5) {
            if chip.direction != 0 {
                Image(systemName: chip.direction > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(WhoopStyle.chevron)
            }
            Text(chip.name)
                .font(WhoopStyle.detail)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(chip.direction == 0 ? 0.1 : 0.16)))
    }

    private func moreView(_ count: Int) -> some View {
        Text("+\(count) more")
            .font(WhoopStyle.detail)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WhoopStyle.ringTrack))
    }

    private func load() async {
        let entries = await repo.journalEntries(days: 400)
        let yesterday = entries.filter { $0.day == day && $0.question != JournalDays.coachAdviceQuestion }
        // Yes days and No days kept apart, as the Coach reads them: an unanswered day is neither.
        var byBehaviour: [String: Set<String>] = [:]
        var controls: [String: Set<String>] = [:]
        for e in entries where e.question != JournalDays.coachAdviceQuestion {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controls[e.question, default: []].insert(e.day) }
        }
        let outcome = Dictionary(days.compactMap { d in d.recovery.map { (d.day, $0) } },
                                 uniquingKeysWith: { _, last in last })
        let ranked = EffectRanker.rank(behaviors: byBehaviour, controls: controls, outcomeByDay: outcome,
                                       outcome: "Recovery")
        var effect: [String: Int] = [:]
        for r in ranked where r.effect.significant { effect[r.behavior] = r.effect.delta > 0 ? 1 : -1 }
        let journal = yesterday.filter(\.answeredYes).prefix(8).map {
            Chip(id: $0.question, name: WhoopScoreInsightText.behaviourName($0.question), direction: effect[$0.question] ?? 0)
        }
        let drivers = WhoopBehaviorDrivers.chips(days: days, sleepPerformance: sleepPerformance, shownDay: day)
            .map { Chip(id: "driver-" + $0.name, name: $0.name, direction: $0.direction) }
        // The ones with a clear effect first, then the rest.
        let all = journal + drivers
        chips = all.filter { $0.direction != 0 } + all.filter { $0.direction == 0 }
        answered = !yesterday.isEmpty
        loaded = true
    }
}

/// Chips wrapped onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - The Strain screen's activity figures

/// A day's time in zones 1 to 3 and 4 to 5, and in strength activity, from its logged activities.
struct WhoopDayActivityFigures: Equatable {
    var zones13Min = 0.0
    var zones45Min = 0.0
    var strengthMin = 0.0
    /// Minutes in each of zones 1 to 5, which the two sums above add up.
    var zoneMin: [Double] = Array(repeating: 0, count: 5)
}

/// Yoop: the activity figures of each of the last days, counted as `WhoopAgeLoader` counts them for WHOOP Age
/// (an imported zone split when the activity has one, else the heart rate of the activity itself), so the
/// Strain screen and the Health tab state one reading of the same minutes.
@MainActor
enum WhoopStrainFigures {
    static func load(repo: Repository, rows: [WorkoutRow]) async -> [String: WhoopDayActivityFigures] {
        var out: [String: WhoopDayActivityFigures] = [:]
        for w in rows {
            let dayKey = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs)))
            let duration = w.durationS ?? Double(w.endTs - w.startTs)
            var bands: [Double]?
            if WorkoutZones.percents(w.zonesJSON) == nil {
                let rest = WhoopActivityZones.restingHR(dayKey: dayKey, days: repo.days)
                let samples = await repo.workoutHrSamples(from: w.startTs, to: w.endTs, source: w.source)
                bands = WhoopActivityZones.bandSeconds(samples, from: w.startTs, to: w.endTs, restingHR: rest)
            }
            var perZone = [Double](repeating: 0, count: 5)
            if let p = WorkoutZones.percents(w.zonesJSON), p.count == 5, duration > 0 {
                for i in 0..<5 { perZone[i] = duration / 60 * p[i] / 100 }
            } else if let b = bands, b.count == 6 {
                for i in 0..<5 { perZone[i] = b[i + 1] / 60 }
            } else {
                perZone = []
            }
            if perZone.count == 5 {
                var day = out[dayKey, default: WhoopDayActivityFigures()]
                for i in 0..<5 { day.zoneMin[i] += perZone[i] }
                day.zones13Min += perZone[0] + perZone[1] + perZone[2]
                day.zones45Min += perZone[3] + perZone[4]
                out[dayKey] = day
            }
            if WhoopAge.isStrengthSport(w.sport), duration > 0 {
                out[dayKey, default: WhoopDayActivityFigures()].strengthMin += duration / 60
            }
        }
        return out
    }

    /// The mean of a figure over the `span` days before `day`, every day counted (a rest day is zero), as
    /// WHOOP's 30-day figure reads. Nil when the history is too short to call a usual.
    static func usual(_ figures: [String: WhoopDayActivityFigures], before day: String, span: Int = 30,
                      knownDays: Int, pick: (WhoopDayActivityFigures) -> Double) -> Double? {
        guard knownDays >= 7 else { return nil }
        let keys = WhoopAge.dayKeys(endingOn: WeeklyDigestEngine.addDays(day, -1), count: span)
        guard !keys.isEmpty else { return nil }
        return keys.reduce(0) { $0 + pick(figures[$1] ?? WhoopDayActivityFigures()) } / Double(keys.count)
    }

    /// Minutes as "1:37".
    static func hoursAndMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
