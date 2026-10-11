import Foundation
import WhoopProtocol

// SleepStager+Bedtime.swift - Yoop: where the night starts.
//
// The detector starts a night at the first sustained stillness. That is not the minute the wearer got into
// bed: a phone in hand, settling and turning keep the stillness test from firing for a while after lying
// down. On the night of 10 to 11 Oct 2026 the wearer sat still on the couch until 01:40 (HR 75), walked about
// until 01:55 (HR 100 to 112) getting ready, lay down at about 01:56 (the wrist turns into the sleeping
// posture, HR 80), and the detector started the night at 02:15:10, 19 minutes later. Time asleep was right
// (416 min), but efficiency (87.5 %) and time to fall asleep (25 min, against about 44) were not.
//
// THE RULE. Start the night at the end of the last real walk before it. A real walk is a run of walk-labelled
// step seconds (`bedtimeMinWalkSeconds` or more, merged across pauses shorter than `bedtimeWalkMergeGapS`),
// so a few steps rolling over in bed do not count. The start moves only when ALL of these hold:
//   - the walk ended `bedtimeMinShiftS` seconds to `bedtimeMaxShiftMin` minutes before the detector's start
//     (the cap is the most a wrong anchor can cost: 1.5 times the longest gap seen, 19 min);
//   - no other real walk lies between the walk's end and the sleep onset, and the onset follows within
//     `bedtimeMaxLatencyMin` (a walk that is followed by more walking was not the walk to bed);
//   - the wearer was not asleep in the `bedtimeReturnGuardMin` before the walk (a bathroom trip in the middle
//     of a night is a return to bed, not a bed time), and the session is a night, not a nap;
//   - the step and heart rate streams cover the gap (a hole could hide a later walk);
//   - heart rate settled below its level during the walk, and the wrist then lay in the posture the night is
//     slept in (within `bedtimePostureMaxDeg` of it), which the couch and the desk are not.
// It never reaches back over stillness: the only anchor is a walk, so the long sedentary stretch before bed
// (00:30 to 01:40 above) is never pulled into the night. The start only moves earlier, and the added time
// reads as wake, so time asleep does not change.
//
// Every number is a first estimate set from the two nights that carry a real walk before bed, not a fit
// (the thresholds' comments say what each was set against); the rule does nothing unless the app sets
// `bedtimeFromWalkEnabled`. Swift only: the fork ships no Android build.

extension SleepStager {

    /// Yoop: start the night at the end of the last real walk before the detector's start, when the checks in
    /// the header above hold. Set by the app; off by default, so NOOP's output is unchanged.
    public static var bedtimeFromWalkEnabled: Bool = false

    /// Walk-labelled step seconds closer together than this belong to one walk. A walk to bed has pauses
    /// (a door, the lights, a toothbrush): on the known night its last 6 s of steps came 84 s after the rest.
    public static let bedtimeWalkMergeGapS: Int = 120

    /// A walk counts as a walk to bed from this many walk-labelled seconds (about 15 steps). On the user's
    /// nights the walks that led to bed were 16 and 48 seconds; the isolated bursts in bed were 2 to 6 (the
    /// 02:10 burst of 11 Oct, 5 s, moved the start 4 min when the bar was 5).
    public static let bedtimeMinWalkSeconds: Int = 10

    /// The most the start may move, in minutes. The gaps from the end of the walk to the detector's start
    /// were 16 and 19 min; 30 min is 1.5 times that, and bounds what a wrong anchor can cost.
    public static let bedtimeMaxShiftMin: Int = 30

    /// A move shorter than this (seconds) is not worth a new start.
    public static let bedtimeMinShiftS: Int = 120

    /// The longest, in minutes, from the end of the walk to the sleep onset. The user's two nights were 28
    /// and 45 min; past 90 the wearer has most likely got up again.
    public static let bedtimeMaxLatencyMin: Int = 90

    /// The shortest in-bed span, in minutes, of a session that has a bed time. Below it the session is a
    /// nap, whose start is wherever the wearer dozed off (the Yoop main night is three hours or more).
    public static let bedtimeMinNightMin: Int = 180

    /// Sleep in this many minutes before the walk means the walk was a return to bed, not a bed time.
    public static let bedtimeReturnGuardMin: Int = 180

