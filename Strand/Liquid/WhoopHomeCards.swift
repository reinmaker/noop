import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopStore

// WHOOP-style fork: the "My Day" and dashboard cards under the Home rings (Tonight's Sleep, Activities,
// My Journal, My Dashboard, the Stress Monitor chart and the 7-day Strain & Recovery chart). Every value
// comes from NOOP's own on-device data and existing helpers; nothing new is computed for scoring.

// MARK: - Shared pieces

/// A WHOOP-style card: UPPERCASE title with an optional chevron, then content.
struct WhoopTitledCard<Content: View>: View {
    let title: String
    var showsChevron: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text(title)
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: NoopMetrics.space1)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(WhoopStyle.detail)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }
}

/// A wide, quiet WHOOP-style action button ("EDIT ALARM", "ADD ACTIVITY").
struct WhoopActionButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: systemImage).font(WhoopStyle.detail)
            Text(title).font(WhoopStyle.smallLabel)
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WhoopStyle.ringTrack))
    }
}

enum WhoopTime {
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    static func duration(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return String(format: "%d:%02d", m / 60, m % 60)
    }
}

// MARK: - Tonight's Sleep

/// "TONIGHT'S SLEEP": recommended bedtime (wake time minus sleep need) and the strap alarm.
///
/// The alarm half uses the same gate and resolver as the Alarms screen (`smartAlarmEnabled`, the strap
/// arm check and `AppModel.nextSmartAlarmDate` with the per-day overrides), so it can never show an
/// alarm that will not fire. Without an armed alarm, bedtime counts back from the usual wake time.
struct WhoopTonightsSleepCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var behavior: BehaviorStore
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter

    /// The next armed strap alarm, or nil (no alarm, or the strap cannot arm one).
    static func nextAlarm(behavior: BehaviorStore, model: AppModel, from now: Date = Date()) -> Date? {
        guard behavior.smartAlarmEnabled, !(model.whoop5Detected && !PuffinExperiment.isEnabled) else { return nil }
        return AppModel.nextSmartAlarmDate(minutes: behavior.smartAlarmMinutes,
                                           weekdays: behavior.smartAlarmWeekdays,
                                           overrides: WindDownNudge.perDayWakeOverrides,
                                           from: now)
    }

    var body: some View {
        let now = Date()
        let alarm = Self.nextAlarm(behavior: behavior, model: model, from: now)
        // WHOOP's Sleep Planner: tonight's need (healthy minimum + Strain + debt) over the usual efficiency,
        // back from the alarm or the usual wake time of recent nights.
        let plan = WhoopSleepPlan.tonight(repo: repo, alarm: alarm, now: now)
        let wake = plan.wake
        let bedtime = plan.bedtime
        let bedtimeText = bedtime <= now ? String(localized: "Now") : WhoopTime.clock(bedtime)

        NavigationLink(value: TabRoute.sleepPlanner) {
            WhoopTitledCard(title: String(localized: "TONIGHT'S SLEEP")) {
                HStack(alignment: .top) {
                    VStack(spacing: NoopMetrics.space1) {
                        HStack(spacing: 6) {
                            Image(systemName: "sunset").font(WhoopStyle.icon)
                            Text(bedtimeText).font(WhoopStyle.number(24))
                        }
                        Text("RECOMMENDED\nBEDTIME")
                            .font(WhoopStyle.smallLabel)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    Rectangle()
                        .fill(WhoopStyle.ringTrack)
                        .frame(height: 1)
                        .frame(maxWidth: 60)
                        .padding(.top, NoopMetrics.space3)
                    VStack(spacing: NoopMetrics.space1) {
                        HStack(spacing: 6) {
                            Image(systemName: "alarm").font(WhoopStyle.icon)
                            Text(WhoopTime.clock(wake)).font(WhoopStyle.number(24))
                        }
                        HStack(spacing: 4) {
                            Circle()
                                .fill(alarm != nil ? WhoopStyle.rangeGreen : StrandPalette.textTertiary)
                                .frame(width: 6, height: 6)
                            Text(alarm != nil ? String(localized: "ALARM ON") : String(localized: "USUAL WAKE"))
                                .font(WhoopStyle.smallLabel)
                                .foregroundStyle(alarm != nil ? WhoopStyle.rangeGreen : StrandPalette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .foregroundStyle(StrandPalette.textPrimary)
                WhoopActionButtonLabel(title: String(localized: "EDIT ALARM"), systemImage: "pencil")
            }
        }
        .buttonStyle(.plain)
        .onAppear { WhoopSleepPlan.lastShown = plan }
    }
}

// MARK: - Activities

/// "ACTIVITIES": last night's sleep and today's workouts as rows, with Add / Start buttons. Start uses
/// the same sport picker and live-workout flow as NOOP's own Start workout control.
struct WhoopActivitiesCard: View {
    let sleepMinutes: Double?
    let sleepStart: Date?
    let sleepEnd: Date?
    let workouts: [WorkoutRow]

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var repo: Repository
    @State private var showLiveWorkout = false
    @State private var showStartSport = false

    /// WHOOP adds a detected activity to the day by itself (`Repository.addDetectedActivities`).
    private func addDetectedActivities() async {
        await repo.addDetectedActivities()
    }

    var body: some View {
        WhoopTitledCard(title: String(localized: "ACTIVITIES"), showsChevron: false) {
            VStack(spacing: NoopMetrics.space2) {
                if let sleepMinutes {
                    NavigationLink(value: TabRoute.sleep) {
                        row(icon: "moon.fill", chip: WhoopTime.duration(minutes: sleepMinutes),
                            chipColor: StrandPalette.restColor, name: String(localized: "SLEEP"),
                            start: sleepStart, end: sleepEnd)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(workouts, id: \.startTs) { w in
                    // Every activity opens its WHOOP-style page; the user's own can be re-typed or deleted
                    // from its menu there, imported history is read-only.
                    NavigationLink(value: TabRoute.activity(WhoopActivityRoute(row: w))) { workoutRow(w) }
                        .buttonStyle(.plain)
                }
                if sleepMinutes == nil && workouts.isEmpty {
                    Text("No activities yet today")
                        .font(WhoopStyle.body)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: NoopMetrics.space2) {
                NavigationLink(value: TabRoute.workouts) {
                    WhoopActionButtonLabel(title: String(localized: "ADD ACTIVITY"), systemImage: "plus")
                }
                .buttonStyle(.plain)
                Button {
                    if model.activeWorkout == nil { showStartSport = true } else { showLiveWorkout = true }
                } label: {
                    WhoopActionButtonLabel(
                        title: model.activeWorkout == nil ? String(localized: "START ACTIVITY")
                                                          : String(localized: "VIEW ACTIVITY"),
                        systemImage: "stopwatch")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model.live)
        }
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet { name in
                model.startWorkout(sport: name)
                showLiveWorkout = true
            }
        }
        .task(id: repo.refreshSeq) { await addDetectedActivities() }
    }

    private func workoutRow(_ w: WorkoutRow) -> some View {
        row(icon: sportSymbol(w.sport),
            chip: w.strain.map { String(format: "%.1f", AICoachEngine.strain21($0)) } ?? "–",
            chipColor: StrandPalette.effortColor,
            name: WorkoutSource.displaySport(w.sport).uppercased(),
            start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
            end: Date(timeIntervalSince1970: TimeInterval(w.endTs)))
    }

    private func row(icon: String, chip: String, chipColor: Color, name: String,
                     start: Date?, end: Date?) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(WhoopStyle.icon)
                Text(chip).font(WhoopStyle.number(18))
            }
            .foregroundStyle(WhoopStyle.onGradient)
            .frame(width: 88, height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chipColor))
            Text(name)
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: NoopMetrics.space1)
            VStack(alignment: .trailing, spacing: 2) {
                if let start { Text(WhoopTime.clock(start)) }
                if let end { Text(WhoopTime.clock(end)) }
            }
            .font(WhoopStyle.caption)
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(NoopMetrics.space2)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WhoopStyle.ringTrack.opacity(0.6)))
    }
}

// MARK: - My Journal

/// "MY JOURNAL": the last seven days with a check for each day whose journal is saved, plus the Behavior
/// Insights button (NOOP's "What Moves You" hub). Days follow the journal's one day model
/// (`JournalDays`): a check under Friday means "What happened on Friday?" is answered, in Yoop or in an
/// imported WHOOP journal. Tapping a day opens the journal on that day; tapping the rest of the card opens
/// it on the day WHOOP would ask about.
struct WhoopJournalCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    /// Stored day keys with any journal answer across the strip (`Repository.journalAnsweredDays`).
    @State private var answeredDays: Set<String> = []

    /// The strip's `JournalDays` offsets, oldest on the left: six days ago through today.
    private var stripOffsets: [Int] { Array((0..<JournalDays.stripCount).reversed()) }

    var body: some View {
        let logicalToday = Repository.logicalDay(Date())
        return WhoopTitledCard(title: String(localized: "MY JOURNAL")) {
            HStack(spacing: 0) {
                ForEach(stripOffsets, id: \.self) { offset in
                    Button { router.openJournal(day: offset) } label: {
                        dayColumn(offset: offset, logicalToday: logicalToday)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(JournalLogCard.dayLabel(offset))
                }
            }
            Button { router.openInsightsHub() } label: {
                WhoopActionButtonLabel(title: String(localized: "BEHAVIOR INSIGHTS"), systemImage: "lightbulb")
            }
            .buttonStyle(.plain)
        }
        // The title and the card's bare surface open the journal on the day WHOOP would ask about; the
        // day buttons and Behavior Insights take their own taps first.
        .contentShape(Rectangle())
        .onTapGesture {
            router.openJournal(day: JournalDays.dueOffset(answered: answeredDays,
                                                          logicalToday: Repository.logicalDay(Date())))
        }
        // Re-read on a data refresh, on every journal save or clear, and when the logical day rolls, so a
        // check appears the moment a day's journal is answered.
        .task(id: JournalStripLoadKey(seq: repo.refreshSeq, journalSeq: repo.journalSeq,
                                      day: Repository.logicalDayKey(Date()))) {
            let today = Repository.logicalDay(Date())
            answeredDays = await repo.journalAnsweredDays(
                from: JournalDays.storageKey(offset: JournalDays.stripCount - 1, logicalToday: today),
                to: JournalDays.storageKey(offset: 0, logicalToday: today))
        }
    }

    private func dayColumn(offset: Int, logicalToday: Date) -> some View {
        let day = JournalDays.behaviourDay(offset: offset, logicalToday: logicalToday)
        let logged = answeredDays.contains(JournalDays.storageKey(offset: offset, logicalToday: logicalToday))
        let isToday = offset == 0
        return VStack(spacing: NoopMetrics.space2) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            ZStack {
                Capsule()
                    .fill(logged ? WhoopStyle.rangeGreen : WhoopStyle.ringTrack)
                    .frame(width: isToday ? 40 : 22, height: 22)
                Image(systemName: logged ? "checkmark" : "plus")
                    .font(WhoopStyle.chevron)
                    .foregroundStyle(logged ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())   // the whole column is the day's tap target
    }
}

/// Reload key for the Home journal strip: a data refresh, a journal save or clear, or a logical-day rollover.
private struct JournalStripLoadKey: Equatable {
    let seq: Int
    let journalSeq: Int
    let day: String
}

// MARK: - My Dashboard

/// "My Dashboard": WHOOP-style metric rows (icon, UPPERCASE name, today's value, the 30-day average
/// under it, and an arrow coloured by whether the move is good or bad for that metric).
struct WhoopDashboardSection: View {
    let today: DailyMetric?
    let days: [DailyMetric]
    let steps: Double?
    let calories: Double?
    let vo2max: Double?
    /// Apple Health steps per day; when present, the steps average uses the phone's history.
    var appleStepsByDay: [String: Double] = [:]
    /// Yoop: the day's total energy (basal + active), and one day's basal energy for the total's average.
    var totalCalories: Double?
    var basalKcalPerDay: Double?
    let onCustomize: () -> Void

    private struct Row: Identifiable {
        let id: String
        let label: String
        let icon: String
        let value: Double?
        let average: Double?
        let decimals: Int
        let higherIsBetter: Bool
        let route: TabRoute?
    }

    /// The prior 30 days' mean, skipping days below `floor` (a day the strap barely recorded would
    /// otherwise drag the "normal" down to nothing). Nil with fewer than 3 usable days.
    private func average(floor: Double = 0, _ pick: (DailyMetric) -> Double?) -> Double? {
        let prior = days.filter { $0.day != today?.day }.suffix(30).compactMap(pick).filter { $0 > floor }
        return prior.count < 3 ? nil : prior.reduce(0, +) / Double(prior.count)
    }

    private var stepsAverage: Double? {
        let phone = days.filter { $0.day != today?.day }.suffix(30)
            .compactMap { appleStepsByDay[$0.day] }.filter { $0 > 1000 }
        if phone.count >= 3 { return phone.reduce(0, +) / Double(phone.count) }
        return average(floor: 1000) { $0.steps.map(Double.init) }
    }

    private var rows: [Row] {
        [
            Row(id: "hrv", label: String(localized: "HEART RATE VARIABILITY"), icon: "waveform.path.ecg",
                value: today?.avgHrv, average: average { $0.avgHrv }, decimals: 0, higherIsBetter: true,
                route: .metric("hrv")),
            Row(id: "rhr", label: String(localized: "RESTING HEART RATE"), icon: "heart",
                value: today?.restingHr.map(Double.init), average: average { $0.restingHr.map(Double.init) },
                decimals: 0, higherIsBetter: false, route: .metric("rhr")),
            Row(id: "resp", label: String(localized: "RESPIRATORY RATE"), icon: "lungs",
                value: today?.respRateBpm, average: average { $0.respRateBpm }, decimals: 1,
                higherIsBetter: false, route: .metric("resp_rate")),
            Row(id: "spo2", label: String(localized: "BLOOD OXYGEN"), icon: "drop",
                value: today?.spo2Pct, average: average { $0.spo2Pct }, decimals: 0, higherIsBetter: true,
                route: nil),
            Row(id: "steps", label: String(localized: "STEPS"), icon: "shoeprints.fill",
                value: steps, average: stepsAverage, decimals: 0,
                higherIsBetter: true, route: nil),
        ] + calorieRows + [
            Row(id: "vo2", label: String(localized: "VO₂ MAX"), icon: "bicycle",
                value: vo2max, average: nil, decimals: 0, higherIsBetter: true, route: nil),
        ]
    }

    /// Yoop stores ACTIVE energy, so its row says so and a TOTAL row adds the basal energy; NOOP's stored
    /// figure is the whole-day total, shown as CALORIES.
    private var calorieRows: [Row] {
        guard PuffinExperiment.whoopScoresEnabled else {
            return [Row(id: "kcal", label: String(localized: "CALORIES"), icon: "flame",
                        value: calories, average: average(floor: 100) { $0.activeKcalEst }, decimals: 0,
                        higherIsBetter: true, route: nil)]
        }
        let activeAverage = average { $0.activeKcalEst }
        return [
            Row(id: "kcal", label: String(localized: "ACTIVE CALORIES"), icon: "flame",
                value: calories, average: activeAverage, decimals: 0, higherIsBetter: true, route: nil),
            Row(id: "kcalTotal", label: String(localized: "TOTAL CALORIES"), icon: "flame.fill",
                value: totalCalories, average: basalKcalPerDay.flatMap { basal in activeAverage.map { $0 + basal } },
                decimals: 0, higherIsBetter: true, route: nil),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("My Dashboard")
                    .font(WhoopStyle.sectionTitle)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button(action: onCustomize) {
                    HStack(spacing: 6) {
                        Text("CUSTOMIZE").font(WhoopStyle.smallLabel)
                        Image(systemName: "pencil").font(WhoopStyle.chevron)
                    }
                    .foregroundStyle(WhoopStyle.onGradient)
                    .padding(.horizontal, NoopMetrics.space3)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(WhoopStyle.reviewGradient))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, NoopMetrics.space2)
            ForEach(rows.filter { $0.value != nil }) { row in
                if let route = row.route {
                    NavigationLink(value: route) { rowView(row) }.buttonStyle(.plain)
                } else {
                    rowView(row)
                }
            }
        }
    }

    private func format(_ v: Double, _ decimals: Int) -> String {
        decimals > 0 ? String(format: "%.\(decimals)f", v) : Int(v.rounded()).formatted()
    }

    private func rowView(_ row: Row) -> some View {
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
                Text(row.value.map { format($0, row.decimals) } ?? "—")
                    .font(WhoopStyle.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let avg = row.average {
                    Text(format(avg, row.decimals))
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            arrow(row)
        }
        .padding(.horizontal, WhoopStyle.compactPadding)
        .padding(.vertical, NoopMetrics.space3)
        .whoopCard()
    }

    @ViewBuilder private func arrow(_ row: Row) -> some View {
        if let v = row.value, let avg = row.average, abs(v - avg) > 0.0001 {
            let up = v > avg
            let good = up == row.higherIsBetter
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(WhoopStyle.chevron)
                .foregroundStyle(good ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                .frame(width: 10)
        } else {
            Color.clear.frame(width: 10)
        }
    }
}

// MARK: - Stress Monitor chart

/// "STRESS MONITOR": today's 0-3 stress line, from the same `StressDayCurve` the Stress screen uses.
struct WhoopStressChartCard: View {
    let currentStress: Double?

    @EnvironmentObject private var repo: Repository
    @State private var points: [DaytimeStress.HourPoint] = []
    /// The time under the reader's finger: the header reads that moment instead of the latest.
    @State private var selection: Date?

    private struct StressSample: Identifiable {
        let time: Date
        let level: Double
        var id: Date { time }
    }

    /// The value shown in the header: the chart's latest reading, so the number and the line agree;
    /// the daily score only until the first hour is scored.
    private var shownStress: Double? {
        points.last(where: { $0.level != nil })?.level ?? currentStress
    }

    private var scored: [StressSample] {
        points.compactMap { p in
            p.level.map { StressSample(time: Date(timeIntervalSince1970: TimeInterval(p.startTs)), level: $0) }
        }
    }

    private var picked: StressSample? {
        selection.flatMap { sel in
            scored.min { abs($0.time.timeIntervalSince(sel)) < abs($1.time.timeIntervalSince(sel)) }
        }
    }

    private var level: (word: String, color: Color) {
        guard let s = picked?.level ?? shownStress else { return (String(localized: "CALIBRATING"), StrandPalette.textTertiary) }
        switch s {
        case ..<1: return (String(localized: "LOW"), WhoopStyle.stressLow)
        case ..<2: return (String(localized: "MEDIUM"), WhoopStyle.stressMedium)
        default: return (String(localized: "HIGH"), WhoopStyle.stressHigh)
        }
    }

    var body: some View {
        NavigationLink(value: TabRoute.stress) {
            WhoopTitledCard(title: String(localized: "STRESS MONITOR")) {
                HStack {
                    if let picked {
                        Text(picked.time, format: .dateTime.hour().minute())
                            .font(WhoopStyle.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Today")
                            .font(WhoopStyle.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Text(level.word).font(WhoopStyle.smallLabel).foregroundStyle(level.color)
                    Text((picked?.level ?? shownStress).map { String(format: "%.1f", $0) } ?? "—")
                        .font(WhoopStyle.number(18))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                let samples = scored
                if samples.count >= 2 {
                    Chart {
                        ForEach(samples) { item in
                            LineMark(x: .value("Time", item.time), y: .value("Stress", item.level))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(LinearGradient(colors: [WhoopStyle.stressLow, WhoopStyle.stressMedium,
                                                                         WhoopStyle.stressHigh],
                                                                startPoint: .bottom, endPoint: .top))
                        }
                        if let picked {
                            RuleMark(x: .value("Time", picked.time))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineStyle(StrokeStyle(lineWidth: 1))
                        }
                    }
                    .whoopScrub($selection)
                    .chartYScale(domain: 0...3)
                    .chartYAxis {
                        AxisMarks(values: [0, 1, 2, 3]) { _ in
                            AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
                            AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour()).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .frame(height: 140)
                } else {
                    Text("Builds through the day as your strap syncs.")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .task {
            let result = await StressDayCurve.today(
                repo: repo, personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?.result
            points = result?.timeline ?? []
        }
    }
}

// MARK: - Strain & Recovery

/// "STRAIN & RECOVERY": the last seven days, Strain (0-21, blue) and Recovery (%, coloured) on one chart.
struct WhoopStrainRecoveryCard: View {
    let days: [DailyMetric]

    /// The day under the reader's finger, read out above the chart.
    @State private var selectedDay: String?

    private struct Point: Identifiable {
        let id = UUID()
        let day: String
        let series: String
        let value: Double
        let label: String
        let color: Color
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func shortDay(_ key: String) -> String {
        guard let d = Self.dayParser.date(from: key) else { return key }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    /// The seven calendar days ending on the latest day, as day keys. Points are keyed by these, not by
    /// weekday name: seven entries with a missing day among them reach back eight days, and two Fridays
    /// on one weekday slot sent the lines back across the chart. A day with no data keeps its slot.
    private var week: [String] {
        guard let last = days.last?.day, let end = Self.dayParser.date(from: last) else { return [] }
        return (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: end) }
            .map { Self.dayParser.string(from: $0) }
    }

    private var points: [Point] {
        let keys = Set(week)
        return days.suffix(8).filter { keys.contains($0.day) }.flatMap { d -> [Point] in
            var out: [Point] = []
            if let s = d.strain {
                let v = AICoachEngine.strain21(s)
                out.append(Point(day: d.day, series: "Strain", value: v,
                                 label: String(format: "%.1f", v), color: StrandPalette.effortColor))
            }
            if let r = d.recovery {
                out.append(Point(day: d.day, series: "Recovery", value: r * 21 / 100,
                                 label: "\(Int(r.rounded()))%", color: StrandPalette.recoveryColor(r)))
            }
            return out
        }
    }

    var body: some View {
        WhoopTitledCard(title: String(localized: "STRAIN & RECOVERY"), showsChevron: false) {
            if points.isEmpty {
                Text("Fills in as days are scored.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                let all = points
                selectedReadout(all)
                Chart {
                    ForEach(all) { p in
                        LineMark(x: .value("Day", p.day), y: .value("Value", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                        PointMark(x: .value("Day", p.day), y: .value("Value", p.value))
                            .foregroundStyle(p.color)
                            .annotation(position: .top, spacing: 2) {
                                Text(p.label).font(WhoopStyle.chevron).foregroundStyle(p.color)
                            }
                    }
                    if let selectedDay {
                        RuleMark(x: .value("Day", selectedDay))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }
                .whoopScrub($selectedDay)
                .chartForegroundStyleScale(["Strain": StrandPalette.effortColor,
                                            "Recovery": StrandPalette.textTertiary])
                .chartLegend(.hidden)
                .chartYScale(domain: 0...23)
                .chartYAxis {
                    AxisMarks(values: [0, 7, 14, 21]) { _ in
                        AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
                        AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .chartXScale(domain: week)
                .chartXAxis {
                    AxisMarks(values: week) { value in
                        AxisValueLabel {
                            Text(shortDay(value.as(String.self) ?? ""))
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .frame(height: 190)
            }
        }
    }
}

extension WhoopStrainRecoveryCard {
    /// "Mon  12.8  73%" for the held day (Strain in its blue, Recovery in its band colour); empty at the
    /// same height otherwise.
    private func selectedReadout(_ all: [Point]) -> some View {
        let held = all.filter { $0.day == selectedDay }
        return HStack(spacing: NoopMetrics.space3) {
            if let selectedDay, !held.isEmpty {
                Text(shortDay(selectedDay))
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                ForEach(held) { p in
                    Text(verbatim: p.label)
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(p.color)
                }
            }
            Spacer()
        }
        .frame(height: 16)
    }
}

// MARK: - My Plan

/// "My Plan": the activity committed from the Coach's suggestion cards today, with a Done check.
struct WhoopPlanCard: View {
    @AppStorage(CoachPlan.storageKey) private var planRaw = ""

    var body: some View {
        if let plan = CoachPlan.decode(planRaw), plan.day == Repository.logicalDayKey(Date()) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("My Plan")
                    .font(WhoopStyle.sectionTitle)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.top, NoopMetrics.space2)
                Button {
                    var updated = plan
                    updated.done.toggle()
                    planRaw = updated.encoded
                } label: {
                    WhoopTitledCard(title: String(localized: "TODAY'S PLAN"), showsChevron: false) {
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            Image(systemName: plan.done ? "checkmark.circle.fill" : "circle")
                                .font(WhoopStyle.headline)
                                .foregroundStyle(plan.done ? WhoopStyle.rangeGreen : StrandPalette.textTertiary)
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                Text(plan.name)
                                    .font(WhoopStyle.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .strikethrough(plan.done)
                                if !plan.why.isEmpty {
                                    Text(plan.why)
                                        .font(WhoopStyle.body)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        ProgressView(value: plan.done ? 1 : 0)
                            .tint(WhoopStyle.rangeGreen)
                        Text(plan.done ? String(localized: "100% ACCOMPLISHED") : String(localized: "0% ACCOMPLISHED"))
                            .font(WhoopStyle.smallLabel)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
