import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Yoop's muscle load (`MuscleLoad`, `StrainBook`): the CR-10 table, the rated load on Strain's own curve,
/// the personal calibration, when a session gets no muscle load, the sanity numbers of the 10 Oct lifting
/// session, and the Repository funnel every Strain readout goes through.
final class MuscleLoadTests: XCTestCase {

    /// Stored (0-100) Strain for a figure on WHOOP's 0-21 axis.
    private func stored(_ strain21: Double) -> Double {
        StrainScorer.effortValue(fromWhoopStrain: strain21)
    }

    /// A figure on WHOOP's 0-21 axis for a stored Strain.
    private func shown(_ stored: Double?) -> Double? {
        stored.map { UnitFormatter.effortValue($0, scale: .whoop) }
    }

    private func row(_ start: Int, sport: String, minutes: Int = 45, strain21: Double? = 11.0,
                     source: String = "manual") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: source,
                   durationS: Double(minutes * 60), energyKcal: nil, avgHr: nil, maxHr: nil,
                   strain: strain21.map { stored($0) }, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private let now = 1_760_000_000
    private let dayKey: (Int) -> String = { _ in "2026-10-10" }

    // MARK: CR-10 table

    func testTheTableHitsItsAnchorsAndJoinsThemWithStraightLines() {
        let anchors: [(Double, Double)] = [(0, 0), (2, 0.35), (4, 0.50), (6, 0.70), (8, 0.85), (10, 0.95)]
        for (effort, reserve) in anchors {
            XCTAssertEqual(MuscleLoad.reserveFraction(effort: effort), reserve, accuracy: 1e-12)
        }
        XCTAssertEqual(MuscleLoad.reserveFraction(effort: 1), 0.175, accuracy: 1e-12)
        XCTAssertEqual(MuscleLoad.reserveFraction(effort: 5), 0.60, accuracy: 1e-12)
        XCTAssertEqual(MuscleLoad.reserveFraction(effort: 7), 0.775, accuracy: 1e-12)
        XCTAssertEqual(MuscleLoad.reserveFraction(effort: 9), 0.90, accuracy: 1e-12)
        XCTAssertEqual(MuscleLoad.reserveFraction(effort: -3), 0, "below the scale reads as its bottom")
        XCTAssertEqual(MuscleLoad.reserveFraction(effort: 14), 0.95, accuracy: 1e-12, "above it, as its top")
    }

    // MARK: Rated load

    func testRatedLoadIsMinutesAtTheRatingsReserveOnStrainsCurve() {
        let perMinute = StrainScorer.whoopMinuteLoad(reserve: 0.775)
        XCTAssertEqual(MuscleLoad.ratedLoad(effort: 7, minutes: 45), 45 * perMinute, accuracy: 1e-9)
        XCTAssertEqual(MuscleLoad.ratedLoad(effort: 7, minutes: 45), 773.6, accuracy: 0.5)
        XCTAssertEqual(MuscleLoad.ratedLoad(effort: 0, minutes: 45), 0)
        XCTAssertEqual(MuscleLoad.ratedLoad(effort: 7, minutes: 0), 0)
        let loads = (0...10).map { MuscleLoad.ratedLoad(effort: $0, minutes: 45) }
        XCTAssertEqual(loads, loads.sorted(), "a harder rating never loads less")
    }

    func testHeartLoadIsTheLoadBehindTheStoredStrain() {
        XCTAssertEqual(MuscleLoad.heartLoad(storedStrain: stored(11.0)), 235.6, accuracy: 0.5)
        XCTAssertEqual(MuscleLoad.heartLoad(storedStrain: stored(17.7)), 1590.9, accuracy: 1)
        XCTAssertEqual(MuscleLoad.heartLoad(storedStrain: nil), 0)
        XCTAssertEqual(MuscleLoad.heartLoad(storedStrain: 0), 0)
    }

    // MARK: Calibration

