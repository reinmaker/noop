import Foundation
import UserNotifications

/// The wind-down nudge (#207): a gentle, NON-critical evening local notification that it is time to start
/// winding down for tonight's bedtime.
///
/// Cross-platform (macOS + iOS): a sideloaded backgrounded app can't fire a dependable LOUD wake alarm
/// (no critical-alert entitlement), but it CAN post a calm reminder. The reminder follows tonight's sleep
/// plan (`WhoopSleepPlan`): it fires `leadMinutes` before the plan's bedtime, so it moves with the day's
/// Strain and sleep debt, with the armed strap alarm and with the user's own wake times. It used to be a
/// fixed daily trigger at wake minus a fixed 8 h need, which knew nothing about the day. Each night is its
/// own one-shot request, re-planned whenever the app becomes active, after a sync, when the bedtime moves
/// by `replanToleranceMinutes` or more, and when a setting changes; the nights after tonight are an
/// estimate that keeps the reminder alive if the app is not opened for a few days. State is its own
/// UserDefaults-backed store so it doesn't couple to the shared BehaviorStore. On-device only.
@MainActor
enum WindDownNudge {

    private static let requestId = "wind-down-nudge"

    // MARK: - Persisted settings (own keys; default OFF, opt-in like every automation)

    private enum K {
        static let enabled = "windDown.enabled"
        static let lead = "windDown.leadMinutes"             // default 30m
        // The wake time the user chose, minutes since midnight. Absent until they pick one: the plan then
        // takes the wake from their recent nights, never from a stored default.
        static let wake = "windDown.wakeMinutes"
        // PR#554 (MumiZed) per-day wake overrides. A JSON map of {weekday(1=Sun…7=Sat): wakeMinutes}.
        // Empty / no entry for a day = that day follows the plan, so the feature is purely additive.
        static let perDayWake = "windDown.perDayWakeMinutes"
        // The fire times (epoch seconds) of the requests last scheduled, so a re-plan can tell whether the
        // day moved the reminder enough to be worth replacing it.
        static let scheduledFires = "windDown.scheduledFires"
    }

    /// How many nights are scheduled ahead: tonight's, exact, and the next ones as an estimate.
    nonisolated static let plannedNights = 3

    /// The bedtime must move this far (minutes) before a re-plan replaces a pending reminder.
    nonisolated static let replanToleranceMinutes = 10

    /// Supplies the plans for the next `count` nights from `now`, soonest first. Set once by `AppModel`, which
    /// owns the repository and the alarm settings a plan reads; nil in tests that do not schedule.
    static var plansProvider: (@MainActor (_ count: Int, _ now: Date) -> [WhoopSleepPlan])?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    static var leadMinutes: Int {
        let v = UserDefaults.standard.object(forKey: K.lead) as? Int ?? 30
        return min(max(v, 0), 120)
    }

    /// The wake time the user chose, or nil when they never did.
    static var chosenWakeMinutes: Int? {
        guard let v = UserDefaults.standard.object(forKey: K.wake) as? Int else { return nil }
        return min(max(v, 0), 24 * 60 - 1)
    }

    // MARK: - Per-day wake overrides (PR#554)

    /// The stored per-weekday wake overrides, {weekday(1=Sun…7=Sat): wakeMinutes}. Empty when the user
    /// hasn't set any (the common case). Values are clamped to a valid minute-of-day on read so a corrupt
    /// blob can't schedule at a nonsense time.
    static var perDayWakeOverrides: [Int: Int] {
        guard let data = UserDefaults.standard.data(forKey: K.perDayWake),
              let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        var out: [Int: Int] = [:]
        for (k, v) in raw {
            guard let day = Int(k), (1...7).contains(day) else { continue }
            out[day] = min(max(v, 0), 24 * 60 - 1)
        }
        return out
    }

    /// The wake time the user chose for a given Calendar weekday (1=Sun…7=Sat): that day's own time if set,
    /// else the wake time they chose for every day, else nil (the plan then uses their recent nights).
    static func chosenWakeMinutes(forWeekday weekday: Int) -> Int? {
        perDayWakeOverrides[weekday] ?? chosenWakeMinutes
    }

