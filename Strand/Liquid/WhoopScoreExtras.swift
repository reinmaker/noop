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

    // MARK: Recovery

    /// The signals behind a Recovery score that the card can name.
    enum Driver: Equatable {
        case hrv, restingHr, respiratory, sleep

        /// The name of the signal as the contributor row states it.
        var label: String {
            switch self {
            case .hrv: return String(localized: "HEART RATE VARIABILITY")
            case .restingHr: return String(localized: "RESTING HEART RATE")
            case .respiratory: return String(localized: "RESPIRATORY RATE")
            case .sleep: return String(localized: "SLEEP PERFORMANCE")
            }
        }

        /// The size of a move that is worth naming, as a share of the usual value (sleep: of 100 points).
        fileprivate var notable: Double {
            switch self {
            case .hrv: return 0.05
            case .restingHr: return 0.03
            case .respiratory: return 0.03
            case .sleep: return 0.06
            }
        }
    }

    /// One signal today against its 30-day usual, nil when either is missing.
    struct Reading: Equatable {
        let driver: Driver
        let today: Double?
        let usual: Double?

        /// The move in the direction that helps Recovery, as a share of what is notable: -1 is a move that
        /// just earns a mention against it, +1 one that just earns a mention for it.
        var score: Double? {
            guard let today, let usual, usual > 0 else { return nil }
            let helpful: Double
            switch driver {
            case .hrv: helpful = (today - usual) / usual
            case .restingHr, .respiratory: helpful = (usual - today) / usual
            case .sleep: helpful = (today - usual) / 100
            }
            return helpful / driver.notable
        }
    }

    /// The signal that pulls Recovery down the most (`drag`) or lifts it the most (`lead`), when one moved by
    /// more than is notable.
    static func strongest(_ readings: [Reading], drag: Bool) -> Driver? {
        let scored = readings.compactMap { r in r.score.map { (r.driver, $0) } }
        if drag {
            guard let worst = scored.min(by: { $0.1 < $1.1 }), worst.1 <= -1 else { return nil }
            return worst.0
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 1 else { return nil }
        return best.0
    }

    /// The card's sentence for a Recovery score (0 to 100): the band, then the signal behind it when one stands out.
    static func recoverySentence(recovery: Double, readings: [Reading]) -> String {
        let band: String
        let drag = recovery < 67
        if recovery >= 67 {
            band = String(localized: "Your body is well recovered and ready for a hard day.")
        } else if recovery >= 34 {
            band = String(localized: "Your recovery is moderate. Keep today's effort steady and listen to your body.")
        } else {
            band = String(localized: "Your recovery is low. Prioritize rest, fluids and an early night.")
        }
        guard let driver = strongest(readings, drag: drag) else { return band }
        let name = driver.label.localizedCapitalized
        let reason = drag
            ? String(localized: "\(name) is the biggest drag on today's Recovery.")
            : String(localized: "\(name) is helping your Recovery the most.")
        return band + " " + reason
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

/// "BEHAVIOR INSIGHTS" on the Recovery screen: yesterday's journal answers that were Yes, as chips marked with
/// what they have done to the wearer's own Recovery (the lag-aware ranker over the whole journal, flagged only
/// when the effect is significant). With no journal for yesterday it asks for one.
struct WhoopRecoveryBehaviorsCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter

    /// The stored journal day of the Recovery shown: the morning after the behaviours, which is the day itself.
    let day: String

    private struct Chip: Identifiable {
        let id: String
        let name: String
        /// +1 when Recovery ran higher on the days it was logged, -1 lower, 0 no clear effect.
        let direction: Int
    }

    @State private var chips: [Chip] = []
    @State private var answered = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("BEHAVIOR INSIGHTS")
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textPrimary)
            if loaded && !answered {
                Text("Log yesterday's journal to see how your behaviors moved your Recovery.")
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Some of your behaviors from yesterday may have moved today's Recovery.")
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !chips.isEmpty {
                    FlowLayout(spacing: NoopMetrics.space2) {
                        ForEach(chips) { chip in chipView(chip) }
                    }
                }
            }
            Button {
                if answered { router.openInsightsHub() } else { router.openJournal(day: 1) }
            } label: {
                WhoopActionButtonLabel(title: answered ? String(localized: "BEHAVIOR INSIGHTS")
                                                       : String(localized: "MY JOURNAL"),
                                       systemImage: answered ? "lightbulb" : "square.and.pencil")
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
        .task(id: "\(repo.refreshSeq)|\(repo.journalSeq)|\(day)") { await load() }
    }

    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 4) {
            if chip.direction != 0 {
                Image(systemName: chip.direction > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(WhoopStyle.chevron)
                    .foregroundStyle(chip.direction > 0 ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
            }
            Text(chip.name)
                .font(WhoopStyle.detail)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(Capsule().fill(WhoopStyle.ringTrack))
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
        let outcome = Dictionary(repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                                 uniquingKeysWith: { _, last in last })
        let ranked = EffectRanker.rank(behaviors: byBehaviour, controls: controls, outcomeByDay: outcome,
                                       outcome: "Recovery")
        var effect: [String: Int] = [:]
        for r in ranked where r.effect.significant { effect[r.behavior] = r.effect.delta > 0 ? 1 : -1 }
        answered = !yesterday.isEmpty
        chips = yesterday.filter(\.answeredYes).prefix(8).map {
            Chip(id: $0.question, name: WhoopScoreInsightText.behaviourName($0.question), direction: effect[$0.question] ?? 0)
        }
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
}

/// Yoop: the activity figures of each of the last days, counted as `WhoopAgeLoader` counts them for WHOOP Age
/// (an imported zone split when the activity has one, else the heart rate of the activity itself), so the
/// Strain screen and the Health tab state one reading of the same minutes.
@MainActor
enum WhoopStrainFigures {
    static func load(repo: Repository, rows: [WorkoutRow]) async -> [String: WhoopDayActivityFigures] {
        var out: [String: WhoopDayActivityFigures] = [:]
        for w in rows {
            let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs)))
            let duration = w.durationS ?? Double(w.endTs - w.startTs)
            var bands: [Double]?
            if WorkoutZones.percents(w.zonesJSON) == nil {
                let rest = WhoopActivityZones.restingHR(dayKey: day, days: repo.days)
                let samples = await repo.workoutHrSamples(from: w.startTs, to: w.endTs, source: w.source)
                bands = WhoopActivityZones.bandSeconds(samples, from: w.startTs, to: w.endTs, restingHR: rest)
            }
            if let z = WhoopAge.zoneMinutes(durationS: duration, importedPercents: WorkoutZones.percents(w.zonesJSON),
                                            bandSeconds: bands) {
                out[day, default: WhoopDayActivityFigures()].zones13Min += z.z13
                out[day, default: WhoopDayActivityFigures()].zones45Min += z.z45
            }
            if WhoopAge.isStrengthSport(w.sport), duration > 0 {
                out[day, default: WhoopDayActivityFigures()].strengthMin += duration / 60
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
