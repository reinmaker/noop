import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// WHOOP-style fork: the figures behind one activity's page (`WhoopActivityScreen`). Heart-rate zones as a
// share of heart-rate reserve, the time in each, the sport's typical range per zone, and the same sport's
// earlier sessions the page compares against. Pure, so tests pin them without a store.

/// WHOOP's activity zones. Zone 1 starts at half the heart-rate reserve and each zone after it 10 points
/// higher, the reserve measured against the 190 bpm yardstick the WHOOP-style Strain curve uses
/// (`StrainScorer.whoopCurveMaxHR`), so the zones move with the resting rate exactly as Strain's own load
/// does. Bands are indexed 0 (restorative, under half the reserve) to 5 (zone 5).
enum WhoopActivityZones {
    /// The lower edges of zones 1 to 5 as a fraction of heart-rate reserve.
    static let reserveEdges: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]
    /// Restorative plus the five zones.
    static let bandCount = 6

    /// Lower edges of zones 1 to 5 in whole bpm, or nil when the resting rate leaves no room for five zones.
    /// Readings are whole bpm, so a zone's first reading is its edge rounded up; classifying by these
    /// rounded edges is the same as by the exact ones, and the labels can never disagree with the bars.
    static func lowerBounds(restingHR: Double, maxHR: Double = StrainScorer.whoopCurveMaxHR) -> [Int]? {
        guard restingHR > 0, maxHR > restingHR else { return nil }
        let edges = reserveEdges.map { Int((restingHR + $0 * (maxHR - restingHR) - 1e-9).rounded(.up)) }
        guard zip(edges, edges.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        return edges
    }

    /// The whole-bpm span a band's label names: restorative has no lower end, zone 5 no upper one.
    struct BpmRange: Equatable {
        let lower: Int?
        let upper: Int?
    }

    /// Label spans for the six bands, restorative first.
    static func bpmRanges(restingHR: Double, maxHR: Double = StrainScorer.whoopCurveMaxHR) -> [BpmRange]? {
        guard let edges = lowerBounds(restingHR: restingHR, maxHR: maxHR) else { return nil }
        var out = [BpmRange(lower: nil, upper: edges[0] - 1)]
        for k in 0..<5 {
            out.append(BpmRange(lower: edges[k], upper: k < 4 ? edges[k + 1] - 1 : nil))
        }
        return out
    }

    /// Seconds in each band, restorative first, from the readings inside `[from, to]`; nil without one.
    /// Each reading holds until the next, capped at the stream's usual spacing (`HRZones.timeInZone`), so
    /// a dropout is not credited to the zone before it.
    static func bandSeconds(_ samples: [HRSample], from: Int, to: Int, restingHR: Double,
                            maxHR: Double = StrainScorer.whoopCurveMaxHR) -> [Double]? {
        guard let edges = lowerBounds(restingHR: restingHR, maxHR: maxHR) else { return nil }
        let inside = samples.filter { $0.ts >= from && $0.ts <= to }
        guard !inside.isEmpty else { return nil }
        let zones = HRZones.zones(maxHR: maxHR, source: "whoop", customLowerBounds: edges.map(Double.init))
        let tiz = HRZones.timeInZone(inside, zoneSet: zones)
        return [tiz.belowZone1] + tiz.seconds
    }

    /// Each band's share (0 to 1) of the counted time; nil when nothing was counted.
    static func shares(_ seconds: [Double]) -> [Double]? {
        let total = seconds.reduce(0, +)
        guard seconds.count == bandCount, total > 0 else { return nil }
        return seconds.map { $0 / total }
    }

    /// Band shares from WHOOP's imported zone percentages (zones 1 to 5, percent of the duration). The
    /// export leaves the time under zone 1 out, so the remainder is restorative.
    static func shares(importedPercents: [Double]) -> [Double]? {
        guard importedPercents.count == 5 else { return nil }
        let zones = importedPercents.map { max(0, $0) / 100 }
        return shares([max(0, 1 - zones.reduce(0, +))] + zones)
    }

    /// The sport's typical range per band: the lowest to the highest share across its earlier sessions.
    /// Nil for every band when there is no earlier session.
    static func typicalRanges(_ past: [[Double]]) -> [ClosedRange<Double>?] {
        let usable = past.filter { $0.count == bandCount }
        return (0..<bandCount).map { band in
            let values = usable.map { $0[band] }
            guard let lo = values.min(), let hi = values.max() else { return nil }
            return lo...hi
        }
    }

    /// The resting rate the zones are measured from: the activity day's own, which is the one that day's
    /// Strain is scored with; else the median of the 14 days up to it (the latest 14 when none are that
    /// early); else Strain's own default.
    static func restingHR(dayKey: String, days: [DailyMetric]) -> Double {
        if let own = days.last(where: { $0.day == dayKey })?.restingHr, own > 0 { return Double(own) }
        func recent(_ list: [DailyMetric]) -> [Double] {
            list.suffix(14).compactMap(\.restingHr).filter { $0 > 0 }.map(Double.init)
        }
        var values = recent(days.filter { $0.day <= dayKey })
        if values.isEmpty { values = recent(days) }
        return median(values) ?? StrainScorer.defaultRestingHR
    }

    /// The middle value, or the mean of the two middle ones for an even count.
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Heart-rate context the chart shows either side of the activity: a twentieth of its length, one to
    /// five minutes.
    static func chartPadding(seconds: Int) -> Int {
        max(60, min(300, seconds / 20))
    }
}

