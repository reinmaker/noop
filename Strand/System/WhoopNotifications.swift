import Foundation
import UserNotifications
import WhoopStore

/// WHOOP-style notifications for Yoop (WHOOP's App Settings > Notifications, plus its evening Day In
/// Review): the Coach on sleep and Recovery ready and on an activity added (a tap opens the Coach, which
/// writes its read of the night or checks in about the session), Day In Review, Daily Stress Summary, Conversational
/// Check-Ins, Device Off-Body and Travel Insights. All local, all on by default, each with its own switch (`WhoopNotificationsView`). The
/// morning Daily Outlook is `CoachBriefScheduler`.
///
/// A tap routes through `NotificationPresenter.onYoopRoute` with the `routeKey` in `userInfo`.
enum WhoopNotifications {
    static let dayReviewKey = "whoopNotif.dayReview"
    static let stressSummaryKey = "whoopNotif.stressSummary"
    static let checkInsKey = "whoopNotif.checkIns"
    static let offBodyKey = "whoopNotif.offBody"
    static let travelKey = "whoopNotif.travel"
    static let sleepReadyKey = "whoopNotif.sleepReady"
    static let activityKey = "whoopNotif.activity"

    /// `userInfo` key naming where a tap should go: "dayReview", "coach" or "stress".
    static let routeKey = "yoop.route"

    private static let dayReviewId = "yoop-day-review"
    private static let dayReviewMinuteKey = "whoopNotif.dayReviewMinute"
    private static let stressSummaryId = "yoop-stress-summary"
    private static let offBodyId = "yoop-off-body"
    private static let travelId = "yoop-travel"
    private static let sleepReadyId = "yoop-sleep-ready"
    private static let sleepReadyDayKey = "whoopNotif.sleepReadyDay"
    private static let activityPostedKey = "whoopNotif.activityPosted"
    private static let timeZoneKey = "whoopNotif.lastTimeZone"

