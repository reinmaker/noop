import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// Naming an activity from the strap's step record as well as heart rate (`WhoopActivityTyper.stepShape`, `refine`).
/// The shapes are the wearer's own, 2 Nov 2026: a 6 km run named Tennis (run share 0.90, 126 ticks a minute), housework
/// named Weightlifting (68 walking ticks a minute), and their lifting sessions (16 to 45).
final class ActivityStepShapeTests: XCTestCase {

    /// One sample a second over `minutes`, the counter climbing `perSecond` ticks a second under `cls`.
    private func samples(minutes: Int, perSecond: Int, cls: Int, from start: Int = 1_000_000) -> [StepSample] {
        var counter = 100
        return (0...(minutes * 60)).map { k in
            counter = (counter + perSecond) & 0xFFFF
            return StepSample(ts: start + k, counter: counter, activityClass: cls)
        }
    }

    func testARunReadsAsMostlyRunTicks() throws {
        let shape = try XCTUnwrap(WhoopActivityTyper.stepShape(samples(minutes: 30, perSecond: 2, cls: 2),
                                                               startSec: 1_000_000, endSec: 1_000_000 + 1_800))
        XCTAssertEqual(shape.runShare, 1.0, accuracy: 1e-9)
        XCTAssertEqual(shape.ticksPerMin, 120, accuracy: 1)
        XCTAssertEqual(shape.walkTicksPerMin, 0, accuracy: 1e-9)
    }

    func testWalkingWorkReadsAsWalkTicks() throws {
        let shape = try XCTUnwrap(WhoopActivityTyper.stepShape(samples(minutes: 30, perSecond: 1, cls: 1),
                                                               startSec: 1_000_000, endSec: 1_000_000 + 1_800))
        XCTAssertEqual(shape.runShare, 0, accuracy: 1e-9)
        XCTAssertEqual(shape.walkTicksPerMin, 60, accuracy: 1)
    }

    /// Too few samples, a backwards window or a counter that jumps give no shape or ignore the jump.
    func testNoShapeWithoutEnoughSteps() {
        XCTAssertNil(WhoopActivityTyper.stepShape([], startSec: 0, endSec: 600))
        XCTAssertNil(WhoopActivityTyper.stepShape(samples(minutes: 0, perSecond: 1, cls: 1), startSec: 1_000_000, endSec: 1_000_000))
        var jump = samples(minutes: 2, perSecond: 1, cls: 1)
        jump[30] = StepSample(ts: jump[30].ts, counter: (jump[29].counter + 5_000) & 0xFFFF, activityClass: 1)
        let shape = WhoopActivityTyper.stepShape(jump, startSec: 1_000_000, endSec: 1_000_000 + 120)
        XCTAssertNotNil(shape)
        XCTAssertLessThan(shape?.ticksPerMin ?? .infinity, 70, "a reboot-sized jump is not counted")
    }

    /// A bout that runs is Running, whatever heart rate said: the 2 Nov 2026 run was named Tennis.
    func testARunIsNamedRunning() {
        let run = WhoopActivityTyper.StepShape(ticksPerMin: 126, walkTicksPerMin: 12, runShare: 0.90)
        XCTAssertEqual(WhoopActivityTyper.refine("Tennis", shape: run), "Running")
        XCTAssertEqual(WhoopActivityTyper.refine(nil, shape: run), "Running")
        let ropeSkipping = WhoopActivityTyper.StepShape(ticksPerMin: 76, walkTicksPerMin: 59, runShare: 0.14)
        XCTAssertEqual(WhoopActivityTyper.refine("Jump rope", shape: ropeSkipping), "Jump rope")
        let tennis = WhoopActivityTyper.StepShape(ticksPerMin: 97, walkTicksPerMin: 95, runShare: 0)
        XCTAssertEqual(WhoopActivityTyper.refine("Tennis", shape: tennis), "Tennis")
    }

    /// Lifting is not named for a bout that walks about; the wearer's own lifting reads 16 to 45 a minute.
    func testWalkingWorkIsNotWeightlifting() {
        let housework = WhoopActivityTyper.StepShape(ticksPerMin: 76, walkTicksPerMin: 68, runShare: 0.06)
        XCTAssertNil(WhoopActivityTyper.refine("Weightlifting", shape: housework), "no name, so it stays Activity")
        XCTAssertEqual(WhoopActivityTyper.refine("Tennis", shape: housework), "Tennis")
        for walk in [16.0, 23, 31, 45] {
            let lifting = WhoopActivityTyper.StepShape(ticksPerMin: walk + 5, walkTicksPerMin: walk, runShare: 0.02)
            XCTAssertEqual(WhoopActivityTyper.refine("Weightlifting", shape: lifting), "Weightlifting", "\(walk)")
        }
    }

    /// With no step record the guess stands.
    func testWithoutASHapeTheGuessStands() {
        XCTAssertEqual(WhoopActivityTyper.refine("Tennis", shape: nil), "Tennis")
        XCTAssertNil(WhoopActivityTyper.refine(nil, shape: nil))
    }
}
