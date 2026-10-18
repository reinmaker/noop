import XCTest
import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The night's blood oxygen from the strap's own reading: one figure, the mean of the night's 30-second bursts.
final class YoopBloodOxygenTests: XCTestCase {

    /// Burst medians (readings that were percentages, median) of the wearer's nights, bursts 20 minutes apart.
    private let night18: [(count: Int, median: Double)] = [
        (28, 92.0), (30, 94.5), (30, 94.0), (30, 92.0), (19, 97), (17, 98), (24, 95.0), (7, 94), (23, 94), (27, 97),
        (17, 88), (29, 92), (30, 89.0), (16, 96.5), (19, 95), (18, 93.0), (25, 97), (30, 87.0), (21, 94)]
    private let night12: [(count: Int, median: Double)] = [
        (27, 94), (14, 96.0), (22, 91.0), (30, 94.0), (30, 91.0), (30, 92.0), (23, 96), (28, 92.0), (29, 96),
        (30, 84.0), (9, 92), (29, 95), (27, 93), (28, 92.0), (19, 94), (28, 94.0), (30, 94.0), (30, 94.0),
        (30, 97.0), (30, 96.0), (30, 96.0), (30, 97.0)]
    private let start = 1_000_000

    /// Readings whose median is each burst's, bursts 20 minutes apart; an x.5 median has half the readings at each
    /// neighbouring percent.
    private func readings(_ bursts: [(count: Int, median: Double)]) -> [(ts: Int, value: Int)] {
        var out: [(ts: Int, value: Int)] = []
        var t = start
        for burst in bursts {
            let low = Int(burst.median.rounded(.down)), high = Int(burst.median.rounded(.up))
            for i in 0..<burst.count { out.append((t + i, low == high ? low : (i < burst.count / 2 ? low : high))) }
            t += 1200
        }
        return out
    }

    private func samples(_ readings: [(ts: Int, value: Int)]) -> [V18AuxSample] {
        readings.map { V18AuxSample(ts: $0.ts, auxByte82: $0.value) }
    }

    private func session(_ from: Int, _ to: Int) -> SleepSession {
        SleepSession(start: from, end: to, efficiency: 0.9, stages: [], restingHR: nil, avgHRV: nil)
    }

    /// The nights of 18 and 12 Oct 2026 both come to 93.6 on their 19 and 22 bursts.
    func testTheNightIsTheMeanOfItsBursts() throws {
        let a = try XCTUnwrap(YoopBloodOxygen.night(readings: readings(night18).shuffled()))
        XCTAssertEqual(a.percent, 93.6, accuracy: 1e-9)
        XCTAssertEqual(a.bursts, 19)
        let b = try XCTUnwrap(YoopBloodOxygen.night(readings: readings(night12)))
        XCTAssertEqual(b.percent, 93.6, accuracy: 1e-9)
        XCTAssertEqual(b.bursts, 22)
    }

    /// A burst weighs once however many readings it holds: a long burst of one value does not outvote the rest.
    func testABurstCountsOnce() throws {
        var bursts = night18
        bursts[0] = (30, 99.0)
        let night = try XCTUnwrap(YoopBloodOxygen.night(readings: readings(bursts)))
        let expected = (bursts.filter { $0.count >= 5 }.map { $0.median }.reduce(0, +)) / 19
        XCTAssertEqual(night.percent, (expected * 10).rounded() / 10, accuracy: 1e-9)
    }

    /// A burst of mostly flag values (under five percentages) is left out, and so is a night of too few bursts.
    func testThinBurstsAndShortNightsGiveNothing() throws {
        var bursts = night18
        bursts.append((4, 70))
        XCTAssertEqual(try XCTUnwrap(YoopBloodOxygen.night(readings: readings(bursts))).bursts, 19)
        XCTAssertNil(YoopBloodOxygen.night(readings: readings(Array(night18.prefix(7)))))
        XCTAssertNotNil(YoopBloodOxygen.night(readings: readings(Array(night18.prefix(8)))))
    }

    /// Flag values (2, 8, 16, 32, 128, 160) and zeros are not percentages, and readings outside the sleep are not
    /// the night's.
    func testFlagValuesAndWakeReadingsAreIgnored() throws {
        let inSleep = readings(night18)
        var aux = samples(inSleep)
        for r in inSleep.prefix(200) { aux.append(V18AuxSample(ts: r.ts, auxByte82: [0, 2, 8, 16, 32, 128, 160].randomElement()!)) }
        let awake = samples((0..<60).map { (ts: start - 5_000 + $0, value: 76) })
        let end = (inSleep.last?.ts ?? start) + 10
        let night = try XCTUnwrap(YoopBloodOxygen.night(sessions: [session(start - 60, end)], aux: aux + awake))
        XCTAssertEqual(night.percent, 93.6, accuracy: 1e-9)
        XCTAssertEqual(night.bursts, 19)
        XCTAssertNil(YoopBloodOxygen.night(sessions: [], aux: aux))
    }

    /// The Yoop rebuild changes only the blood oxygen.
    func testWithBloodOxygenChangesOnlyThat() {
        let day = DailyMetric(day: "2026-10-18", totalSleepMin: 401, efficiency: 0.82, deepMin: 64, remMin: 70,
                              lightMin: 266, disturbances: 10, restingHr: 50, avgHrv: 84.5, recovery: 73,
                              strain: 32.2, exerciseCount: 0, spo2Pct: nil, skinTempDevC: -0.3, respRateBpm: 15.2,
                              steps: 5940, activeKcalEst: 129, spo2Red: nil, spo2Ir: nil, avgSdnn: 92.3,
                              skinTempC: 31.85, sleepHrOnly: false)
        let updated = day.with(spo2Pct: 93.6)
        XCTAssertEqual(updated.spo2Pct, 93.6)
        XCTAssertEqual(updated.with(spo2Pct: nil), day)
    }
}
