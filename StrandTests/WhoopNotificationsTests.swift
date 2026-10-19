import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The Coach's two notes next to WHOOP's: the night is scored, and an activity was added.
final class WhoopNotificationsTests: XCTestCase {

    private func night(sleepMin: Double?, recovery: Double?) -> DailyMetric {
        DailyMetric(day: "2026-10-19", totalSleepMin: sleepMin, efficiency: 0.9, deepMin: 80, remMin: 90,
                    lightMin: 300, disturbances: nil, restingHr: 50, avgHrv: 80, recovery: recovery,
                    strain: nil, exerciseCount: nil)
    }

    /// The note names Recovery and the length of the night.
    func testSleepReadyBodyNamesRecoveryAndSleep() throws {
        let body = try XCTUnwrap(WhoopNotifications.sleepReadyBody(night(sleepMin: 481, recovery: 72.6)))
        XCTAssertTrue(body.contains("73%"), body)
        XCTAssertTrue(body.contains("8 hr 1 min"), body)
    }

    /// A night with no Recovery yet (the baseline is still building) says how long it was.
    func testSleepReadyBodyWithoutRecovery() throws {
        let body = try XCTUnwrap(WhoopNotifications.sleepReadyBody(night(sleepMin: 395, recovery: nil)))
        XCTAssertTrue(body.contains("6 hr 35 min"), body)
        XCTAssertFalse(body.contains("%"), body)
    }

    /// Under two hours is a nap, not a night: no note.
    func testANapIsNotANight() {
        XCTAssertNil(WhoopNotifications.sleepReadyBody(night(sleepMin: 119, recovery: 60)))
        XCTAssertNil(WhoopNotifications.sleepReadyBody(night(sleepMin: nil, recovery: 60)))
        XCTAssertNotNil(WhoopNotifications.sleepReadyBody(night(sleepMin: 120, recovery: 60)))
    }

    /// Once per day.
    func testOneSleepNotePerDay() {
        XCTAssertTrue(WhoopNotifications.isNewSleepDay(last: nil, todayKey: "2026-10-19"))
        XCTAssertTrue(WhoopNotifications.isNewSleepDay(last: "2026-10-18", todayKey: "2026-10-19"))
        XCTAssertFalse(WhoopNotifications.isNewSleepDay(last: "2026-10-19", todayKey: "2026-10-19"))
    }

    /// A tap on the activity note carries the session to the Coach, whatever the sport is called.
    func testWorkoutRouteRoundTrips() throws {
        let route = WhoopNotifications.workoutRoute(sport: "Run", minutes: 42)
        XCTAssertEqual(route, "workout|42|Run")
        let parsed = try XCTUnwrap(WhoopNotifications.parseWorkoutRoute(route))
        XCTAssertEqual(parsed.sport, "Run")
        XCTAssertEqual(parsed.minutes, 42)
        let odd = try XCTUnwrap(WhoopNotifications.parseWorkoutRoute(
            WhoopNotifications.workoutRoute(sport: "Hot | Yoga", minutes: 55)))
        XCTAssertEqual(odd.sport, "Hot | Yoga")
        XCTAssertNil(WhoopNotifications.parseWorkoutRoute(WhoopNotifications.sleepReadRoute))
        XCTAssertNil(WhoopNotifications.parseWorkoutRoute("workout|x|Run"))
        XCTAssertNil(WhoopNotifications.parseWorkoutRoute("workout|42|"))
    }

    /// The Coach is told about the session and asked how it felt; the sleep read names Recovery.
    func testCoachOpenersCarryTheirContext() {
        let text = AICoachEngine.workoutFollowUpInstruction(sport: "Run", minutes: 42)
        XCTAssertTrue(text.contains("42 minute Run"), text)
        XCTAssertTrue(text.contains("how it felt"), text)
        XCTAssertTrue(AICoachEngine.sleepReadInstruction.contains("Recovery"))
        XCTAssertNotEqual(AICoachEngine.Opener.workoutFollowUp(sport: "Run", minutes: 42),
                          AICoachEngine.Opener.workoutFollowUp(sport: "Run", minutes: 43))
    }

    /// An activity that ended recently and has not been announced is news; an old one (a restore) and a repeat are not.
    func testActivityNews() {
        let now = 1_000_000
        XCTAssertTrue(WhoopNotifications.isActivityNews(startSec: now - 4_000, endSec: now - 600, now: now, posted: []))
        XCTAssertFalse(WhoopNotifications.isActivityNews(startSec: now - 20_000, endSec: now - 4 * 3600, now: now, posted: []))
        XCTAssertFalse(WhoopNotifications.isActivityNews(startSec: now - 4_000, endSec: now - 600, now: now,
                                                         posted: [now - 4_000]))
    }
}