    func testCalibrationNeedsThreeRatingsAndIsClamped() {
        XCTAssertEqual(MuscleLoad.calibration(ratios: []), 1)
        XCTAssertEqual(MuscleLoad.calibration(ratios: [1.6, 1.7]), 1, "fewer than three leaves k at 1")
        XCTAssertEqual(MuscleLoad.calibration(ratios: [1.2, 0.8, 1.0]), 1.0, accuracy: 1e-12, "the median")
        XCTAssertEqual(MuscleLoad.calibration(ratios: [0.6, 0.7, 0.9, 1.1]), 0.8, accuracy: 1e-12)
        XCTAssertEqual(MuscleLoad.calibration(ratios: [3, 4, 5]), 2.0, "clamped at double")
        XCTAssertEqual(MuscleLoad.calibration(ratios: [0.1, 0.2, 0.3]), 0.5, "clamped at half")
        XCTAssertEqual(MuscleLoad.calibration(ratios: [.nan, 0, 1.2]), 1, "non-readings do not count")
    }

    func testCalibrationReadsRatedSessionsThatAreNotStrengthFromTheLast90Days() {
        // Three rated runs whose heart load is half of what their rating implies: k = 0.5.
        var rows: [WorkoutRow] = []
        var efforts: [Int: Int] = [:]
        let runLoad = MuscleLoad.ratedLoad(effort: 6, minutes: 45)
        let runStrain = StrainScorer.whoopStrain(load: runLoad / 2)
        for i in 1...3 {
            let r = row(now - i * 86_400, sport: "Running", strain21: runStrain)
            rows.append(r)
            efforts[r.startTs] = 6
        }
        // One older than the window and one strength session, neither of which may count.
        let old = row(now - 120 * 86_400, sport: "Running", strain21: 18)
        let lift = row(now - 3_600, sport: "Weightlifting")
        rows += [old, lift]
        efforts[old.startTs] = 2
        efforts[lift.startTs] = 8

        let book = StrainBook.build(rows: rows, efforts: efforts, now: now, dayKey: dayKey)
        XCTAssertEqual(book.calibration, 0.5, accuracy: 1e-9)
        let expected = max(0, book.calibration * MuscleLoad.ratedLoad(effort: 8, minutes: 45)
                                - MuscleLoad.heartLoad(storedStrain: lift.strain))
        XCTAssertEqual(book.splits[lift.startTs]?.muscleLoad ?? -1, expected, accuracy: 1e-9)
        XCTAssertEqual(book.splits[rows[0].startTs]?.muscleLoad, 0, "a run gets no muscle load, only calibrates")
    }

    // MARK: When there is none

    func testAnUnratedSessionGetsNoMuscleLoad() {
        let lift = row(now - 3_600, sport: "Weightlifting")
        let book = StrainBook.build(rows: [lift], efforts: [:], now: now, dayKey: dayKey)
        XCTAssertEqual(book, .empty)
        XCTAssertEqual(book.activityStrain(lift), lift.strain)
        XCTAssertEqual(book.dayStrain(day: "2026-10-10", stored: stored(17.7), live: nil), stored(17.7))
    }

    // MARK: The default for an unrated strength session

    /// Yoop: the load grows with the square of the session's length, up to the lengths it was fitted on.
    func testTheDefaultLoadGrowsWithTheSquareOfTheLengthAndIsCapped() {
        XCTAssertEqual(MuscleLoad.durationLoad(minutes: 0), 0)
        XCTAssertEqual(MuscleLoad.durationLoad(minutes: 45), 0.0773 * 45 * 45, accuracy: 1e-9)
        XCTAssertEqual(MuscleLoad.durationLoad(minutes: 30) * 4, MuscleLoad.durationLoad(minutes: 60), accuracy: 1e-9)
        XCTAssertEqual(MuscleLoad.durationLoad(minutes: 150), MuscleLoad.durationLoad(minutes: 60), "capped at 60 minutes")
    }

