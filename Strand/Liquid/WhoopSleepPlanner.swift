import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// WHOOP's Sleep Planner arithmetic, fitted to the user's WHOOP export (121 nights; RMSE 26 min on sleep
/// need): sleep need = the healthy minimum (7:30, or more for a long sleeper) + 5.45 min for each point of
/// today's Strain above 8.2 (`WhoopSleepDebt.needMinPerStrainPoint`) + sleep debt (`SleepModel.nightNeed`,
/// the need the next morning's Hours vs Needed measures the night against); time in bed = need / the usual sleep efficiency; bedtime = wake
/// time - time in bed. With an 8:30 alarm this gives WHOOP's own 00:29 for 7 Oct 2026. The sleep debt is
/// half of the last night's shortfall against that night's own need (`WhoopSleepDebt`, fitted to the same
/// export), the figure the Sleep Debt tile and the ledger show.
///
/// Where the time in bed goes. The need says how long to be in bed, so the plan counts the bedtime back from
/// the wake time by that: a recommendation, not a copy of the user's habit. The wake time stays where the user
/// keeps it, and a hard day, which asks for more sleep, starts the night earlier and leaves its end alone. WHOOP
/// does the same (read from its Sleep Planner on 31 Oct 2026: bed 22:59 for the wake time set to 8:30, 9:31 in
/// bed, with the optimal window 01:55 to 08:40 shown beside it). The usual middle of the night, the standard
/// marker of a person's chronotype (Roenneberg, Wirz-Justice and Merrow 2003, J Biol Rhythms 18:80-90), only
/// places that optimal window. An earlier version centred the time in bed on it, which put the suggested
/// bedtime and wake time where the user already slept (01:47 and 10:07 against their usual 01:40 and 09:40) and
/// moved the wake time later on a hard day.
///
/// With no alarm and no chosen wake time the wake is the usual one, the median of the last 7 nights. With
/// fewer than `minNightsForWindow` recent nights there is no usual middle to draw the optimal window from, but
/// the usual wake time of the nights there are still stands.
///
/// The wake time is, in order: the strap alarm that fires tonight, a wake time the user chose (a weekday's
/// own time, else the one wake time they set), the end of the placed time in bed, the usual wake time. No
/// stored default stands in for any of them: the plan is nil when none exists.
struct WhoopSleepPlan {
    /// Where the wake time comes from, which decides how a screen labels it.
    enum WakeSource: Equatable {
        /// The strap alarm that will fire on tonight's morning.
        case alarm
        /// A wake time the user chose: a weekday's own time, else the one wake time they set.
        case chosen
        /// The usual wake time, kept, with the bedtime counted back from it by the sleep need.
        case recommended
        /// The usual wake time of the few recent nights on record.
        case usual
    }

    let baselineMin: Double
    let strainMin: Double
    let debtMin: Double
    let efficiency: Double
    let wake: Date
    let wakeSource: WakeSource
    /// Start of the time in bed centred on the usual middle of the night, when recent nights exist.
    let optimalStart: Date?
    /// The usual wake time of the recent nights, whatever the wake time follows (an armed alarm, say): what the
    /// strap alarm is set to on request. Nil with fewer than `minNightsForWindow` recent nights.
    let recommendedWake: Date?

    var needMin: Double { baselineMin + strainMin + debtMin }
    var timeInBedMin: Double { needMin / efficiency }
    var bedtime: Date { wake.addingTimeInterval(-timeInBedMin * 60) }
    var optimalEnd: Date? { optimalStart.map { $0.addingTimeInterval(timeInBedMin * 60) } }
    var wakeIsAlarm: Bool { wakeSource == .alarm }

    /// Hours before bedtime after which no more training should happen. Vigorous exercise that ends within an
    /// hour of lying down delays sleep and shortens it, while earlier training does not (Stutz, Eiholzer and
    /// Spengler, Sports Medicine 2019, a meta-analysis of 23 studies); three hours leaves margin for the heart
    /// rate, and the skin and core temperature the effort raised, to settle.
    static let trainingCutoffHours = 3.0

