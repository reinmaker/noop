import Foundation

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
    }

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
        let nearest = zip(rows, named).map { row, example -> (distance: Double, sport: String) in
            let squares: Double = (0..<target.count).reduce(0.0) { sum, j in
                let z = (target[j] - row[j]) / spread[j]
                return sum + z * z
            }
            return (squares.squareRoot(), example.sport)
        }
        .sorted { $0.distance < $1.distance }
        .prefix(neighbours)
        var votes: [String: Double] = [:]
        for n in nearest { votes[n.sport, default: 0] += 1 / (n.distance + 0.3) }
        let total = votes.values.reduce(0, +)
        guard total > 0, let best = votes.max(by: { $0.value < $1.value }),
              best.value / total >= minShare else { return nil }
        return best.key
    }

    /// Average and peak HR, log length (a 20 to 40 minute gap matters more than 120 to 140), and the hour
    /// on a circle so 23:00 sits next to 01:00.
    private static func features(_ e: Example) -> [Double] {
        let angle = 2 * Double.pi * e.startHour / 24
        return [e.avgBpm, e.maxBpm, log(e.durationMin), sin(angle), cos(angle)]
    }
}
