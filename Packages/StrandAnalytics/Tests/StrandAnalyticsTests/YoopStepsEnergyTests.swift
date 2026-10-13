import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The Yoop step rules (`StepsCounter.yoopCountingEnabled`). The switch is off by default; each test turns it
/// on and `tearDown` puts it back, so the NOOP tests elsewhere keep their default path. The Yoop energy has
/// its own tests (`YoopEnergyLineTests`).
final class YoopStepsEnergyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StepsCounter.yoopCountingEnabled = true
    }

    override func tearDown() {
        StepsCounter.yoopCountingEnabled = false
        super.tearDown()
    }

    private func s(_ ts: Int, _ counter: Int, _ cls: Int? = 1) -> StepSample {
        StepSample(ts: ts, counter: counter, activityClass: cls)
    }

    private func count(_ samples: [StepSample], sleeps: [SleepSession] = []) -> SleepAwareStepCounter.Count {
        SleepAwareStepCounter.count(samples, sleepSessions: sleeps)
    }

    // MARK: - Steps

    func testStillReleaseBatchJustBeforeTheWalkCounts() {
        // The pedometer releases the 6 steps it held, labelled still, one second before the walk label.
        let samples = [s(9, 100, 0), s(10, 106, 0), s(11, 108, 1), s(12, 110, 1)]
        XCTAssertEqual(count(samples).totalTicks, 10)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(count(samples).totalTicks, 4)
    }

    func testStillReleaseBatchJustAfterAWalkCounts() {
        let samples = [s(9, 100, 1), s(10, 102, 1), s(12, 109, 0)]
        XCTAssertEqual(count(samples).totalTicks, 9)
    }

    func testStillReleaseBatchFarFromAnyWalkIsRejected() {
        let result = count([s(9, 100, 0), s(10, 106, 0), s(100, 106, 0), s(101, 108, 1)])
        XCTAssertEqual(result.totalTicks, 2)
        XCTAssertEqual(result.rejectedActivityClassTicks, 6)
    }

    func testStillTicksOutsideTheReleaseSizeAreRejected() {
        let result = count([s(9, 100, 0), s(10, 103, 0), s(11, 105, 1)])
        XCTAssertEqual(result.totalTicks, 2)
        XCTAssertEqual(result.rejectedActivityClassTicks, 3)
    }

    func testHeldReleaseSettlesAcrossPages() {
        let accumulator = SleepAwareStepCounter.Accumulator(sleepSessions: [], hasActivityClasses: true)
        accumulator.acceptPage([s(9, 100, 0), s(10, 107, 0)])
        accumulator.acceptPage([s(11, 109, 1)])
        XCTAssertEqual(accumulator.finish().totalTicks, 9)
    }

    func testReleaseStillHeldAtTheEndIsRejected() {
        let result = count([s(9, 100, 1), s(100, 100, 0), s(101, 106, 0)])
        XCTAssertEqual(result.totalTicks, 0)
        XCTAssertEqual(result.rejectedActivityClassTicks, 6)
    }

    func testWalkReleaseOfNineInOneSecondCounts() {
        XCTAssertEqual(count([s(0, 100), s(1, 109)]).totalTicks, 9)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(count([s(0, 100), s(1, 109)]).totalTicks, 0)
    }

    func testAbsurdOneSecondJumpIsRejected() {
        // A release plus 3.5 steps a second allows 12 in one second.
        XCTAssertEqual(count([s(0, 100), s(1, 112)]).totalTicks, 12)
        let result = count([s(0, 100), s(1, 113)])
        XCTAssertEqual(result.totalTicks, 0)
        XCTAssertEqual(result.rejectedImplausibleTicks, 13)
    }

    func testDropoutTicksCountWhateverTheClosingLabel() {
        // 1,543 steps across a 2,192 s dropout while worn, closed by a still second (9 Oct 2026).
        let samples = [s(0, 31_055, 0), s(2_192, 32_598, 0)]
        XCTAssertEqual(count(samples).totalTicks, 1_543)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(count(samples).totalTicks, 0)
    }

    func testDropoutFasterThanAnyCadenceIsRejected() {
        // 100 s allow 9 + 350 = 359.
        XCTAssertEqual(count([s(0, 1_000), s(100, 1_359)]).totalTicks, 359)
        XCTAssertEqual(count([s(0, 1_000), s(100, 1_360)]).rejectedImplausibleTicks, 360)
    }

    func testCounterDecreaseIsAResetNotAWrap() {
        // 3 h dropout, counter 30,000 then 5: the wrapped 35,541 would pass the cadence limit, but a
        // decrease counts only as a wrap under the old 512 guard. Counting resumes from the new value.
        let result = count([s(0, 30_000), s(10_800, 5), s(10_801, 7)])
        XCTAssertEqual(result.totalTicks, 2)
        XCTAssertEqual(result.rejectedImplausibleTicks, 35_541)
    }

    func testU16WrapStillCounts() {
        XCTAssertEqual(count([s(0, 65_534), s(1, 2)]).totalTicks, 4)
    }

    func testStepsInWindowFollowsTheSwitch() {
        let samples = [s(9, 100, 0), s(10, 106, 0), s(11, 108, 1), s(12, 110, 1)]
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 10)
        StepsCounter.yoopCountingEnabled = false
        XCTAssertEqual(StepsCounter.stepsInWindow(samples), 4)
    }

    func testMinuteTicksHoldExactlyTheAcceptedTicks() {
        // Two minutes awake, then a night with one isolated bed tick and one coherent walk.
        let night = SleepSession(start: 1_000, end: 2_000, efficiency: 1, stages: [], restingHR: nil, avgHRV: nil)
        let samples = [s(50, 100), s(59, 102), s(61, 105), s(62, 106, 0),
                       s(1_100, 106), s(1_101, 107),
                       s(1_500, 107), s(1_501, 109), s(1_502, 111), s(1_503, 113), s(1_504, 115), s(1_505, 117)]
        let accumulator = SleepAwareStepCounter.Accumulator(sleepSessions: [night], hasActivityClasses: true,
                                                            recordsMinutes: true)
        let result = accumulator.acceptPage(samples).finish()
        XCTAssertEqual(result.totalTicks, 15)
        XCTAssertEqual(result.rejectedIsolatedSleepTicks, 1)
        XCTAssertEqual(accumulator.acceptedTicksByMinute, [0: 2, 1: 3, 25: 10])
    }
}
