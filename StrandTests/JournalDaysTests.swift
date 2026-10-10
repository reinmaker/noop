import XCTest
import WhoopStore
@testable import Strand

/// Pins the journal's one day model (`JournalDays`): which stored row a journal day reads and writes,
/// which day the journal opens on, how imported WHOOP questions match the in-app catalog, and what
/// "Use previous answers" copies. Every journal surface goes through these, so they must not drift.
final class JournalDaysTests: XCTestCase {

    /// Noon on 2026-10-10 in the test machine's zone: the logical today for every case below.
    private let logicalToday: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 10; c.hour = 12
        return Calendar.current.date(from: c)!
    }()

    private func e(_ day: String, _ q: String, _ yes: Bool, _ value: Double? = nil) -> JournalEntry {
        JournalEntry(day: day, question: q, answeredYes: yes, notes: nil, numericValue: value)
    }

    private func key(_ offset: Int) -> String {
        JournalDays.storageKey(offset: offset, logicalToday: logicalToday)
    }

    // MARK: - Day model

    func testYesterdaysJournalIsStoredUnderThisMorning() {
        // "What happened yesterday, October 9?" asked on the morning of October 10 lives on the 10th,
        // the wake-day row a WHOOP import uses for the same entry.
        XCTAssertEqual(key(1), "2026-10-10")
        XCTAssertEqual(Repository.localDayKey(JournalDays.behaviourDay(offset: 1, logicalToday: logicalToday)),
                       "2026-10-09")
        // Logging ahead for today lands on tomorrow's morning; older days step back one row each.
        XCTAssertEqual(key(0), "2026-10-11")
        XCTAssertEqual(key(2), "2026-10-09")
        XCTAssertEqual(key(JournalDays.maxOffset), "2026-10-04")
    }

    func testStorageKeyIsTheMorningAfterTheBehaviourDay() {
        for offset in 0...JournalDays.maxOffset {
            let day = JournalDays.behaviourDay(offset: offset, logicalToday: logicalToday)
            let morningAfter = Calendar.current.date(byAdding: .day, value: 1, to: day)!
            XCTAssertEqual(key(offset), Repository.localDayKey(morningAfter), "offset \(offset)")
        }
    }

    // MARK: - Which day the journal opens on

    func testOpensOnYesterdayWhileItIsUnanswered() {
        XCTAssertEqual(JournalDays.dueOffset(answered: [], logicalToday: logicalToday), 1)
        // An older answered day does not move it off yesterday.
        XCTAssertEqual(JournalDays.dueOffset(answered: [key(3)], logicalToday: logicalToday), 1)
        // Neither does logging ahead for today.
        XCTAssertEqual(JournalDays.dueOffset(answered: [key(0)], logicalToday: logicalToday), 1)
    }

    func testOnceYesterdayIsDoneOpensOnTheNewestUnansweredStripDay() {
        XCTAssertEqual(JournalDays.dueOffset(answered: [key(1)], logicalToday: logicalToday), 2)
        XCTAssertEqual(JournalDays.dueOffset(answered: [key(1), key(2)], logicalToday: logicalToday), 3)
        XCTAssertEqual(JournalDays.dueOffset(answered: [key(1), key(2), key(4)], logicalToday: logicalToday), 3)
    }

    func testWholeStripAnsweredFallsBackToYesterday() {
        let all = Set((1..<JournalDays.stripCount).map(key))
        XCTAssertEqual(JournalDays.dueOffset(answered: all, logicalToday: logicalToday), 1)
        // A day past the strip is not a reason to open there.
        XCTAssertEqual(JournalDays.dueOffset(answered: all.union([key(0)]), logicalToday: logicalToday), 1)
    }

    func testCoachNotesDoNotMarkADayAnswered() {
        let entries = [e("2026-10-10", JournalDays.coachAdviceQuestion, true),
                       e("2026-10-09", "Did you drink any alcohol?", false)]
        XCTAssertEqual(JournalDays.answeredDays(entries), ["2026-10-09"])
    }

    // MARK: - Matching imported WHOOP questions

    func testQuestionKeyIgnoresCaseAndStrayWhitespace() {
        XCTAssertEqual(JournalDays.questionKey("DID YOU TAKE MAGNESIUM?\n"),
                       JournalDays.questionKey("Did you take magnesium?"))
        XCTAssertEqual(JournalDays.questionKey("  Did you  share your bed? "),
                       JournalDays.questionKey("did you share your bed?"))
        XCTAssertNotEqual(JournalDays.questionKey("Did you use a sauna?"),
                          JournalDays.questionKey("Did you read before bed?"))
    }

    func testImportedPicksAreReadForThatDayOnly() {
        let imported = [e("2026-10-10", "DID YOU DRINK ANY ALCOHOL?\n", true),
                        e("2026-10-10", "Did you feel stressed?", false),
                        e("2026-10-09", "Did you use a sauna?", true)]
        let picks = JournalDays.answersByQuestionKey(imported, day: "2026-10-10")
        XCTAssertEqual(picks[JournalDays.questionKey("Did you drink any alcohol?")], true)
        XCTAssertEqual(picks[JournalDays.questionKey("Did you feel stressed?")], false)
        XCTAssertNil(picks[JournalDays.questionKey("Did you use a sauna?")])
    }

    // MARK: - Use previous answers

    func testPreviousAnswersAreTheMostRecentEarlierJournal() {
        let entries = [e("2026-10-06", "Did you use a sauna?", true),
                       e("2026-10-08", "Did you drink any alcohol?", true),
                       e("2026-10-08", "Did you feel stressed?", false),
                       e("2026-10-09", JournalDays.coachAdviceQuestion, true),
                       e("2026-10-10", "Did you read before bed?", true),
                       e("2026-10-11", "Did you nap?", true)]
        let previous = JournalDays.previousAnswers(entries, before: "2026-10-10")
        // The 9th only holds a Coach note, so the 8th is the journal to copy; the shown day and later
        // days are never a source.
        XCTAssertEqual(Set(previous.map(\.day)), ["2026-10-08"])
        XCTAssertEqual(previous.count, 2)
        XCTAssertTrue(JournalDays.previousAnswers(entries, before: "2026-10-06").isEmpty)
    }

    func testPrefillCopiesUnderTheCatalogsOwnQuestion() {
        let previous = [e("2026-10-09", "DID YOU DRINK ANY ALCOHOL?\n", true),
                        e("2026-10-09", "Did you feel stressed?", false)]
        let items: [(canonical: String, isNumeric: Bool)] = [
            (canonical: "Did you drink any alcohol?", isNumeric: false),
            (canonical: "Did you feel stressed?", isNumeric: false),
            (canonical: "Did you use a sauna?", isNumeric: false),
        ]
        let plan = JournalDays.prefillPlan(items: items, previous: previous)
        XCTAssertEqual(plan, [
            JournalDays.Prefill(question: "Did you drink any alcohol?", answeredYes: true, value: nil),
            JournalDays.Prefill(question: "Did you feel stressed?", answeredYes: false, value: nil),
        ])
    }

    func testPrefillCopiesNumbersOnlyIntoNumericItems() {
        let previous = [e("2026-10-09", "Caffeine mg", true, 200),
                        e("2026-10-09", "Alcohol units", true),
                        e("2026-10-09", "Creatine grams", true, 5)]
        let items: [(canonical: String, isNumeric: Bool)] = [
            (canonical: "Caffeine mg", isNumeric: true),
            (canonical: "Alcohol units", isNumeric: true),     // yes/no source, no number to copy
            (canonical: "Creatine grams", isNumeric: false),   // now a yes/no item: copies the yes
        ]
        let plan = JournalDays.prefillPlan(items: items, previous: previous)
        XCTAssertEqual(plan, [
            JournalDays.Prefill(question: "Caffeine mg", answeredYes: true, value: 200),
            JournalDays.Prefill(question: "Creatine grams", answeredYes: true, value: nil),
        ])
    }

    func testPrefillPrefersANumberWhenTheSameQuestionHasTwoRows() {
        // An imported yes/no and an in-app number for one question on the same earlier day.
        let previous = [e("2026-10-09", "caffeine mg ", true),
                        e("2026-10-09", "Caffeine mg", true, 150)]
        let plan = JournalDays.prefillPlan(items: [(canonical: "Caffeine mg", isNumeric: true)],
                                           previous: previous)
        XCTAssertEqual(plan, [JournalDays.Prefill(question: "Caffeine mg", answeredYes: true, value: 150)])
    }

    func testNoEarlierJournalMeansNothingToCopy() {
        XCTAssertTrue(JournalDays.prefillPlan(items: [(canonical: "Did you nap?", isNumeric: false)],
                                              previous: []).isEmpty)
    }
}