    /// The last sensible time to train today: `trainingCutoffHours` before tonight's bedtime. The Home row
    /// turns from the Daily Outlook into the Day In Review at this time, and the Coach is told not to suggest
    /// training after it.
    var trainingCutoff: Date { bedtime.addingTimeInterval(-Self.trainingCutoffHours * 3600) }

    /// What a screen calls the wake time, from where it comes.
    var wakeLabel: String {
        switch wakeSource {
        case .alarm: return String(localized: "ALARM ON")
        case .chosen: return String(localized: "YOUR WAKE TIME")
        case .recommended: return String(localized: "RECOMMENDED WAKE")
        case .usual: return String(localized: "USUAL WAKE")
        }
    }

    /// When the wind-down reminder for this plan fires: `leadMinutes` before the bedtime.
    func reminderDate(leadMinutes: Int) -> Date { bedtime.addingTimeInterval(-Double(leadMinutes) * 60) }

    /// Whether the optimal window is a different window from the plan's own (an alarm, a chosen time or the
    /// limit moved it), so showing both says something.
    var optimalDiffersFromPlan: Bool {
        guard let start = optimalStart else { return false }
        return abs(start.timeIntervalSince(bedtime)) >= 60
    }

    /// The part of the plan the Home insight depends on, in steps of 10 minutes: it changes when the bedtime
    /// or the wake time has moved 10 minutes or more, so a card the Coach wrote about an earlier plan is
    /// written again.
    var fingerprintToken: String {
        let bucket = { (d: Date) in Int((d.timeIntervalSince1970 / 600).rounded(.down)) }
        return "\(bucket(bedtime))-\(bucket(wake))"
    }

    // MARK: Constants

    /// Recent nights the rhythm is read from.
    static let recentNights = 7
    /// Fewest recent nights that give a rhythm to anchor the time in bed to.
    static let minNightsForWindow = 3

    // MARK: Rhythm (pure)

    /// The user's usual night on a noon-to-noon clock: minutes after the 12:00 before it, so a night that
    /// runs past midnight stays on one axis. Each field is a median over the recent nights.
    struct Rhythm: Equatable {
        let wake: Double
        let onset: Double
        let midpoint: Double
        let nights: Int
    }

    /// Minutes after the preceding noon at which `ts` falls on the local clock.
    static func noonClock(_ ts: Int, calendar: Calendar = .current) -> Double {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        let clock = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        return (clock - 720 + 1440).truncatingRemainder(dividingBy: 1440)
    }

    /// The clock minute (0 to 1439) a noon-to-noon coordinate stands for.
    static func clockMinute(ofNoonClock x: Double) -> Int {
        Int((x + 720).truncatingRemainder(dividingBy: 1440).rounded()) % 1440
    }

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The usual night from the recent nights' asleep windows (`SleepModel.nightWindows`), nil with none.
    static func rhythm(of nights: [(start: Int, end: Int)], calendar: Calendar = .current) -> Rhythm? {
        guard let wake = median(nights.map { noonClock($0.end, calendar: calendar) }),
              let onset = median(nights.map { noonClock($0.start, calendar: calendar) }),
              let midpoint = median(nights.map { noonClock($0.start, calendar: calendar) + Double($0.end - $0.start) / 120 })
        else { return nil }
        return Rhythm(wake: wake, onset: onset, midpoint: midpoint, nights: nights.count)
    }

