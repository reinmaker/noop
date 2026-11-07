import XCTest
import Foundation
@testable import Strand

/// Which journal questions are asked (`JournalQuestionPicker`). The counts are the wearer's own, over the 60 days to
/// 6 Oct 2026 in their WHOOP journal: "Ate food close to bedtime?" 25 Yes of 52, "Consumed protein?" 16 of 52,
/// "Have any alcoholic drinks?" 10 of 52, "Played video games?" 11 of 51, and the questions that never change,
/// "Consumed caffeine?" 51 Yes of 51, "Used marijuana?" 48 of 52, "Went to a restaurant?" 0 of 51, "Used tobacco in
/// any form?" 0 of 50 and "Read in bed?" 0 of 50.
final class JournalQuestionPickerTests: XCTestCase {

    private let lateMeal = "Ate food close to bedtime?"
    private let protein = "Consumed protein?"
    private let alcohol = "Have any alcoholic drinks?"
    private let games = "Played video games?"
    private let caffeine = "Consumed caffeine?"
    private let marijuana = "Used marijuana?"
    private let restaurant = "Went to a restaurant?"
    private let tobacco = "Used tobacco in any form?"
    private let readInBed = "Read in bed?"

    private func stats(_ yes: Int, _ no: Int, ago: Int = 1) -> JournalQuestionPicker.Stats {
        .init(yes: yes, no: no, daysSinceAnswered: ago)
    }

    private var wearer: [String: JournalQuestionPicker.Stats] {
        [lateMeal: stats(25, 27), protein: stats(16, 36), alcohol: stats(10, 42), games: stats(11, 40),
         caffeine: stats(51, 0), marijuana: stats(48, 4), restaurant: stats(0, 51), tobacco: stats(0, 50),
         readInBed: stats(0, 50)]
            .reduce(into: [:]) { $0[JournalCatalogStore.norm($1.key)] = $1.value }
    }

    private var everything: [String] {
        [lateMeal, protein, alcohol, games, caffeine, marijuana, restaurant, tobacco, readInBed]
            + JournalCatalogStore.starterQuestions
    }

    private func asked(_ context: JournalQuestionPicker.DayContext = .init(),
                       pinned: Set<String> = []) -> [JournalQuestionPicker.Pick] {
        JournalQuestionPicker.pick(candidates: everything, stats: wearer, context: context, pinned: pinned)
    }

    // MARK: - An ordinary morning

    func testAnOrdinaryMorningAsksOnlyTheQuestionsThatChange() {
        let picks = asked().map(\.question)
        XCTAssertEqual(Set(picks), [lateMeal, protein, alcohol, games])
    }

    func testQuestionsWhoseAnswerNeverChangesAreNotAsked() {
        let picks = asked().map(\.question)
        for settled in [caffeine, marijuana, restaurant, tobacco, readInBed] {
            XCTAssertFalse(picks.contains(settled), settled)
        }
    }

    func testStarterQuestionsNobodyAnsweredWaitForTheDataToPointAtThem() {
        let picks = asked().map(\.question)
        for starter in JournalCatalogStore.starterQuestions { XCTAssertFalse(picks.contains(starter), starter) }
    }

    func testTheBestSplitComesFirst() {
        // 25 of 52 is the closest to even, 10 of 52 the furthest of the four.
        let picks = asked().map(\.question)
        XCTAssertEqual(picks.first, lateMeal)
        XCTAssertEqual(picks.last, alcohol)
    }

    func testTheSameQuestionFromTheExportAndTheStarterListIsAskedOnce() {
        let picks = asked(.init(lowRecovery: true)).map(\.question)
        XCTAssertEqual(picks.filter { JournalQuestionPicker.topic($0) == "alcohol" }.count, 1)
        XCTAssertTrue(picks.contains(alcohol), "the one the wearer has answers for")
    }

    // MARK: - What the morning says

