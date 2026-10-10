import Foundation
import WhoopStore

/// The journal's one day model (Yoop, WHOOP parity). Every journal surface (the journal screen, the
/// Home journal strip, the Today journal widget and the morning prompt) names a journal by the day the
/// behaviours HAPPENED on, the way WHOOP asks "What happened yesterday?", and maps that day to its
/// stored row through this one type, so no two surfaces can read or write different rows for one day.
///
/// The stored key is the morning AFTER the behaviour day. A WHOOP import keys each journal entry to the
/// wake day of its cycle (#136) and Insights compares a key against that morning's Charge, so "what
/// happened on Oct 9" lives under 2026-10-10, the same row a WHOOP export lands on. Offsets count
/// behaviour days back from the logical (04:00) today: 0 = today (logging ahead), 1 = yesterday.
/// Pure: callers pass the logical today, so one clock feeds every surface and tests can pin it.
enum JournalDays {
    /// The oldest behaviour day the journal picker reaches: one week of backfill (#656).
    static let maxOffset = 7
    /// Behaviour days a journal strip shows, today included (the Home card and the Today widget).
    static let stripCount = 7
    /// The question a saved Coach reply is stored under (CoachView). It is a note, not an answer, so it
    /// never marks a day as journalled and never counts as an answer for "Use previous answers".
    static let coachAdviceQuestion = "Coach advice"

    /// The calendar date of behaviour day `offset`.
    static func behaviourDay(offset: Int, logicalToday: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: logicalToday) ?? logicalToday
    }

    /// The stored row key for behaviour day `offset`: the local day key of the morning after it.
    static func storageKey(offset: Int, logicalToday: Date, calendar: Calendar = .current) -> String {
        Repository.localDayKey(calendar.date(byAdding: .day, value: 1 - offset, to: logicalToday) ?? logicalToday)
    }

    /// Stored day keys that carry at least one answer, imported or in-app. Coach notes do not count.
    static func answeredDays(_ entries: [JournalEntry]) -> Set<String> {
        Set(entries.filter { $0.question != coachAdviceQuestion }.map(\.day))
    }

    /// The day the journal opens on, the one WHOOP would ask about: yesterday while it has no answers;
    /// once yesterday is done, the newest unanswered older day on the strip; once the whole strip is
    /// done, yesterday again.
    static func dueOffset(answered: Set<String>, logicalToday: Date, calendar: Calendar = .current) -> Int {
        for offset in 1..<stripCount
        where !answered.contains(storageKey(offset: offset, logicalToday: logicalToday, calendar: calendar)) {
            return offset
        }
        return 1
    }

    /// Match key for a question: trimmed, whitespace-collapsed and case-folded (`JournalCatalogStore.norm`),
    /// so an imported "DID YOU TAKE MAGNESIUM?\n" and the in-app "Did you take magnesium?" are one question.
    static func questionKey(_ question: String) -> String { JournalCatalogStore.norm(question) }

    /// One stored day's yes/no answers keyed by `questionKey`, so imported WHOOP picks can be read
    /// against the in-app catalog whatever their casing or stray whitespace. Coach notes are left out.
    static func answersByQuestionKey(_ entries: [JournalEntry], day: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for e in entries where e.day == day && e.question != coachAdviceQuestion {
            out[questionKey(e.question)] = e.answeredYes
        }
        return out
    }

    /// The rows of the most recent stored day strictly before `day` that carries any answer, imported or
    /// in-app: what "Use previous answers" copies forward. Empty when there is no earlier journal.
    static func previousAnswers(_ entries: [JournalEntry], before day: String) -> [JournalEntry] {
        let earlier = entries.filter { $0.day < day && $0.question != coachAdviceQuestion }
        guard let latest = earlier.map(\.day).max() else { return [] }
        return earlier.filter { $0.day == latest }
    }

    /// One answer "Use previous answers" writes for the shown day.
    struct Prefill: Equatable {
        let question: String
        let answeredYes: Bool
        /// The copied number for a numeric item; nil for a yes/no answer.
        let value: Double?
    }

    /// What to copy from `previous` onto an empty day: one answer per catalog item the earlier journal
    /// answered, written under the item's own canonical question so the copy reads and clears exactly
    /// like a tap. A numeric item copies only a number (an imported WHOOP row carries none); a yes/no
    /// item copies the yes/no. Items the earlier journal did not answer stay unanswered.
    static func prefillPlan(items: [(canonical: String, isNumeric: Bool)],
                            previous: [JournalEntry]) -> [Prefill] {
        var rowsByKey: [String: [JournalEntry]] = [:]
        for e in previous { rowsByKey[questionKey(e.question), default: []].append(e) }
        var out: [Prefill] = []
        for item in items {
            guard let rows = rowsByKey[questionKey(item.canonical)], let last = rows.last else { continue }
            if item.isNumeric {
                guard let value = rows.compactMap(\.numericValue).last else { continue }
                out.append(Prefill(question: item.canonical, answeredYes: true, value: value))
            } else {
                out.append(Prefill(question: item.canonical, answeredYes: last.answeredYes, value: nil))
            }
        }
        return out
    }
}
