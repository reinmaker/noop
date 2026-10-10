import XCTest
@testable import Strand

/// WHOOP-style activity detection (`WhoopActivityDetector`).
final class WhoopActivityDetectorTests: XCTestCase {

    /// One reading every 10 s at `bpm` for `minutes`, starting at minute `from`.
    private func block(_ bpm: Int, from: Int, minutes: Int) -> [(ts: Int, bpm: Int)] {
        (0..<(minutes * 6)).map { (ts: 1_800_000_000 + from * 60 + $0 * 10, bpm: bpm) }
    }

    /// Lifting: three minutes of sets, one minute of rest, five times. Found as one 20-minute bout.
    func testSetBreaksDoNotEndTheBout() {
        var hr: [(ts: Int, bpm: Int)] = []
        for round in 0..<5 {
            hr += block(125, from: round * 4, minutes: 3)
            hr += block(85, from: round * 4 + 3, minutes: 1)
        }
        let found = WhoopActivityDetector.detect(hr: hr, restingBpm: 52, excluded: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertGreaterThanOrEqual(found.first?.durationMin ?? 0, 18)
    }

    func testShortBurstsAndExcludedSpansAreIgnored() {
        XCTAssertTrue(WhoopActivityDetector.detect(hr: block(130, from: 0, minutes: 8), restingBpm: 52, excluded: []).isEmpty)
        let session = block(125, from: 0, minutes: 20)
        let saved = (1_800_000_000 + 5 * 60)...(1_800_000_000 + 10 * 60)
        XCTAssertTrue(WhoopActivityDetector.detect(hr: session, restingBpm: 52, excluded: [saved]).isEmpty)
        XCTAssertEqual(WhoopActivityDetector.detect(hr: session, restingBpm: 52, excluded: []).count, 1)
    }

    /// An everyday walk (light intensity, never reaching half the heart-rate reserve) is not an activity.
    func testEverydayWalkIsNotAnActivity() {
        var hr = block(95, from: 0, minutes: 30)
        hr += block(110, from: 30, minutes: 5)
        XCTAssertTrue(WhoopActivityDetector.detect(hr: hr, restingBpm: 48, excluded: []).isEmpty)
    }

    /// A warm-up with exercise-like wrist motion joins the bout; one behind a longer break does not.
    func testWarmUpWithMotionMovesTheStartBack() {
        var hr = block(85, from: 0, minutes: 6)          // warm-up below the active bar, minutes 0-5
        hr += block(130, from: 6, minutes: 20)           // the game, minutes 6-25
        let base = 1_800_000_000 / 60
        var motion: [Int: Double] = [:]
        for m in 0..<26 { motion[base + m] = 0.8 }
        let found = WhoopActivityDetector.detect(hr: hr, restingBpm: 48, excluded: [], motion: motion)
        XCTAssertEqual(found.first?.startSec, 1_800_000_000)
        let still = WhoopActivityDetector.detect(hr: hr, restingBpm: 48, excluded: [])
        XCTAssertEqual(still.first?.startSec, 1_800_000_000 + 6 * 60)
    }

    /// A moving sport ends at its last moving, working minute; the walk-off at a raised heart rate is not
    /// part of it.
    func testCoolDownWalkIsNotPartOfAMovingSport() {
        var hr = block(140, from: 0, minutes: 20)         // the game, minutes 0-19
        hr += block(110, from: 20, minutes: 10)           // walking off, still above the active bar
        let base = 1_800_000_000 / 60
        var motion: [Int: Double] = [:]
        for m in 0..<20 { motion[base + m] = 1.0 }
        for m in 20..<30 { motion[base + m] = 0.12 }
        let found = WhoopActivityDetector.detect(hr: hr, restingBpm: 48, excluded: [], motion: motion)
        XCTAssertEqual(found.first?.endSec, 1_800_000_000 + 19 * 60 + 59)
        XCTAssertEqual(WhoopActivityDetector.detect(hr: hr, restingBpm: 48, excluded: []).first?.endSec,
                       1_800_000_000 + 29 * 60 + 59)
    }
}