    /// Fitted to WHOOP's own Activity Strain on this user's 36 lifting sessions: a 47 minute session whose heart
    /// rate alone gives 6.7 reads about 11.0 (WHOOP's sessions of 44 to 53 minutes read 10.6 to 12.5).
    func testAnUnratedLiftReadsAboutWhatWHOOPGivesIt() {
        let lift = row(now - 3_600, sport: "Weightlifting", minutes: 47, strain21: 6.7)
        let book = StrainBook.build(rows: [lift], efforts: [:], now: now, dayKey: dayKey, unratedStrengthDefault: true)
        let split = book.splits[lift.startTs]
        XCTAssertEqual(split?.isEstimate, true)
        XCTAssertEqual(split?.heartStrain ?? 0, 6.7, accuracy: 1e-6)
        XCTAssertEqual(shown(book.activityStrain(lift)) ?? 0, 11.0, accuracy: 0.1)
        XCTAssertGreaterThan(shown(book.dayStrain(day: "2026-10-10", stored: stored(8), live: nil)) ?? 0, 8)
        XCTAssertEqual(book.muscleByDay["2026-10-10"] ?? 0, MuscleLoad.durationLoad(minutes: 47), accuracy: 1e-9)
    }

    /// The default is only for Yoop's own unrated strength sessions: not asked for, not a rated one, not an
    /// import (which already holds WHOOP's own muscular load), not another sport.
    func testTheDefaultIsOnlyForYoopsOwnUnratedStrength() {
        let lift = row(now - 3_600, sport: "Weightlifting")
        XCTAssertEqual(StrainBook.build(rows: [lift], efforts: [:], now: now, dayKey: dayKey), .empty)
        let run = row(now - 7_200, sport: "Running")
        let imported = row(now - 10_800, sport: "Weightlifting", source: "my-whoop")
        let rated = row(now - 14_400, sport: "Weightlifting")
        let book = StrainBook.build(rows: [lift, run, imported, rated], efforts: [rated.startTs: 8], now: now,
                                    dayKey: dayKey, unratedStrengthDefault: true)
        XCTAssertEqual(book.splits[lift.startTs]?.isEstimate, true)
        XCTAssertNil(book.splits[run.startTs])
        XCTAssertNil(book.splits[imported.startTs])
        XCTAssertEqual(book.splits[rated.startTs]?.isEstimate, false, "a rating is used as before")
        XCTAssertEqual(book.splits[rated.startTs]?.effort, 8)
    }

    func testNoMuscleLoadWhenHeartRateAlreadyCoversTheRating() {
        // Rated 4 ("somewhat hard") for 45 minutes is a rated load of about 153, under the 236 heart rate measured.
        let lift = row(now - 3_600, sport: "Weightlifting")
        let book = StrainBook.build(rows: [lift], efforts: [lift.startTs: 4], now: now, dayKey: dayKey)
        XCTAssertEqual(book.splits[lift.startTs]?.muscleLoad, 0)
        XCTAssertEqual(book.activityStrain(lift), lift.strain)
        XCTAssertTrue(book.muscleByDay.isEmpty)
    }

    func testOnlyStrengthSessionsAndOnlyYoopsOwnGetMuscleLoad() {
        let run = row(now - 7_200, sport: "Running")
        let imported = row(now - 3_600, sport: "Weightlifting", source: "my-whoop")
        let book = StrainBook.build(rows: [run, imported], efforts: [run.startTs: 9, imported.startTs: 9],
                                    now: now, dayKey: dayKey)
        XCTAssertEqual(book.splits[run.startTs]?.muscleLoad, 0)
        XCTAssertNil(book.splits[imported.startTs], "imported history cannot be rated")
        XCTAssertTrue(book.muscleByDay.isEmpty)
    }

    func testStrengthTypesMatchWhateverTheirCaseAndSpacing() {
        for sport in ["Weightlifting", "weightlifting", "Powerlifting", "Strength Trainer", "StrengthTrainer",
                      "Functional Fitness", "CrossFit", "Weight Training", "Strength", "Strength Training",
                      "TraditionalStrengthTraining", "Bodybuilding", "Calisthenics"] {
            XCTAssertTrue(MuscleLoad.isStrength(sport), sport)
        }
        for sport in ["Running", "Activity", "Tennis", "Yoga", "HIIT"] {
            XCTAssertFalse(MuscleLoad.isStrength(sport), sport)
        }
        XCTAssertTrue(MuscleLoad.isRateable(row(0, sport: "Weightlifting", source: "manual")))
        XCTAssertTrue(MuscleLoad.isRateable(row(0, sport: "Weightlifting", source: "my-whoop-noop")))
        XCTAssertFalse(MuscleLoad.isRateable(row(0, sport: "Weightlifting", source: "my-whoop")))
        XCTAssertFalse(MuscleLoad.isRateable(row(0, sport: "Weightlifting", source: "apple-health")))
    }

