import Foundation
import WhoopProtocol

/// Yoop: names a detected activity the way WHOOP does, from the user's own labelled history. A
/// k-nearest-neighbour vote over average HR, peak HR, length and time of day. The history is every
/// workout with a real type: imported WHOOP workouts, ones logged by hand, and detected ones whose type
/// the user picked, so each correction counts from the next detection on.
///
/// Checked leave-one-out on the user's WHOOP export (101 named workouts, k = 7, cutoff 0.5): it names
/// 77% of them and is right on 85% of those, and on 95% of Weightlifting, Tennis and Running. When the
/// vote is split it returns nil and the activity stays "Activity", as WHOOP does when it is unsure; the
/// light ones (Walking, Commuting, Parenting) are where heart rate alone cannot tell types apart.
enum WhoopActivityTyper {
    struct Example: Equatable {
        let sport: String
        let avgBpm: Double
        let maxBpm: Double
        let durationMin: Double
        let startHour: Double
        /// How much this example's vote counts (`userLabelWeight` for a type the user set in Yoop).
        var weight: Double = 1
    }

    /// Vote weight of a type the user set or logged in Yoop, against 1 for imported history: one
    /// correction ("this was basketball") should outweigh a few old sessions that look alike.
    static let userLabelWeight = 3.0

    static let neighbours = 7
    static let minExamples = 5
    /// The winning type's share of the weighted vote needed to name the activity.
    static let minShare = 0.5

    /// Types that name nothing, so they are never learnt from: WHOOP's unnamed "Activity", NOOP's
    /// "detected" token and the generic "Workout".
    static func isUnnamed(_ sport: String) -> Bool {
        let s = sport.trimmingCharacters(in: .whitespaces).lowercased()
        return s.isEmpty || s == "activity" || s == "detected" || s == "workout"
    }

    /// The type for a bout, or nil when the history is too short or the vote is split.
    static func guess(avgBpm: Double, maxBpm: Double, durationMin: Double, startHour: Double,
                      history: [Example]) -> String? {
        let named = history.filter { !isUnnamed($0.sport) && $0.durationMin > 0 }
        guard named.count >= minExamples else { return nil }
        let rows = named.map(features)
        let target = features(Example(sport: "", avgBpm: avgBpm, maxBpm: maxBpm,
                                      durationMin: max(1, durationMin), startHour: startHour))
        let spread = (0..<target.count).map { j -> Double in
            let column = rows.map { $0[j] }
            let mean = column.reduce(0, +) / Double(column.count)
            let sd = (column.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(column.count)).squareRoot()
            return sd > 0 ? sd : 1
        }
        let nearest = zip(rows, named).map { row, example -> (distance: Double, sport: String, weight: Double) in
            let squares: Double = (0..<target.count).reduce(0.0) { sum, j in
                let z = (target[j] - row[j]) / spread[j]
                return sum + z * z
            }
            return (squares.squareRoot(), example.sport, example.weight)
        }
        .sorted { $0.distance < $1.distance }
        .prefix(neighbours)
        var votes: [String: Double] = [:]
        for n in nearest { votes[n.sport, default: 0] += n.weight / (n.distance + 0.3) }
        let total = votes.values.reduce(0, +)
        guard total > 0, let best = votes.max(by: { $0.value < $1.value }),
              best.value / total >= minShare else { return nil }
        return best.key
    }

    /// The strap's own step record over a bout: counter ticks a minute, the walk-labelled ticks a minute, and the
    /// share of the ticks labelled run. Heart rate alone cannot tell a run from tennis, or a day of carrying and
    /// cleaning from lifting weights: on 2 Nov 2026 a 6 km run (run share 0.90, 126 ticks a minute) was named
    /// Tennis, and a stretch of housework (68 walking ticks a minute, heart rate 99) was named Weightlifting.
    struct StepShape: Equatable {
        let ticksPerMin: Double
        let walkTicksPerMin: Double
        let runShare: Double
    }

    /// The step shape of `[startSec, endSec]` from the strap's step samples, or nil with too few of them (a strap
    /// that banks no steps, or none delivered for the bout). Counts each wrap-aware counter increment under 512 on
    /// the sample that carries it, by that sample's activity class. Pure.
    static func stepShape(_ samples: [StepSample], startSec: Int, endSec: Int) -> StepShape? {
        guard endSec > startSec else { return nil }
        let inside = samples.filter { $0.ts >= startSec && $0.ts <= endSec }.sorted { $0.ts < $1.ts }
        guard inside.count >= 60 else { return nil }
        var total = 0, walk = 0, run = 0
        for (a, b) in zip(inside, inside.dropFirst()) {
            let delta = (b.counter - a.counter) & 0xFFFF
            guard delta > 0, delta < 512 else { continue }
            total += delta
            if b.activityClass == 2 { run += delta } else if b.activityClass == 1 { walk += delta }
        }
        let minutes = Double(endSec - startSec) / 60
        return StepShape(ticksPerMin: Double(total) / minutes, walkTicksPerMin: Double(walk) / minutes,
                         runShare: total > 0 ? Double(run) / Double(total) : 0)
    }

    /// A bout is a run when this share of its step ticks is labelled run and it moves at least
    /// `runTicksPerMin` ticks a minute: the user's two recorded runs read 0.94 (150 a minute) and 0.90 (126); jump
    /// rope read 0.08 to 0.14 and tennis 0.
    static let runShareMin = 0.6
    static let runTicksPerMinMin = 80.0

    /// Weightlifting and other strength types are not named for a bout that walks more than this many ticks a
    /// minute: the user's lifting sessions read 16 to 45, a stretch of housework 68.
    static let strengthWalkTicksPerMinMax = 55.0

    /// The type after the strap's steps have had their say: Running for a bout that runs, no name (so "Activity")
    /// for a strength guess over a bout that walks about, else the guess. Without a step shape, the guess. Pure.
    static func refine(_ guess: String?, shape: StepShape?) -> String? {
        guard let shape else { return guess }
        if shape.runShare >= runShareMin, shape.ticksPerMin >= runTicksPerMinMin { return "Running" }
        if let guess, MuscleLoad.isStrength(guess), shape.walkTicksPerMin > strengthWalkTicksPerMinMax { return nil }
        return guess
    }

    /// Average and peak HR, log length (a 20 to 40 minute gap matters more than 120 to 140), and the hour
    /// on a circle so 23:00 sits next to 01:00.
    private static func features(_ e: Example) -> [Double] {
        let angle = 2 * Double.pi * e.startHour / 24
        return [e.avgBpm, e.maxBpm, log(e.durationMin), sin(angle), cos(angle)]
    }
}
