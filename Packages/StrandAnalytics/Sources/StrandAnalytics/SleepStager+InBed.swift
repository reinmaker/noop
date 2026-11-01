import Foundation
import WhoopProtocol

// SleepStager+InBed.swift - Yoop: where the night ends, and how long it counts as in bed.
//
// WHOOP times a night from the minute it scores the wearer asleep to the minute it scores them awake for
// good, and calls that span the time in bed: its efficiency is asleep over that span, and its awake time is
// what lies inside it. Over the wearer's 121 exported nights the awake time averages 32 min and efficiency
// 94 %. The detector's window is wider: on the 12 nights from 9 to 22 Oct 2026 it opened 30 min before the
// first asleep epoch and closed 14 min after the last, with 22 min awake in between, so the same sleep read
// 84 % efficient and lowered Sleep Performance (efficiency carries 0.368 of its fit) by about 4 points. On
// 10 Oct the wearer woke at about 10:00 and Yoop ended the night at 10:25.
//
// THE RULE. Cut each night to its first asleep epoch (light, deep or REM) through the end of its last. The
// wake before and after is dropped from the session and from its stages, so the session's own start, end
// and efficiency, the daily time in bed, the Sleep page, the bed and wake times that Consistency reads and
// the planner's usual times all say what WHOOP's say. Time asleep and the awake time inside the night do
// not change. A session with no asleep epoch, or one with nothing to cut, comes back as it went in.
//
// The rule does nothing unless the app sets `inBedFromOnsetEnabled`. Swift only: the fork ships no Android
// build.

// THE GAP BETWEEN TWO SLEEPS. The day's sleeps that lie less than 90 min apart are folded into one night, the gap
// counted as awake. That is right for a wake in bed and wrong when the wearer got up: on the night of 31 Oct to
// 1 Nov 2026 three sleeps (23:15 to 00:18, 01:31 to 02:03, 02:50 to 09:32; mean heart rate 65, 55 and 49) were
// folded into one "night" from 23:15 to 09:32 with two hours of gaps, 20 wake events, 77 % efficiency, and a bedtime
// the wearer said was far too early (they fell asleep around 02:00 and woke around 09:45; the strap's steps in the
// two gaps, 299 and 297 counter ticks at about 70 bpm, show them up and about). Earlier nights tell the gaps apart
// the same way: 43 ticks for a wake in bed (19 Oct), 220 to 302 for a walk (20 and 28 Oct).
//
// THE RULE. A sleep the wearer was up and about before, 150 or more counter ticks (about 75 steps) in the gap since
// the sleep ahead of it, is not bridged into it (`SleepStageTotals.upBeforeStarts`). The two stay two sleeps, the
// earlier a nap, and the night is the one the wearer settled into.

extension SleepStager {

    /// Yoop: the onsets of the sleeps, among `sessions`, that the wearer was up and about before: the gap since the
    /// sleep ahead of it is under 90 min (the longest a gap is bridged) and holds `minTicks` or more of the strap's
    /// step counter. `steps` is the strap's step stream over the gaps. Off (not `inBedFromOnsetEnabled`) it is
    /// empty, so NOOP's grouping is unchanged. Pure + deterministic.
    public static func upBeforeStarts(sessions: [(start: Int, end: Int)], steps: [StepSample],
                                      minTicks: Int = 150, enabled: Bool = inBedFromOnsetEnabled) -> Set<Int> {
        guard enabled, sessions.count > 1, !steps.isEmpty else { return [] }
        let sorted = sessions.sorted { $0.start < $1.start }
        var out = Set<Int>()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.start - a.end
            guard gap > 0, gap < SleepStageTotals.nightTailBridgeMaxMin * 60 else { continue }
            let inGap = steps.filter { $0.ts >= a.end && $0.ts <= b.start }
            if let ticks = StepsCounter.stepsInWindow(inGap), ticks >= minTicks { out.insert(b.start) }
        }
        return out
    }

    /// Yoop: count a night from its first asleep epoch to its last, as WHOOP does. Set by the app; off by
    /// default, so NOOP's output is unchanged.
    public static var inBedFromOnsetEnabled: Bool = false

    /// Cut each session to its asleep span: the start moves to the first asleep stage, the end to the end of
    /// the last, the wake outside them is dropped from the stages and efficiency is recomputed over the
    /// shorter span. Runs after `refineBedtime`, whose earlier start it replaces. Off, or a session with no
    /// asleep stage or nothing to cut, returns it unchanged. Pure + deterministic.
    public static func trimToSleep(_ sessions: [SleepSession],
                                   enabled: Bool = inBedFromOnsetEnabled) -> [SleepSession] {
        guard enabled, !sessions.isEmpty else { return sessions }
        return sessions.map { s in
            guard let first = s.stages.firstIndex(where: { !SleepStageVocabulary.isWake($0.stage) }),
                  let last = s.stages.lastIndex(where: { !SleepStageVocabulary.isWake($0.stage) }) else { return s }
            let start = max(s.start, s.stages[first].start)
            let end = min(s.end, s.stages[last].end)
            guard end > start, start > s.start || end < s.end else { return s }
            var stages = Array(s.stages[first...last])
            stages[0].start = start
            stages[stages.count - 1].end = end
            return SleepSession(start: start, end: end,
                                efficiency: efficiency(start: start, end: end, stages: stages),
                                stages: stages, restingHR: s.restingHR, avgHRV: s.avgHRV, hrOnly: s.hrOnly)
        }
    }
}
