import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// WHOOP-style fork: the page behind My Dashboard's STEPS row. The headline is the row's own number (passed
// in from Home); the hours are the strap's counter split by clock hour exactly as the day counted it, and
// the week and the best day are read from the same stored days Home's average reads.

struct WhoopStepsScreen: View {
    let figures: WhoopRowFigures

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @AppStorage(DayCycleMode.storageKey) private var dayCycleModeRaw = DayCycleMode.sleepOnset.rawValue

    /// The day's hours; nil until the first read lands, and when the source has no hourly detail.
    @State private var hours: WhoopHourly.Split?
    @State private var loaded = false
    @State private var appleByDay: [String: Double] = [:]

    private var value: Double? { figures.value }

    /// The last 30 days of counts, each day's strap count else the phone's, as Home's normal reads them,
    /// with the shown day taking the row's own number.
    private var recent: [(day: String, value: Double)] {
        WhoopDayFigures.recent(days: repo.days.filter { $0.day <= figures.day }, endingOn: figures.day, count: 30,
                               shown: value) { $0.steps.map(Double.init) ?? appleByDay[$0.day] }
    }

    private var week: [(day: String, value: Double)] { Array(recent.suffix(7)) }

    var body: some View {
        WhoopDayPage(title: whoopPageTitle(day: figures.day, isToday: figures.isToday)) {
            let standing = WhoopDayFigures.standing(value: value, normal: figures.average)
            WhoopPageHero(icon: "shoeprints.fill", label: String(localized: "STEPS"),
                          value: value.map { Int($0.rounded()).formatted() } ?? "--",
                          normal: figures.average.map { Int($0.rounded()).formatted() },
                          direction: WhoopDayFigures.direction(value: value, normal: figures.average),
                          caption: sourceLine)
            if let sentence = sentence(standing) { WhoopPageSentence(text: sentence) }
            hourlyCard
            WhoopWeeklyBars(title: String(localized: "LAST 7 DAYS"),
                            points: week.map { item in
                                (day: weekday(item.day), value: item.value,
                                 label: Int(item.value.rounded()).formatted(),
                                 color: StrandPalette.effortColor.opacity(item.day == figures.day ? 1 : 0.45))
                            },
                            maxValue: max(1, week.map(\.value).max() ?? 1))
            if let best = WhoopDayFigures.best(recent) {
                WhoopPageFigureCard(title: String(localized: "BEST DAY IN THE LAST 30"),
                                    value: Int(best.value.rounded()).formatted(), unit: String(localized: "STEPS"),
                                    detail: bestDetail(best))
            }
            WhoopPageNote(title: String(localized: "HOW STEPS ARE COUNTED"), lines: noteLines)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WhoopCoachPill(screen: .steps, figure: value.map { String(Int($0.rounded())) } ?? "")
        }
        .task(id: "\(figures.day)|\(repo.refreshSeq)") { await load() }
    }

    // MARK: Hours

    @ViewBuilder private var hourlyCard: some View {
        if let hours, !hours.bars.isEmpty {
            WhoopHourBarsCard(title: String(localized: "STEPS BY HOUR"), split: hours,
                              tint: StrandPalette.effortColor,
                              readout: { bar in
                                  String(localized: "\(whoopHourText(bar.start)): \(bar.value.formatted()) steps")
                              },
                              hint: String(localized: "Hold and drag to read an hour"),
                              reconciliation: reconciliation(hours))
        } else if loaded {
            WhoopPageNote(title: String(localized: "STEPS BY HOUR"), lines: [noHoursLine])
        }
    }

    /// Whether the hours hold all of the day's number, in words. Nil when they do and there is nothing to
    /// add; a shortfall or an excess is stated rather than folded into a bar.
    private func reconciliation(_ hours: WhoopHourly.Split) -> String? {
        guard let value else { return nil }
        let gap = Int(value.rounded()) - hours.placed
        if gap == 0 {
            return String(localized: "The hours add up to the day's \(hours.placed.formatted()) steps.")
        }
        return gap > 0
            ? String(localized: "\(gap.formatted()) of the day's steps cannot be placed in an hour.")
            : String(localized: "The hours hold \((-gap).formatted()) more steps than the day's total, counted since it was last updated.")
    }