    /// The time to put on the strap alarm when it is switched on with none ever chosen, so the alarm is not armed
    /// for the store's 07:00 placeholder: the wake time the user chose for tonight if they did, else the plan's
    /// recommended wake time (its usual one with too few nights to place it), as minutes after midnight. Nil when
    /// the alarm's time was chosen, or when there is no plan to take one from.
    static func strapAlarmSeed(plan: WhoopSleepPlan?, timeIsChosen: Bool) -> Int? {
        guard !timeIsChosen, let plan else { return nil }
        let wake = plan.wakeSource == .chosen ? plan.wake : (plan.recommendedWake ?? plan.wake)
        let c = Calendar.current.dateComponents([.hour, .minute], from: wake)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// The usual wake time of the recent nights as a clock time (minutes after midnight), or nil with none.
    /// What the wind-down card shows for the wake time until the user picks one.
    @MainActor
    static func usualWakeMinutes(repo: Repository) -> Int? {
        rhythm(of: SleepModel.nightWindows(repo.sleeps, last: recentNights)).map { clockMinute(ofNoonClock: $0.wake) }
    }

    // MARK: Resolving tonight

    /// The next time the clock reads `minutes` after midnight on `day`.
    private static func instant(clockMinutes minutes: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    /// Tonight's plan, or nil when nothing says when the night ends: no alarm, no wake time the user chose and
    /// no recent night to take the usual wake time from.
    ///
    /// `alarm` is the strap alarm that will fire (`armedAlarm`); it decides the wake time only when it falls
    /// within 12 h of tonight's usual wake time, so a weekday alarm that is days away does not become tonight's
    /// plan. `wakeOverrides` and `chosenWake` are the user's own wake times (`WindDownNudge`). Tonight is the
    /// first wake time ahead of `now`, skipping today's when the last night on record already ended today.
    @MainActor
    static func tonight(repo: Repository, alarm: Date?, now: Date = Date(),
                        wakeOverrides: [Int: Int], chosenWake: Int?) -> WhoopSleepPlan? {
        let cal = Calendar.current
        let days = repo.days
        let efficiencies = days.suffix(14).compactMap(\.efficiency).filter { $0 > 0.5 && $0 <= 1 }
        let efficiency = min(0.98, max(0.8, median(efficiencies) ?? 0.94))
        let nights = SleepModel.nightWindows(repo.sleeps, last: recentNights)
        let habit = rhythm(of: nights, calendar: cal)

        // The night: the first wake time ahead of now. A night that already ended today is over, so today's
        // wake time is skipped; the wake time of a day is the user's own for it, else the usual one.
        let lastEnd = nights.last.map { Date(timeIntervalSince1970: TimeInterval($0.end)) }
        let wokeToday = lastEnd.map { cal.isDate($0, inSameDayAs: now) } ?? false
        let today = cal.startOfDay(for: now)
        var night: (day: Date, wake: Date, chosen: Bool)?
        for offset in (wokeToday ? 1 : 0)...(wokeToday ? 2 : 1) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let mine = wakeOverrides[cal.component(.weekday, from: day)] ?? chosenWake
            let minutes = mine ?? habit.map { clockMinute(ofNoonClock: $0.wake) }
            guard let minutes else { continue }
            let at = instant(clockMinutes: minutes, on: day, calendar: cal)
            if at > now { night = (day, at, mine != nil); break }
        }

        let useAlarm: Bool
        if let alarm, let night { useAlarm = abs(alarm.timeIntervalSince(night.wake)) < 12 * 3600 } else { useAlarm = alarm != nil }
        guard let wakeBasis = useAlarm ? alarm : night?.wake else { return nil }

        // The need of the night ending at the wake time, through the resolver Hours vs Needed measures that
        // night against the next morning, with each day's Strain as the Strain ring shows it, effort ratings
        // included (`Repository.strainDays`).
        let need = SleepModel.nightNeed(wakeDay: Repository.localDayKey(wakeBasis), days: repo.strainDays,
                                        importedSleep: repo.importedSleep)
        let inBed = need.needMin / efficiency

        var optimalStart: Date?
        var recommended: Date?
        if let habit, let night {
            // The night's usual wake time; the optimal window is the time in bed centred on the usual middle of
            // the night, drawn beside the plan and not the plan itself.
            let usualWake = instant(clockMinutes: clockMinute(ofNoonClock: habit.wake), on: night.day, calendar: cal)
            let centredEnd = usualWake.addingTimeInterval((habit.midpoint + inBed / 2 - habit.wake) * 60)
            optimalStart = centredEnd.addingTimeInterval(-inBed * 60)
            if habit.nights >= minNightsForWindow { recommended = usualWake }
        }

        let wake: Date
        let source: WakeSource
        if useAlarm, let alarm {
            (wake, source) = (alarm, .alarm)
        } else if let night, night.chosen {
            (wake, source) = (night.wake, .chosen)
        } else if let recommended {
            (wake, source) = (recommended, .recommended)
        } else {
            (wake, source) = (wakeBasis, .usual)
        }
        return WhoopSleepPlan(baselineMin: need.baselineMin, strainMin: need.strainMin, debtMin: need.debtMin,
                              efficiency: efficiency, wake: wake, wakeSource: source,
                              optimalStart: optimalStart, recommendedWake: recommended)
    }

    /// Whether switching the strap alarm on arms anything that will go off. A WHOOP 5/MG arms its firmware
    /// alarm only with Experimental on (`BLEManager.armStrapAlarm` logs "not armed" and returns otherwise,
    /// #864).
    @MainActor
    static func strapCanArm(model: AppModel) -> Bool {
        !(model.whoop5Detected && !PuffinExperiment.isEnabled)
    }

    /// The next time the strap alarm will actually buzz, or nil when there is none to promise: the alarm is
    /// off, or the strap cannot arm it. The one gate and the one resolver for every readout of the alarm,
    /// which takes `overrides` (default: the stored per-weekday times) because a day with its own time fires
    /// at that time. `from` is a parameter so a ticking countdown resolves against the clock it is given.
    @MainActor
    static func armedAlarm(behavior: BehaviorStore, model: AppModel,
                           overrides: [Int: Int]? = nil, from now: Date = Date()) -> Date? {
        armedAlarm(behavior: behavior, canArm: strapCanArm(model: model), overrides: overrides, from: now)
    }

    /// `armedAlarm` with the strap's ability to arm already decided (`strapCanArm`).
    @MainActor
    static func armedAlarm(behavior: BehaviorStore, canArm: Bool,
                           overrides: [Int: Int]? = nil, from now: Date = Date()) -> Date? {
        guard behavior.smartAlarmEnabled, canArm else { return nil }
        return AppModel.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                           weekdays: behavior.smartAlarmWeekdays,
                                           overrides: overrides ?? WindDownNudge.perDayWakeOverrides,
                                           from: now)
    }

