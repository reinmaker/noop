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

    /// The sleep note waits until the strap has recorded a quarter of an hour after the last sleep: a night
    /// still going has its last asleep minute at the newest data, so it is not over; one the wearer has got up
    /// from is. Data that ran behind the clock counts as the data, not the clock.
    func testNightIsOverOnlyAfterDataFollowsTheLastSleep() {
        let now = 2_000_000
        // Asleep: the last sleep is the newest data.
        XCTAssertFalse(WhoopNotifications.nightIsOver(nightEnd: now - 60, newestSample: now - 30, now: now))
        // A sync delivered the buffer two hours behind the clock, ending with the last sleep: still going.
        XCTAssertFalse(WhoopNotifications.nightIsOver(nightEnd: now - 7_200, newestSample: now - 7_190, now: now))
        // Up for fourteen minutes: not yet; for fifteen: over.
        XCTAssertFalse(WhoopNotifications.nightIsOver(nightEnd: now - 840, newestSample: now, now: now))
        XCTAssertTrue(WhoopNotifications.nightIsOver(nightEnd: now - 900, newestSample: now, now: now))
        // The night ended long ago and the strap has recorded since.
        XCTAssertTrue(WhoopNotifications.nightIsOver(nightEnd: now - 5 * 3600, newestSample: now - 60, now: now))
        // Data stamped after the clock (a skewed strap) cannot make a night over early.
        XCTAssertFalse(WhoopNotifications.nightIsOver(nightEnd: now - 300, newestSample: now + 3_600, now: now))
    }

    /// An activity is added only after the strap has recorded ten minutes since its last raised minute, counted
    /// from the newest sample as well as the clock.
    func testActivityHasSettledOnlyAfterDataFollowsIt() {
        let now = 3_000_000
        let settle = Repository.activityAddSettleSec
        XCTAssertEqual(settle, 600)
        // Going: its last raised minute is the newest data.
        XCTAssertFalse(Repository.activityHasSettled(endSec: now - 60, now: now, newestSample: now, settleSec: settle))
        // A sync delivered the buffer ten minutes behind the clock, ending with the last raised minute.
        XCTAssertFalse(Repository.activityHasSettled(endSec: now - 600, now: now, newestSample: now - 590,
                                                     settleSec: settle))
        // Ten minutes of quiet recorded after it: finished.
        XCTAssertTrue(Repository.activityHasSettled(endSec: now - 600, now: now, newestSample: now, settleSec: settle))
        XCTAssertFalse(Repository.activityHasSettled(endSec: now - 599, now: now, newestSample: now, settleSec: settle))
        // The detector's own five minutes still apply where nothing longer is asked.
        XCTAssertTrue(Repository.activityHasSettled(endSec: now - 300, now: now, newestSample: now, settleSec: 300))
    }
}
