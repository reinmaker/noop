import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Yoop's sleep debt (`WhoopSleepDebt`): half of the last night's shortfall against that night's own need,
/// run as a chain over the nights the app holds. One resolver feeds the Sleep Debt tile, the ledger, the
/// Sleep Planner, the Alarms hero, the Coach, Hours vs Needed and the stored Sleep Performance; without
/// Yoop's scores every one of them is the NOOP ledger, as before.
@MainActor
final class WhoopSleepDebtTests: XCTestCase {

    // MARK: Fixtures

    /// Stored (0-100) Strain for a figure on WHOOP's 0-21 axis.
    private func stored(_ strain21: Double) -> Double {
        StrainScorer.effortValue(fromWhoopStrain: strain21)
    }

    private func day(_ key: String, asleep: Double?, strain21: Double? = nil, efficiency: Double? = 0.9) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: asleep, efficiency: efficiency, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: strain21.map { stored($0) }, exerciseCount: nil)
    }

    private func imported(need: Double? = nil, debt: Double? = nil) -> ImportedSleepFigures {
        ImportedSleepFigures(performancePct: nil, consistencyPct: nil, needMin: need, debtMin: debt)
    }

    /// A local wall-clock time.
    private func at(_ key: String, _ hour: Int, _ minute: Int = 0) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: key)!.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    /// Runs `body` with Yoop's scores on or off, restoring the switches after.
    private func withYoopScores(_ on: Bool, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [PuffinExperiment.whoopScoresKey, PuffinExperiment.whoopStrainCurveKey,
                    PuffinExperiment.banisterEffortKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(on, forKey: PuffinExperiment.whoopScoresKey)
        defaults.set(on, forKey: PuffinExperiment.whoopStrainCurveKey)
        defaults.removeObject(forKey: PuffinExperiment.banisterEffortKey)
        try body()
    }

    private func assertClose(_ actual: [Double], _ expected: [Double], accuracy: Double = 1e-6,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, message, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: accuracy, message, file: file, line: line)
        }
    }

    /// Five nights with a hard day between the third and the fourth, each figure worked out by hand.
    private var byHand: [DailyMetric] {
        [day("2026-10-01", asleep: 400), day("2026-10-02", asleep: 450), day("2026-10-03", asleep: 300, strain21: 14),
         day("2026-10-04", asleep: 500), day("2026-10-05", asleep: 440)]
    }

    /// The nights of 9 to 12 Oct as Yoop holds them (asleep minutes and the day's Strain on the 0-21 axis as
    /// listed for the user's own nights), after fourteen ordinary nights and one imported WHOOP night whose
    /// own need was 540 for 534 asleep; nothing was recorded on 7 and 8 Oct but 8 Oct's Strain.
    private var worked: [DailyMetric] {
        (22...30).map { day(String(format: "2026-09-%02d", $0), asleep: 420, strain21: 8) }
            + (1...5).map { day(String(format: "2026-10-%02d", $0), asleep: 420, strain21: 8) }
            + [day("2026-10-06", asleep: 534, strain21: 6.0),
               day("2026-10-08", asleep: nil, strain21: 5.7),
               day("2026-10-09", asleep: 307, strain21: 9.7),
               day("2026-10-10", asleep: 533, strain21: 18.0),
               day("2026-10-11", asleep: 416, strain21: 7.0),
               day("2026-10-12", asleep: 479, strain21: 10.6)]
    }

    private var workedImport: [String: ImportedSleepFigures] { ["2026-10-06": imported(need: 540)] }

    // MARK: The rule

    func testHalfOfTheShortfallCarriesAndAMetNeedCarriesNothing() {
        XCTAssertEqual(WhoopSleepDebt.carryShare, 0.5)
        XCTAssertEqual(WhoopSleepDebt.carried(needMin: 508, asleepMin: 416), 46, accuracy: 1e-12)
        XCTAssertEqual(WhoopSleepDebt.carried(needMin: 450, asleepMin: 450), 0)
        XCTAssertEqual(WhoopSleepDebt.carried(needMin: 450, asleepMin: 533), 0, "extra sleep never creates a surplus")
        XCTAssertEqual(WhoopSleepDebt.carried(needMin: 462, asleepMin: 462 - 17), 8.5, accuracy: 1e-12)
    }

    // MARK: The chain

    /// Each night's debt is half of the night before's shortfall against that night's own need, which holds
    /// the debt before it: 450 / 475 / 462.5 / 562.86 / 481.43 for the five nights, 470.715 for the sixth.
    func testAChainWorkedOutByHand() {
        let nights = WhoopSleepDebt.nights(days: byHand, importedSleep: [:])
        XCTAssertEqual(nights.map(\.day), byHand.map(\.day))
        assertClose(nights.map(\.planned.debtMin), [0, 25, 12.5, 81.25, 31.43])
        assertClose(nights.map(\.planned.strainMin), [0, 0, 0, 31.61, 0])
        assertClose(nights.map(\.planned.baselineMin), [450, 450, 450, 450, 450])
        assertClose(nights.map(\.needMin), [450, 475, 462.5, 562.86, 481.43])
        assertClose(nights.map(\.leftMin), [25, 12.5, 81.25, 31.43, 20.715])
        XCTAssertEqual(nights.first?.planned.debtMin, 0, "the first night has nothing before it")
        let tonight = WhoopSleepDebt.need(endingOn: "2026-10-06", days: byHand, importedSleep: [:])
        XCTAssertEqual(tonight.needMin, 470.715, accuracy: 1e-9)
        XCTAssertEqual(tonight.debtMin, nights.last?.leftMin)
    }

    /// A day with no sleep total is skipped: the debt passes over it, and no zero is filled in for the night,
    /// which would read as a whole night of shortfall. Its Strain still belongs to the day.
    func testANightWithoutASleepTotalIsSkippedNotZeroFilled() {
        let days = [day("2026-10-01", asleep: 400), day("2026-10-02", asleep: nil, strain21: 12),
                    day("2026-10-03", asleep: 0), day("2026-10-04", asleep: 480)]
        let nights = WhoopSleepDebt.nights(days: days, importedSleep: [:])
        XCTAssertEqual(nights.map(\.day), ["2026-10-01", "2026-10-04"])
        XCTAssertEqual(nights[1].planned.debtMin, 25, "half of the 50 min the first night fell short")
        XCTAssertEqual(nights[1].planned.strainMin, 0, "3 Oct's Strain is what counts for 4 Oct, and it had none")
        let afterTheHardDay = [day("2026-10-01", asleep: 400), day("2026-10-02", asleep: nil, strain21: 12),
                               day("2026-10-03", asleep: 480)]
        XCTAssertEqual(WhoopSleepDebt.nights(days: afterTheHardDay, importedSleep: [:]).last?.planned.strainMin ?? -1,
                       WhoopSleepDebt.needMinPerStrainPoint * (12 - WhoopSleepDebt.needStrainFloor), accuracy: 1e-9,
                       "a night after a day with no sleep total still reads that day's Strain")
    }

    /// An imported WHOOP night is measured against WHOOP's own need, and its shortfall against that need
    /// is what the next night carries.
    func testAnImportedNightKeepsWhoopsNeedAndPassesItsShortfallOn() {
        let days = [day("2026-10-01", asleep: 400), day("2026-10-02", asleep: 450), day("2026-10-03", asleep: 480)]
        let nights = WhoopSleepDebt.nights(days: days, importedSleep: ["2026-10-02": imported(need: 520, debt: 99)])
        XCTAssertTrue(nights[1].hasImportedNeed)
        XCTAssertEqual(nights[1].needMin, 520)
        XCTAssertEqual(nights[1].leftMin, 35, accuracy: 1e-12)
        XCTAssertEqual(nights[2].planned.debtMin, 35, accuracy: 1e-12, "the shortfall against WHOOP's need, not a computed one")
        XCTAssertFalse(nights[2].hasImportedNeed)
        // The batch resolver gives the imported night its own need and no parts, the planned nights theirs.
        withYoopScores(true) {
            let needs = SleepModel.nightNeeds(days: days, importedSleep: ["2026-10-02": imported(need: 520, debt: 99)])
            XCTAssertEqual(needs.needMin["2026-10-02"], 520)
            XCTAssertNil(needs.planned["2026-10-02"])
            XCTAssertEqual(needs.planned["2026-10-03"]?.debtMin ?? -1, 35, accuracy: 1e-12)
        }
    }

    /// The order the days arrive in does not matter, only their day keys.
    func testTheDaysNeedNotArriveInOrder() {
        XCTAssertEqual(WhoopSleepDebt.nights(days: byHand.reversed(), importedSleep: [:]),
                       WhoopSleepDebt.nights(days: byHand, importedSleep: [:]))
        XCTAssertEqual(WhoopSleepDebt.need(endingOn: "2026-10-06", days: byHand.reversed(), importedSleep: [:]),
                       WhoopSleepDebt.need(endingOn: "2026-10-06", days: byHand, importedSleep: [:]))
    }

    // MARK: Regression on twelve consecutive nights

    /// Twelve consecutive nights (the last four are the user's own, listed in minutes), recomputed by an
    /// independent script that shares no code with the app: the debt each night starts with, the need it is
    /// measured against, the debt it leaves and Hours vs Needed. A change to the rule or to how the chain
    /// walks the nights moves these.
    func testTwelveConsecutiveNightsMatchAnIndependentRecompute() {
        let table: [(day: String, asleep: Double, strain21: Double)] = [
            ("2026-10-01", 420, 8), ("2026-10-02", 390, 12), ("2026-10-03", 450, 6), ("2026-10-04", 360, 14),
            ("2026-10-05", 440, 9), ("2026-10-06", 400, 11), ("2026-10-07", 430, 7), ("2026-10-08", 380, 10),
            ("2026-10-09", 307, 9.7), ("2026-10-10", 533, 18.0), ("2026-10-11", 416, 7.0), ("2026-10-12", 479, 10.6)]
        let days = table.map { day($0.day, asleep: $0.asleep, strain21: $0.strain21) }
        let nights = WhoopSleepDebt.nights(days: days, importedSleep: [:])
        XCTAssertEqual(nights.count, 12)
        assertClose(nights.map(\.planned.debtMin),
                    [0, 15, 37.5, 29.105, 59.5525, 50.58125, 52.470625, 43.8653125, 56.93265625,
                     104.871328125, 15.0231640625, 51.2165820313])
        assertClose(nights.map(\.planned.strainMin), [0, 0, 20.71, 0, 31.61, 4.36, 15.26, 0, 9.81, 8.175, 53.41, 0])
        assertClose(nights.map(\.needMin),
                    [450, 465, 508.21, 479.105, 541.1625, 504.94125, 517.730625, 493.8653125, 516.74265625,
                     563.046328125, 518.433164063, 501.216582031])
        assertClose(nights.map(\.leftMin),
                    [15, 37.5, 29.105, 59.5525, 50.58125, 52.470625, 43.8653125, 56.93265625,
                     104.871328125, 15.0231640625, 51.2165820313, 11.108291015625])
        assertClose(nights.map { $0.asleepMin / $0.needMin * 100 },
                    [93.333333, 83.870968, 88.546073, 75.140105, 81.306447, 79.217137, 83.054774, 76.944055,
                     59.410617, 94.663614, 80.241780, 95.567469], accuracy: 1e-5)
        // The need of the night after them, and the same chain read through the model's resolvers.
        withYoopScores(true) {
            let tonight = SleepModel.nightNeed(wakeDay: "2026-10-13", days: days, importedSleep: [:])
            XCTAssertEqual(tonight.debtMin, 11.108291015625, accuracy: 1e-9)
            XCTAssertEqual(tonight.strainMin, 13.08, accuracy: 1e-9)
            XCTAssertEqual(tonight.needMin, 450 + 13.08 + 11.108291015625, accuracy: 1e-9)
            let series = SleepModel.sleepDebtSeries(days: days, importedSleep: [:], napSleepMinByDay: [:])
            assertClose(series.series, nights.map(\.leftMin))
        }
    }

    /// The nights of 9 to 12 Oct: with the Strain of 18.0 on 10 Oct the night of the 10th to the 11th needs
    /// 503 and the 416 slept are 83%, not the 78% the NOOP ledger gave; 12 Oct needs 494 for 97%; and the
    /// night after them is planned at 470.
    func testTheNightsOf9To12OctFollowFromTheListedMinutes() {
        let nights = WhoopSleepDebt.nights(days: worked, importedSleep: workedImport)
        let byDay = Dictionary(uniqueKeysWithValues: nights.map { ($0.day, $0) })
        // 9 Oct starts with half of what the imported night fell short of its own need: 3 min.
        XCTAssertEqual(byDay["2026-10-09"]?.planned.debtMin ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(byDay["2026-10-09"]?.needMin ?? -1, 453, accuracy: 1e-9)
        XCTAssertEqual(byDay["2026-10-10"]?.planned.debtMin ?? -1, 73, accuracy: 1e-9)
        XCTAssertEqual(byDay["2026-10-10"]?.planned.strainMin ?? -1, 8.175, accuracy: 1e-9, "9 Oct's Strain was 9.7")
        XCTAssertEqual(byDay["2026-10-10"]?.needMin ?? -1, 531.175, accuracy: 1e-9)
        XCTAssertEqual(byDay["2026-10-11"]?.planned.strainMin ?? -1, 53.41, accuracy: 1e-9)
        XCTAssertEqual(byDay["2026-10-11"]?.planned.debtMin ?? -1, 0, accuracy: 1e-9, "533 slept met the 531")
        XCTAssertEqual(byDay["2026-10-11"]?.needMin ?? -1, 503.41, accuracy: 1e-9)
        XCTAssertEqual(416 / (byDay["2026-10-11"]?.needMin ?? 1) * 100, 82.6, accuracy: 0.05)
        XCTAssertEqual(byDay["2026-10-12"]?.planned.debtMin ?? -1, 43.705, accuracy: 1e-9)
        XCTAssertEqual(byDay["2026-10-12"]?.needMin ?? -1, 493.705, accuracy: 1e-9)
        XCTAssertEqual(479 / (byDay["2026-10-12"]?.needMin ?? 1) * 100, 97.0, accuracy: 0.05)
        let tonight = WhoopSleepDebt.need(endingOn: "2026-10-13", days: worked, importedSleep: workedImport)
        XCTAssertEqual(tonight.debtMin, 7.3525, accuracy: 1e-9)
        XCTAssertEqual(tonight.strainMin, 13.08, accuracy: 1e-9)
        XCTAssertEqual(tonight.needMin, 470.4325, accuracy: 1e-9)
    }

    // MARK: One value for every readout

    /// The Sleep Debt tile, the ledger, tonight's need, the Sleep Planner, the Alarms hero and the Coach line
    /// state one debt, the one the last night leaves, and Hours vs Needed, the planner's own need for a night
    /// and the stored Sleep Performance are measured against one need.
    func testTheTileTheLedgerAndTonightsPlanReadOneDebt() throws {
        try withYoopScores(true) {
            let days = worked
            let figures = workedImport
            let tile = SleepModel.sleepDebtSeries(days: days, importedSleep: figures, napSleepMinByDay: ["2026-10-12": 40])
            let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: ["2026-10-12": 40], importedSleep: figures)
            let need = SleepModel.nightNeed(wakeDay: "2026-10-13", days: days, importedSleep: figures)
            XCTAssertEqual(tile.latest ?? -1, 7.3525, accuracy: 1e-9)
            XCTAssertEqual(ledger.magnitudeMin, tile.latest ?? -1, "the ledger reads the tile's value, naps or none")
            XCTAssertEqual(ledger.balanceMin, -(tile.latest ?? 0))
            XCTAssertTrue(ledger.isDebt)
            XCTAssertEqual(need.debtMin, tile.latest ?? -1)

            let repo = Repository(deviceId: "test-whoop-debt")
            repo.days = days
            repo.importedSleep = figures
            let plan = try XCTUnwrap(WhoopSleepPlan.tonight(repo: repo, alarm: at("2026-10-13", 7, 30),
                                                            now: at("2026-10-12", 22, 0), wakeOverrides: [:], chosenWake: nil))
            XCTAssertEqual(plan.debtMin, tile.latest ?? -1)
            XCTAssertEqual(NightNeed(baselineMin: plan.baselineMin, strainMin: plan.strainMin, debtMin: plan.debtMin), need)
            XCTAssertTrue(SmartAlarmView.needSummary(plan).contains(WhoopTime.duration(minutes: tile.latest ?? -1)),
                          SmartAlarmView.needSummary(plan))
            XCTAssertTrue(plan.coachLine.contains("sleep debt 0h 7m"), plan.coachLine)

            // The next morning: the night is banked, and every reading of its need is the plan's.
            let morning = days + [day("2026-10-13", asleep: 480, strain21: 3)]
            repo.days = morning
            let needs = SleepModel.nightNeeds(days: repo.strainDays, importedSleep: figures)
            XCTAssertEqual(needs.planned["2026-10-13"], need)
            XCTAssertEqual(needs.needMin["2026-10-13"] ?? -1, plan.needMin, accuracy: 1e-9)
            let hoursVsNeeded = SleepModel.hoursVsNeededSeries(days: repo.strainDays, importedSleep: figures)
            XCTAssertEqual(hoursVsNeeded.series.last ?? -1, 480 / plan.needMin * 100, accuracy: 1e-9)
            let tileMorning = SleepModel.sleepDebtSeries(days: repo.strainDays, importedSleep: figures, napSleepMinByDay: [:])
            XCTAssertEqual(tileMorning.latest ?? -1, 0, accuracy: 1e-9, "the night met its need, so it leaves nothing")
            XCTAssertEqual(SleepModel.debtLedger(days: repo.strainDays, napSleepMinByDay: [:], importedSleep: figures).magnitudeMin, 0)
        }
    }

    /// The model the Sleep screen and Home's host build carries those same values.
    func testTheBuiltModelCarriesTheSameDebtAndNeeds() throws {
        try withYoopScores(true) {
            let figures = workedImport
            let end = at("2026-10-12", 9)
            let session = CachedSleepSession(startTs: Int(end.timeIntervalSince1970) - 8 * 3_600,
                                             endTs: Int(end.timeIntervalSince1970),
                                             efficiency: 0.9, restingHr: nil, avgHrv: nil, stagesJSON: nil)
            let model = try XCTUnwrap(SleepModel.build(SleepModelInputs(
                days: worked, sleeps: [session], allSessions: [], importedSleep: figures,
                habitualMidsleepSec: nil, motionByStart: [:])))
            let tile = SleepModel.sleepDebtSeries(days: worked, importedSleep: figures, napSleepMinByDay: [:])
            XCTAssertEqual(model.sleepDebt.series, tile.series)
            XCTAssertEqual(model.sleepDebtLedger.magnitudeMin, model.sleepDebt.latest ?? -1)
            let needs = SleepModel.nightNeeds(days: worked, importedSleep: figures)
            XCTAssertEqual(model.nightNeeds, needs.planned)
            XCTAssertEqual(model.nightNeeds["2026-10-12"]?.debtMin ?? -1, 43.705, accuracy: 1e-9,
                           "Hours vs Needed for 12 Oct splits its need with the debt 11 Oct left")
            XCTAssertEqual(model.hoursVsNeeded.series.last ?? -1, 479 / 493.705 * 100, accuracy: 1e-9)
        }
    }

    /// An imported WHOOP debt for a night stays export-verbatim for that night, and the ledger follows it.
    func testAnImportedDebtStaysVerbatimAndTheLedgerFollowsIt() {
        withYoopScores(true) {
            let days = [day("2026-06-01", asleep: 480), day("2026-06-02", asleep: 400)]
            let figures = ["2026-06-02": imported(need: 480, debt: 17.25)]
            let tile = SleepModel.sleepDebtSeries(days: days, importedSleep: figures, napSleepMinByDay: [:])
            XCTAssertEqual(tile.latest ?? -1, 17.25, accuracy: 1e-12)
            XCTAssertEqual(SleepModel.debtLedger(days: days, napSleepMinByDay: [:], importedSleep: figures).magnitudeMin,
                           17.25, accuracy: 1e-12)
        }
    }

    /// The ledger's bars are each night's sleep against the healthy minimum, 14 nights at most.
    func testTheLedgerHoldsTheLastFourteenNightsAgainstTheHealthyMinimum() {
        withYoopScores(true) {
            let ledger = SleepModel.debtLedger(days: worked, napSleepMinByDay: [:], importedSleep: workedImport)
            XCTAssertEqual(ledger.nightCount, 14)
            XCTAssertEqual(ledger.needMin, 450)
            XCTAssertEqual(ledger.nights.last?.day, "2026-10-12")
            XCTAssertEqual(ledger.nights.last?.deltaMin, 479 - 450)
            XCTAssertEqual(ledger.nights.first?.day, "2026-09-27", "19 nights with sleep, the last 14 of them")
        }
    }

    /// No other source file runs the NOOP ledger or WHOOP's rule: a second reader of the debt would be a
    /// second answer. The readers take it from `SleepModel`, which takes it from `WhoopSleepDebt`.
    func testNoOtherSourceFileResolvesTheDebt() throws {
        let sources = try WhoopSleepPlanTests.strandSources()
        func code(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.drop(while: { $0 == " " }).hasPrefix("//") }.joined(separator: "\n")
        }
        func files(calling needle: String) -> [String] {
            sources.filter { code($0.1).contains(needle) }.map { $0.0 }
        }
        XCTAssertEqual(files(calling: "SleepDebt.ledger("), ["Screens/SleepModel.swift"])
        XCTAssertEqual(files(calling: "SleepDebt.debtSeries("), ["Screens/SleepModel.swift"])
        XCTAssertEqual(files(calling: "WhoopSleepDebt.carried("), ["Data/WhoopSleepDebt.swift"])
        XCTAssertEqual(files(calling: "WhoopSleepDebt.nights("), ["Screens/SleepModel.swift"])
        XCTAssertEqual(files(calling: "WhoopSleepDebt.need("), ["Screens/SleepModel.swift"])
        XCTAssertEqual(files(calling: "Chain(importedSleep:"), ["Data/WhoopSleepDebt.swift"])
        // The tile, the ledger and the plan are read off the model and the plan, never recomputed beside them.
        XCTAssertEqual(files(calling: "sleepDebtSeries("), ["Screens/SleepModel.swift"])
        XCTAssertEqual(files(calling: "debtLedger("), ["Screens/SleepModel.swift"])
        XCTAssertEqual(files(calling: "whoopDebtSeries("), ["Screens/SleepModel.swift"])
    }

    // MARK: The engine

    /// The one-time rescore has a new flag, so a device that ran the earlier ones scores its recent nights
    /// again against the debt and the Strain term WHOOP states.
    func testTheRescoreFlagMovedToVersionThree() {
        XCTAssertEqual(IntelligenceEngine.nightNeedRescoreFlagKey, "yoop.nightNeedRescore.v3.done")
        XCTAssertNotEqual(IntelligenceEngine.nightNeedRescoreFlagKey, "yoop.nightNeedRescore.v2.done")
        XCTAssertNotEqual(IntelligenceEngine.nightNeedRescoreFlagKey, "yoop.nightNeedRescore.v1.done")
    }

    /// The score the engine stores reads the need the chain gives the night, whatever `only` limits.
    func testTheEnginesNeedForAScoredNightIsTheChainsWhateverOnlyLimits() {
        withYoopScores(true) {
            let all = SleepModel.nightNeeds(days: worked, importedSleep: workedImport)
            let some = SleepModel.nightNeeds(days: worked, importedSleep: workedImport,
                                             only: ["2026-10-11", "2026-10-12"])
            XCTAssertEqual(Set(some.needMin.keys), ["2026-10-11", "2026-10-12"])
            XCTAssertEqual(some.needMin["2026-10-11"], all.needMin["2026-10-11"])
            XCTAssertEqual(some.needMin["2026-10-12"] ?? -1, 493.705, accuracy: 1e-9)
            let night = worked[worked.count - 1]
            let score = WhoopScores.sleepPerformance(daily: night, needMin: some.needMin["2026-10-12"] ?? 0, consistency: nil)
            let hoursVsNeeded: Double = 479.0 / 493.705 * 100.0
            let weighted: Double = 0.272 * hoursVsNeeded + 0.368 * 90.0
            XCTAssertEqual(score ?? -1, weighted * (0.967 / 0.640), accuracy: 1e-9)
        }
    }

    // MARK: Without Yoop's scores

    /// Every debt readout without Yoop's scores is the NOOP ledger, to the last bit: these figures were
    /// captured from the build before WHOOP's debt was added, over a history with gaps, a night without a
    /// sleep total, naps and an imported debt.
    func testWithoutYoopsScoresEveryDebtReadoutIsTheNoopLedgerBitForBit() {
        withYoopScores(false) {
            var rows: [DailyMetric] = []
            for i in 0..<40 {
                let key = WeeklyDigestEngine.addDays("2026-08-20", i)
                if i == 9 || i == 23 { continue }
                let asleep: Double? = (i % 13 == 6) ? nil : 330 + Double((i * 37) % 190)
                rows.append(day(key, asleep: asleep, strain21: Double((i * 5) % 21)))
            }
            XCTAssertEqual(rows.count, 38)
            let naps: [String: Double] = ["2026-09-02": 45, "2026-09-20": 20]
            let figures = ["2026-09-05": imported(debt: 77)]

            let needs: [(wake: String, baseline: Double, strain: Double, debt: Double, debtImported: Double)] = [
                ("2026-08-30", 450.0, 0.0, 48.7, 48.7), ("2026-09-06", 450.0, 51.1, 77.3, 77.0),
                ("2026-09-17", 450.0, 0.0, 106.2, 106.2), ("2026-09-27", 450.0, 51.1, 116.2, 116.2),
                ("2026-09-29", 450.0, 0.0, 77.9, 77.9)]
            for expected in needs {
                let plain = SleepModel.nightNeed(wakeDay: expected.wake, days: rows, importedSleep: [:])
                XCTAssertEqual(plain.baselineMin, expected.baseline, expected.wake)
                XCTAssertEqual(plain.strainMin, expected.strain, expected.wake)
                XCTAssertEqual(plain.debtMin, expected.debt, expected.wake)
                XCTAssertEqual(SleepModel.nightNeed(wakeDay: expected.wake, days: rows, importedSleep: figures).debtMin,
                               expected.debtImported, expected.wake)
            }

            let series = SleepModel.sleepDebtSeries(days: rows, importedSleep: [:], napSleepMinByDay: naps)
            XCTAssertEqual(series.series, [82.5, 107.5, 100.9, 77.0, 43.4, 0.0, 44.6, 48.7, 10.3, 73.3, 87.6, 50.4, 34.3, 0.0,
                                           70.4, 88.8, 78.5, 32.2, 90.9, 102.8, 68.6, 29.5, 92.1, 106.2, 93.6, 66.3, 31.0, 84.7,
                                           84.5, 64.1, 32.5, 99.3, 115.6, 104.3, 77.7])
            XCTAssertEqual(series.latest, 77.7)
            XCTAssertEqual(series.typical, 67.83142857142856)
            let withImport = SleepModel.sleepDebtSeries(days: rows, importedSleep: figures, napSleepMinByDay: [:])
            XCTAssertEqual(withImport.series, [82.5, 107.5, 100.9, 77.0, 43.4, 0.0, 44.6, 48.7, 10.3, 73.3, 87.6, 75.1, 47.9,
                                               12.6, 77.0, 92.6, 80.6, 33.3, 91.5, 103.1, 68.8, 29.6, 92.2, 106.2, 93.6, 66.3,
                                               31.0, 95.7, 90.6, 67.4, 34.3, 100.3, 116.2, 104.6, 77.9])

            let ledger = SleepModel.debtLedger(days: rows, napSleepMinByDay: naps)
            XCTAssertEqual(ledger.balanceMin, -77.7)
            XCTAssertEqual(ledger.needMin, 480.0)
            XCTAssertEqual(ledger.nightCount, 14)
            XCTAssertEqual(ledger.nights.map(\.deltaMin),
                           [15.0, -138.0, -101.0, -64.0, -27.0, 10.0, -123.0, -69.0, -32.0, 5.0, -148.0, -111.0, -74.0, -37.0])
            // The ledger's import argument changes nothing without Yoop's scores.
            XCTAssertEqual(SleepModel.debtLedger(days: rows, napSleepMinByDay: naps, importedSleep: figures), ledger)

            let all = SleepModel.nightNeeds(days: rows, importedSleep: figures)
            XCTAssertTrue(all.planned.isEmpty)
            XCTAssertEqual(all.needMin.count, 35)
            XCTAssertEqual(all.needMin["2026-09-27"], 450.0)
            XCTAssertEqual(SleepModel.hoursVsNeededSeries(days: rows, importedSleep: [:]).typical, 93.3142857142857)
        }
    }
}
