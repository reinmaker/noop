import Foundation

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

extension SleepStager {

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
