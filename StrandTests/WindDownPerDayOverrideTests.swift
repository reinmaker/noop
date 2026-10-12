import XCTest
@testable import Strand

/// PR#554 (MumiZed, reimplemented as NoopApp) per-day wake overrides for the wind-down reminder, and the
/// wake time the user chose for every other day.
///
/// The reminder follows tonight's sleep plan (`WhoopSleepPlan`): it fires `lead` minutes before the plan's
/// bedtime, and a wake time the user chose is the plan's wake time. These pin: a chosen time round-trips
/// through the store, a day without one has none (the plan then takes the wake from the recent nights, and
/// no stored 07:00 stands in), an override wins over the chosen time for its own weekday only, clamping is
/// honest, and a reminder is an absolute instant, so an early wake still reminds the evening before (#1863).
///
/// `WindDownNudge` is @MainActor and backed by UserDefaults.standard, so each test clears its keys first.
@MainActor
final class WindDownPerDayOverrideTests: XCTestCase {

    private let perDayKey = "windDown.perDayWakeMinutes"
    private let wakeKey = "windDown.wakeMinutes"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: perDayKey)
        UserDefaults.standard.removeObject(forKey: wakeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: perDayKey)
        UserDefaults.standard.removeObject(forKey: wakeKey)
        super.tearDown()
    }

    func testNothingChosen_noDayHasAWakeTime() {
        XCTAssertNil(WindDownNudge.chosenWakeMinutes, "no stored default: 07:00 is only ever a time somebody picked")
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
        for weekday in 1...7 {
            XCTAssertNil(WindDownNudge.chosenWakeMinutes(forWeekday: weekday))
        }
    }

    func testNoOverrides_everyDayUsesTheChosenWake() {
        WindDownNudge.setWakeMinutes(9 * 60)
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
        for weekday in 1...7 {
            XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: weekday), 9 * 60)
        }
    }

    func testClearingTheChosenWake_returnsToNothingChosen() {
        WindDownNudge.setWakeMinutes(9 * 60)
        WindDownNudge.clearWakeMinutes()
        XCTAssertNil(WindDownNudge.chosenWakeMinutes)
    }

    func testOverrideAppliesToItsWeekdayOnly() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)   // Saturday lie-in to 09:00
        XCTAssertTrue(WindDownNudge.hasPerDayOverrides)
        XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: 7), 9 * 60)
        for weekday in 1...6 {
            XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: weekday), 7 * 60)
        }
    }

    func testAnOverrideWithNoChosenWake_leavesTheOtherDaysToThePlan() {
        WindDownNudge.setWakeOverride(weekday: 7, minutes: 9 * 60)
        XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: 7), 9 * 60)
        XCTAssertNil(WindDownNudge.chosenWakeMinutes(forWeekday: 3))
    }

    func testClearingAnOverride_revertsThatDay() {
        WindDownNudge.setWakeMinutes(7 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: 8 * 60)   // Sunday 08:00
        XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: 1), 8 * 60)
        WindDownNudge.setWakeOverride(weekday: 1, minutes: nil)      // clear it
        XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: 1), 7 * 60)
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }

    func testOverrideMinutesAreClamped() {
        WindDownNudge.setWakeOverride(weekday: 4, minutes: 5_000)   // way past a day
        XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: 4), 24 * 60 - 1)
        WindDownNudge.setWakeOverride(weekday: 4, minutes: -100)
        XCTAssertEqual(WindDownNudge.chosenWakeMinutes(forWeekday: 4), 0)
    }

    func testInvalidWeekday_isIgnored() {
        WindDownNudge.setWakeOverride(weekday: 9, minutes: 8 * 60)   // no weekday 9
        XCTAssertFalse(WindDownNudge.hasPerDayOverrides)
    }

    // MARK: - #1863: an early wake reminds the evening before

    /// Tuesday 03:30 is a wake time the evening before: the reminder is bedtime minus the lead, an absolute
    /// instant, so it lands on Monday evening without any weekday arithmetic to get wrong.
    func testAnEarlyWakeRemindsTheEveningBefore() throws {
        let cal = Calendar.current
        let tuesday = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 3, minute: 30)))
        let plan = WhoopSleepPlan(baselineMin: 450, strainMin: 0, debtMin: 0, efficiency: 0.9, wake: tuesday,
                                  wakeSource: .chosen, optimalStart: nil, recommendedWake: nil)
        let fire = WindDownNudge.fireDate(for: plan, leadMinutes: 30)
        XCTAssertEqual(fire, plan.bedtime.addingTimeInterval(-30 * 60))
        // 03:30 minus 8 h 20 m in bed (7 h 30 m at 90%) minus 30 min is 18:40 on Monday.
        let parts = cal.dateComponents([.day, .hour, .minute], from: fire)
        XCTAssertEqual(parts.day, 12)
        XCTAssertEqual(parts.hour, 18)
        XCTAssertEqual(parts.minute, 40)
    }
}
