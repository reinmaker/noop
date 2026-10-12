import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// WHOOP-style fork: the page behind My Dashboard's ACTIVE CALORIES and TOTAL CALORIES rows (CALORIES when
// Yoop scores are off). The headline numbers are the rows' own, passed in from Home. Active energy is then
// split by clock hour and by activity with `Calories.yoopActiveKcalByMinute`, whose minutes add up to the
// day's active energy bit for bit, so every split here adds up to the number the row shows.

struct WhoopCaloriesScreen: View {
    let figures: WhoopRowFigures

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    /// What one read of the day's minutes produced.
    private struct Breakdown {
        var hours: WhoopHourly.Split
        var activities: [Activity]
        /// Active energy outside every activity, in whole kcal.
        var rest: Int
    }

    private struct Activity: Identifiable {
        let row: WorkoutRow
        /// Its share of the day's active energy, in whole kcal.
        let kcal: Int
        var id: String { "\(row.startTs)|\(row.sport)|\(row.source)" }
    }

    @State private var breakdown: Breakdown?
    @State private var loaded = false
    @State private var weekTotals: [WhoopStackedWeekBars.Day] = []
    @State private var weekActive: [String: Double] = [:]

    /// The seven calendar days ending on the shown day.
    private var week: [String] { WhoopDayFigures.dayKeys(endingOn: figures.day, count: 7) }

    /// Yoop stores ACTIVE energy and adds basal for a total; NOOP's stored figure is the whole-day total.
    private var splitsEnergy: Bool { PuffinExperiment.whoopScoresEnabled }
    private var active: Double? { figures.value }

    /// Basal energy as the two rows show it: the TOTAL row's whole number less the ACTIVE row's, so the two
    /// parts shown always add up to the total shown.
    private var basal: Int? {
        guard let total = figures.total, let active else { return nil }
        return Int(total.rounded()) - Int(active.rounded())
    }

    var body: some View {
        WhoopDayPage(title: whoopPageTitle(day: figures.day, isToday: figures.isToday)) {
            if splitsEnergy { splitHero } else { singleHero }
            if let sentence = sentence { WhoopPageSentence(text: sentence) }
            if splitsEnergy {
                hourlyCard
                activitiesCard
                WhoopStackedWeekBars(title: String(localized: "LAST 7 DAYS"), days: weekTotals, week: week,
                                     shownDay: figures.day, baseTint: StrandPalette.metricAmber.opacity(0.45),
                                     topTint: StrandPalette.metricAmber, baseName: String(localized: "BASAL"),
                                     topName: String(localized: "ACTIVE"))
            } else {
                WhoopDayBarsCard(title: String(localized: "LAST 7 DAYS"), week: week, values: weekActive,
                                 shownDay: figures.day, tint: StrandPalette.metricAmber)
            }
            WhoopPageNote(title: String(localized: "HOW CALORIES ARE ESTIMATED"), lines: noteLines)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            WhoopCoachPill(screen: .calories, figure: active.map { String(Int($0.rounded())) } ?? "")
        }
        .task(id: "\(figures.day)|\(repo.refreshSeq)") { await load() }
    }

    // MARK: Headline