    /// The largest angle, in degrees, between the wrist's orientation after the walk and the one the night is
    /// slept in (the first half hour after onset). After the walk it was 12 and 14 degrees on the two nights;
    /// the couch was 73 and 47 degrees from the posture slept in, so 30 keeps twice the margin on the bed side.
    public static let bedtimePostureMaxDeg: Double = 30

    /// A step second is a walking second when its counter moved and the strap labelled it walk or run, with
    /// no more than this many seconds since the previous record (a longer interval is a dropout).
    private static let bedtimeStepGapS = 2

    /// The walks in a step stream: runs of walk-labelled seconds merged across pauses shorter than
    /// `mergeGapS`, oldest first. Class 0 ticks are the pedometer's held steps released in one second, so
    /// they never decide where a walk ends. A stream with no activity classes has no walks (the counter
    /// alone also moves with the arm). Pure.
    static func walkBursts(_ steps: [StepSample],
                           mergeGapS: Int = bedtimeWalkMergeGapS) -> [(start: Int, end: Int, seconds: Int)] {
        let s = steps.sorted { $0.ts < $1.ts }
        var out: [(start: Int, end: Int, seconds: Int)] = []
        guard s.count >= 2 else { return out }
        for i in 1..<s.count {
            let dt = s[i].ts - s[i - 1].ts
            let delta = (s[i].counter - s[i - 1].counter) & 0xFFFF
            guard dt >= 1, dt <= bedtimeStepGapS, delta >= 1, delta < StepsCounter.maxStepDelta,
                  let c = s[i].activityClass, c == 1 || c == 2 else { continue }
            let ts = s[i].ts
            if let last = out.last, ts - last.end <= mergeGapS {
                out[out.count - 1] = (start: last.start, end: ts, seconds: last.seconds + 1)
            } else {
                out.append((start: ts, end: ts, seconds: 1))
            }
        }
        return out
    }

