import XCTest
import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Yoop prices each activity it recorded or detected by the one WHOOP-fitted heart-rate line
/// (`IntelligenceEngine.repricedActivities`), so an activity's page, the workout list and its share of the
/// day on the Calories page state one number.
@MainActor
final class RepriceOwnActivitiesTests: XCTestCase {
    private let base = 1_800_000_000 - 1_800_000_000 % 3_600

    private func row(_ sport: String, _ start: Int, _ end: Int, source: String = "manual",
                     kcal: Double? = 404.5) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source, durationS: Double(end - start),
                   energyKcal: kcal, avgHr: 98, maxHr: 141, strain: 7.4, distanceM: nil, zonesJSON: nil,
                   notes: "kept", steps: nil)
    }

    /// A strap that read `bpm` every second for the whole of `[base, base + 4 hours)`.
    private func strap(_ bpm: Int) -> (Int, Int) async -> [HRSample] {
        let start = base, end = base + 14_400
        return { from, to in
            let lo = max(from, start), hi = min(to, end)
            guard hi >= lo else { return [] }
            return (lo...hi).map { HRSample(ts: $0, bpm: bpm) }
        }
    }

    func testAnOwnActivityIsPricedByTheLineAndKeepsEveryOtherField() async {
        let own = row("Weightlifting", base + 1_830, base + 5_370)   // 30 s into minutes 30 and 89
        let updated = await IntelligenceEngine.repricedActivities([own], hrSamples: strap(110))
        XCTAssertEqual(updated.count, 1)
        let priced = updated[0]
        let minutes = Double(60)   // minutes 30 to 89, each counted whole
        XCTAssertEqual(priced.energyKcal ?? 0, (0.1988 * 110 - 16.43) * minutes, accuracy: 1e-9)
        XCTAssertEqual(priced.startTs, own.startTs)
        XCTAssertEqual(priced.endTs, own.endTs)
        XCTAssertEqual(priced.sport, own.sport)
        XCTAssertEqual(priced.source, "manual")
        XCTAssertEqual(priced.avgHr, 98)
        XCTAssertEqual(priced.maxHr, 141)
        XCTAssertEqual(priced.strain, 7.4)
        XCTAssertEqual(priced.notes, "kept")
    }

    func testItIsIdempotent() async {
        let own = row("Walking", base + 600, base + 3_600)
        let first = await IntelligenceEngine.repricedActivities([own], hrSamples: strap(100))
        let second = await IntelligenceEngine.repricedActivities(first, hrSamples: strap(100))
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
    }

    func testActivitiesFromOtherSourcesKeepTheirOwnEnergy() async {
        let rows = [row("Running", base, base + 3_000, source: "whoop", kcal: 670),
                    row("Running", base, base + 3_000, source: "apple-health", kcal: 488.7),
                    row("Weightlifting", base, base + 3_000, source: "lifting", kcal: nil)]
        let updated = await IntelligenceEngine.repricedActivities(rows, hrSamples: strap(150))
        XCTAssertTrue(updated.isEmpty)
    }

    func testAnActivityWithoutStrapHeartRateKeepsItsEnergy() async {
        let typed = row("Padel", base + 20_000, base + 23_000, kcal: 500)   // after the strap's readings end
        let updated = await IntelligenceEngine.repricedActivities([typed], hrSamples: strap(150))
        XCTAssertTrue(updated.isEmpty)
        // One reading is not a window.
        let lone = await IntelligenceEngine.repricedActivities(
            [typed], hrSamples: { _, _ in [HRSample(ts: base + 20_100, bpm: 150)] })
        XCTAssertTrue(lone.isEmpty)
    }

    func testAnActivityBelowTheLinesZeroHasNoEnergy() async {
        let calm = row("Walking", base + 600, base + 3_600, kcal: 161.9)
        let updated = await IntelligenceEngine.repricedActivities([calm], hrSamples: strap(80))
        XCTAssertEqual(updated.count, 1)
        XCTAssertNil(updated[0].energyKcal)
        // And an activity with none stays as it is.
        let none = row("Walking", base + 600, base + 3_600, kcal: nil)
        let again = await IntelligenceEngine.repricedActivities([none], hrSamples: strap(80))
        XCTAssertTrue(again.isEmpty)
    }

    func testTheHeartRateIsReadFromWholeMinutesAtBothEnds() async {
        var asked: [(Int, Int)] = []
        let start = base + 1_830, end = base + 5_370   // 30 s into a minute at both ends
        _ = await IntelligenceEngine.repricedActivities([row("Walking", start, end)], hrSamples: { from, to in
            asked.append((from, to))
            return []
        })
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].0, start / 60 * 60)
        XCTAssertEqual(asked[0].1, (end - 1) / 60 * 60 + 59)
    }
}