    func testALowRecoveryAddsTheCausesItPointsAt() {
        let picks = asked(.init(lowRecovery: true))
        XCTAssertTrue(picks.contains { $0.question == "Did you have caffeine late in the day?" && $0.reason == .cue })
        XCTAssertTrue(picks.contains { $0.question == "Did you feel stressed?" && $0.reason == .cue })
        XCTAssertLessThanOrEqual(picks.count, JournalQuestionPicker.maxAsked)
    }

    func testIllnessSignsAskHowTheWearerFeelsFirstOfTheCues() {
        let picks = asked(.init(lowRecovery: true, illnessSigns: true))
        let cued = picks.filter { $0.reason == .cue }.map(\.question)
        XCTAssertEqual(cued.count, JournalQuestionPicker.maxCued)
        XCTAssertTrue(cued.contains("Did you feel sick or ill?"))
        XCTAssertTrue(cued.contains("Did you have caffeine late in the day?"), "the strongest cue after it")
    }

    func testAPoorNightAsksAboutScreensAndLateCaffeine() {
        let cued = asked(.init(poorSleep: true)).filter { $0.reason == .cue }.map(\.question)
        XCTAssertEqual(Set(cued), ["Did you have caffeine late in the day?", "Did you view a screen in bed?"])
    }

    func testAHardDayStartsNoQuestionOfItsOwn() {
        XCTAssertEqual(Set(asked(.init(hardDay: true)).map(\.question)), Set(asked().map(\.question)))
    }

    func testNeverMoreThanTheCapIsAsked() {
        let all = JournalQuestionPicker.DayContext(lowRecovery: true, poorSleep: true, hardDay: true, illnessSigns: true)
        XCTAssertLessThanOrEqual(asked(all).count, JournalQuestionPicker.maxAsked)
    }

    // MARK: - Pinned, check-ins and a new wearer

    func testAPinnedQuestionIsAskedWhateverItsCounts() {
        let picks = asked(pinned: [tobacco])
        XCTAssertEqual(picks.first?.question, tobacco)
        XCTAssertEqual(picks.first?.reason, .pinned)
    }

    func testAQuestionThatWentQuietIsAskedAgainAfterTwoWeeks() {
        var counts = wearer
        counts[JournalCatalogStore.norm(marijuana)] = stats(48, 4, ago: 20)
        let picks = JournalQuestionPicker.pick(candidates: everything, stats: counts, context: .init())
        XCTAssertEqual(picks.last, .init(question: marijuana, reason: .checkIn))
        XCTAssertEqual(picks.filter { $0.reason == .checkIn }.count, 1)
    }

    func testAQuietQuestionAnsweredRecentlyIsLeftAlone() {
        XCTAssertFalse(asked().contains { $0.reason == .checkIn })
    }

    func testANewWearerIsAskedTheFirstFewQuestionsOfTheList() {
        let picks = JournalQuestionPicker.pick(candidates: JournalCatalogStore.starterQuestions, stats: [:],
                                               context: .init())
        XCTAssertEqual(picks.map(\.question), Array(JournalCatalogStore.starterQuestions.prefix(4)))
        XCTAssertTrue(picks.allSatisfy { $0.reason == .starter })
    }

    func testAWearerWithHistoryIsNotAskedTheListToo() {
        XCTAssertFalse(asked().contains { $0.reason == .starter })
    }

    // MARK: - Counts and information

    func testInformationIsHighestAtAnEvenSplitAndLowForAnAnswerThatNeverChanges() throws {
        let even = try XCTUnwrap(JournalQuestionPicker.information(stats(25, 25)))
        let never = try XCTUnwrap(JournalQuestionPicker.information(stats(0, 50)))
        XCTAssertEqual(even, 1.0, accuracy: 0.01)
        XCTAssertLessThan(never, JournalQuestionPicker.minInformation)
        XCTAssertNil(JournalQuestionPicker.information(stats(2, 2)), "too few answers to say")
    }

    func testStatsCountOnlyTheLastSixtyDaysBeforeToday() {
        let s = JournalQuestionPicker.stats(yesDays: ["2026-10-05", "2026-10-04", "2026-08-01"],
                                            noDays: ["2026-10-03", "2026-10-07"], today: "2026-10-06")
        XCTAssertEqual(s.yes, 2, "2026-08-01 is 66 days back")
        XCTAssertEqual(s.no, 1, "2026-10-07 is after today")
        XCTAssertEqual(s.daysSinceAnswered, 1)
    }

