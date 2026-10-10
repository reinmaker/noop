import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// The WHOOP-style activity page's figures: zone edges from the resting rate and the 190 bpm yardstick,
/// time per zone from the heart rate, the sport's typical range per zone, and the same-sport comparisons.
final class WhoopActivityStatsTests: XCTestCase {

    private func row(_ start: Int, sport: String = "Running", strain: Double? = nil, kcal: Double? = nil,
                     steps: Int? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1800, sport: sport, source: "manual", durationS: 1800,
                   energyKcal: kcal, avgHr: nil, maxHr: nil, strain: strain, distanceM: nil, zonesJSON: nil,
                   notes: nil, steps: steps)
    }

    private func day(_ key: String, rest: Int?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rest, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
    }

    // MARK: Zone edges

    /// The user's WHOOP page with a resting rate of 50: Z2 134-147, Z3 148-161, Z4 162-175, Z5 176+.
    func testEdgesMatchWhoopAtRestFifty() {
        XCTAssertEqual(WhoopActivityZones.lowerBounds(restingHR: 50), [120, 134, 148, 162, 176])
        let ranges = WhoopActivityZones.bpmRanges(restingHR: 50)
        XCTAssertEqual(ranges?.count, 6)
        XCTAssertEqual(ranges?[0], .init(lower: nil, upper: 119))
        XCTAssertEqual(ranges?[1], .init(lower: 120, upper: 133))
        XCTAssertEqual(ranges?[2], .init(lower: 134, upper: 147))
        XCTAssertEqual(ranges?[3], .init(lower: 148, upper: 161))
        XCTAssertEqual(ranges?[4], .init(lower: 162, upper: 175))
        XCTAssertEqual(ranges?[5], .init(lower: 176, upper: nil))
        XCTAssertEqual(WhoopActivityScreen.bpmText(ranges![5]), "176+ " + String(localized: "BPM"))
        XCTAssertEqual(WhoopActivityScreen.bpmText(ranges![0]), "<120 " + String(localized: "BPM"))
    }

    /// A fractional edge rounds up to the first whole bpm that reaches it, and the zones follow the rest.
    func testEdgesRoundUpAndMoveWithRest() {
        // 52 + p * 138: 121, 134.8, 148.6, 162.4, 176.2.
        XCTAssertEqual(WhoopActivityZones.lowerBounds(restingHR: 52), [121, 135, 149, 163, 177])
        // Another yardstick moves them too: 60 + p * 120.
        XCTAssertEqual(WhoopActivityZones.lowerBounds(restingHR: 60, maxHR: 180), [120, 132, 144, 156, 168])
    }

    func testNoZonesWithoutRoomForThem() {
        XCTAssertNil(WhoopActivityZones.lowerBounds(restingHR: 0))
        XCTAssertNil(WhoopActivityZones.lowerBounds(restingHR: 190))
        XCTAssertNil(WhoopActivityZones.lowerBounds(restingHR: 188))
        XCTAssertNil(WhoopActivityZones.bpmRanges(restingHR: 200))
    }

    // MARK: Time per zone

    /// Ten one-second readings in each band; the readings outside the window are left out.
    func testSecondsPerBandFromReadings() {
        let start = 1_000_000
        let levels = [100, 125, 140, 150, 170, 180]
        var samples: [HRSample] = [HRSample(ts: start - 5, bpm: 185)]
        for (i, bpm) in levels.enumerated() {
            for s in 0..<10 { samples.append(HRSample(ts: start + i * 10 + s, bpm: bpm)) }
        }
        samples.append(HRSample(ts: start + 200, bpm: 185))
        let seconds = WhoopActivityZones.bandSeconds(samples, from: start, to: start + 59, restingHR: 50)
        XCTAssertEqual(seconds, [10, 10, 10, 10, 10, 10])
        let shares = WhoopActivityZones.shares(seconds ?? [])
        XCTAssertEqual(shares?.reduce(0, +) ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(shares?[5] ?? 0, 1.0 / 6, accuracy: 1e-9)
    }

    /// A zone starts at its edge: 176 is zone 5, 175 zone 4, 120 zone 1, 119 restorative.
    func testEdgesAreInclusive() {
        let start = 2_000_000
        let samples = [119, 120, 175, 176].enumerated().map { HRSample(ts: start + $0.offset, bpm: $0.element) }
        let seconds = WhoopActivityZones.bandSeconds(samples, from: start, to: start + 3, restingHR: 50)
        XCTAssertEqual(seconds, [1, 1, 0, 0, 1, 1])
    }

    /// A dropout is not credited to the zone before it.
    func testGapIsNotCountedAsTimeInZone() {
        let start = 3_000_000
        var samples = (0..<30).map { HRSample(ts: start + $0, bpm: 180) }
        samples += (0..<30).map { HRSample(ts: start + 600 + $0, bpm: 100) }
        let seconds = WhoopActivityZones.bandSeconds(samples, from: start, to: start + 700, restingHR: 50)
        XCTAssertEqual(seconds?[5], 30)
        XCTAssertEqual(seconds?[0], 30)
    }

    func testNoSecondsWithoutReadings() {
        XCTAssertNil(WhoopActivityZones.bandSeconds([], from: 0, to: 100, restingHR: 50))
        XCTAssertNil(WhoopActivityZones.bandSeconds([HRSample(ts: 500, bpm: 150)], from: 0, to: 100, restingHR: 50))
        XCTAssertNil(WhoopActivityZones.shares([0, 0, 0, 0, 0, 0]))
    }

    /// WHOOP's export leaves the time under zone 1 out; it comes back as restorative.
    func testImportedPercentsLeaveRestorativeAsTheRest() {
        let shares = WhoopActivityZones.shares(importedPercents: [10, 20, 30, 20, 10])
        XCTAssertEqual(shares?.count, 6)
        XCTAssertEqual(shares?[0] ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(shares?[3] ?? -1, 0.3, accuracy: 1e-9)
        // Rounding past 100 leaves no restorative and still sums to one.
        let over = WhoopActivityZones.shares(importedPercents: [30, 30, 30, 10, 2])
        XCTAssertEqual(over?[0], 0)
        XCTAssertEqual(over?.reduce(0, +) ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(WhoopActivityZones.shares(importedPercents: [10, 20]))
    }

    // MARK: Typical range

    func testTypicalRangeIsLowestToHighestShare() {
        let ranges = WhoopActivityZones.typicalRanges([
            [0.1, 0.1, 0.2, 0.3, 0.2, 0.1],
            [0.0, 0.2, 0.1, 0.4, 0.2, 0.1],
            [0.2, 0.1],   // malformed, ignored
        ])
        XCTAssertEqual(ranges.count, 6)
        XCTAssertEqual(ranges[0], 0.0...0.1)
        XCTAssertEqual(ranges[3], 0.3...0.4)
        XCTAssertEqual(ranges[5], 0.1...0.1)
        XCTAssertTrue(WhoopActivityZones.typicalRanges([]).allSatisfy { $0 == nil })
    }

    // MARK: Resting rate

    func testRestingRatePrefersTheDayThenTheFourteenDayMedian() {
        let days = (1...20).map { day(String(format: "2026-09-%02d", $0), rest: 40 + $0) }
            + [day("2026-09-21", rest: nil)]
        XCTAssertEqual(WhoopActivityZones.restingHR(dayKey: "2026-09-10", days: days), 50)
        // No rest that day: the median of the 14 days up to it (09-08 to 09-21, rests 48...60).
        XCTAssertEqual(WhoopActivityZones.restingHR(dayKey: "2026-09-21", days: days), 54)
        // An even count takes the mean of the middle two (09-20 also unmeasured, rests 48...59).
        XCTAssertEqual(WhoopActivityZones.restingHR(dayKey: "2026-09-21", days: days.map {
            $0.day == "2026-09-20" ? day($0.day, rest: nil) : $0 }), 53.5)
        // Before every stored day: the latest 14.
        XCTAssertEqual(WhoopActivityZones.restingHR(dayKey: "2026-08-01", days: days), 54)
        XCTAssertEqual(WhoopActivityZones.restingHR(dayKey: "2026-09-10", days: []), StrainScorer.defaultRestingHR)
    }

    // MARK: Same-sport comparisons

    func testTypicalUsesTheLastThirtyDaysOfTheSameSport() {
        let now = 1_800_000_000
        let dayS = 86_400
        let current = row(now, strain: 15)
        let history = [
            current,
            row(now - 2 * dayS, strain: 10),
            row(now - 5 * dayS, strain: 12),
            row(now - 9 * dayS, strain: 14),
            row(now - 40 * dayS, strain: 20),                    // outside the 30 days
            row(now - 3 * dayS, sport: "Cycling", strain: 5),    // another sport
            row(now + dayS, strain: 21),                         // later than the activity
            row(now - 4 * dayS, strain: 0),                      // zero is not a measurement
            row(now - 30, strain: 16),                           // another source's copy of this one
        ]
        let typical = WhoopActivityBaseline.typical({ $0.strain }, for: current, in: history)
        XCTAssertEqual(typical ?? 0, 12, accuracy: 1e-9)
        XCTAssertEqual(WhoopActivityBaseline.sessions(for: current, in: history).map(\.startTs),
                       [now - 2 * dayS, now - 4 * dayS, now - 5 * dayS, now - 9 * dayS])
    }

    func testTypicalFallsBackToAllHistoryWithFewerThanThree() {
        let now = 1_800_000_000
        let dayS = 86_400
        let current = row(now, kcal: 400)
        let history = [
            row(now - 2 * dayS, kcal: 300),
            row(now - 60 * dayS, kcal: 500),
            row(now - 90 * dayS, kcal: 700),
            row(now - 3 * dayS, sport: "Walking", kcal: 100),
        ]
        let typical = WhoopActivityBaseline.typical({ $0.energyKcal }, for: current, in: history)
        XCTAssertEqual(typical ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(WhoopActivityBaseline.sessions(for: current, in: history).count, 3)
        // No earlier session of the sport: no typical value.
        XCTAssertNil(WhoopActivityBaseline.typical({ $0.energyKcal }, for: row(now, sport: "Yoga"), in: history))
    }

    /// The sport matches across spellings ("TraditionalStrengthTraining" and its spaced form).
    func testSameSportAcrossSpellings() {
        let current = row(1_000_000, sport: "Traditional Strength Training", strain: 9)
        let history = [row(900_000, sport: "TraditionalStrengthTraining", strain: 11)]
        XCTAssertEqual(WhoopActivityBaseline.typical({ $0.strain }, for: current, in: history), 11)
    }

    /// The chip's triangle compares what the page shows: 16.8 against 17.0 is down, 16.96 against 17.0 level.
    func testDirectionAtThePrecisionShown() {
        XCTAssertEqual(WhoopActivityBaseline.direction(16.8, typical: 17.0, decimals: 1), -1)
        XCTAssertEqual(WhoopActivityBaseline.direction(6091, typical: 5520, decimals: 0), 1)
        XCTAssertEqual(WhoopActivityBaseline.direction(16.96, typical: 17.0, decimals: 1), 0)
        XCTAssertEqual(WhoopActivityBaseline.direction(412.4, typical: 412, decimals: 0), 0)
    }

    // MARK: Labels

    func testClockAndZoneTitles() {
        XCTAssertEqual(WhoopTime.hms(seconds: 2306), "0:38:26")
        XCTAssertEqual(WhoopTime.hms(seconds: 3725.6), "1:02:06")
        let split = WhoopTime.hmsSplit(seconds: 918)
        XCTAssertEqual(split.main, "0:15")
        XCTAssertEqual(split.seconds, ":18")
        XCTAssertEqual(WhoopActivityScreen.bandTitle(5, reservePercents: true),
                       String(localized: "ZONE \(5)") + " (90-100%)")
        XCTAssertEqual(WhoopActivityScreen.bandTitle(2, reservePercents: true),
                       String(localized: "ZONE \(2)") + " (60-70%)")
        XCTAssertEqual(WhoopActivityScreen.bandTitle(0, reservePercents: true),
                       String(localized: "RESTORATIVE") + " (<50%)")
        XCTAssertEqual(WhoopActivityScreen.bandTitle(3, reservePercents: false), String(localized: "ZONE \(3)"))
    }

    func testChartPaddingIsATwentiethWithinOneToFiveMinutes() {
        XCTAssertEqual(WhoopActivityZones.chartPadding(seconds: 2306), 115)
        XCTAssertEqual(WhoopActivityZones.chartPadding(seconds: 300), 60)
        XCTAssertEqual(WhoopActivityZones.chartPadding(seconds: 4 * 3600), 300)
    }
}