    /// On unless switched off.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    private static func content(_ title: String, _ body: String, route: String?) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if let route { c.userInfo = [routeKey: route] }
        return c
    }

    /// Only ever adds when permission is already granted; never prompts.
    private static func add(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.add(request)
        }
    }

    private static func cancel(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: Day In Review (when Home's row turns into the Review)

    /// The minute of the day the Home row turns from the Daily Outlook into the Day In Review when there is no
    /// sleep plan to read it from (`WhoopMyDaySection.isOutlook`: 19:00).
    static let dayReviewFallbackMinute = 19 * 60

    /// The earliest and latest minute of the day the note is sent at, so an odd plan cannot send it at noon or
    /// after midnight.
    static let dayReviewMinuteRange = (12 * 60)...(23 * 60 + 30)

    /// How many coming evenings are scheduled at once: the app may not be opened for a few days, and a note
    /// that was scheduled once is not repeated (the time moves with the plan).
    static let dayReviewDaysAhead = 3

    /// The minute of the day of the training cutoff, which is when Home's row becomes the Review, kept within
    /// `dayReviewMinuteRange`; the fallback minute without a cutoff. A cutoff between midnight and 04:00 (the
    /// logical day's rollover) belongs to the evening before, so it is the latest minute. Pure.
    static func dayReviewMinute(cutoff: Date?, calendar: Calendar = .current) -> Int {
        guard let cutoff else { return dayReviewFallbackMinute }
        let c = calendar.dateComponents([.hour, .minute], from: cutoff)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if minute < 4 * 60 { return dayReviewMinuteRange.upperBound }
        return min(dayReviewMinuteRange.upperBound, max(dayReviewMinuteRange.lowerBound, minute))
    }

    /// The next `count` times the clock reads `minute` after `now`, soonest first. Pure.
    static func dayReviewDates(now: Date, minute: Int, count: Int = dayReviewDaysAhead,
                               calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: now)
        for _ in 0..<(count + 2) where out.count < count {
            if let at = calendar.date(byAdding: .minute, value: minute, to: day), at > now { out.append(at) }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return out
    }

    /// Home tells the note when the row turns into the Review (the training cutoff of tonight's plan, or nil
    /// without a plan), and the note is scheduled again if that minute moved. It used to be a fixed 8:30 pm,
    /// so "Your Day In Review is ready" arrived while Home still showed the Daily Outlook.
    static func setDayReviewMinute(cutoff: Date?) {
        let minute = dayReviewMinute(cutoff: cutoff)
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: dayReviewMinuteKey) == nil || defaults.integer(forKey: dayReviewMinuteKey) != minute
        else { return }
        defaults.set(minute, forKey: dayReviewMinuteKey)
        scheduleDayReview()
    }

    /// Idempotent: re-adding the same id replaces it, and the first id is the one the old repeating 8:30 pm
    /// note used, so it is replaced too. Call on launch and when the switch changes.
    static func scheduleDayReview() {
        let ids = (0..<dayReviewDaysAhead).map { $0 == 0 ? dayReviewId : "\(dayReviewId)-\($0 + 1)" }
        guard isOn(dayReviewKey) else { cancel(ids); return }
        let defaults = UserDefaults.standard
        let minute = defaults.object(forKey: dayReviewMinuteKey) == nil
            ? dayReviewFallbackMinute : defaults.integer(forKey: dayReviewMinuteKey)
        let cal = Calendar.current
        let dates = dayReviewDates(now: Date(), minute: minute, calendar: cal)
        cancel(ids)
        for (id, date) in zip(ids, dates) {
            add(UNNotificationRequest(
                identifier: id,
                content: content(String(localized: "Your Day In Review is ready"),
                                 String(localized: "See how today went and what tonight's sleep needs."),
                                 route: "dayReview"),
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: date),
                    repeats: false)))
        }
    }

    // MARK: Daily Stress Summary (9pm, today's numbers as of the last update)

    /// Called whenever today's stress is computed; replaces tonight's summary with the latest figures.
    static func updateStressSummary(highMinutes: Int, scoredMinutes: Int) {
        guard isOn(stressSummaryKey) else { cancel([stressSummaryId]); return }
        let cal = Calendar.current
        let now = Date()
        guard let nine = cal.date(bySettingHour: 21, minute: 0, second: 0, of: now), nine > now else { return }
        let h = highMinutes / 60, m = highMinutes % 60
        let high = h > 0 ? String(localized: "\(h) hr \(m) min") : String(localized: "\(m) min")
        let share = scoredMinutes > 0 ? Int((Double(highMinutes) / Double(scoredMinutes) * 100).rounded()) : 0
        add(UNNotificationRequest(
            identifier: stressSummaryId,
            content: content(String(localized: "Daily Stress Summary"),
                             String(localized: "You spent \(high) in the high stress zone today (\(share)% of the day so far)."),
                             route: "stress"),
            trigger: UNCalendarNotificationTrigger(dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: nine),
                                                   repeats: false)))
    }

    // MARK: Conversational Check-Ins (next evening, about something you told the Coach)

    static func scheduleCheckIn(title: String, category: String) {
        guard isOn(checkInsKey) else { return }
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()),
              let at = cal.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) else { return }
        let body: String
        switch category {
        case "Goal": body = String(localized: "How's it going with \(title)? Tell me where you're at.")
        case "Event": body = String(localized: "Checking in about \(title). How are you feeling about it?")
        default: body = String(localized: "How's your \(title) today? Let me know so I can adjust your plan.")
        }
        let id = "yoop-checkin-" + title.lowercased().filter { $0.isLetter || $0.isNumber }
        add(UNNotificationRequest(
            identifier: id,
            content: content(String(localized: "Checking in"), body, route: "coach"),
            trigger: UNCalendarNotificationTrigger(dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: at),
                                                   repeats: false)))
    }

    // MARK: Sleep and Recovery ready (the night is scored)

    /// What the note says about a scored night, or nil when it is too short to be a night (under two hours).
    static func sleepReadyBody(_ night: DailyMetric) -> String? {
        guard let sleepMin = night.totalSleepMin, sleepMin >= WhoopAge.minNightMinutes else { return nil }
        let h = Int(sleepMin) / 60, m = Int(sleepMin) % 60
        let duration = String(localized: "\(h) hr \(m) min")
        guard let recovery = night.recovery else {
            return String(localized: "You slept \(duration). Tap for my read on your day.")
        }
        let percent = "\(Int(recovery.rounded()))%"
        return String(localized: "Recovery \(percent) after \(duration) of sleep. Tap for my read on your day.")
    }

    /// Once a day: the first time `todayKey` has been announced.
    static func isNewSleepDay(last: String?, todayKey: String) -> Bool { last != todayKey }

    /// How long the strap must have recorded after the night's last sleep before the night counts as over.
    static let sleepSettleSec = 15 * 60

    /// Whether the night has ended: the strap recorded at least `sleepSettleSec` of data after its last
    /// asleep minute. A night still going is scored as it stands, two hours in, with a duration and a Recovery
    /// that the finished night then contradicts; its last asleep minute is the newest data, so this is false
    /// until the wearer is up. Measured from the newest sample as well as the clock, as `activityHasSettled`
    /// is. Pure.
    static func nightIsOver(nightEnd: Int, newestSample: Int, now: Int) -> Bool {
        min(now, newestSample) - nightEnd >= sleepSettleSec
    }

    /// After a scoring pass: the first time today's night is scored AND over, say so once for the day. WHOOP
    /// tells you when your sleep has been analysed; Yoop did not, and then told you during the night.
    /// `nightEnd` is the end of today's last sleep session and `newestSample` the newest heart-rate time the
    /// strap has delivered; without either there is no evidence the night is over, so nothing is said.
    static func sleepScored(_ dailies: [DailyMetric], todayKey: String, nightEnd: Int?, newestSample: Int?,
                            now: Int = Int(Date().timeIntervalSince1970)) {
        guard isOn(sleepReadyKey),
              let night = dailies.first(where: { $0.day == todayKey }),
              let body = sleepReadyBody(night),
              let nightEnd, let newestSample,
              nightIsOver(nightEnd: nightEnd, newestSample: newestSample, now: now) else { return }
        let defaults = UserDefaults.standard
        guard isNewSleepDay(last: defaults.string(forKey: sleepReadyDayKey), todayKey: todayKey) else { return }
        defaults.set(todayKey, forKey: sleepReadyDayKey)
        add(UNNotificationRequest(
            identifier: sleepReadyId,
            content: content(String(localized: "Coach"), body, route: sleepReadRoute),
            trigger: nil))
    }

    // MARK: Activity added (Yoop detected and saved one)

    /// The route a tap on the sleep note carries: the Coach writes its read on the night.
    static let sleepReadRoute = "sleepRead"

    /// The route a tap on the activity note carries: the Coach checks in about that session.
    static func workoutRoute(sport: String, minutes: Int) -> String { "workout|\(minutes)|\(sport)" }

    /// Inverse of `workoutRoute`; nil for any other route. The sport is everything after the second bar.
    static func parseWorkoutRoute(_ route: String) -> (sport: String, minutes: Int)? {
        let parts = route.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "workout", let minutes = Int(parts[1]), !parts[2].isEmpty else { return nil }
        return (parts[2], minutes)
    }

    /// An activity found long after it ended (a restore, a late sync) is not news.
    static let activityNewsWindowSec = 3 * 3600

    static func isActivityNews(startSec: Int, endSec: Int, now: Int, posted: [Int]) -> Bool {
        now - endSec <= activityNewsWindowSec && !posted.contains(startSec)
    }

    /// After Yoop adds an activity by itself: say so once, with its type and length.
    static func activityAdded(sport: String, durationMin: Int, startSec: Int, endSec: Int) {
        guard isOn(activityKey) else { return }
        let defaults = UserDefaults.standard
        let posted = defaults.array(forKey: activityPostedKey) as? [Int] ?? []
        guard isActivityNews(startSec: startSec, endSec: endSec, now: Int(Date().timeIntervalSince1970),
                             posted: posted) else { return }
        defaults.set(Array((posted + [startSec]).suffix(50)), forKey: activityPostedKey)
        add(UNNotificationRequest(
            identifier: "yoop-activity-\(startSec)",
            content: content(String(localized: "Coach"),
                             String(localized: "\(sport), \(durationMin) min. Tap and tell me how it felt."),
                             route: workoutRoute(sport: sport, minutes: durationMin)),
            trigger: nil))
    }

    // MARK: Device Off-Body (strap off the wrist for 10 minutes)

    /// Wrist off: arm a notice for 10 minutes from now. Wrist on: cancel it.
    static func wristChanged(worn: Bool) {
        guard isOn(offBodyKey), !worn else { cancel([offBodyId]); return }
        add(UNNotificationRequest(
            identifier: offBodyId,
            content: content(String(localized: "Your strap is off-body"),
                             String(localized: "It's been off your wrist for 10 minutes. Put it back on so today's data stays complete."),
                             route: nil),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)))
    }

    // MARK: Travel Insights (time zone changed)

    /// On app activation: when the time zone differs from the last one seen, post a travel tip.
    static func checkTimeZone() {
        let current = TimeZone.current
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: timeZoneKey)
        defaults.set(current.identifier, forKey: timeZoneKey)
        guard isOn(travelKey), let last, last != current.identifier,
              let previous = TimeZone(identifier: last) else { return }
        let shift = (current.secondsFromGMT() - previous.secondsFromGMT()) / 3600
        guard shift != 0 else { return }
        let direction = shift > 0 ? String(localized: "ahead") : String(localized: "behind")
        let hours = abs(shift)
        add(UNNotificationRequest(
            identifier: travelId,
            content: content(String(localized: "Travel insight"),
                             String(localized: "You're \(hours) hours \(direction) of home. Get morning daylight, keep caffeine early, and aim to sleep at local bedtime tonight."),
                             route: "coach"),
            trigger: nil))
    }
}
