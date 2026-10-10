import Foundation
import WhoopStore

/// The user's own cause-and-effect numbers, worked out on the phone, so the Coach can back what a number
/// means and what to do about it with the user's history instead of doing arithmetic over the daily
/// table. On the user's WHOOP export: Recovery averaged 56% the morning after a day of Strain 14 or more
/// (24 days) against 71% after Strain under 10 (55 days), and 67% after 7.5 h of sleep or more against
/// 62% under 6.5 h.
enum CoachPatterns {
    /// Days each side of a comparison needs before it is stated.
    static let minDays = 3
    /// How far back the patterns look, in calendar days ending on the newest row.
    static let lookbackDays = 120

    /// The block for the Coach's context, or nil when no comparison has enough days on both sides.
    static func block(days: [DailyMetric]) -> String? {
        let sorted = days.sorted { $0.day < $1.day }
        let recent: [DailyMetric]
        if let newest = sorted.last?.day, let start = dayKey(newest, minusDays: lookbackDays - 1) {
            recent = sorted.filter { $0.day >= start }
        } else {
            recent = Array(sorted.suffix(lookbackDays))
        }
        var lines: [String] = []

        // A day's row carries the night before it, so its sleep and its Recovery belong together. A night
        // stored as 0 minutes is a night with nothing recorded, not a short one.
        let slept = recent.compactMap { d -> (hours: Double, recovery: Double?, hrv: Double?)? in
            guard let minutes = d.totalSleepMin, minutes > 0 else { return nil }
            return (hours: minutes / 60, recovery: d.recovery, hrv: d.avgHrv)
        }
        let long = slept.filter { $0.hours >= 7.5 }, short = slept.filter { $0.hours < 6.5 }
        if let line = compare("Recovery after 7.5 h of sleep or more", long.compactMap(\.recovery),
                              "after under 6.5 h", short.compactMap(\.recovery), unit: "%") {
            lines.append(line)
        }
        if let line = compare("HRV after 7.5 h of sleep or more", long.compactMap(\.hrv),
                              "after under 6.5 h", short.compactMap(\.hrv), unit: " ms") {
            lines.append(line)
        }

        // A day's Strain against the next morning's Recovery, for calendar-consecutive days only. A day the
        // strap was not worn reads as almost no Strain, so it is left out rather than counted as easy.
        var afterHard: [Double] = [], afterEasy: [Double] = []
        for (today, next) in zip(recent, recent.dropFirst()) where isNextDay(today.day, next.day) {
            guard let stored = today.strain, let recovery = next.recovery else { continue }
            let strain = AICoachEngine.strain21(stored)
            if strain >= 14 {
                afterHard.append(recovery)
            } else if strain < 10, isWornDay(today) {
                afterEasy.append(recovery)
            }
        }
        if let line = compare("Recovery the morning after a day of Strain 14 or more", afterHard,
                              "after Strain under 10", afterEasy, unit: "%") {
            lines.append(line)
        }

        guard !lines.isEmpty else { return nil }
        let span = calendarDays(from: recent.first?.day, to: recent.last?.day) ?? recent.count
        return "PERSONAL PATTERNS (worked out from the user's own last \(span) calendar days, \(recent.count) "
            + "of them with data; association, not proof). Use these to back what a number means and what to do:\n"
            + lines.map { "  \u{2022} " + $0 }.joined(separator: "\n")
    }

    /// Whether the strap was worn that day: Strain of at least 1 on the 0-21 scale and a night of sleep.
    /// A day off the wrist stores no Strain or almost none, and would otherwise pass for an easy day.
    static func isWornDay(_ d: DailyMetric) -> Bool {
        guard let stored = d.strain, AICoachEngine.strain21(stored) >= 1 else { return false }
        guard let sleep = d.totalSleepMin, sleep > 0 else { return false }
        return true
    }

    /// Calendar days from `first` to `last` inclusive (both "yyyy-MM-dd"), or nil when either is missing
    /// or does not parse. Rows skip the days with no data, so a count of rows is not a count of days.
    static func calendarDays(from first: String?, to last: String?) -> Int? {
        guard let first, let last, let a = parser.date(from: first), let b = parser.date(from: last), b >= a else {
            return nil
        }
        return Int((b.timeIntervalSince(a) / 86_400).rounded()) + 1
    }

    /// The "yyyy-MM-dd" key `days` calendar days before `key`, or nil when `key` does not parse.
    static func dayKey(_ key: String, minusDays days: Int) -> String? {
        guard let date = parser.date(from: key) else { return nil }
        return parser.string(from: date.addingTimeInterval(-Double(days) * 86_400))
    }

    /// "Recovery after 7.5 h of sleep or more: 67% on average (51 days), against 62% after under 6.5 h (25 days)."
    static func compare(_ label: String, _ a: [Double], _ otherLabel: String, _ b: [Double], unit: String) -> String? {
        guard a.count >= minDays, b.count >= minDays else { return nil }
        let meanA = Int((a.reduce(0, +) / Double(a.count)).rounded())
        let meanB = Int((b.reduce(0, +) / Double(b.count)).rounded())
        return "\(label): \(meanA)\(unit) on average (\(a.count) days), against \(meanB)\(unit) \(otherLabel) "
            + "(\(b.count) days)."
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Whether `next` is the calendar day after `day` (both "yyyy-MM-dd").
    static func isNextDay(_ day: String, _ next: String) -> Bool {
        guard let a = parser.date(from: day), let b = parser.date(from: next) else { return false }
        return b.timeIntervalSince(a) == 86_400
    }
}