    func testStatsOfAQuestionNeverAnsweredHaveNoLastDay() {
        let s = JournalQuestionPicker.stats(yesDays: [], noDays: [], today: "2026-10-06")
        XCTAssertEqual(s, .init())
        XCTAssertNil(s.daysSinceAnswered)
    }

    func testDayNumbersCountDaysAcrossMonthsYearsAndLeapDays() {
        XCTAssertEqual(JournalQuestionPicker.dayNumber("1970-01-01"), 0)
        XCTAssertEqual(JournalQuestionPicker.dayNumber("2026-10-06"), 20_732)
        XCTAssertEqual(JournalQuestionPicker.dayNumber("2024-03-01")! - JournalQuestionPicker.dayNumber("2024-02-28")!, 2)
        XCTAssertEqual(JournalQuestionPicker.dayNumber("2026-01-01")! - JournalQuestionPicker.dayNumber("2025-01-01")!, 365)
        XCTAssertNil(JournalQuestionPicker.dayNumber("2026-13-01"))
        XCTAssertNil(JournalQuestionPicker.dayNumber("not a day"))
    }

    // MARK: - Why a question is asked

    func testACueNamesWhatPointsAtIt() {
        let both = JournalQuestionPicker.DayContext(lowRecovery: true, poorSleep: true, illnessSigns: true)
        XCTAssertEqual(JournalQuestionPicker.cueSource("Did you feel sick or ill?", both), .illness)
        XCTAssertEqual(JournalQuestionPicker.cueSource("Did you have caffeine late in the day?", both), .recovery,
                       "recovery and sleep tie at 0.7; recovery is listed first")
        XCTAssertEqual(JournalQuestionPicker.cueSource("Did you view a screen in bed?", both), .sleep)
        XCTAssertNil(JournalQuestionPicker.cueSource("Did you use a sauna?", both))
        XCTAssertNil(JournalQuestionPicker.cueSource("Did you drink any alcohol?", .init()))
    }

    // MARK: - The day's context

    func testContextReadsLowRecoveryFromRedOrFromTwentyUnderUsual() {
        func low(_ r: Double?, usual: Double?) -> Bool {
            JournalQuestionPicker.context(recovery: r, usualRecovery: usual, sleepMin: nil, efficiency: nil,
                                          strain21: nil, flaggedVitals: 0).lowRecovery
        }
        XCTAssertTrue(low(19, usual: 67), "the wearer's 3 Nov: 19 %")
        XCTAssertTrue(low(30, usual: nil))
        XCTAssertTrue(low(55, usual: 80))
        XCTAssertFalse(low(67, usual: 67))
        XCTAssertFalse(low(nil, usual: 67))
    }

    func testContextReadsAPoorNightFromShortSleepOrLowEfficiency() {
        func poor(_ minutes: Double?, _ eff: Double?) -> Bool {
            JournalQuestionPicker.context(recovery: nil, usualRecovery: nil, sleepMin: minutes, efficiency: eff,
                                          strain21: nil, flaggedVitals: 0).poorSleep
        }
        XCTAssertTrue(poor(179, 0.95), "3 Nov: 2 h 59")
        XCTAssertTrue(poor(450, 0.7))
        XCTAssertFalse(poor(470, 0.94))
        XCTAssertFalse(poor(nil, nil))
    }

    func testContextReadsAHardDayAndIllnessSigns() {
        let c = JournalQuestionPicker.context(recovery: nil, usualRecovery: nil, sleepMin: nil, efficiency: nil,
                                              strain21: 14, flaggedVitals: 2)
        XCTAssertTrue(c.hardDay)
        XCTAssertTrue(c.illnessSigns)
        let calm = JournalQuestionPicker.context(recovery: nil, usualRecovery: nil, sleepMin: nil, efficiency: nil,
                                                 strain21: 13.9, flaggedVitals: 1)
        XCTAssertTrue(calm.isEmpty)
    }
}
