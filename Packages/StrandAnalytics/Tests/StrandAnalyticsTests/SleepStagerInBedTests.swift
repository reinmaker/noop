import XCTest
@testable import StrandAnalytics

/// Yoop: a night is counted from its first asleep epoch to its last, as WHOOP counts time in bed
/// (`SleepStager.trimToSleep`). Every night here is synthetic: some minutes of wake, sleep with a wake in the
/// middle, and some minutes of wake at the end.
final class SleepStagerInBedTests: XCTestCase {
    private let t0 = 1_791_600_000
    private func m(_ minutes: Double) -> Int { t0 + Int((minutes * 60).rounded()) }

    override func tearDown() {
        SleepStager.inBedFromOnsetEnabled = false
        super.tearDown()
    }

    /// Wake 0-30, light 30-130, wake 130-150 (the awake time inside the night), deep 150-250, REM 250-300,
    /// wake 300-314.
    private func night(hrOnly: Bool = false) -> SleepSession {
        let stages = [
            StageSegment(start: m(0), end: m(30), stage: "wake"),
            StageSegment(start: m(30), end: m(130), stage: "light"),
            StageSegment(start: m(130), end: m(150), stage: "wake"),
            StageSegment(start: m(150), end: m(250), stage: "deep"),
            StageSegment(start: m(250), end: m(300), stage: "rem"),
            StageSegment(start: m(300), end: m(314), stage: "wake"),
        ]
        return SleepSession(start: m(0), end: m(314),
                            efficiency: SleepStager.efficiency(start: m(0), end: m(314), stages: stages),
                            stages: stages, restingHR: 51, avgHRV: 88, hrOnly: hrOnly)
    }

    func testNightRunsFromFirstAsleepToLastAndKeepsTheWakeInside() {
        let out = SleepStager.trimToSleep([night()], enabled: true)[0]
        XCTAssertEqual(out.start, m(30))
        XCTAssertEqual(out.end, m(300))
        XCTAssertEqual(out.stages.map { $0.stage }, ["light", "wake", "deep", "rem"])
        XCTAssertEqual(out.stages.first?.start, out.start)
        XCTAssertEqual(out.stages.last?.end, out.end)
        // The segments still tile the span with no gap.
        for (a, b) in zip(out.stages, out.stages.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        // 250 min asleep over 270 in bed; the 20 min of wake inside the night stay.
        XCTAssertEqual(out.efficiency, 250.0 / 270.0, accuracy: 1e-9)
        XCTAssertEqual(night().efficiency, 250.0 / 314.0, accuracy: 1e-9)
    }

    func testTimeAsleepDoesNotChange() {
        let before = night(), after = SleepStager.trimToSleep([night()], enabled: true)[0]
        let asleep = { (s: SleepSession) in
            s.stages.filter { $0.stage != "wake" }.reduce(0) { $0 + ($1.end - $1.start) }
        }
        XCTAssertEqual(asleep(before), asleep(after))
    }

    func testVitalsAndTheHrOnlyFlagAreCarried() {
        let out = SleepStager.trimToSleep([night(hrOnly: true)], enabled: true)[0]
        XCTAssertEqual(out.restingHR, 51)
        XCTAssertEqual(out.avgHRV, 88)
        XCTAssertTrue(out.hrOnly)
    }

    func testSwitchOffMeansNoChange() {
        let s = night()
        XCTAssertEqual(SleepStager.trimToSleep([s], enabled: false), [s])
        XCTAssertEqual(SleepStager.trimToSleep([s]), [s])   // the flag is off by default
        SleepStager.inBedFromOnsetEnabled = true
        XCTAssertNotEqual(SleepStager.trimToSleep([s]), [s])
    }

    func testNightWithNothingToCutAndNightWithNoSleepComeBackAsTheyWent() {
        let tight = SleepSession(start: m(0), end: m(60), efficiency: 1,
                                 stages: [StageSegment(start: m(0), end: m(60), stage: "light")],
                                 restingHR: nil, avgHRV: nil)
        let awake = SleepSession(start: m(0), end: m(60), efficiency: 0,
                                 stages: [StageSegment(start: m(0), end: m(60), stage: "wake")],
                                 restingHR: nil, avgHRV: nil)
        let bare = SleepSession(start: m(0), end: m(60), efficiency: 0, stages: [], restingHR: nil, avgHRV: nil)
        XCTAssertEqual(SleepStager.trimToSleep([tight, awake, bare], enabled: true), [tight, awake, bare])
        XCTAssertEqual(SleepStager.trimToSleep([], enabled: true), [])
    }

    func testOnlyTheEdgeThatHasWakeMoves() {
        let stages = [
            StageSegment(start: m(0), end: m(20), stage: "wake"),
            StageSegment(start: m(20), end: m(100), stage: "light"),
        ]
        let s = SleepSession(start: m(0), end: m(100), efficiency: 0.8, stages: stages, restingHR: nil, avgHRV: nil)
        let out = SleepStager.trimToSleep([s], enabled: true)[0]
        XCTAssertEqual(out.start, m(20))
        XCTAssertEqual(out.end, m(100))
        XCTAssertEqual(out.efficiency, 1.0, accuracy: 1e-9)
    }

    func testEveryNightInAListIsCutOnItsOwn() {
        let nap = SleepSession(start: m(1000), end: m(1060), efficiency: 0.5,
                               stages: [StageSegment(start: m(1000), end: m(1015), stage: "wake"),
                                        StageSegment(start: m(1015), end: m(1045), stage: "light"),
                                        StageSegment(start: m(1045), end: m(1060), stage: "wake")],
                               restingHR: nil, avgHRV: nil)
        let out = SleepStager.trimToSleep([night(), nap], enabled: true)
        XCTAssertEqual(out.map { $0.start }, [m(30), m(1015)])
        XCTAssertEqual(out.map { $0.end }, [m(300), m(1045)])
    }
}
