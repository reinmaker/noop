import XCTest
import Foundation
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The figures behind the pages My Dashboard's rows open: one definition of the step count, the 30-day
/// normal, the week and the best day, shared by the rows and the pages so they cannot disagree.
final class WhoopDayFiguresTests: XCTestCase {
    private func day(_ key: String, steps: Int? = nil, kcal: Double? = nil, spo2: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                    exerciseCount: nil, spo2Pct: spo2, steps: steps, activeKcalEst: kcal)
    }

    // MARK: the step count

    func testStepsTakeTheStrapThenThePhoneThenTheEstimate() {
        XCTAssertEqual(WhoopDayFigures.steps(strap: 10_767, phone: 12_000, estimate: 9_000)?.value, 10_767)
        XCTAssertEqual(WhoopDayFigures.steps(strap: 10_767, phone: 12_000, estimate: 9_000)?.source, .strap)
        XCTAssertEqual(WhoopDayFigures.steps(strap: nil, phone: 12_000, estimate: 9_000)?.source, .phone)
        XCTAssertEqual(WhoopDayFigures.steps(strap: nil, phone: nil, estimate: 9_000.5)?.value, 9_000.5)
        XCTAssertNil(WhoopDayFigures.steps(strap: nil, phone: nil, estimate: nil))
    }

    func testTheSourceTheRowHandsOnMatchesTheNumberItStates() {
        XCTAssertEqual(WhoopDayFigures.stepSource(strap: 10, phone: 20, hasValue: true), .strap)
        XCTAssertEqual(WhoopDayFigures.stepSource(strap: nil, phone: 20, hasValue: true), .phone)
        XCTAssertEqual(WhoopDayFigures.stepSource(strap: nil, phone: nil, hasValue: true), .estimate)
        XCTAssertNil(WhoopDayFigures.stepSource(strap: nil, phone: nil, hasValue: false))
        // The same order as the resolver, for every combination.
        for strap in [nil, 10] as [Int?] {
            for phone in [nil, 20] as [Int?] {
                for estimate in [nil, 5.0] as [Double?] {
                    let resolved = WhoopDayFigures.steps(strap: strap, phone: phone, estimate: estimate)
                    XCTAssertEqual(WhoopDayFigures.stepSource(strap: strap, phone: phone.map(Double.init),
                                                              hasValue: resolved != nil), resolved?.source)
                }
            }
        }
    }

    // MARK: the normal

    func testNormalIsTheMeanOfThePriorThirtyDaysWithoutTheShownDay() {
        let days = (1...35).map { day("d\(String(format: "%02d", $0))", steps: $0 * 1_000) }
        let normal = WhoopDayFigures.normal(days: days, excluding: "d35", floor: 0) { $0.steps.map(Double.init) }
        // The 30 days before d35 are d05...d34: the mean of 5 000...34 000.
        XCTAssertEqual(normal, 19_500)
    }

    func testNormalSkipsBarelyRecordedDaysAndNeedsThree() {
        let days = [day("a", steps: 200), day("b", steps: 9_000), day("c", steps: 11_000), day("d", steps: 400),
                    day("e", steps: 10_000), day("today", steps: 5_000)]
        XCTAssertEqual(WhoopDayFigures.normal(days: days, excluding: "today", floor: 1_000) {
            $0.steps.map(Double.init)
        }, 10_000)
        XCTAssertNil(WhoopDayFigures.normal(days: Array(days.prefix(3)), excluding: nil, floor: 1_000) {
            $0.steps.map(Double.init)
        })
    }

    func testTheNormalSpansTheRangeAPageStatesIt() {
        let days = [day("a", spo2: 94), day("b", spo2: 97), day("c", spo2: 96), day("d", spo2: 98),
                    day("today", spo2: 99)]
        let prior = WhoopDayFigures.normalValues(days: days, excluding: "today") { $0.spo2Pct }
        XCTAssertEqual(prior, [94, 97, 96, 98])
        XCTAssertEqual(WhoopDayFigures.normal(days: days, excluding: "today") { $0.spo2Pct }, 96.25)
    }

    // MARK: arrows and sentences

    func testDirectionIsTheRuleTheRowsDrawTheirArrowsBy() {
        XCTAssertEqual(WhoopDayFigures.direction(value: 10_001, normal: 10_000), 1)
        XCTAssertEqual(WhoopDayFigures.direction(value: 9_999, normal: 10_000), -1)
        XCTAssertEqual(WhoopDayFigures.direction(value: 10_000, normal: 10_000), 0)
        XCTAssertEqual(WhoopDayFigures.direction(value: 10_000, normal: 10_000.00005), 0)
        XCTAssertEqual(WhoopDayFigures.direction(value: nil, normal: 10), 0)
        XCTAssertEqual(WhoopDayFigures.direction(value: 10, normal: nil), 0)
    }

    func testStandingCallsWithinTwoPercentLevel() {
        XCTAssertEqual(WhoopDayFigures.standing(value: 10_100, normal: 10_000), .level)
        XCTAssertEqual(WhoopDayFigures.standing(value: 9_800, normal: 10_000), .level)
        XCTAssertEqual(WhoopDayFigures.standing(value: 12_000, normal: 10_000), .above(2_000))
        XCTAssertEqual(WhoopDayFigures.standing(value: 7_500, normal: 10_000), .below(2_500))
        XCTAssertEqual(WhoopDayFigures.standing(value: 5, normal: nil), .unknown)
        XCTAssertEqual(WhoopDayFigures.standing(value: 5, normal: 0), .unknown)
    }

    // MARK: the week and the best day

    func testRecentEndsOnTheShownDayWithItsOwnNumber() {
        let days = [day("2026-10-08", steps: 4_462), day("2026-10-09", steps: 18_967), day("2026-10-10", steps: 24_062),
                    day("2026-10-11", steps: 10_000)]
        // The row states 10 767 for the 11th (a later read of the same day); the page uses the row's number.
        let week = WhoopDayFigures.recent(days: days, endingOn: "2026-10-11", count: 7, shown: 10_767) {
            $0.steps.map(Double.init)
        }
        XCTAssertEqual(week.map(\.day), ["2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11"])
        XCTAssertEqual(week.last?.value, 10_767)
        XCTAssertEqual(week.first?.value, 4_462)
    }

    func testRecentLeavesAMissingDayOutAndNeverReachesBackFurther() {
        let days = [day("2026-10-01", steps: 1), day("2026-10-05", steps: 5), day("2026-10-07", steps: 7)]
        let week = WhoopDayFigures.recent(days: days, endingOn: "2026-10-07", count: 7, shown: nil) {
            $0.steps.map(Double.init)
        }
        // Seven calendar days ending the 7th start on the 1st: the 1st is in, the days between are not.
        XCTAssertEqual(week.map(\.day), ["2026-10-01", "2026-10-05", "2026-10-07"])
        let short = WhoopDayFigures.recent(days: days, endingOn: "2026-10-07", count: 3, shown: nil) {
            $0.steps.map(Double.init)
        }
        XCTAssertEqual(short.map(\.day), ["2026-10-05", "2026-10-07"])
    }

    func testRecentCountsCalendarDaysAcrossAMonthEnd() {
        XCTAssertEqual(WhoopDayFigures.dayKeys(endingOn: "2026-03-02", count: 4),
                       ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"])
    }

    func testBestIsTheHighestDayAndTheEarliestOnATie() {
        let recent: [(day: String, value: Double)] = [("a", 5), ("b", 9), ("c", 9), ("d", 2)]
        XCTAssertEqual(WhoopDayFigures.best(recent)?.day, "b")
        XCTAssertEqual(WhoopDayFigures.best(recent)?.value, 9)
        XCTAssertNil(WhoopDayFigures.best([]))
    }

    // MARK: windows and nights

    func testAClosedDaysWindowRunsFromItsOnsetToTheNextOnset() {
        // 11 Oct onset 01:55:32 and 12 Oct onset 00:40:53 on the user's strap: 22 h 45 min 21 s.
        let markers = ["2026-10-11": 1_791_672_932, "2026-10-12": 1_791_754_853]
        XCTAssertEqual(WhoopDayFigures.windowSeconds(day: "2026-10-11", markers: markers), 81_921)
    }

    func testADayWithoutMarkersIsItsCalendarDay() {
        XCTAssertEqual(WhoopDayFigures.windowSeconds(day: "2026-10-11", markers: [:]), 86_400)
        // A missing next marker falls back to the next midnight, as Home does for a past day.
        let start = Int(Calendar.current.startOfDay(for: WhoopDayFigures.date(of: "2026-10-11")!).timeIntervalSince1970)
        XCTAssertEqual(WhoopDayFigures.windowSeconds(day: "2026-10-11", markers: ["2026-10-11": start + 3_600]), 86_400 - 3_600)
    }

    func testANightIsCountedAgainstItsEffectiveOnset() {
        let row = CachedSleepSession(startTs: 1_000, endTs: 30_000, efficiency: 0.9, restingHr: 50, avgHrv: 70,
                                     stagesJSON: "[{\"start\":1000,\"end\":2000,\"stage\":\"light\"}]",
                                     startTsAdjusted: 1_500)
        let session = WhoopDayFigures.sleepSession(row)
        XCTAssertEqual(session.start, 1_500)
        XCTAssertEqual(session.end, 30_000)
        XCTAssertEqual(session.stages.count, 1)
        XCTAssertEqual(session.efficiency, 0.9, accuracy: 1e-12)
    }

    // MARK: the normals every readout shares

    func testTheStepsNormalTakesThePhonesCountsForDaysBeforeTheStrapCounted() {
        let days = [day("2026-10-01"), day("2026-10-02"), day("2026-10-03"), day("2026-10-04", steps: 400),
                    day("2026-10-05", steps: 20_000), day("2026-10-06", steps: 14_000), day("today", steps: 99)]
        let apple = ["2026-10-01": 9_000.0, "2026-10-02": 12_000.0, "2026-10-03": 3_000.0, "2026-10-04": 9_999.0]
        // Strap counts first (the 400 is under the floor and out), the phone's for the days without one.
        let normal = WhoopDayFigures.stepsNormal(days: days, excluding: "today", appleStepsByDay: apple)
        XCTAssertEqual(normal ?? 0, (9_000 + 12_000 + 3_000 + 20_000 + 14_000) / 5, accuracy: 1e-9)
        // The mean of the strap's own counts alone is another number: this is the one the Coach used to quote.
        let strapOnly = WhoopDayFigures.normal(days: days, excluding: "today") { $0.steps.map(Double.init) }
        XCTAssertEqual(strapOnly ?? 0, (400 + 20_000 + 14_000) / 3, accuracy: 1e-9)
        XCTAssertNotEqual(normal, strapOnly)
    }

    func testTheEnergyNormalFloorFollowsTheMode() {
        let days = [day("a", kcal: 50), day("b", kcal: 300), day("c", kcal: 500), day("d", kcal: 700), day("today", kcal: 1)]
        XCTAssertEqual(WhoopDayFigures.energyNormal(days: days, excluding: "today", yoop: true) ?? 0, 387.5, accuracy: 1e-9)
        XCTAssertEqual(WhoopDayFigures.energyNormal(days: days, excluding: "today", yoop: false) ?? 0, 500, accuracy: 1e-9)
    }

    func testTheComparedNormalIsByNowWhenThereIsOne() {
        let both = WhoopDayFigures.compared(fullDay: 10_634, byNow: 3_100)
        XCTAssertEqual(both, WhoopDayFigures.NormalReading(value: 3_100, byNow: true, fullDay: 10_634))
        let whole = WhoopDayFigures.compared(fullDay: 10_634, byNow: nil)
        XCTAssertEqual(whole, WhoopDayFigures.NormalReading(value: 10_634, byNow: false, fullDay: 10_634))
        XCTAssertNil(WhoopDayFigures.compared(fullDay: nil, byNow: nil))
        XCTAssertEqual(WhoopDayFigures.compared(fullDay: nil, byNow: 5)?.byNow, true)
    }

    func testTheCoachIsToldTheNormalTheRowStates() {
        let byNow = WhoopDayFigures.NormalReading(value: 14_100.4, byNow: true, fullDay: 14_565)
        XCTAssertEqual(byNow.coachPhrase(),
                       " (your normal by this time of day: 14100; a whole day usually reaches 14565)")
        XCTAssertEqual(byNow.coachPhrase(unit: " kcal"),
                       " (your normal by this time of day: 14100 kcal; a whole day usually reaches 14565 kcal)")
        let whole = WhoopDayFigures.NormalReading(value: 10_634, byNow: false, fullDay: 10_634)
        XCTAssertEqual(whole.coachPhrase(), " (your 30-day normal for a whole day: 10634; today is not over)")
    }

    // MARK: the week keeps its calendar days

    func testAMissingDayKeepsItsEmptySlotInTheWeek() {
        // 7 Oct has no row: the week ending 12 Oct is 6 to 12 Oct, with 7 Oct empty, and the Monday before
        // (5 Oct) does not take its place.
        let days = ["2026-10-05", "2026-10-06", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11", "2026-10-12"]
            .map { day($0, steps: 5_000) }
        let week = WhoopDayFigures.dayKeys(endingOn: "2026-10-12", count: 7)
        XCTAssertEqual(week, ["2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11",
                              "2026-10-12"])
        let values = Dictionary(WhoopDayFigures.recent(days: days, endingOn: "2026-10-12", count: 30, shown: nil) {
            $0.steps.map(Double.init)
        }.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        XCTAssertNil(values["2026-10-07"])
        XCTAssertEqual(week.filter { values[$0] != nil }.count, 6)
        XCTAssertFalse(week.contains("2026-10-05"))
        XCTAssertNotNil(values["2026-10-05"])   // still inside the 30 days, so it counts for the best day
    }

    func testAClosedDaysWindowBoundsAreOnsetToTheNextOnset() {
        let markers = ["2026-10-11": 1_791_672_932, "2026-10-12": 1_791_754_853]
        let bounds = WhoopDayFigures.window(day: "2026-10-11", markers: markers)
        XCTAssertEqual(bounds.from, 1_791_672_932)
        XCTAssertEqual(bounds.to, 1_791_754_853)
    }
}
