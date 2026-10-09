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
    /// How far back the patterns look.
    static let lookbackDays = 120

    /// The block for the Coach's context, or nil when no comparison has enough days on both sides.
    static func block(days: [DailyMetric]) -> String? {
        let recent = Array(days.sorted { $0.day < $1.day }.suffix(lookbackDays))
        var lines: [String] = []

        // A day's row carries the night before it, so its sleep and its Recovery belong together.
        let slept = recent.compactMap { d -> (hours: Double, recovery: Double?, hrv: Double?)? in
            d.totalSleepMin.map { (hours: $0 / 60, recovery: d.recovery, hrv: d.avgHrv) }
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

        // A day's Strain against the next morning's Recovery, for calendar-consecutive days only.
        var afterHard: [Double] = [], afterEasy: [Double] = []
        for (today, next) in zip(recent, recent.dropFirst()) where isNextDay(today.day, next.day) {
            guard let stored = today.strain, let recovery = next.recovery else { continue }
            let strain = AICoachEngine.strain21(stored)
            if strain >= 14 { afterHard.append(recovery) } else if strain < 10 { afterEasy.append(recovery) }
        }
        if let line = compare("Recovery the morning after a day of Strain 14 or more", afterHard,
                              "after Strain under 10", afterEasy, unit: "%") {
            lines.append(line)
        }

        guard !lines.isEmpty else { return nil }
        return "PERSONAL PATTERNS (worked out from the user's own last \(recent.count) days; association, "
            + "not proof). Use these to back what a number means and what to do:\n"
            + lines.map { "  \u{2022} " + $0 }.joined(separator: "\n")
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
