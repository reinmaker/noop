import XCTest
@testable import Strand

/// Naming a detected activity from the user's own history (`WhoopActivityTyper`).
final class WhoopActivityTyperTests: XCTestCase {

    private func examples(_ sport: String, avg: Double, max: Double, minutes: Double, hour: Double,
                          count: Int = 6) -> [WhoopActivityTyper.Example] {
        (0..<count).map { i in
            let jitter = Double(i % 3) - 1
            return .init(sport: sport, avgBpm: avg + jitter * 3, maxBpm: max + jitter * 4,
                         durationMin: minutes + jitter * 5, startHour: hour + jitter * 0.5)
        }
    }

    /// Shaped on the user's WHOOP history: lifting, tennis and running sit far apart on heart rate.
    private var history: [WhoopActivityTyper.Example] {
        examples("Weightlifting", avg: 102, max: 143, minutes: 46, hour: 16)
            + examples("Tennis", avg: 123, max: 165, minutes: 113, hour: 19)
            + examples("Running", avg: 170, max: 191, minutes: 38, hour: 20)
    }

    func testNamesTheTypeItsHeartRateMatches() {
        XCTAssertEqual(WhoopActivityTyper.guess(avgBpm: 168, maxBpm: 189, durationMin: 35, startHour: 20.5,
                                                history: history), "Running")
        XCTAssertEqual(WhoopActivityTyper.guess(avgBpm: 104, maxBpm: 140, durationMin: 50, startHour: 15,
                                                history: history), "Weightlifting")
        XCTAssertEqual(WhoopActivityTyper.guess(avgBpm: 120, maxBpm: 162, durationMin: 100, startHour: 18.5,
                                                history: history), "Tennis")
    }

    /// A correction joins the history, so the next activity like it takes the user's type.
    func testLearnsFromTheUsersChoice() {
        let ride = (avg: 135.0, max: 160.0, minutes: 60.0, hour: 7.0)
        let learnt = history + examples("Cycling", avg: ride.avg, max: ride.max, minutes: ride.minutes, hour: ride.hour)
        XCTAssertNotEqual(WhoopActivityTyper.guess(avgBpm: ride.avg, maxBpm: ride.max, durationMin: ride.minutes,
                                                   startHour: ride.hour, history: history), "Cycling")
        XCTAssertEqual(WhoopActivityTyper.guess(avgBpm: ride.avg, maxBpm: ride.max, durationMin: ride.minutes,
                                                startHour: ride.hour, history: learnt), "Cycling")
    }

    /// A type the user set in Yoop outvotes older look-alike history: two basketball corrections beat six
    /// tennis sessions with nearly the same heart rate.
    func testUserCorrectionsOutweighOldHistory() {
        let tennis = examples("Tennis", avg: 138, max: 180, minutes: 100, hour: 19.5)
        let corrected = (0..<2).map { _ in
            WhoopActivityTyper.Example(sport: "Basketball", avgBpm: 140, maxBpm: 182, durationMin: 98, startHour: 19.6,
                                       weight: WhoopActivityTyper.userLabelWeight)
        }
        XCTAssertEqual(WhoopActivityTyper.guess(avgBpm: 139, maxBpm: 181, durationMin: 99, startHour: 19.6,
                                                history: tennis + corrected), "Basketball")
    }

    /// Too little history, or a split vote, leaves the activity unnamed; unnamed rows teach nothing.
    func testStaysUnnamedWhenUnsure() {
        XCTAssertNil(WhoopActivityTyper.guess(avgBpm: 170, maxBpm: 190, durationMin: 38, startHour: 20,
                                              history: Array(history.prefix(4))))
        let light = examples("Walking", avg: 97, max: 123, minutes: 15, hour: 12, count: 3)
            + examples("Commuting", avg: 97, max: 123, minutes: 15, hour: 12, count: 3)
            + examples("Dog Walking", avg: 97, max: 123, minutes: 15, hour: 12, count: 1)
        XCTAssertNil(WhoopActivityTyper.guess(avgBpm: 97, maxBpm: 123, durationMin: 15, startHour: 12, history: light))
        let unnamed = examples("Activity", avg: 170, max: 191, minutes: 38, hour: 20, count: 10)
        XCTAssertNil(WhoopActivityTyper.guess(avgBpm: 170, maxBpm: 191, durationMin: 38, startHour: 20, history: unnamed))
        XCTAssertTrue(WhoopActivityTyper.isUnnamed("detected"))
        XCTAssertFalse(WhoopActivityTyper.isUnnamed("Weightlifting"))
    }
}
