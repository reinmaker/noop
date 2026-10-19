import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// A night's window on Home, in the consistency bars and in the sleep planner is the night the Sleep page shows.
final class SleepNightWindowsTests: XCTestCase {

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Int {
        let parts = DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)
        return Int(Calendar.current.date(from: parts)!.timeIntervalSince1970)
    }

    private func record(_ from: Int, _ to: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: from, endTs: to, efficiency: 0.9, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// 19 Oct 2026 as it was stored: 01:57 to 06:26, an hour awake, then 07:30 to 10:23. Home and the consistency
    /// bars showed the first record only (01:57 to 06:26); the Sleep page showed the whole night.
    func testANightSplitByAWakeRunsToTheLastRecord() {
        let sleeps = [record(at(19, 1, 57), at(19, 6, 26)), record(at(19, 7, 30), at(19, 10, 23))]
        let windows = SleepModel.nightWindows(sleeps)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, at(19, 1, 57))
        XCTAssertEqual(windows[0].end, at(19, 10, 23))
    }

    /// A night in one record is that record, as before.
    func testASingleRecordNightIsItself() {
        let windows = SleepModel.nightWindows([record(at(18, 23, 30), at(19, 7, 30))])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, at(18, 23, 30))
        XCTAssertEqual(windows[0].end, at(19, 7, 30))
    }

    /// A nap hours after waking is not part of the night, and a window under three hours is left out.
    func testANapAfterTheNightIsLeftOut() {
        let sleeps = [record(at(19, 1, 0), at(19, 9, 0)), record(at(19, 12, 30), at(19, 13, 30))]
        let windows = SleepModel.nightWindows(sleeps)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].end, at(19, 9, 0))
    }

    /// Two nights come back oldest first, the second one whole.
    func testTwoNightsOldestFirst() {
        let sleeps = [record(at(19, 7, 30), at(19, 10, 23)), record(at(18, 0, 10), at(18, 9, 40)),
                      record(at(19, 1, 57), at(19, 6, 26))]
        let windows = SleepModel.nightWindows(sleeps)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, at(18, 0, 10))
        XCTAssertEqual(windows[1].start, at(19, 1, 57))
        XCTAssertEqual(windows[1].end, at(19, 10, 23))
    }

    /// The consistency score reads the whole night's wake time: against two usual nights ending around 09:40,
    /// waking at 10:23 costs about an hour of shift, where the first record's 06:26 cost over three.
    func testConsistencyUsesTheWholeNight() throws {
        let usual = [record(at(16, 0, 30), at(16, 9, 30)), record(at(17, 0, 40), at(17, 9, 40)),
                     record(at(18, 0, 10), at(18, 9, 40))]
        let whole = SleepModel.consistencyScores(SleepModel.nightWindows(
            usual + [record(at(19, 1, 57), at(19, 6, 26)), record(at(19, 7, 30), at(19, 10, 23))]))
        let firstOnly = SleepModel.consistencyScores(SleepModel.nightWindows(usual)
            + [(start: at(19, 1, 57), end: at(19, 6, 26))])
        let a = try XCTUnwrap(whole.last?.score), b = try XCTUnwrap(firstOnly.last?.score)
        XCTAssertGreaterThan(a, b + 15, "whole night \(a), first record \(b)")
    }
}