    // MARK: Sanity numbers: the 45 minute lifting session of 2026-10-10

    /// The session scored 11.0 from heart rate (a load of about 236) on a day of 17.7 (about 1590). The
    /// brief expected a rating of 7 to land near 14 and the day at 18.3 to 18.5; on the specified table a
    /// rating of 6 is the nearer (13.7 and 18.3 on the refitted curve of 15 Oct 2026, 14.3 and 18.4 on the
    /// first), since 7 sits at 0.775 of the reserve. Both are pinned so a change to the table or the curve
    /// shows here.
    func testSanityNumbersOfThe10OctLiftingSession() {
        let lift = row(now - 3_600, sport: "Weightlifting")
        let day = stored(17.7)

        let six = StrainBook.build(rows: [lift], efforts: [lift.startTs: 6], now: now, dayKey: dayKey)
        XCTAssertEqual(shown(six.activityStrain(lift)) ?? 0, 13.7, accuracy: 0.1)
        let daySix = shown(six.dayStrain(day: "2026-10-10", stored: day, live: nil)) ?? 0
        XCTAssertEqual(daySix, 18.27, accuracy: 0.05)

        let seven = StrainBook.build(rows: [lift], efforts: [lift.startTs: 7], now: now, dayKey: dayKey)
        XCTAssertEqual(shown(seven.activityStrain(lift)) ?? 0, 15.1, accuracy: 0.1)
        XCTAssertEqual(shown(seven.dayStrain(day: "2026-10-10", stored: day, live: nil)) ?? 0, 18.7, accuracy: 0.1)

        // The split adds up: heart 11.0 plus the muscle part is the activity's Strain.
        let split = six.splits[lift.startTs]
        XCTAssertEqual(split?.heartStrain ?? 0, 11.0, accuracy: 1e-6)
        XCTAssertEqual((split?.heartStrain ?? 0) + (split?.muscleStrain ?? 0), shown(six.activityStrain(lift)) ?? 0,
                       accuracy: 1e-6)
        XCTAssertEqual(split?.effort, 6)
    }

    func testDayStrainStillCapsAt21() {
        let lift = row(now - 3_600, sport: "Weightlifting", minutes: 120)
        let book = StrainBook.build(rows: [lift], efforts: [lift.startTs: 10], now: now, dayKey: dayKey)
        XCTAssertEqual(book.dayStrain(day: "2026-10-10", stored: stored(20.5), live: nil) ?? 0, StrainScorer.maxStrain,
                       accuracy: 1e-9)
    }

    // MARK: One resolver

