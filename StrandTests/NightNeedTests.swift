import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopStore

/// One need per night (`SleepModel.nightNeed`): the Sleep Planner sets it in the evening, and the next
/// morning Hours vs Needed, the Sleep screen's Sleep Performance and the engine's stored score measure the
/// night against that same figure.
final class NightNeedTests: XCTestCase {

    /// Stored (0-100) Strain for a figure on WHOOP's 0-21 axis.
    private func stored(_ strain21: Double) -> Double {
        StrainScorer.effortValue(fromWhoopStrain: strain21)
    }

    private func day(_ key: String, asleep: Double?, strain21: Double? = nil, efficiency: Double? = 0.9) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: asleep, efficiency: efficiency, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: strain21.map { stored($0) }, exerciseCount: nil)
    }

    /// A local wall-clock time.
    private func at(_ key: String, _ hour: Int, _ minute: Int) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: key)!.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    /// Two weeks of 7-hour nights, then 10 Oct with Strain 18.0: the evening before the night of 10 to 11 Oct.
    private var evening: [DailyMetric] {
        (26...30).map { day(String(format: "2026-09-%02d", $0), asleep: 420, strain21: 9) }
            + (1...9).map { day(String(format: "2026-10-%02d", $0), asleep: 420, strain21: 9) }
            + [day("2026-10-10", asleep: 430, strain21: 18)]
    }

    /// The night of 10 to 11 Oct: 416 min asleep.
    private let night = DailyMetric(day: "2026-10-11", totalSleepMin: 416, efficiency: 0.88, deepMin: nil,
                                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                                    recovery: nil, strain: nil, exerciseCount: nil)

    /// The next morning: the night banked, and the new day's first Strain.
    private var morning: [DailyMetric] { evening + [night.with(strain: 3)] }

    /// Runs `body` with Yoop's scores on or off, restoring the switches after.
    @MainActor
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

    /// Runs `body` with Yoop's scores off, then on: what the NOOP ledger and WHOOP's debt both have to get right.
    @MainActor
    private func inBothModes(_ body: (Bool) throws -> Void) rethrows {
        for on in [false, true] { try withYoopScores(on) { try body(on) } }
    }

    // MARK: The need

    /// The planner's arithmetic: the healthy minimum + 7.3 min per point of the previous day's Strain above
    /// 10 + the sleep debt the Sleep Debt series carries out of the previous night. Without Yoop's scores
    /// the debt is the NOOP ledger's; with them it is WHOOP's, and the same two readouts agree.
    @MainActor
    func testNeedIsTheHealthyMinimumPlusStrainAboveTenPlusTheCarriedDebt() {
        for yoop in [false, true] {
            withYoopScores(yoop) {
                let need = SleepModel.nightNeed(wakeDay: "2026-10-11", days: evening, importedSleep: [:])
                XCTAssertEqual(need.baselineMin, 450, "7-hour nights sit under the 7:30 floor")
                XCTAssertEqual(need.strainMin, 7.3 * 8, accuracy: 1e-9)
                let carried = SleepModel.sleepDebtSeries(days: evening, importedSleep: [:], napSleepMinByDay: [:]).latest
                XCTAssertEqual(need.debtMin, carried, "yoop \(yoop)")
                XCTAssertGreaterThan(need.debtMin, 0)
                XCTAssertEqual(need.needMin, 450 + 7.3 * 8 + need.debtMin, accuracy: 1e-9)
            }
        }
    }

    /// Without Yoop's scores the debt is the latest value of the full NOOP ledger series over the days
    /// before the night, whatever the history holds: gaps, a day with no sleep, an imported debt for the
    /// latest day. (The resolver reads only the last 14 nights with sleep, to stay linear on a long history.)
    @MainActor
    func testTheNoopLedgerDebtMatchesTheFullSeriesOnALongAwkwardHistory() {
        withYoopScores(false) {
            var rows: [DailyMetric] = []
            for i in 0..<120 {
                let key = WeeklyDigestEngine.addDays("2026-06-01", i)
                if i % 17 == 5 { continue }                                              // a missing day
                rows.append(day(key, asleep: i % 11 == 3 ? nil : 330 + Double((i * 29) % 170), strain21: Double(i % 21)))
            }
            let importedFigures: [[String: ImportedSleepFigures]] = [
                [:], ["2026-09-12": ImportedSleepFigures(performancePct: nil, consistencyPct: nil, needMin: nil, debtMin: 77)]]
            for imported in importedFigures {
                for wakeDay in ["2026-06-20", "2026-08-01", "2026-09-12", "2026-09-13", "2026-09-27"] {
                    let prior = rows.filter { $0.day < wakeDay }
                    let full = SleepModel.sleepDebtSeries(days: prior, importedSleep: imported, napSleepMinByDay: [:]).latest
                    let need = SleepModel.nightNeed(wakeDay: wakeDay, days: rows, importedSleep: imported)
                    XCTAssertEqual(need.debtMin, max(0, full ?? 0), "debt for \(wakeDay)")
                    XCTAssertEqual(need.baselineMin, SleepModel.sleepNeedMin(days: prior), "minimum for \(wakeDay)")
                }
            }
        }
    }

    /// With Yoop's scores on, one night's need from the single-night resolver and from the batch one are the
    /// same figure, on a long history with gaps, nights without a sleep total and an imported night.
    @MainActor
    func testTheSingleNightAndTheBatchResolveOneNeedOnALongAwkwardHistory() {
        withYoopScores(true) {
            var rows: [DailyMetric] = []
            for i in 0..<120 {
                let key = WeeklyDigestEngine.addDays("2026-06-01", i)
                if i % 17 == 5 { continue }                                              // a missing day
                rows.append(day(key, asleep: i % 11 == 3 ? nil : 330 + Double((i * 29) % 170), strain21: Double(i % 21)))
            }
            let importedFigures: [[String: ImportedSleepFigures]] = [
                [:], ["2026-09-12": ImportedSleepFigures(performancePct: nil, consistencyPct: nil, needMin: 520, debtMin: 77)]]
            for imported in importedFigures {
                let all = SleepModel.nightNeeds(days: rows, importedSleep: imported)
                for wakeDay in ["2026-06-20", "2026-08-01", "2026-09-12", "2026-09-13", "2026-09-27"] {
                    let need = SleepModel.nightNeed(wakeDay: wakeDay, days: rows, importedSleep: imported)
                    let prior = rows.filter { $0.day < wakeDay }
                    XCTAssertEqual(need.baselineMin, SleepModel.sleepNeedMin(days: prior), "minimum for \(wakeDay)")
                    let batch = SleepModel.nightNeeds(days: rows, importedSleep: imported, only: [wakeDay])
                    XCTAssertEqual(batch.needMin[wakeDay], all.needMin[wakeDay], "only: limits the work, not the answer")
                    XCTAssertEqual(batch.planned[wakeDay], all.planned[wakeDay])
                    if rows.contains(where: { $0.day == wakeDay && ($0.totalSleepMin ?? 0) > 0 }), imported[wakeDay]?.needMin == nil {
                        XCTAssertEqual(batch.planned[wakeDay], need, "the batch and the single night agree for \(wakeDay)")
                    }
                }
            }
        }
    }

    /// The night's own sleep, and anything after it, cannot move its need: the morning resolves the
    /// evening's figure.
    @MainActor
    func testOnlyTheDaysBeforeTheNightCount() {
        inBothModes { yoop in
            let later = morning + [day("2026-10-12", asleep: 300, strain21: 20)]
            XCTAssertEqual(SleepModel.nightNeed(wakeDay: "2026-10-11", days: later, importedSleep: [:]),
                           SleepModel.nightNeed(wakeDay: "2026-10-11", days: evening, importedSleep: [:]), "yoop \(yoop)")
        }
    }

    /// Strain counts from the day before the night only; a day under 10 adds nothing.
    @MainActor
    func testStrainIsThePreviousDaysAndOnlyAboveTen() {
        inBothModes { yoop in
            let restDay = evening.dropLast() + [day("2026-10-10", asleep: 430, strain21: 9.5)]
            XCTAssertEqual(SleepModel.nightNeed(wakeDay: "2026-10-11", days: Array(restDay), importedSleep: [:]).strainMin, 0, "yoop \(yoop)")
            // No row for 10 Oct: the 18.0 of 9 Oct belongs to an earlier night.
            let gap = evening.dropLast(2) + [day("2026-10-09", asleep: 420, strain21: 18)]
            XCTAssertEqual(SleepModel.nightNeed(wakeDay: "2026-10-11", days: Array(gap), importedSleep: [:]).strainMin, 0, "yoop \(yoop)")
        }
    }

    /// Effort ratings reach the need: it reads Strain off the days as the Strain ring resolves them.
    @MainActor
    func testARatedLiftRaisesTheNeedThroughTheStrainFunnel() {
        inBothModes { yoop in
            ratedLiftRaisesTheNeed(yoop: yoop)
        }
    }

    private func ratedLiftRaisesTheNeed(yoop: Bool) {
        let start = 1_760_000_000
        let lift = WorkoutRow(startTs: start, endTs: start + 45 * 60, sport: "Weightlifting", source: "manual",
                              durationS: 45 * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: stored(11),
                              distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        let book = StrainBook.build(rows: [lift], efforts: [start: 7], now: start) { _ in "2026-10-10" }
        let resolved = book.resolved(evening, live: nil)
        let ringStrain = UnitFormatter.effortValue(book.dayStrain(day: "2026-10-10", stored: stored(18), live: nil) ?? 0,
                                                   scale: .whoop)
        XCTAssertGreaterThan(ringStrain, 18)
        let need = SleepModel.nightNeed(wakeDay: "2026-10-11", days: resolved, importedSleep: [:])
        XCTAssertEqual(need.strainMin, 7.3 * (ringStrain - 10), accuracy: 1e-9, "yoop \(yoop)")
    }

    // MARK: One resolver for the plan and the morning's scores

    /// The plan shown on the evening of 10 Oct and every reading of the night the next morning resolve one
    /// need: the Sleep screen's Hours vs Needed, its Sleep Performance, and the engine's stored score, which
    /// reads the days as they will read once its pass is stored.
    @MainActor
    func testThePlanAndTheNextMorningsScoresResolveOneNeed() throws {
        try withYoopScores(true) {
            let repo = Repository(deviceId: "my-whoop")
            repo.days = evening
            let plan = try XCTUnwrap(WhoopSleepPlan.tonight(repo: repo, alarm: at("2026-10-11", 7, 30), now: at("2026-10-10", 22, 0), wakeOverrides: [:], chosenWake: nil))
            let planned = NightNeed(baselineMin: plan.baselineMin, strainMin: plan.strainMin, debtMin: plan.debtMin)
            XCTAssertEqual(planned, SleepModel.nightNeed(wakeDay: "2026-10-11", days: evening, importedSleep: [:]))

            repo.days = morning
            let needs = SleepModel.nightNeeds(days: repo.strainDays, importedSleep: repo.importedSleep)
            XCTAssertEqual(needs.planned["2026-10-11"], planned)
            XCTAssertEqual(needs.needMin["2026-10-11"], plan.needMin)
            let hoursVsNeeded = SleepModel.hoursVsNeededSeries(days: repo.strainDays, importedSleep: repo.importedSleep)
            XCTAssertEqual(hoursVsNeeded.series.last ?? 0, 416 / plan.needMin * 100, accuracy: 1e-9)
            XCTAssertLessThan(hoursVsNeeded.series.last ?? 100, 416 / 450 * 100, "no longer against the minimum alone")

            let expected = WhoopScores.sleepPerformance(daily: night, needMin: plan.needMin, consistency: nil)
            XCTAssertNotNil(expected)
            let screen = SleepModel.performanceByDay(days: repo.strainDays, importedSleep: repo.importedSleep)
            XCTAssertEqual(screen["2026-10-11"], expected)

            let afterPass = IntelligenceEngine.daysAfterPass(shown: evening, scored: [night], imported: [],
                                                             userEditedDays: [])
            XCTAssertEqual(SleepModel.nightNeeds(days: repo.resolvingStrain(afterPass), importedSleep: [:],
                                                 only: ["2026-10-11"]).needMin["2026-10-11"], plan.needMin)
        }
    }

    /// A night imported from WHOOP keeps WHOOP's own need, which already holds Strain and debt.
    @MainActor
    func testAnImportedNightKeepsWhoopsNeed() {
        withYoopScores(true) {
            let imported = ["2026-10-11": ImportedSleepFigures(performancePct: nil, consistencyPct: nil,
                                                               needMin: 548, debtMin: nil)]
            let needs = SleepModel.nightNeeds(days: morning, importedSleep: imported)
            XCTAssertEqual(needs.needMin["2026-10-11"], 548)
            XCTAssertNil(needs.planned["2026-10-11"])
            XCTAssertEqual(SleepModel.hoursVsNeededSeries(days: morning, importedSleep: imported).series.last ?? 0,
                           416 / 548 * 100, accuracy: 1e-9)
        }
    }

    /// Without Yoop's scores every night is measured against the personal-mean need, as before.
    @MainActor
    func testWithoutYoopsScoresTheNeedIsUnchanged() {
        withYoopScores(false) {
            let needs = SleepModel.nightNeeds(days: morning, importedSleep: [:])
            XCTAssertTrue(needs.planned.isEmpty)
            XCTAssertEqual(needs.needMin["2026-10-11"], SleepModel.sleepNeedMin(days: morning))
            XCTAssertEqual(SleepModel.hoursVsNeededSeries(days: morning, importedSleep: [:]).series.last ?? 0,
                           416 / SleepModel.sleepNeedMin(days: morning) * 100, accuracy: 1e-9)
        }
    }

    // MARK: The engine's view of the days

    /// A scored day is merged under its import as `Repository.mergeDaily` merges it; other days stay as shown.
    func testDaysAfterPassMergesEachScoredDayUnderItsImport() {
        let shown = [day("2026-10-09", asleep: 400, strain21: 12), day("2026-10-10", asleep: 410, strain21: 14)]
        let importRow = day("2026-10-10", asleep: 425, strain21: nil)
        let scored = [day("2026-10-10", asleep: 300, strain21: 17), day("2026-10-11", asleep: 416, strain21: 2)]
        let after = IntelligenceEngine.daysAfterPass(shown: shown, scored: scored, imported: [importRow],
                                                     userEditedDays: [])
        XCTAssertEqual(after.map(\.day), ["2026-10-09", "2026-10-10", "2026-10-11"])
        XCTAssertEqual(after[0], shown[0])
        XCTAssertEqual(after[1].totalSleepMin, 425, "the import's sleep wins")
        XCTAssertEqual(after[1].strain, stored(17), "the pass fills what the import lacks")
        XCTAssertEqual(after[2], scored[1])
        let edited = IntelligenceEngine.daysAfterPass(shown: shown, scored: scored, imported: [importRow],
                                                      userEditedDays: ["2026-10-10"])
        XCTAssertEqual(edited[1].totalSleepMin, 300, "an edited night keeps its computed sleep")
    }
}
