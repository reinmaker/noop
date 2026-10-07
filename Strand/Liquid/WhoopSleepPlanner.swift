import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// WHOOP's Sleep Planner arithmetic, fitted to the user's WHOOP export (121 nights; RMSE 26 min on sleep
/// need): sleep need = the healthy minimum (7:30, or more for a long sleeper) + 7.3 min for each point of
/// today's Strain above 10 + sleep debt; time in bed = need / the usual sleep efficiency; bedtime = wake
/// time - time in bed. With an 8:30 alarm this gives WHOOP's own 00:29 for 7 Oct 2026. The wake time is
/// the alarm when one is set, else the usual wake time of recent nights; the optimal window is the time
/// in bed centred on the usual middle of the night.
struct WhoopSleepPlan {
    let baselineMin: Double
    let strainMin: Double
    let debtMin: Double
    let efficiency: Double
    let wake: Date
    let wakeIsAlarm: Bool
    /// Start of the time in bed centred on the usual middle of the night, when recent nights exist.
    let optimalStart: Date?

    var needMin: Double { baselineMin + strainMin + debtMin }
    var timeInBedMin: Double { needMin / efficiency }
    var bedtime: Date { wake.addingTimeInterval(-timeInBedMin * 60) }
    var optimalEnd: Date? { optimalStart.map { $0.addingTimeInterval(timeInBedMin * 60) } }

    /// The plan a screen showed last, so the Coach quotes the same times.
    @MainActor static var lastShown: WhoopSleepPlan?

    private static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The next time the clock reads `minutes` after midnight, after `now`.
    private static func next(clockMinutes minutes: Int, after now: Date) -> Date {
        let cal = Calendar.current
        let today = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now) ?? now
        return today > now ? today : (cal.date(byAdding: .day, value: 1, to: today) ?? today)
    }

    @MainActor
    static func tonight(repo: Repository, alarm: Date?, now: Date = Date()) -> WhoopSleepPlan {
        let days = repo.days
        let baseline = SleepModel.sleepNeedMin(days: days)
        let strain = days.last?.strain.map(AICoachEngine.strain21) ?? 0
        let debt = SleepModel.sleepDebtSeries(days: days, importedSleep: repo.importedSleep,
                                              napSleepMinByDay: [:]).latest ?? 0
        let efficiencies = days.suffix(14).compactMap(\.efficiency).filter { $0 > 0.5 && $0 <= 1 }
        let efficiency = min(0.98, max(0.8, median(efficiencies) ?? 0.94))

        let cal = Calendar.current
        func clock(_ ts: Int) -> Double {
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
            return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
        }
        let nights = SleepModel.nightWindows(repo.sleeps, last: 7)
        let wake: Date
        if let alarm {
            wake = alarm
        } else if let usual = median(nights.map { clock($0.end) }) {
            wake = next(clockMinutes: Int(usual), after: now)
        } else {
            wake = next(clockMinutes: WindDownNudge.wakeMinutes, after: now)
        }

        let need = baseline + 7.3 * max(0, strain - 10) + max(0, debt)
        let inBed = need / efficiency
        // The usual middle of the night on a noon-to-noon clock, placed on the night that ends at `wake`.
        let middles = nights.map { n -> Double in
            let start = clock(n.start)
            return (start < 720 ? start + 1440 : start) + Double(n.end - n.start) / 120
        }
        var optimalStart: Date?
        if let middle = median(middles) {
            let wakeNoon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: wake) ?? wake
            let nightNoon = wake < wakeNoon ? (cal.date(byAdding: .day, value: -1, to: wakeNoon) ?? wakeNoon) : wakeNoon
            optimalStart = nightNoon.addingTimeInterval((middle - 720 - inBed / 2) * 60)
        }
        return WhoopSleepPlan(baselineMin: baseline, strainMin: 7.3 * max(0, strain - 10), debtMin: max(0, debt),
                              efficiency: efficiency, wake: wake, wakeIsAlarm: alarm != nil,
                              optimalStart: optimalStart)
    }

    /// One line for the Coach's context, so its bedtime advice matches the card.
    var coachLine: String {
        func hm(_ m: Double) -> String { "\(Int(m) / 60)h \(Int(m) % 60)m" }
        return "Tonight's sleep plan, as the app's Tonight's Sleep card shows it: get in bed by "
            + "\(WhoopTime.clock(bedtime)) to wake at \(WhoopTime.clock(wake)) "
            + "(\(wakeIsAlarm ? "alarm" : "usual wake time")); sleep need \(hm(needMin)) = healthy minimum "
            + "\(hm(baselineMin)) + recent Strain \(hm(strainMin)) + sleep debt \(hm(debtMin)); time in bed "
            + "\(hm(timeInBedMin)) at \(Int((efficiency * 100).rounded()))% sleep efficiency. Use exactly these "
            + "times whenever you suggest a bedtime, lights out or a wake time."
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
        let plan = WhoopSleepPlan.tonight(repo: repo, alarm: WhoopTonightsSleepCard.nextAlarm(behavior: behavior, model: model))
        ScrollView {
            VStack(spacing: NoopMetrics.space5) {
                BrandMark(size: 44)
                    .padding(.top, NoopMetrics.space4)
                Text(plan.wakeIsAlarm
                     ? String(localized: "Your alarm will go off at \(WhoopTime.clock(plan.wake)). Get in bed by \(WhoopTime.clock(plan.bedtime)) to reach your sleep need.")
                     : String(localized: "Get in bed by \(WhoopTime.clock(plan.bedtime)) to reach your sleep need and wake at \(WhoopTime.clock(plan.wake))."))
                    .font(WhoopStyle.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top) {
                    figure(WhoopTime.clock(plan.bedtime), String(localized: "SUGGESTED TIME TO BED"))
                    Spacer()
                    figure(WhoopTime.clock(plan.wake),
                           plan.wakeIsAlarm ? String(localized: "ALARM ON") : String(localized: "USUAL WAKE"))
                }
                timeInBed(plan)
                needCard(plan)
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
        .onAppear { WhoopSleepPlan.lastShown = plan }
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
            if let start = plan.optimalStart, let end = plan.optimalEnd {
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
