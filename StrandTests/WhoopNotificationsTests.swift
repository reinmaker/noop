import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// The two notes Yoop was missing next to WHOOP's: the night is scored, and an activity was added.
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

    /// An activity that ended recently and has not been announced is news; an old one (a restore) and a repeat are not.
    func testActivityNews() {
        let now = 1_000_000
        XCTAssertTrue(WhoopNotifications.isActivityNews(startSec: now - 4_000, endSec: now - 600, now: now, posted: []))
        XCTAssertFalse(WhoopNotifications.isActivityNews(startSec: now - 20_000, endSec: now - 4 * 3600, now: now, posted: []))
        XCTAssertFalse(WhoopNotifications.isActivityNews(startSec: now - 4_000, endSec: now - 600, now: now,
                                                         posted: [now - 4_000]))
    }
}
