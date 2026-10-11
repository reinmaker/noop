import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Yoop: a night starts at the end of the last real walk before the detector's start
/// (`SleepStager.refineBedtime`). Every vector here is synthetic and says so: a couch, a walk, a bed, and the
/// detector's start some minutes after it, laid on a one-second timeline.
final class SleepStagerBedtimeTests: XCTestCase {
    private let t0 = 1_791_600_000
    private func m(_ minutes: Double) -> Int { t0 + Int((minutes * 60).rounded()) }

    private let couch: (Double, Double, Double) = (0.92, 0.25, -0.20)
    private let bed: (Double, Double, Double) = (0.64, -0.50, 0.59)

    override func tearDown() {
        SleepStager.bedtimeFromWalkEnabled = false
        super.tearDown()
    }

    private struct Streams {
        var steps: [StepSample] = []
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
    }

    /// One record a second from minute 0 to `totalMin`: the counter climbs by 2 a second, labelled walk,
    /// inside each `walks` range, and holds, labelled still, outside them.
    private func streams(totalMin: Double,
                         walks: [(from: Double, to: Double)],
                         hr: (Double) -> Int,
                         posture: (Double) -> (Double, Double, Double)) -> Streams {
        var out = Streams()
        var counter = 1000
        for k in 0..<Int(totalMin * 60) {
            let minute = Double(k) / 60.0
            let walking = walks.contains { minute >= $0.from && minute < $0.to }
            if walking { counter += 2 }
            out.steps.append(StepSample(ts: t0 + k, counter: counter, activityClass: walking ? 1 : 0))
            out.hr.append(HRSample(ts: t0 + k, bpm: hr(minute)))
            let p = posture(minute)
            out.grav.append(GravitySample(ts: t0 + k, x: p.0, y: p.1, z: p.2))
        }
        return out
    }

    /// A night: wake from `start` to `onset` (none when they are the same), light after, ending `hours` after
    /// the start.
    private func night(start: Double, onset: Double, hours: Double = 8) -> SleepSession {
        let s = m(start), o = m(onset), e = m(start + hours * 60)
        var stages = [StageSegment(start: o, end: e, stage: "light")]
        if o > s { stages.insert(StageSegment(start: s, end: o, stage: "wake"), at: 0) }
        return SleepSession(start: s, end: e, efficiency: SleepStager.efficiency(start: s, end: e, stages: stages),
                            stages: stages, restingHR: 52, avgHRV: 80)
    }

    private func asleepMinutes(_ s: SleepSession) -> Int {
        s.stages.filter { !SleepStageVocabulary.isWake($0.stage) }.reduce(0) { $0 + ($1.end - $1.start) } / 60
    }

    /// The scene most tests start from: the couch until minute 108, a two-minute walk to bed, lying down at
    /// 110 (HR settles from 85 to 65), and the detector starting the night at minute `startMin`.
    private func scene(walkEnd: Double = 110, startMin: Double = 130, onsetMin: Double = 150,
                       extraWalks: [(from: Double, to: Double)] = [],
                       afterWalkHr: Int = 85,
                       afterWalkPosture: (Double, Double, Double)? = nil) -> (Streams, SleepSession) {
        let walk = (from: walkEnd - 2, to: walkEnd)
        let bedPosture = afterWalkPosture ?? bed
        func heartRate(_ minute: Double) -> Int {
            if minute < walk.from { return 75 }
            if minute < walk.to { return 105 }
            return minute < walkEnd + 15 ? afterWalkHr : 65
        }
        func posture(_ minute: Double) -> (Double, Double, Double) {
            if minute < walkEnd { return couch }
            return minute < onsetMin ? bedPosture : bed
        }
        let s = streams(totalMin: onsetMin + 45, walks: [walk] + extraWalks, hr: heartRate, posture: posture)
        return (s, night(start: startMin, onset: onsetMin))
    }

    private func refine(_ sessions: [SleepSession], _ s: Streams, band: [(ts: Int, state: Int)] = [],
                        enabled: Bool = true) -> [SleepSession] {
        SleepStager.refineBedtime(sessions, steps: s.steps, hr: s.hr, grav: s.grav, bandSleepState: band,
                                  enabled: enabled)
    }

    private func decide(_ session: SleepSession, _ s: Streams, others: [SleepSession] = [],
                        band: [(ts: Int, state: Int)] = []) -> (start: Int, reason: String) {
        SleepStager.bedtimeDecision(session, others: others, steps: s.steps, hr: s.hr, grav: s.grav,
                                    bandSleepState: band)
    }

