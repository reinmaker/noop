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

    /// 12 Oct lifting: sets at 95-130 bpm with four-minute rests at 80-90 bpm, the wrist moving about 0.3 g
    /// throughout. It is one bout over its whole span, not a one-minute stub from the motion-based
    /// cool-down (the median motion alone made it a "moving sport" whose last "playing" minute was its first).
    func testLiftingWithLongRestsAndModerateMotionIsOneBout() {
        var hr: [(ts: Int, bpm: Int)] = []
        hr += block(105, from: 0, minutes: 4)
        hr += block(130, from: 4, minutes: 4)             // the hardest set, peak 130
        hr += block(98, from: 8, minutes: 6)
        hr += block(84, from: 14, minutes: 4)              // a four-minute rest between sets
        hr += block(100, from: 18, minutes: 14)
        hr += block(86, from: 32, minutes: 4)              // another rest
        hr += block(96, from: 36, minutes: 10)
        let base = 1_800_000_000 / 60
        var motion: [Int: Double] = [:]
        for m in 0..<46 { motion[base + m] = 0.32 }
        let found = WhoopActivityDetector.detect(hr: hr, restingBpm: 50, excluded: [], motion: motion)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.startSec, 1_800_000_000)
        XCTAssertEqual(found.first?.endSec, 1_800_000_000 + 45 * 60 + 59)
    }

    /// One active minute set apart by three quiet ones after the last set is not part of the session.
    func testALoneMinuteAfterTheLastSetDoesNotExtendTheBout() {
        var hr = block(125, from: 0, minutes: 16)
        hr += block(80, from: 16, minutes: 3)
        hr += block(95, from: 19, minutes: 1)              // a brisk minute walking out, just above the bar
        hr += block(78, from: 20, minutes: 5)
        let found = WhoopActivityDetector.detect(hr: hr, restingBpm: 50, excluded: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.endSec, 1_800_000_000 + 15 * 60 + 59)
    }

    /// A rest of six minutes still splits two efforts.
    func testSixMinuteBreakSplitsTwoEfforts() {
        var hr = block(125, from: 0, minutes: 14)
        hr += block(80, from: 14, minutes: 6)
        hr += block(125, from: 20, minutes: 14)
        XCTAssertEqual(WhoopActivityDetector.detect(hr: hr, restingBpm: 50, excluded: []).count, 2)
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

    /// 22 Oct 2026, from the wearer's own heart rate, one mean per minute from 17:50: a run at 138 to 192 bpm from
    /// minute 30 (18:20) to about minute 73 (19:03), then walking and sitting at 95 to 115 bpm until minute 210.
    /// That tail never fell under the active bar (92 bpm), so the activity ran to the end of the data (187 minutes,
    /// 18:12 to 21:18) and was typed Tennis; it now ends where the hard part ends.
    private let runAndCoolDown: [Int] = [
        64, 68, 71, 69, 70, 73, 71, 70, 78, 72, 77, 81, 79, 81, 81,
        77, 79, 72, 82, 80, 80, 85, 92, 90, 97, 93, 94, 86, 81, 117,
        138, 147, 156, 159, 162, 160, 162, 170, 175, 182, 182, 179, 180, 184, 187,
        187, 186, 185, 186, 187, 187, 188, 185, 171, 178, 185, 188, 186, 185, 187,
        188, 188, 191, 192, 192, 176, 168, 158, 157, 181, 173, 161, 153, 144, 142,
        130, 122, 127, 131, 139, 129, 120, 115, 111, 108, 109, 108, 105, 103, 104,
        99, 100, 102, 102, 103, 103, 108, 106, 111, 112, 116, 109, 114, 113, 109,
        104, 100, 112, 113, 110, 104, 100, 96, 93, 95, 92, 96, 92, 95, 88,
        86, 99, 104, 98, 102, 104, 102, 104, 107, 104, 98, 100, 100, 103, 102,
        102, 106, 96, 99, 103, 105, 103, 102, 97, 93, 98, 103, 107, 109, 105,
        105, 105, 107, 108, 106, 106, 103, 102, 105, 101, 88, 96, 92, 94, 93,
        85, 79, 72, 72, 81, 93, 100, 109, 107, 102, 92, 96, 99, 100, 84,
        87, 94, 98, 94, 92, 99, 100, 98, 96, 97, 94, 94, 96, 94, 96,
        96, 94, 96, 97, 95, 96, 100, 101, 90, 93, 95, 98, 92, 96, 82,
        80,
    ]

    func testAHardRunIsNotStretchedByTheEasyHoursAfterIt() throws {
        let base = 1_800_000_000
        let hr = runAndCoolDown.enumerated().filter { $0.element > 0 }.map { (ts: base + $0.offset * 60, bpm: $0.element) }
        let found = try XCTUnwrap(WhoopActivityDetector.detect(hr: hr, restingBpm: 50, excluded: []).first)
        XCTAssertEqual((found.startSec - base) / 60, 22, accuracy: 3, "starts as the effort starts")
        XCTAssertLessThan((found.endSec - base) / 60, 95, "ends within a few minutes of the hard part")
        XCTAssertGreaterThan((found.endSec - base) / 60, 73, "keeps the hard part")
        XCTAssertLessThan(found.durationMin, 80)
        XCTAssertGreaterThan(found.avgBpm, 140, "the hard part sets the average, not the walk home")
    }

    /// A walk-off close to the effort level stays with the session (the cool-down cut is for a long, much easier tail).
    func testABriskWalkOffStaysInTheSession() {
        var hr = block(150, from: 0, minutes: 30)
        hr += block(112, from: 30, minutes: 20)
        let found = WhoopActivityDetector.detect(hr: hr, restingBpm: 50, excluded: [])
        XCTAssertEqual(found.first?.endSec, 1_800_000_000 + 49 * 60 + 59)
    }
}
