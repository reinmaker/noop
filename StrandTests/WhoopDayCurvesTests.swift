import XCTest
import Foundation
@testable import Strand

/// Today against its own normal by this time of day: the closed days' curves, and the mean of what those
/// days had reached at the same clock time.
final class WhoopDayCurvesTests: XCTestCase {
    private func at(_ day: String, _ hour: Double) -> Int {
        Int(Calendar.current.startOfDay(for: WhoopDayFigures.date(of: day)!).timeIntervalSince1970 + hour * 3_600)
    }

    private func nextDay(_ day: String) -> String {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: WhoopDayFigures.date(of: day)!)!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: next)
    }

    /// A day whose window runs `startHour` to `startHour` the next day, with `perHour` steps (and `perHour / 10`
    /// kcal) every hour.
    private func curve(_ day: String, startHour: Double = 1, perHour: Double = 1_000, fromStart: Bool = true,
                       steps: Bool = true) -> WhoopDayCurve {
        let from = at(day, startHour), to = at(nextDay(day), startHour)
        var stepMinutes: [Int: Double] = [:], kcalMinutes: [Int: Double] = [:]
        for minute in (from / 60)..<(to / 60) {
            stepMinutes[minute] = perHour / 60
            kcalMinutes[minute] = perHour / 600
        }
        return WhoopDayCurve.make(day: day, sig: "s", from: from, to: to,
                                  stepsByMinute: steps ? stepMinutes : nil, kcalByMinute: kcalMinutes,
                                  stepsFromStart: fromStart, kcalFromStart: fromStart)
    }

    private let june = (1...8).map { String(format: "2026-06-%02d", $0) }

    // MARK: the curve

    func testACurveAccumulatesAndReadsLinearlyInsideAQuarterHour() {
        let c = curve("2026-06-01")
        XCTAssertEqual(c.total(.steps) ?? 0, 24_000, accuracy: 1e-6)
        XCTAssertEqual(c.cumulative(.steps, at: at("2026-06-01", 12)) ?? 0, 11_000, accuracy: 1e-6)
        // Seven and a half minutes into a quarter hour is half of that quarter hour's 250 steps.
        XCTAssertEqual(c.cumulative(.steps, at: at("2026-06-01", 12) + 450) ?? 0, 11_125, accuracy: 1e-6)
        XCTAssertEqual(c.cumulative(.kcal, at: at("2026-06-01", 12)) ?? 0, 1_100, accuracy: 1e-6)
    }

    func testACurveIsNothingBeforeItsWindowAndWholeAfterIt() {
        let c = curve("2026-06-01")
        XCTAssertEqual(c.cumulative(.steps, at: at("2026-06-01", 0)), 0)
        XCTAssertEqual(c.cumulative(.steps, at: at("2026-06-03", 0)) ?? 0, 24_000, accuracy: 1e-6)
    }

    func testACurveWithoutStepsHasNoStepFigures() {
        let c = curve("2026-06-01", steps: false)
        XCTAssertNil(c.total(.steps))
        XCTAssertNil(c.cumulative(.steps, at: at("2026-06-01", 12)))
        XCTAssertNotNil(c.total(.kcal))
    }

    func testMinutesOutsideTheWindowAreNotInTheCurve() {
        let from = at("2026-06-01", 1), to = at("2026-06-01", 2)
        let c = WhoopDayCurve.make(day: "2026-06-01", sig: "s", from: from, to: to,
                                   stepsByMinute: [from / 60 - 3: 50, from / 60 + 5: 10, to / 60 + 2: 70],
                                   kcalByMinute: nil, stepsFromStart: true, kcalFromStart: false)
        XCTAssertEqual(c.total(.steps), 10)
    }

    func testTheMinuteHoldingTheWindowStartIsInTheCurve() {
        let from = at("2026-06-01", 1) + 30, to = at("2026-06-01", 2)
        let c = WhoopDayCurve.make(day: "2026-06-01", sig: "s", from: from, to: to,
                                   stepsByMinute: [(from - 30) / 60: 4, (from + 30) / 60: 6, (from - 90) / 60: 50],
                                   kcalByMinute: nil, stepsFromStart: true, kcalFromStart: false)
        XCTAssertEqual(c.total(.steps), 10)
    }

    func testACurveSurvivesBeingStoredAndRead() throws {
        let c = curve("2026-06-01")
        let back = try JSONDecoder().decode(WhoopDayCurve.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    // MARK: the normal by now

    func testTheNormalByNowIsWhatTheDaysHadReachedAtThisTimeOfDay() {
        let curves = june.dropLast().map { curve($0) }     // seven closed days, 1 to 7 June
        let normal = WhoopByNow.normal(.steps, curves: curves, asOf: at("2026-06-08", 12), todayKey: "2026-06-08",
                                       floor: 1_000)
        XCTAssertEqual(normal ?? 0, 11_000, accuracy: 1e-6)
        // Whole days would say 24,000: today at noon is nowhere near behind them.
        XCTAssertEqual(WhoopByNow.normal(.kcal, curves: curves, asOf: at("2026-06-08", 12), todayKey: "2026-06-08",
                                         floor: 0) ?? 0, 1_100, accuracy: 1e-6)
    }

    func testThereIsNoNormalByNowWithFewerThanSevenCompleteDays() {
        let six = june.prefix(6).map { curve($0) }
        XCTAssertNil(WhoopByNow.normal(.steps, curves: six, asOf: at("2026-06-08", 12), todayKey: "2026-06-08",
                                       floor: 1_000))
        // A day recorded only from the afternoon is not a whole day, so it does not make up the seven.
        let partial = six + [curve("2026-06-07", fromStart: false)]
        XCTAssertNil(WhoopByNow.normal(.steps, curves: partial, asOf: at("2026-06-08", 12), todayKey: "2026-06-08",
                                       floor: 1_000))
        // A day that ended under the floor does not either.
        let thin = six + [curve("2026-06-07", perHour: 20)]
        XCTAssertNil(WhoopByNow.normal(.steps, curves: thin, asOf: at("2026-06-08", 12), todayKey: "2026-06-08",
                                       floor: 1_000))
    }

    func testTodayAndLaterDaysAreNotPartOfTheirOwnNormal() {
        let curves = june.map { curve($0) }
        // Read for 5 June: only 1 to 4 June are prior, so there are not seven.
        XCTAssertNil(WhoopByNow.normal(.steps, curves: curves, asOf: at("2026-06-05", 12), todayKey: "2026-06-05",
                                       floor: 1_000))
    }

    func testAWindowThatBeganBeforeMidnightCountsFromItsOwnStart() {
        // A night that began at 23:00 on the previous date has 13 hours behind it by noon.
        let curves = june.dropLast().map { day -> WhoopDayCurve in
            let from = at(day, 23) - 86_400, to = at(day, 23)
            var minutes: [Int: Double] = [:]
            for minute in (from / 60)..<(to / 60) { minutes[minute] = 1_000.0 / 60 }
            return WhoopDayCurve.make(day: day, sig: "s", from: from, to: to, stepsByMinute: minutes,
                                      kcalByMinute: nil, stepsFromStart: true, kcalFromStart: false)
        }
        let normal = WhoopByNow.normal(.steps, curves: curves, asOf: at("2026-06-08", 12), todayKey: "2026-06-08",
                                       floor: 1_000)
        XCTAssertEqual(normal ?? 0, 13_000, accuracy: 1e-6)
    }

    func testAnEnergyNormalNeedsTheEnergyCurve() {
        let curves = june.dropLast().map { day -> WhoopDayCurve in
            let c = curve(day)
            return WhoopDayCurve(day: c.day, sig: c.sig, from: c.from, to: c.to, origin: c.origin, steps: c.steps,
                                 kcal: nil, stepsFromStart: true, kcalFromStart: true)
        }
        XCTAssertNil(WhoopByNow.normal(.kcal, curves: curves, asOf: at("2026-06-08", 12), todayKey: "2026-06-08",
                                       floor: 0))
    }
}