    /// Whether ANY per-day override is set.
    static var hasPerDayOverrides: Bool { !perDayWakeOverrides.isEmpty }

    /// Set or clear a single weekday's wake override (pass nil to clear, so that day follows the plan again),
    /// re-planning if enabled. Clamps the minute-of-day so a bad value can't be stored.
    static func setWakeOverride(weekday: Int, minutes: Int?) {
        guard (1...7).contains(weekday) else { return }
        var map = perDayWakeOverrides
        if let m = minutes {
            map[weekday] = min(max(m, 0), 24 * 60 - 1)
        } else {
            map.removeValue(forKey: weekday)
        }
        let encodable = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: K.perDayWake)
        }
        if isEnabled { schedule() }
    }

    // MARK: - Public API

    /// The result of enabling the nudge, so the UI can react instead of silently persisting an "on" toggle
    /// that can never fire. `.denied` means the OS won't deliver (permission off), so the caller should
    /// revert the switch and point the user at Settings.
    enum EnableOutcome { case scheduled, denied, off }

    /// Enable/disable and (re)schedule. Enabling gates on notification authorization FIRST, mirroring the
    /// smart-alarm backup path in `AppModel.scheduleSmartAlarmBackupNotification`: if undetermined it asks
    /// once and schedules on grant; if already denied it reports back rather than persisting a dead toggle.
    ///
    /// Why this matters: the old version called `requestAuthorization` with an empty completion and then
    /// scheduled unconditionally. `requestAuthorization` only shows the system dialog when the status is
    /// `.notDetermined`; once a user (or a prior sideload install with the same bundle id) has denied, the
    /// dialog never returns and the app silently scheduled reminders the OS would never deliver, with
    /// nothing in the UI to explain it. Now denial surfaces.
    ///
    /// `completion` always runs on the main actor (the settings/authorization callbacks fire off-main).
    static func setEnabled(_ on: Bool, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            UserDefaults.standard.removeObject(forKey: K.scheduledFires)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: allRequestIds)
            completion?(.off)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    schedule()
                    completion?(.scheduled)
                case .notDetermined:
                    // First ask: the system dialog appears now (a predictable moment), then we schedule on
                    // grant so the FIRST night is covered rather than only after some later re-plan.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        Task { @MainActor in
                            if granted {
                                UserDefaults.standard.set(true, forKey: K.enabled)
                                schedule()
                                completion?(.scheduled)
                            } else {
                                UserDefaults.standard.set(false, forKey: K.enabled)
                                completion?(.denied)
                            }
                        }
                    }
                default:
                    // .denied (or any future non-authorized case): don't fake an enabled toggle. The caller
                    // surfaces a "notifications are off" prompt with a jump to Settings.
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    /// Set the wake time the plan uses on every day without a time of its own, re-planning if enabled.
    static func setWakeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.wake)
        if isEnabled { schedule() }
    }

    /// Forget the chosen wake time, so the plan takes it from the user's recent nights again.
    static func clearWakeMinutes() {
        UserDefaults.standard.removeObject(forKey: K.wake)
        if isEnabled { schedule() }
    }

    // MARK: - Scheduling

    /// Every request id the nudge has ever used, so a re-plan or a switch-off also clears what an earlier
    /// version left in the notification center: the old repeating daily trigger and its per-weekday twins.
    private static var allRequestIds: [String] {
        [requestId] + (1...7).map { "\(requestId)-wd\($0)" } + (0..<plannedNights).map { "\(requestId)-n\($0)" }
    }

    /// When the reminder for `plan` fires: `lead` minutes before its bedtime.
    static func fireDate(for plan: WhoopSleepPlan, leadMinutes lead: Int) -> Date {
        plan.bedtime.addingTimeInterval(-Double(lead) * 60)
    }

    /// The fire times worth scheduling: those still ahead of `now`. Tonight's is dropped once it has passed,
    /// so the reminder never fires late, and the nights after it still go out.
    static func upcomingFires(plans: [WhoopSleepPlan], leadMinutes lead: Int, now: Date) -> [Date] {
        plans.map { fireDate(for: $0, leadMinutes: lead) }.filter { $0 > now.addingTimeInterval(30) }
    }

    /// Whether the reminders pending (`scheduled`, their fire times) differ enough from the ones the plans
    /// now give (`desired`) to be replaced: a different number of nights, or any reminder `tolerance` minutes
    /// or more away. A pending time that has already passed no longer counts.
    nonisolated static func needsReplan(scheduled: [Date], desired: [Date], now: Date,
                            toleranceMinutes tolerance: Int = replanToleranceMinutes) -> Bool {
        let pending = scheduled.filter { $0 > now }
        guard pending.count == desired.count else { return true }
        return zip(pending.sorted(), desired.sorted()).contains { abs($0.timeIntervalSince($1)) >= Double(tolerance) * 60 }
    }

    /// Re-plan the pending reminders from the plans as they stand now, replacing them only when the day has
    /// moved one by `replanToleranceMinutes` or more (or none is pending). Called when the app becomes
    /// active, after a sync, and when the Strain moves the bedtime; a no-op while the nudge is off.
    static func replan(now: Date = Date()) {
        guard isEnabled else { return }
        // Nothing recorded yet: the first plan after an update from the fixed daily nudge, which clears it.
        guard UserDefaults.standard.object(forKey: K.scheduledFires) != nil else { return schedule(now: now) }
        let desired = upcomingFires(plans: plansProvider?(plannedNights, now) ?? [], leadMinutes: leadMinutes, now: now)
        let stored = (UserDefaults.standard.array(forKey: K.scheduledFires) as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        if needsReplan(scheduled: stored, desired: desired, now: now) { schedule(now: now) }
    }

    /// Replace every pending reminder with one request per planned night.
    private static func schedule(now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        // Clear the old single and per-weekday repeating triggers along with the new one-shots, so a re-plan
        // (or an upgrade from the fixed daily nudge) never double-fires or leaves an orphaned reminder.
        center.removePendingNotificationRequests(withIdentifiers: allRequestIds)

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to wind down")
        content.body = String(localized: "A calm hour now helps you hit your wake time well-rested.")
        content.sound = .default

        let plans = plansProvider?(plannedNights, now) ?? []
        var fires: [Date] = []
        for (night, plan) in plans.enumerated() {
            let fire = fireDate(for: plan, leadMinutes: leadMinutes)
            guard fire > now.addingTimeInterval(30) else { continue }
            // The wall-clock date and time, and nothing finer (a nanosecond or a week-of-year component would
            // have to match too): it fires once, at that local time, and the next re-plan follows the clock.
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: "\(requestId)-n\(night)", content: content, trigger: trigger))
            fires.append(fire)
        }
        UserDefaults.standard.set(fires.map(\.timeIntervalSince1970), forKey: K.scheduledFires)
    }
}

extension AppModel {
    /// Tonight's plan for the Coach, and the next nights' plans for the wind-down reminder, from the same call
    /// the screens make (`WhoopSleepPlan.current`), so a reminder, a card and the Coach cannot name different times.
    func wireSleepPlan() {
        coach.sleepPlan = { [weak self] in self?.sleepPlans(count: 1).first }
        WindDownNudge.plansProvider = { [weak self] count, now in self?.sleepPlans(count: count, now: now) ?? [] }
    }

    /// The plans for the next `count` nights from `now`, soonest first: tonight's from today's data, and each
    /// later night from the same data with no Strain yet, which is an estimate until its own day has been lived.
    func sleepPlans(count: Int, now: Date = Date()) -> [WhoopSleepPlan] {
        var plans: [WhoopSleepPlan] = []
        var at = now
        while plans.count < count, let plan = WhoopSleepPlan.current(repo: repo, behavior: behavior, model: self, now: at) {
            plans.append(plan)
            // Six hours after waking is inside that day, before the next night's wake time.
            at = plan.wake.addingTimeInterval(6 * 3600)
        }
        return plans
    }
}