    /// Tonight's plan as every screen, the Coach and the wind-down reminder read it: the one call, so none of
    /// them can show a different bedtime or wake time from another.
    @MainActor
    static func current(repo: Repository, behavior: BehaviorStore, model: AppModel,
                        overrides: [Int: Int]? = nil, now: Date = Date()) -> WhoopSleepPlan? {
        let overrides = overrides ?? WindDownNudge.perDayWakeOverrides
        return tonight(repo: repo, alarm: armedAlarm(behavior: behavior, model: model, overrides: overrides, from: now),
                       now: now, wakeOverrides: overrides, chosenWake: WindDownNudge.chosenWakeMinutes)
    }

    /// One line for the Coach's context, so its bedtime advice matches the card. A part of the need that
    /// is zero (or unknown, which the plan stores as zero) is left out rather than quoted as "0h 0m".
    var coachLine: String {
        func hm(_ m: Double) -> String { "\(Int(m) / 60)h \(Int(m) % 60)m" }
        let bed = WhoopTime.clock(bedtime)
        let up = WhoopTime.clock(wake)
        let source: String
        switch wakeSource {
        case .alarm: source = "alarm"
        case .chosen: source = "wake time the user set"
        case .recommended: source = "usual wake time, with the bedtime counted back from it by the sleep need"
        case .usual: source = "usual wake time"
        }
        let percent = Int((efficiency * 100).rounded())
        var parts: [String] = []
        parts.append("Tonight's sleep plan, as the app's Tonight's Sleep card shows it: get in bed by \(bed) to wake at \(up) (\(source));")
        var extras: [String] = []
        if strainMin >= 1 { extras.append("recent Strain \(hm(strainMin))") }
        if debtMin >= 1 { extras.append("sleep debt \(hm(debtMin))") }
        if extras.isEmpty {
            parts.append("sleep need \(hm(needMin)), the healthy minimum;")
        } else {
            parts.append("sleep need \(hm(needMin)) = healthy minimum \(hm(baselineMin)) + "
                         + extras.joined(separator: " + ") + ";")
        }
        parts.append("time in bed \(hm(timeInBedMin)) at \(percent)% sleep efficiency.")
        parts.append("The last sensible time to train today is \(WhoopTime.clock(trainingCutoff)), \(Int(Self.trainingCutoffHours)) hours before bed: "
                     + "never suggest training after it, and treat the day as over from then.")
        parts.append("Use exactly these times whenever you suggest a bedtime, lights out or a wake time.")
        return parts.joined(separator: " ")
    }
}