    private var noHoursLine: String {
        switch figures.stepSource {
        case .phone: return String(localized: "Your iPhone gave a total for this day but no hour by hour detail.")
        case .estimate: return String(localized: "This day is an estimate from your strap's motion, so it has no hours.")
        default: return String(localized: "Your strap's step counter has no samples for this day.")
        }
    }

    // MARK: Words

    private var sourceLine: String? {
        switch figures.stepSource {
        case .strap: return String(localized: "Counted by your strap")
        case .phone: return String(localized: "From your iPhone, before your strap counted")
        case .estimate: return String(localized: "Estimated from your strap's motion")
        case nil: return nil
        }
    }

    /// One plain sentence: the day against the 30-day normal.
    private func sentence(_ standing: WhoopDayFigures.Standing) -> String? {
        let normal = figures.average.map { Int($0.rounded()).formatted() } ?? ""
        switch standing {
        case .above(let gap):
            return String(localized: "That is \(Int(gap.rounded()).formatted()) more than your 30-day normal of \(normal).")
        case .below(let gap):
            return figures.isToday
                ? String(localized: "\(Int(gap.rounded()).formatted()) more steps would reach your 30-day normal of \(normal).")
                : String(localized: "That is \(Int(gap.rounded()).formatted()) fewer than your 30-day normal of \(normal).")
        case .level:
            return String(localized: "That is about your 30-day normal of \(normal).")
        case .unknown:
            return String(localized: "Your 30-day normal appears after a few days of steps.")
        }
    }

    private func bestDetail(_ best: (day: String, value: Double)) -> String {
        let date = WhoopDayFigures.date(of: best.day)?
            .formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) ?? best.day
        return best.day == figures.day ? String(localized: "\(date). This is it.") : date
    }

    private var noteLines: [String] {
        [String(localized: "Your strap counts steps with its own pedometer, which holds back the first few steps of a walk until it is sure you are walking. Yoop adds those back. While you sleep, only a steady walking pattern counts."),
         String(localized: "It is an estimate, and it can differ from your phone's count, which only counts while you carry the phone.")]
    }

    private func weekday(_ key: String) -> String {
        WhoopDayFigures.date(of: key)?.formatted(.dateTime.weekday(.abbreviated)) ?? key
    }

    // MARK: Load

    private func load() async {
        defer { loaded = true }
        appleByDay = Dictionary((await repo.appleDailyRows()).compactMap { row in row.steps.map { (row.day, Double($0)) } },
                                uniquingKeysWith: { a, b in max(a, b) })
        let cal = Calendar.current
        let dayStart = WhoopDayFigures.date(of: figures.day).map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
        let calendarFrom = Int(dayStart.timeIntervalSince1970)
        let from = figures.windowFrom ?? calendarFrom
        let toExclusive = from + (figures.windowSeconds ?? 86_400)
        let sleeps = repo.sleeps
        switch figures.stepSource {
        case .strap:
            // The sleep-onset day counts against the night's sleep; the midnight day counts its own samples.
            let onsetDay = DayCycleMode.persisted(dayCycleModeRaw) == .sleepOnset
            let session = onsetDay ? sleeps.map { WhoopDayFigures.sleepSession($0) } : []
            guard let ticks = await repo.countedStepMinutes(from: from, toExclusive: toExclusive, sleeps: session,
                                                            seedsFromBefore: onsetDay) else {
                hours = nil
                return
            }
            let perStep = max(profile.stepTicksPerStep, 0.5)
            let counted = Int((Double(ticks.values.reduce(0, +)) / perStep).rounded())
            hours = WhoopHourly.split(valueByMinute: ticks.mapValues { Double($0) / perStep },
                                      from: from, toExclusive: toExclusive, total: counted,
                                      asleep: sleeps.map { (start: $0.effectiveStartTs, end: $0.endTs) })
        case .phone:
            // The phone counts calendar days, so its hours are the calendar day's.
            let end = Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
            let rows = await repo.appleStepHours(from: calendarFrom, toExclusive: end)
            guard !rows.isEmpty else { hours = nil; return }
            let byMinute = Dictionary(rows.map { ($0.ts / 60, Double($0.steps)) }, uniquingKeysWith: +)
            hours = WhoopHourly.split(valueByMinute: byMinute, from: calendarFrom, toExclusive: end,
                                      total: rows.reduce(0) { $0 + $1.steps },
                                      asleep: sleeps.map { (start: $0.effectiveStartTs, end: $0.endTs) })
        case .estimate, nil:
            hours = nil
        }
    }
}