    private func dayRow(_ key: String, strain: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 230,
                    disturbances: 1, restingHr: 50, avgHrv: 80, recovery: 60, strain: strain, exerciseCount: 1)
    }

    /// Every series reader (`resolved`) shows each day exactly as the single-day resolver does, live value
    /// and muscle load included, and leaves every other field alone.
    func testTheSeriesAndTheSingleDayResolveIdentically() {
        let lift = row(now - 3_600, sport: "Weightlifting")
        let book = StrainBook.build(rows: [lift], efforts: [lift.startTs: 7], now: now) { _ in "2026-10-10" }
        let days = [dayRow("2026-10-08", strain: stored(9)), dayRow("2026-10-09", strain: nil),
                    dayRow("2026-10-10", strain: stored(15)), dayRow("2026-10-11", strain: stored(3))]
        let live = LiveDayStrain(day: "2026-10-11", value: stored(6))
        let resolved = book.resolved(days, live: live)
        XCTAssertEqual(resolved.map(\.day), days.map(\.day))
        for (shownDay, storedDay) in zip(resolved, days) {
            XCTAssertEqual(shownDay.strain, book.dayStrain(day: storedDay.day, stored: storedDay.strain, live: live))
            XCTAssertEqual(shownDay.with(strain: storedDay.strain), storedDay, "only Strain changes")
        }
        XCTAssertEqual(resolved[0], days[0], "a day nothing touches is the same row")
        XCTAssertEqual(shown(resolved[3].strain) ?? 0, 6, accuracy: 1e-9, "the live value beats the stored row")
        XCTAssertGreaterThan(resolved[2].strain ?? 0, days[2].strain ?? 0, "the rated lift lifts its day")
    }

    // MARK: The ratings store

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "MuscleLoadTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testTheRatingsStoreSetsClampsMovesAndClears() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ActivityEffortStore(defaults: defaults)
        XCTAssertNil(store.effort(startTs: 100))
        store.set(7, startTs: 100)
        store.set(14, startTs: 200)
        XCTAssertEqual(store.all, [100: 7, 200: 10])
        store.move(from: 100, to: 160)
        XCTAssertEqual(store.all, [160: 7, 200: 10])
        store.move(from: 999, to: 1_000)
        XCTAssertEqual(store.all, [160: 7, 200: 10], "nothing rated, nothing moves")
        store.set(nil, startTs: 160)
        store.set(nil, startTs: 200)
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertNil(defaults.object(forKey: ActivityEffortStore.key))
    }

    // MARK: Repository

    /// Runs `body` with Yoop's scores on the WHOOP curve (`on`) or off, restoring the switches after.
    @MainActor
    private func withMuscleLoad(_ on: Bool, _ body: () async throws -> Void) async rethrows {
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
        try await body()
    }

    @MainActor
    func testTheRepositoryFunnelCarriesARatingAndDropsItWithItsActivity() async throws {
        try await withMuscleLoad(true) {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            let deviceId = "my-whoop"
            let store = try await WhoopStore.inMemory()
            let start = Int(Date().timeIntervalSince1970) - 4 * 3_600
            let lift = row(start, sport: "Weightlifting")
            _ = try await store.upsertWorkouts([lift], deviceId: deviceId)
            let repo = Repository(deviceId: deviceId)
            repo.setStoreForTesting(store)
            repo.activityEffortStore = ActivityEffortStore(defaults: defaults)
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))

            await repo.setActivityEffort(6, for: lift)
            XCTAssertEqual(repo.activityEffort(lift), 6)
            XCTAssertEqual(shown(repo.activityStrain(lift)) ?? 0, 13.7, accuracy: 0.1)
            XCTAssertEqual(shown(repo.dayStrain(day: key, stored: stored(17.7))) ?? 0, 18.3, accuracy: 0.1)
            XCTAssertEqual(repo.strainBook.splits[lift.startTs]?.effort, 6)

            // A re-save under a new start (an edit, or a detected bout moved) takes the rating along.
            let moved = row(start + 60, sport: "Weightlifting")
            await repo.saveManualWorkout(moved, replacing: lift)
            XCTAssertNil(repo.activityEffort(lift))
            XCTAssertEqual(repo.activityEffort(moved), 6)

            // Deleting the activity drops its rating and what it added.
            await repo.deleteWorkout(moved)
            XCTAssertNil(repo.activityEffort(moved))
            XCTAssertEqual(repo.strainBook, .empty)
            XCTAssertEqual(repo.activityStrain(moved), moved.strain)
            XCTAssertEqual(repo.dayStrain(day: key, stored: stored(17.7)), stored(17.7))
        }
    }

    @MainActor
    func testWithoutYoopsScoresEveryResolverReturnsTheStoredValue() async throws {
        try await withMuscleLoad(false) {
            let (defaults, name) = scratchDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            let store = try await WhoopStore.inMemory()
            let start = Int(Date().timeIntervalSince1970) - 4 * 3_600
            let lift = row(start, sport: "Weightlifting")
            _ = try await store.upsertWorkouts([lift], deviceId: "my-whoop")
            let repo = Repository(deviceId: "my-whoop")
            repo.setStoreForTesting(store)
            repo.activityEffortStore = ActivityEffortStore(defaults: defaults)

            await repo.setActivityEffort(9, for: lift)
            repo.noteLiveDayStrain(day: "2026-10-10", value: stored(19))
            XCTAssertEqual(repo.strainBook, .empty)
            XCTAssertEqual(repo.activityStrain(lift), lift.strain)
            XCTAssertEqual(repo.dayStrain(day: "2026-10-10", stored: stored(12)), stored(12))
        }
    }
}
