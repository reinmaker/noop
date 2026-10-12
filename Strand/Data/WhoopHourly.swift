import Foundation

/// Yoop: a day's steps or active energy split into clock hours, for the Steps and Calories pages.
///
/// The figures are the day's own: steps are the ticks the day counted (`SleepAwareStepCounter`'s accepted
/// minutes) and energy is `Calories.yoopActiveKcalByMinute`, whose sum is the day's active energy. Hours
/// are rounded together, by largest remainder, so the bars add up to the day's whole number and none of
/// them is rounded away. Whatever the day states beyond what the bars hold is `unplaced` and is said on
/// the page rather than folded into a bar.
enum WhoopHourly {
    /// One clock hour of the day window.
    struct Bar: Identifiable, Equatable {
        /// Epoch seconds at the start of the local clock hour.
        let start: Int
        let value: Int
        /// Most of the hour lies inside a sleep session.
        let asleep: Bool
        var id: Int { start }
    }

    /// The bars of a window, oldest hour first, and the whole number they were rounded to add up to.
    struct Split: Equatable {
        let bars: [Bar]
        var placed: Int { bars.reduce(0) { $0 + $1.value } }
    }

    /// Epoch seconds at the start of the local clock hour holding `ts`. Not `ts - ts % 3600`: a zone
    /// half an hour off UTC has its hours half an hour off the epoch's.
    static func hourStart(_ ts: Int, timeZone: TimeZone) -> Int {
        let offset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        let into = ((ts + offset) % 3_600 + 3_600) % 3_600
        return ts - into
    }

    /// `total` shared out over `shares` in proportion, in whole units, largest remainder first (earlier
    /// entries first on a tie). The result adds up to `total`; an all-zero `shares` gets all zeros.
    static func apportion(_ shares: [Double], total: Int) -> [Int] {
        let clean = shares.map { $0.isFinite ? max(0, $0) : 0 }
        let sum = clean.reduce(0, +)
        guard total > 0, sum > 0 else { return Array(repeating: 0, count: shares.count) }
        let scaled = clean.map { $0 / sum * Double(total) }
        var parts = scaled.map { Int($0.rounded(.down)) }
        let missing = total - parts.reduce(0, +)
        if missing > 0 {
            let order = scaled.indices.sorted { a, b in
                let fa = scaled[a] - Double(parts[a]), fb = scaled[b] - Double(parts[b])
                return fa != fb ? fa > fb : a < b
            }
            for index in order.prefix(missing) { parts[index] += 1 }
        }
        return parts
    }

    /// The window's clock hours with `valueByMinute` (keyed `ts / 60`) summed into them and rounded to
    /// `total`. A minute outside `[from, toExclusive)` is not in any hour. `asleep` are the sleep
    /// sessions, as (start, end) epoch seconds; an hour is asleep when at least half of it is inside one.
    static func split(valueByMinute: [Int: Double], from: Int, toExclusive: Int, total: Int,
                      asleep: [(start: Int, end: Int)], timeZone: TimeZone = .current) -> Split {
        guard toExclusive > from else { return Split(bars: []) }
        var starts: [Int] = []
        var cursor = hourStart(from, timeZone: timeZone)
        while cursor < toExclusive {
            starts.append(cursor)
            cursor += 3_600
        }
        var sums = Array(repeating: 0.0, count: starts.count)
        let first = starts[0]
        for (minute, value) in valueByMinute {
            let ts = minute * 60
            guard ts >= from, ts < toExclusive else { continue }
            let index = (hourStart(ts, timeZone: timeZone) - first) / 3_600
            if index >= 0, index < sums.count { sums[index] += value }
        }
        let values = apportion(sums, total: total)
        let bars = starts.indices.map { index -> Bar in
            let lo = max(starts[index], from), hi = min(starts[index] + 3_600, toExclusive)
            let covered = asleep.reduce(0) { $0 + max(0, min($1.end, hi) - max($1.start, lo)) }
            return Bar(start: starts[index], value: values[index],
                       asleep: hi > lo && covered * 2 >= hi - lo)
        }
        return Split(bars: bars)
    }

    /// `total` split between windows (start, end in epoch seconds) and the rest of the day. Each minute
    /// belongs to the first window it overlaps, so overlapping windows never count a minute twice, and a
    /// window shorter than a minute still holds the minute it falls in. Returns one whole number per
    /// window, in order, and the rest; together they add up to `total`.
    static func shares(valueByMinute: [Int: Double], windows: [(start: Int, end: Int)],
                       total: Int) -> (windows: [Int], rest: Int) {
        var sums = Array(repeating: 0.0, count: windows.count + 1)
        for (minute, value) in valueByMinute {
            let ts = minute * 60
            let index = windows.firstIndex { ts + 60 > $0.start && ts < max($0.end, $0.start + 1) } ?? windows.count
            sums[index] += value
        }
        let parts = apportion(sums, total: total)
        return (Array(parts.dropLast()), parts.last ?? 0)
    }
}