    /// The couch, a walk to bed, lying down, and a detector start 20 min later: the start moves to the end of
    /// the walk, the time between reads as wake (the night's own leading wake, extended), the time asleep is
    /// untouched and the efficiency falls with the longer span.
    func testWalkThenBedMovesTheStart() {
        let (s, night) = scene()
        let out = refine([night], s)[0]
        XCTAssertEqual(out.start, m(110) - 1)
        XCTAssertEqual(out.end, night.end)
        XCTAssertEqual(out.stages, [StageSegment(start: m(110) - 1, end: m(150), stage: "wake"), night.stages[1]])
        XCTAssertEqual(asleepMinutes(out), asleepMinutes(night))
        XCTAssertLessThan(out.efficiency, night.efficiency)
        XCTAssertEqual(out.restingHR, 52)
        XCTAssertEqual(out.avgHRV, 80)
        XCTAssertEqual(decide(night, s).reason, "moved")
    }

    /// A night the detector opened on sleep, not wake, gets a wake segment for the added time.
    func testSleepFromTheStartGetsAWakeSegmentInFront() {
        let (s, _) = scene(startMin: 130, onsetMin: 130)
        let sleeper = night(start: 130, onset: 130)
        XCTAssertEqual(sleeper.stages.count, 1)
        let out = refine([sleeper], s)[0]
        XCTAssertEqual(out.stages, [StageSegment(start: m(110) - 1, end: m(130), stage: "wake"), sleeper.stages[0]])
        XCTAssertEqual(asleepMinutes(out), asleepMinutes(sleeper))
    }

    /// A long sedentary stretch before bed is not pulled into the night: the only walk was an hour back, or
    /// two hours back, and the stillness since is not an anchor.
    func testLongSedentaryStretchBeforeBedDoesNotMove() {
        let (s, night) = scene(walkEnd: 70)
        XCTAssertEqual(refine([night], s)[0], night)
        XCTAssertEqual(decide(night, s).reason, "farBack")
        let (s2, night2) = scene(walkEnd: 10)
        XCTAssertEqual(refine([night2], s2)[0], night2)
    }

    /// No walk at all: couch, then the detector's start. Nothing to anchor on.
    func testNoWalkLeavesTheStartAlone() {
        let st = streams(totalMin: 195, walks: [], hr: { _ in 75 }, posture: { _ in self.couch })
        let n = night(start: 130, onset: 150)
        XCTAssertEqual(refine([n], st)[0], n)
        XCTAssertEqual(decide(n, st).reason, "noWalk")
    }

    /// A few steps rolling over in bed are not a walk: a 5 s burst 4 min before the start does not anchor,
    /// and one after the real walk does not replace it.
    func testSmallBurstsInBedAreNotAWalk() {
        let burst = (from: 126.0, to: 126.0 + 5.0 / 60.0)
        let st = streams(totalMin: 195, walks: [burst], hr: { _ in 75 }, posture: { _ in self.bed })
        let n = night(start: 130, onset: 150)
        XCTAssertEqual(decide(n, st).reason, "noWalk")
        let (s, night2) = scene(extraWalks: [(from: 126.0, to: 126.0 + 5.0 / 60.0)])
        XCTAssertEqual(refine([night2], s)[0].start, m(110) - 1)
    }

    /// A bathroom walk in the middle of a night, then a second session after it: that is a return to bed.
    /// The other session before it, or the band asleep before it, each refuse alone.
    func testMidNightBathroomWalkIsNotABedTime() {
        let walkAt = 305.0
        let st = streams(totalMin: 318 + 20 + 45, walks: [(from: walkAt, to: walkAt + 2)],
                         hr: { $0 < walkAt ? 55 : ($0 < walkAt + 2 ? 90 : 62) },
                         posture: { $0 < walkAt ? self.bed : self.bed })
        let first = night(start: 0, onset: 20, hours: 5)
        let second = night(start: 318, onset: 338, hours: 4)
        XCTAssertEqual(decide(second, st).reason, "moved")                      // alone it would move
        XCTAssertEqual(decide(second, st, others: [first, second]).reason, "afterSleep")
        XCTAssertEqual(refine([first, second], st), [first, second])
        let band = stride(from: m(20), to: m(300), by: 30).map { (ts: $0, state: SleepStager.bandStateAsleep) }
        XCTAssertEqual(decide(second, st, band: band).reason, "afterSleep")
    }

    /// The cap: a walk that ended 29 min before the start moves it, 31 does not, and 1 does not either.
    func testTheCapAndTheMinimumShift() {
        for (gap, expected) in [(29.0, "moved"), (31.0, "farBack"), (1.0, "tinyShift")] {
            let (s, night) = scene(walkEnd: 130 - gap)
            XCTAssertEqual(decide(night, s).reason, expected, "gap \(gap)")
        }
        XCTAssertEqual(SleepStager.bedtimeMaxShiftMin, 30)
    }

