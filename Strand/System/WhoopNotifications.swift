import Foundation
import UserNotifications

/// WHOOP-style notifications for Yoop (WHOOP's App Settings > Notifications, plus its evening Day In
/// Review): Day In Review, Daily Stress Summary, Conversational Check-Ins, Device Off-Body and Travel
/// Insights. All local, all on by default, each with its own switch (`WhoopNotificationsView`). The
/// morning Daily Outlook is `CoachBriefScheduler`.
///
/// A tap routes through `NotificationPresenter.onYoopRoute` with the `routeKey` in `userInfo`.
enum WhoopNotifications {
    static let dayReviewKey = "whoopNotif.dayReview"
    static let stressSummaryKey = "whoopNotif.stressSummary"
    static let checkInsKey = "whoopNotif.checkIns"
    static let offBodyKey = "whoopNotif.offBody"
    static let travelKey = "whoopNotif.travel"

    /// `userInfo` key naming where a tap should go: "dayReview", "coach" or "stress".
    static let routeKey = "yoop.route"

    private static let dayReviewId = "yoop-day-review"
    private static let stressSummaryId = "yoop-stress-summary"
    private static let offBodyId = "yoop-off-body"
    private static let travelId = "yoop-travel"
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

    // MARK: Day In Review (every evening at 8:30pm)

    /// Idempotent: re-adding the same id replaces it. Call on launch and when the switch changes.
    static func scheduleDayReview() {
        guard isOn(dayReviewKey) else { cancel([dayReviewId]); return }
        var when = DateComponents()
        when.hour = 20
        when.minute = 30
        add(UNNotificationRequest(
            identifier: dayReviewId,
            content: content(String(localized: "Your Day In Review is ready"),
                             String(localized: "See how today went and what tonight's sleep needs."),
                             route: "dayReview"),
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true)))
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