// MARK: - Sleep Planner screen

/// WHOOP's Sleep Planner: when to get in bed for tonight's sleep need and the wake time, the time in bed
/// against the usual (optimal) window, and what the need is made of.
struct WhoopSleepPlannerScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter

    var body: some View {
        let plan = WhoopSleepPlan.current(repo: repo, behavior: behavior, model: model)
        ScrollView {
            VStack(spacing: NoopMetrics.space5) {
                BrandMark(size: 44)
                    .padding(.top, NoopMetrics.space4)
                if let plan {
                    Text(sentence(plan))
                        .font(WhoopStyle.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top) {
                        figure(WhoopTime.clock(plan.bedtime), String(localized: "SUGGESTED TIME TO BED"))
                        Spacer()
                        figure(WhoopTime.clock(plan.wake), plan.wakeLabel)
                    }
                    timeInBed(plan)
                    needCard(plan)
                } else {
                    Text("Your sleep plan appears after a few nights of sleep, or once you set a wake time.")
                        .font(WhoopStyle.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { router.openAlarms() } label: {
                    WhoopActionButtonLabel(title: String(localized: "EDIT ALARM"), systemImage: "pencil")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space10)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text("SLEEP PLANNER"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func sentence(_ plan: WhoopSleepPlan) -> String {
        let bed = WhoopTime.clock(plan.bedtime)
        let up = WhoopTime.clock(plan.wake)
        if plan.wakeIsAlarm {
            return String(localized: "Your alarm will go off at \(up). Get in bed by \(bed) to reach your sleep need.")
        }
        return String(localized: "Get in bed by \(bed) to reach your sleep need and wake at \(up).")
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(spacing: NoopMetrics.space1) {
            Text(value).font(WhoopStyle.number(32)).foregroundStyle(StrandPalette.textPrimary)
            Text(label)
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func timeInBed(_ plan: WhoopSleepPlan) -> some View {
        VStack(spacing: NoopMetrics.space2) {
            Text("TIME IN BED").font(WhoopStyle.smallLabel).foregroundStyle(WhoopStyle.rangeGreen)
            ZStack {
                WhoopHatch().clipShape(RoundedRectangle(cornerRadius: 4)).frame(height: 14)
                Text(WhoopTime.duration(minutes: plan.timeInBedMin))
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, NoopMetrics.space3)
                    .padding(.vertical, NoopMetrics.space1)
                    .background(Capsule().fill(StrandPalette.surfaceBase))
                    .overlay(Capsule().strokeBorder(WhoopStyle.rangeGreen, lineWidth: 1.5))
            }
            // The optimal window is the plan's own only when the wake time is the usual one and the need is the
            // usual length; otherwise both are worth showing, as WHOOP shows them.
            if let start = plan.optimalStart, let end = plan.optimalEnd, plan.optimalDiffersFromPlan {
                Text(String(localized: "OPTIMAL \(WhoopTime.clock(start)) - \(WhoopTime.clock(end))"))
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .padding(WhoopStyle.cardPadding)
        .frame(maxWidth: .infinity)
        .whoopCard()
    }

    private func needCard(_ plan: WhoopSleepPlan) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text("SLEEP NEEDED").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(WhoopTime.duration(minutes: plan.needMin)).font(WhoopStyle.number(18)).foregroundStyle(StrandPalette.textPrimary)
            }
            row(String(localized: "Healthy Minimum"), WhoopTime.duration(minutes: plan.baselineMin))
            row(String(localized: "Recent Strain"), "+" + WhoopTime.duration(minutes: plan.strainMin))
            row(String(localized: "Sleep Debt"), "+" + WhoopTime.duration(minutes: plan.debtMin))
            row(String(localized: "Usual sleep efficiency"), "\(Int((plan.efficiency * 100).rounded()))%")
        }
        .padding(WhoopStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .whoopCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(WhoopStyle.body).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(WhoopStyle.body).foregroundStyle(StrandPalette.textPrimary)
        }
    }
}