    /// More walking between the walk and the onset means it was not the walk to bed.
    func testMoreWalkingBeforeOnsetRefuses() {
        let (s, night) = scene(extraWalks: [(from: 135, to: 136)])
        XCTAssertEqual(decide(night, s).reason, "moreWalking")
        XCTAssertEqual(refine([night], s)[0], night)
    }

    /// A walk that runs into the detector's session is not over when the session starts.
    func testWalkingIntoTheSessionRefuses() {
        let (s, night) = scene(startMin: 130, extraWalks: [(from: 129, to: 131)])
        XCTAssertEqual(decide(night, s).reason, "walkIntoSession")
    }

    /// The onset must follow the walk within the latency bound.
    func testSlowOnsetRefuses() {
        let (s, night) = scene(startMin: 130, onsetMin: 110 + 95)
        XCTAssertEqual(decide(night, s).reason, "slowOnset")
    }

    /// Sitting on after the walk: the wrist stays in the couch posture, not the one the night is slept in.
    func testCouchPostureAfterTheWalkRefuses() {
        let (s, night) = scene(afterWalkPosture: couch)
        XCTAssertEqual(decide(night, s).reason, "posture")
        XCTAssertEqual(refine([night], s)[0], night)
    }

    /// Heart rate that rose after the walk is not lying down.
    func testHeartRateAboveTheWalkRefuses() {
        let (s, night) = scene(afterWalkHr: 115)
        XCTAssertEqual(decide(night, s).reason, "heartRate")
    }

    /// A hole in the step stream over the gap could hide a later walk.
    func testMissingStepsOverTheGapRefuse() {
        let (whole, night) = scene()
        var s = whole
        s.steps = s.steps.filter { $0.ts < m(115) || $0.ts > m(125) }
        XCTAssertEqual(decide(night, s).reason, "gap")
    }

    /// A nap, or an hrOnly night, has no bed time.
    func testNapAndHrOnlyAreNotMoved() {
        let (s, _) = scene()
        let nap = night(start: 130, onset: 135, hours: 2)
        XCTAssertEqual(decide(nap, s).reason, "notNight")
        let n = night(start: 130, onset: 150)
        let hrOnly = SleepSession(start: n.start, end: n.end, efficiency: n.efficiency, stages: n.stages,
                                  restingHR: nil, avgHRV: nil, hrOnly: true)
        XCTAssertEqual(refine([hrOnly], s)[0], hrOnly)
    }

    /// Off: nothing changes, by argument and by the default knob. On by the knob: it moves.
    func testSwitchOffMeansNoChange() {
        let (s, night) = scene()
        XCTAssertFalse(SleepStager.bedtimeFromWalkEnabled)
        XCTAssertEqual(refine([night], s, enabled: false), [night])
        XCTAssertEqual(SleepStager.refineBedtime([night], steps: s.steps, hr: s.hr, grav: s.grav,
                                                 bandSleepState: []), [night])
        SleepStager.bedtimeFromWalkEnabled = true
        XCTAssertEqual(SleepStager.refineBedtime([night], steps: s.steps, hr: s.hr, grav: s.grav,
                                                 bandSleepState: [])[0].start, m(110) - 1)
        XCTAssertEqual(SleepStager.refineBedtime([night], steps: [], hr: s.hr, grav: s.grav,
                                                 bandSleepState: []), [night])
    }

    /// The walk finder: still ticks (the pedometer's held steps) never end a walk, the u16 counter wraps,
    /// pauses shorter than the merge gap join, and a stream with no activity classes has no walks.
    func testWalkBursts() {
        var steps: [StepSample] = []
        var c = 65_520
        func tick(_ ts: Int, _ add: Int, _ cls: Int?) { c = (c + add) & 0xFFFF; steps.append(StepSample(ts: ts, counter: c, activityClass: cls)) }
        tick(100, 0, 0)
        tick(101, 6, 0)                                  // a held release under the still label
        for k in 0..<12 { tick(102 + k, 2, 1) }          // 12 walking seconds, across the wrap
        tick(114, 6, 0)                                  // a release after the walk, not a walk
        for k in 115..<190 { tick(k, 0, 0) }              // still, a record a second
        for k in 0..<5 { tick(190 + k, 1, 2) }           // a run, 75 s later: merged at 120 s, apart at 60 s
        let merged = SleepStager.walkBursts(steps, mergeGapS: 120)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 102)
        XCTAssertEqual(merged[0].end, 194)
        XCTAssertEqual(merged[0].seconds, 17)
        let apart = SleepStager.walkBursts(steps, mergeGapS: 60)
        XCTAssertEqual(apart.map { $0.seconds }, [12, 5])
        XCTAssertEqual(SleepStager.walkBursts(steps.map { StepSample(ts: $0.ts, counter: $0.counter) }).count, 0)
    }
}