/// The same sport's earlier sessions an activity is compared with: the typical chips beside Strain and
/// steps, the zones' typical ranges and the key statistics "vs. 30 day average". Those in the 30 days
/// before the activity, or every earlier one when the 30 days hold fewer than three. Zero and missing
/// values are not measurements and are left out.
enum WhoopActivityBaseline {
    static let windowDays = 30
    static let minimumCount = 3

    /// Earlier sessions of the same sport, newest first: those that ended by the time this one started.
    /// The activity itself is never among them, nor another source's copy of it (the history's
    /// cross-source dedup can keep that copy, a few seconds earlier, in place of this row).
    static func earlierSameSport(_ row: WorkoutRow, in history: [WorkoutRow]) -> [WorkoutRow] {
        let key = WorkoutSource.sportKey(row.sport)
        return history
            .filter { $0.endTs <= row.startTs && WorkoutSource.sportKey($0.sport) == key }
            .sorted { $0.startTs > $1.startTs }
    }

    /// The sessions the zones' typical ranges are read from.
    static func sessions(for row: WorkoutRow, in history: [WorkoutRow]) -> [WorkoutRow] {
        let earlier = earlierSameSport(row, in: history)
        let recent = earlier.filter { $0.startTs >= row.startTs - windowDays * 86_400 }
        return recent.count >= minimumCount ? recent : earlier
    }

    /// The values one figure is compared with.
    static func values(_ pick: (WorkoutRow) -> Double?, for row: WorkoutRow, in history: [WorkoutRow]) -> [Double] {
        let earlier = earlierSameSport(row, in: history)
        let windowStart = row.startTs - windowDays * 86_400
        let recent = earlier.filter { $0.startTs >= windowStart }.compactMap(pick).filter { $0 > 0 }
        return recent.count >= minimumCount ? recent : earlier.compactMap(pick).filter { $0 > 0 }
    }

    /// The typical value of one figure: the mean of `values`, nil without any.
    static func typical(_ pick: (WorkoutRow) -> Double?, for row: WorkoutRow, in history: [WorkoutRow]) -> Double? {
        let v = values(pick, for: row, in: history)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// +1 when the activity reads above its typical value, -1 below, 0 when the two read the same at the
    /// precision shown.
    static func direction(_ value: Double, typical: Double, decimals: Int) -> Int {
        let scale = pow(10, Double(decimals))
        let a = (value * scale).rounded(), b = (typical * scale).rounded()
        return a == b ? 0 : (a > b ? 1 : -1)
    }
}

extension WhoopTime {
    /// "0:38:26": hours, minutes and seconds.
    static func hms(seconds: Double) -> String {
        let parts = hmsParts(seconds)
        return String(format: "%d:%02d:%02d", parts.h, parts.m, parts.s)
    }

    /// The zone rows' clock: "0:15" in large type and ":18" beside it in small.
    static func hmsSplit(seconds: Double) -> (main: String, seconds: String) {
        let parts = hmsParts(seconds)
        return (String(format: "%d:%02d", parts.h, parts.m), String(format: ":%02d", parts.s))
    }

    private static func hmsParts(_ seconds: Double) -> (h: Int, m: Int, s: Int) {
        let total = max(0, Int(seconds.rounded()))
        return (total / 3600, (total % 3600) / 60, total % 60)
    }
}