    private var splitHero: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            WhoopPageHero(icon: "flame.fill", label: String(localized: "TOTAL CALORIES"),
                          value: figures.total.map { Int($0.rounded()).formatted() } ?? "--",
                          unit: String(localized: "KCAL"),
                          normal: figures.totalAverage.map { Int($0.rounded()).formatted() },
                          normalLabel: normalLabel,
                          direction: WhoopDayFigures.direction(value: figures.total, normal: figures.totalAverage),
                          detail: fullDayLine(figures.fullDayTotalAverage))
            HStack(spacing: NoopMetrics.space3) {
                part(icon: "flame", label: String(localized: "ACTIVE"), value: active.map { Int($0.rounded()) },
                     normal: figures.average,
                     direction: WhoopDayFigures.direction(value: active, normal: figures.average))
                part(icon: "bed.double", label: String(localized: "BASAL"), value: basal, normal: nil, direction: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var singleHero: some View {
        WhoopPageHero(icon: "flame", label: String(localized: "CALORIES"),
                      value: active.map { Int($0.rounded()).formatted() } ?? "--", unit: String(localized: "KCAL"),
                      normal: figures.average.map { Int($0.rounded()).formatted() },
                      normalLabel: normalLabel,
                      direction: WhoopDayFigures.direction(value: active, normal: figures.average),
                      detail: fullDayLine(figures.fullDayAverage))
    }

    /// What the normal under the headline is: today's by this time of day, or the 30-day whole-day one.
    private var normalLabel: String {
        figures.byNow ? String(localized: "NORMAL BY NOW") : String(localized: "30-DAY NORMAL")
    }

    /// Today's whole-day normal beside the by-now one, so the distance to a full day is stated.
    private func fullDayLine(_ full: Double?) -> String? {
        guard figures.byNow, let full else { return nil }
        return String(localized: "A full day usually reaches \(Int(full.rounded()).formatted()).")
    }

    private func part(icon: String, label: String, value: Int?, normal: Double?, direction: Int) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: icon).font(WhoopStyle.icon).foregroundStyle(StrandPalette.textSecondary)
                Text(label).font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(value.map { $0.formatted() } ?? "--")
                .font(WhoopStyle.number(32))
                .foregroundStyle(StrandPalette.textPrimary)
            if let normal {
                HStack(spacing: NoopMetrics.space1) {
                    Text(figures.byNow ? String(localized: "\(Int(normal.rounded()).formatted()) by now")
                         : Int(normal.rounded()).formatted())
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    if direction != 0 {
                        Image(systemName: direction > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(WhoopStyle.chevron)
                            .foregroundStyle(direction > 0 ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
    }

    // MARK: Hours and activities

    @ViewBuilder private var hourlyCard: some View {
        if let hours = breakdown?.hours, !hours.bars.isEmpty {
            WhoopHourBarsCard(title: String(localized: "ACTIVE CALORIES BY HOUR"), split: hours,
                              tint: StrandPalette.metricAmber,
                              readout: { bar in
                                  String(localized: "\(whoopHourText(bar.start)): \(bar.value.formatted()) kcal")
                              },
                              hint: String(localized: "Hold and drag to read an hour"),
                              reconciliation: reconciliation(hours))
        } else if loaded {
            WhoopPageNote(title: String(localized: "ACTIVE CALORIES BY HOUR"),
                          lines: [String(localized: "There is no heart rate for this day, so it cannot be split into hours.")])
        }
    }

    /// Whether the hours hold all of the day's active energy, in words; a shortfall or an excess is stated.
    private func reconciliation(_ hours: WhoopHourly.Split) -> String? {
        guard let active else { return nil }
        let gap = Int(active.rounded()) - hours.placed
        if gap == 0 {
            return String(localized: "The hours add up to the day's \(hours.placed.formatted()) active calories.")
        }
        return gap > 0
            ? String(localized: "\(gap.formatted()) of the day's active calories cannot be placed in an hour.")
            : String(localized: "The hours hold \((-gap).formatted()) more calories than the day's total, counted since it was last updated.")
    }

    @ViewBuilder private var activitiesCard: some View {
        if let breakdown, !breakdown.activities.isEmpty {
            WhoopTitledCard(title: String(localized: "ACTIVITIES"), showsChevron: false) {
                VStack(spacing: 0) {
                    ForEach(breakdown.activities) { item in
                        NavigationLink(value: TabRoute.activity(WhoopActivityRoute(row: item.row))) {
                            activityRow(item)
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
                    }
                    HStack {
                        Text("Everything else")
                            .font(WhoopStyle.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        Text("\(breakdown.rest.formatted()) kcal")
                            .font(WhoopStyle.detail)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .padding(.vertical, NoopMetrics.space3)
                }
                Text("Each share is the part of the day's active calories that fell inside that activity. An activity's own page works out its calories separately from its heart rate, so the two can differ.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if loaded, breakdown != nil {
            WhoopPageNote(title: String(localized: "ACTIVITIES"),
                          lines: [String(localized: "No activities were logged on this day. Its active calories came from walking and moving about.")])
        }
    }

    private func activityRow(_ item: Activity) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: sportSymbol(item.row.sport))
                .font(WhoopStyle.icon)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(WorkoutSource.displaySport(item.row.sport))
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(windowText(item.row))
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let own = item.row.energyKcal, own > 0 {
                    Text("On its own page: \(Int(own.rounded()).formatted()) kcal, with resting energy")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: NoopMetrics.space1)
            Text("\(item.kcal.formatted()) kcal")
                .font(WhoopStyle.detail)
                .foregroundStyle(StrandPalette.textPrimary)
            Image(systemName: "chevron.right")
                .font(WhoopStyle.chevron)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, NoopMetrics.space3)
    }

    private func windowText(_ row: WorkoutRow) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let end = Date(timeIntervalSince1970: TimeInterval(max(row.endTs, row.startTs)))
        return "\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Words

    /// One plain sentence: the day's active energy against its 30-day normal. Without Yoop scores the one
    /// number is the whole day's energy and the headline's normal and arrow already say as much.
    private var sentence: String? {
        guard splitsEnergy, let active else { return nil }
        let normal = figures.average.map { Int($0.rounded()).formatted() } ?? ""
        if figures.byNow {
            switch WhoopDayFigures.standing(value: active, normal: figures.average) {
            case .above(let gap):
                return String(localized: "Your active calories are \(Int(gap.rounded()).formatted()) above your normal by now, \(normal).")
            case .below(let gap):
                return String(localized: "Your active calories are \(Int(gap.rounded()).formatted()) below your normal by now, \(normal).")
            case .level:
                return String(localized: "Your active calories are about your normal by now, \(normal).")
            case .unknown:
                return nil
            }
        }
        switch WhoopDayFigures.standing(value: active, normal: figures.average) {
        case .above(let gap):
            return String(localized: "Your active calories are \(Int(gap.rounded()).formatted()) above your 30-day normal of \(normal).")
        case .below(let gap):
            return String(localized: "Your active calories are \(Int(gap.rounded()).formatted()) below your 30-day normal of \(normal).")
        case .level:
            return String(localized: "Your active calories are about your 30-day normal of \(normal).")
        case .unknown:
            return String(localized: "Your 30-day normal of active calories appears after a few days.")
        }
    }

    private var noteLines: [String] {
        guard splitsEnergy else {
            return [String(localized: "This is your strap's heart-rate estimate for the whole day, resting and active energy together. It is not a lab measurement.")]
        }
        var lines = [String(localized: "Active energy is worked out minute by minute from your steps and heart rate. A minute of walking is priced by its steps, and a minute of harder effort by your heart rate.")]
        lines.append(String(localized: "During a strength session the strap's step counter follows your arm movement, so those minutes are priced by heart rate, never as walking."))
        lines.append(String(localized: "Basal energy is the energy your body uses at rest, estimated from your age, height, weight and sex (Mifflin-St Jeor), over the hours of this day."))
        lines.append(String(localized: "Both are estimates, not lab measurements."))
        return lines
    }

    // MARK: Load

    private func load() async {
        defer { loaded = true }
        let cal = Calendar.current
        let dayStart = WhoopDayFigures.date(of: figures.day).map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: Date())
        let from = figures.windowFrom ?? Int(dayStart.timeIntervalSince1970)
        let toExclusive = from + (figures.windowSeconds ?? 86_400)
        weekActive = Dictionary(WhoopDayFigures.recent(days: repo.days.filter { $0.day <= figures.day },
                                                       endingOn: figures.day, count: 7, shown: active) { $0.activeKcalEst }
            .map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        await loadWeek()
        guard splitsEnergy, active != nil else { return }

        let sleeps = repo.sleeps
        let logged = await repo.workoutRows(days: 4000)
        let steps = await WhoopDayMinutes.steps(repo: repo, profile: profile, from: from, to: toExclusive)
        guard let energy = await WhoopDayMinutes.activeKcal(repo: repo, profile: profile, day: figures.day,
                                                            from: from, to: toExclusive,
                                                            stepsByMinute: steps?.perMinute ?? [:],
                                                            workouts: logged) else {
            breakdown = nil
            return
        }
        let byMinute = energy.perMinute

        // Rounded together: the bars, the activities and the rest add up to the day's whole number.
        let counted = Int(byMinute.keys.sorted().reduce(0.0) { $0 + (byMinute[$1] ?? 0) }.rounded())
        let hours = WhoopHourly.split(valueByMinute: byMinute, from: from, toExclusive: toExclusive, total: counted,
                                      asleep: sleeps.map { (start: $0.effectiveStartTs, end: $0.endTs) })
        let rows = logged
            .filter { $0.startTs >= from && $0.startTs < toExclusive }
            .sorted { $0.startTs < $1.startTs }
        let shares = WhoopHourly.shares(valueByMinute: byMinute,
                                        windows: rows.map { (start: $0.startTs, end: $0.endTs) }, total: counted)
        let listed = zip(rows, shares.windows).map { Activity(row: $0.0, kcal: $0.1) }.filter { $0.kcal > 0 }
        breakdown = Breakdown(hours: hours, activities: listed, rest: shares.rest)
    }

    /// The last seven days, each with its basal energy over its own window, as Home states it for that day;
    /// the shown day is the rows' own numbers.
    private func loadWeek() async {
        guard splitsEnergy, let basalPerDay = figures.basalKcalPerDay else { weekTotals = []; return }
        let markers = Dictionary(
            (await repo.exploreSeries(key: DayCycleIntelligenceIntegration.onsetKey, source: "my-whoop"))
                .map { ($0.day, Int($0.value)) }, uniquingKeysWith: { _, last in last })
        let days = repo.days.filter { $0.day <= figures.day }
        weekTotals = WhoopDayFigures.recent(days: days, endingOn: figures.day, count: 7, shown: active) {
            $0.activeKcalEst
        }.map { item in
            if item.day == figures.day, let total = figures.total {
                return WhoopStackedWeekBars.Day(day: item.day, base: total - item.value, top: item.value)
            }
            let seconds = WhoopDayFigures.windowSeconds(day: item.day, markers: markers)
            return WhoopStackedWeekBars.Day(day: item.day, base: basalPerDay * Double(seconds) / 86_400, top: item.value)
        }
    }
}