    /// Where one session's night should start, and why: the end of the last real walk before it when every
    /// check in the header holds, else the session's own start. `others` are the day's other sessions. The
    /// reason is a short token for the trace and the tests: "moved", or the first check that refused.
    /// Pure + deterministic.
    static func bedtimeDecision(_ s: SleepSession,
                                others: [SleepSession],
                                steps: [StepSample],
                                hr: [HRSample],
                                grav: [GravitySample],
                                bandSleepState: [(ts: Int, state: Int)],
                                minWalkSeconds: Int = bedtimeMinWalkSeconds,
                                mergeGapS: Int = bedtimeWalkMergeGapS,
                                maxShiftMin: Int = bedtimeMaxShiftMin,
                                maxLatencyMin: Int = bedtimeMaxLatencyMin,
                                postureMaxDeg: Double = bedtimePostureMaxDeg) -> (start: Int, reason: String) {
        let maxShiftS = maxShiftMin * 60
        let latencyS = maxLatencyMin * 60
        let returnGuardS = bedtimeReturnGuardMin * 60
        let median = { (xs: [Int]) -> Double? in
            guard !xs.isEmpty else { return nil }
            let v = xs.sorted(), n = v.count
            return n % 2 == 1 ? Double(v[n / 2]) : Double(v[n / 2 - 1] + v[n / 2]) / 2.0
        }
        // The mean direction of gravity over [lo, hi), as a unit vector, or nil on fewer than 20 samples.
        let direction = { (lo: Int, hi: Int) -> (Double, Double, Double)? in
            var x = 0.0, y = 0.0, z = 0.0, n = 0
            for g in grav where g.ts >= lo && g.ts < hi { x += g.x; y += g.y; z += g.z; n += 1 }
            let norm = (x * x + y * y + z * z).squareRoot()
            return n < 20 || norm <= 0 ? nil : (x / norm, y / norm, z / norm)
        }
        let keep = { (why: String) -> (start: Int, reason: String) in (start: s.start, reason: why) }
        guard !s.hrOnly, s.end - s.start >= bedtimeMinNightMin * 60 else { return keep("notNight") }
        guard let onset = s.stages.first(where: { !SleepStageVocabulary.isWake($0.stage) })?.start,
              onset >= s.start else { return keep("noOnset") }
        // Only the stream around the start matters; this keeps a two-day window cheap.
        let near = steps.filter { $0.ts >= s.start - maxShiftS - 3600 && $0.ts <= onset + latencyS }
        guard near.contains(where: { $0.activityClass != nil }) else { return keep("noSteps") }
        let walks = walkBursts(near, mergeGapS: mergeGapS).filter { $0.seconds >= minWalkSeconds }
        // The last real walk that began before the detector's start, and it must be over by then.
        guard let walk = walks.last(where: { $0.start < s.start }) else { return keep("noWalk") }
        guard walk.end < s.start else { return keep("walkIntoSession") }
        let shift = s.start - walk.end
        guard shift >= bedtimeMinShiftS else { return keep("tinyShift") }
        guard shift <= maxShiftS else { return keep("farBack") }
        guard onset - walk.end <= latencyS else { return keep("slowOnset") }
        // Nothing more than a few steps between the walk and the onset: more walking means this was not the
        // walk to bed.
        guard !walks.contains(where: { $0.start > walk.end && $0.start <= max(onset, s.start) }) else {
            return keep("moreWalking")
        }
        // A return to bed in the middle of a night: another session just before, or the band asleep.
        guard !others.contains(where: { $0 != s && $0.start < s.start && $0.end > walk.end - returnGuardS })
        else { return keep("afterSleep") }
        let asleepMinutes = Set(bandSleepState
            .filter { $0.state == bandStateAsleep && $0.ts >= walk.end - returnGuardS && $0.ts < walk.end }
            .map { $0.ts / 60 }).count
        guard asleepMinutes < 10 else { return keep("afterSleep") }
        // The streams must cover the gap, or a later walk could be hiding in a hole.
        let gapStepRows = near.filter { $0.ts >= walk.end && $0.ts <= s.start }.count
        let gapHr = hr.filter { $0.ts > walk.end && $0.ts <= s.start }
        guard Double(gapStepRows) >= 0.8 * Double(shift), Double(gapHr.count) >= 0.6 * Double(shift) else {
            return keep("gap")
        }
        guard let hrAfter = median(gapHr.map { $0.bpm }),
              let hrWalk = median(hr.filter { $0.ts >= walk.start && $0.ts <= walk.end }.map { $0.bpm }),
              hrAfter <= hrWalk else { return keep("heartRate") }
        // Lying down: the wrist is in the posture this night is slept in.
        guard let slept = direction(onset, onset + 1800),
              let after = direction(walk.end + 60, s.start) else { return keep("noPosture") }
        let dot = max(-1.0, min(1.0, slept.0 * after.0 + slept.1 * after.1 + slept.2 * after.2))
        guard acos(dot) * 180.0 / Double.pi <= postureMaxDeg else { return keep("posture") }
        return (start: walk.end, reason: "moved")
    }

    /// Move each night's start to the end of the last real walk before it, when every check in the header
    /// holds (`bedtimeDecision`); any other session, and any night a check refuses, comes back as it went
    /// in. The time added before the old start is wake, so asleep time is unchanged and efficiency is
    /// recomputed over the longer span. `steps`, `hr`, `grav` and `bandSleepState` are the streams the day
    /// was scored from. Off, or no step stream, returns `sessions` unchanged. Pure + deterministic.
    public static func refineBedtime(_ sessions: [SleepSession],
                                     steps: [StepSample],
                                     hr: [HRSample],
                                     grav: [GravitySample],
                                     bandSleepState: [(ts: Int, state: Int)],
                                     enabled: Bool = bedtimeFromWalkEnabled) -> [SleepSession] {
        guard enabled, !sessions.isEmpty, !steps.isEmpty else { return sessions }
        return sessions.map { s in
            let d = bedtimeDecision(s, others: sessions, steps: steps, hr: hr, grav: grav,
                                    bandSleepState: bandSleepState)
            guard d.start < s.start else { return s }
            // The gap before the old start reads as wake.
            var stages = s.stages
            if let first = stages.first, SleepStageVocabulary.isWake(first.stage), first.start == s.start {
                stages[0].start = d.start
            } else {
                stages.insert(StageSegment(start: d.start, end: s.start, stage: "wake"), at: 0)
            }
            return SleepSession(start: d.start, end: s.end,
                                efficiency: efficiency(start: d.start, end: s.end, stages: stages),
                                stages: stages, restingHR: s.restingHR, avgHRV: s.avgHRV, hrOnly: s.hrOnly)
        }
    }
}
