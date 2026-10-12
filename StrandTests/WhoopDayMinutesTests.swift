import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// Which minutes of a day the energy pricing treats as a logged strength session's: the ones whose step
/// ticks are arm motion, not walking. The pricing itself is tested in `YoopStepsEnergyTests`.
@MainActor
final class WhoopDayMinutesTests: XCTestCase {
    private func row(_ sport: String, _ start: Int, _ end: Int, source: String = "manual") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source, durationS: Double(end - start),
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                   notes: nil, steps: nil)
    }

    private let base = 1_800_000_000 - 1_800_000_000 % 3_600

    func testOnlyStrengthSessionsAreHeartPriced() {
        let rows = [row("Weightlifting", base, base + 3_000), row("Running", base + 4_000, base + 5_000),
                    row("Basketball", base + 6_000, base + 7_000),
                    row("Traditional Strength Training", base + 8_000, base + 9_000, source: "apple-health")]
        let windows = WhoopDayMinutes.strengthWindows(workouts: rows, from: base - 100, to: base + 20_000)
        XCTAssertEqual(windows.map(\.start), [base, base + 8_000])
        XCTAssertEqual(windows.map(\.end), [base + 3_000, base + 9_000])
    }

    func testEveryStrengthSportOfTheMuscleLoadListCounts() {
        // The one list: a sport added to `MuscleLoad.strengthSports` is heart-priced with no second edit here.
        XCTAssertFalse(MuscleLoad.strengthSports.isEmpty)
        for sport in MuscleLoad.strengthSports {
            let windows = WhoopDayMinutes.strengthWindows(workouts: [row(sport, base, base + 600)],
                                                         from: base, to: base + 3_600)
            XCTAssertEqual(windows.count, 1, sport)
        }
        XCTAssertTrue(WhoopDayMinutes.strengthWindows(workouts: [row("Running", base, base + 600)],
                                                     from: base, to: base + 3_600).isEmpty)
    }

    func testAWindowIsClippedToTheDaysWindow() {
        let windows = WhoopDayMinutes.strengthWindows(workouts: [row("Weightlifting", base - 600, base + 1_200)],
                                                     from: base, to: base + 900)
        XCTAssertEqual(windows.map(\.start), [base])
        XCTAssertEqual(windows.map(\.end), [base + 900])
        // Out of the window altogether is out of the day.
        XCTAssertTrue(WhoopDayMinutes.strengthWindows(workouts: [row("Weightlifting", base + 2_000, base + 3_000)],
                                                     from: base, to: base + 900).isEmpty)
    }

    func testTheMinutesAreTheOnesTheSessionTouches() {
        // 13:29:00 to 14:23:00 touches the minutes 13:29 to 14:22, which are 54.
        let start = base + 29 * 60, end = base + 83 * 60
        let minutes = WhoopDayMinutes.heartPricedMinutes([(start: start, end: end)])
        XCTAssertEqual(minutes.count, 54)
        XCTAssertEqual(minutes.min(), start / 60)
        XCTAssertEqual(minutes.max(), end / 60 - 1)
        // A session ending 30 s into a minute touches that minute, and one starting mid-minute its start's.
        let ragged = WhoopDayMinutes.heartPricedMinutes([(start: start + 30, end: end + 30)])
        XCTAssertEqual(ragged.min(), start / 60)
        XCTAssertEqual(ragged.max(), end / 60)
        XCTAssertTrue(WhoopDayMinutes.heartPricedMinutes([]).isEmpty)
    }

    func testADayWithNoStrengthSessionHasNoHeartPricedMinutes() {
        // 9 and 11 Oct had walks and nothing; their energy is priced exactly as before.
        let rows = [row("Walking", base, base + 3_000), row("Walking", base + 4_000, base + 5_000)]
        XCTAssertTrue(WhoopDayMinutes.heartPricedMinutes(
            WhoopDayMinutes.strengthWindows(workouts: rows, from: base - 100, to: base + 20_000)).isEmpty)
    }
}
