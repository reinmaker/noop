import Foundation
import StrandAnalytics
import WhoopStore

/// Yoop: the one rule behind every "within range" the app states: Home's HEALTH MONITOR card, the Health tab,
/// the Health Monitor screen and the Coach. Each vital is judged against the wearer's own usual range, and the
/// range is built from the same 30 values as the "30-day normal" Home's rows print beside the number
/// (`WhoopDayFigures.normalValues`), so a normal and the range around it cannot disagree.
///
/// The rule: the range is the span a new night is expected to fall in 19 times in 20, given the last 30 nights
/// with a reading: the mean plus or minus t x s x sqrt(1 + 1/n), where s is the sample standard deviation and t the
/// 97.5% point of Student's t on n - 1 degrees of freedom (the prediction interval of a new observation from a
/// normal sample; Altman and Bland 1995 for a reference range from a sample). It needs `minNights` readings;
/// with fewer there is no verdict, only the count of nights still needed, because a verdict from a fixed adult
/// band would be a claim about the wearer the data does not support.
///
/// Yoop's own rule (`PuffinExperiment.whoopScoresEnabled`) follows how WHOOP's Health Monitor reads, as found in its
/// own screens on 17 Oct 2026 and tested on the user's WHOOP export: the "typical range" it prints is the middle half
/// of the last 30 nights (25th to 75th percentile; it reproduced WHOOP's printed ranges for skin temperature, resting
/// heart rate and respiratory rate to the digit and HRV's lower end), a reading outside it but not far is "near"
/// and still a green check, and only a reading well past it on the harmful side is flagged: HRV falling, resting heart
/// rate, respiratory rate or skin temperature rising. WHOOP does not publish where it draws that line; against the
/// 30 nights its orange limits sit between about 1.4 and 3.5 standard deviations, so Yoop flags at 2. Blood oxygen
/// has fixed bands on WHOOP (95% to 100% typical, 90% and above fine, 89% and below flagged), not a personal range.
///
/// Exceptions, each stated on the screen: blood oxygen is imported (a WHOOP export or Apple Health), not
/// measured by the strap, and is judged against the usual lower limit of 95% instead of the wearer's own range;
/// a reading that is not from the latest night is shown with its date and left out of the count.
enum HealthMonitorRule {

    enum Vital: String, CaseIterable, Identifiable {
        case respiratoryRate, bloodOxygen, restingHr, hrv, skinTemperature
        var id: String { rawValue }
    }

    /// The order WHOOP lists them in.
    static let tracked: [Vital] = [.respiratoryRate, .bloodOxygen, .restingHr, .hrv, .skinTemperature]

    /// Nights the range is built from, and the fewest it is stated with.
    static let windowNights = 30
    static let minNights = 14
    /// The usual lower limit of blood oxygen, in percent (a reading under it is flagged whoever the wearer is).
    static let bloodOxygenFloor = 95.0
    /// Yoop: under this whole percent blood oxygen is flagged; from it up to the floor it is "near".
    static let bloodOxygenFlagBelow = 90.0

    // MARK: Interval

    /// A range around the usual value.
    struct Interval: Equatable {
        let mean: Double
        let low: Double
        let high: Double
        let nights: Int
        /// Yoop: the limits a reading has to pass, on the harmful side, to be flagged (the mean plus or minus
        /// `flagSDs` standard deviations of the same nights). Nil under the prediction interval rule.
        var flagLow: Double?
        var flagHigh: Double?

        /// The same range with a value taken off both ends and the mean (skin temperature, shown as a change
        /// from the usual value).
        func shifted(by offset: Double) -> Interval {
            Interval(mean: mean - offset, low: low - offset, high: high - offset, nights: nights,
                     flagLow: flagLow.map { $0 - offset }, flagHigh: flagHigh.map { $0 - offset })
        }
    }

    /// The 97.5% point of Student's t for `df` degrees of freedom, by the Cornish-Fisher expansion about the
    /// normal point: within 0.002 of the table for 8 or more degrees of freedom.
    static func tQuantile975(df: Int) -> Double {
        let z = 1.959964, v = Double(max(1, df))
        return z + (z * z * z + z) / (4 * v) + (5 * pow(z, 5) + 16 * pow(z, 3) + 3 * z) / (96 * v * v)
    }

    /// Yoop: how many standard deviations past the mean, on the harmful side, a reading is flagged.
    static let flagSDs = 2.0

    /// The `p` quantile of `values` by linear interpolation between the sorted values.
    static func quantile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = Double(sorted.count - 1) * p
        let below = Int(position.rounded(.down))
        let above = min(below + 1, sorted.count - 1)
        return sorted[below] + (sorted[above] - sorted[below]) * (position - Double(below))
    }

    /// The range a new night is expected to fall in 19 times in 20 (Yoop: the middle half of the nights), from the
    /// last `windowNights` of `values` (oldest first). Nil under `minNights` values.
    static func interval(of values: [Double]) -> Interval? {
        let recent = Array(values.suffix(windowNights))
        let n = recent.count
        guard n >= minNights else { return nil }
        let mean = recent.reduce(0, +) / Double(n)
        let variance = recent.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(n - 1)
        if PuffinExperiment.whoopScoresEnabled {
            let sd = variance.squareRoot()
            return Interval(mean: mean, low: quantile(recent, 0.25), high: quantile(recent, 0.75), nights: n,
                            flagLow: mean - flagSDs * sd, flagHigh: mean + flagSDs * sd)
        }
        let reach = tQuantile975(df: n - 1) * (variance.squareRoot()) * (1 + 1 / Double(n)).squareRoot()
        return Interval(mean: mean, low: mean - reach, high: mean + reach, nights: n)
    }

    // MARK: Status

    enum Verdict: Equatable {
        case within
        /// Yoop: outside the typical range but not flagged (WHOOP's "near": still a green check).
        case near
        case above
        case below
        /// Fewer than `minNights` readings; the count so far.
        case learning(nights: Int)
        case noData
    }

    struct Status: Equatable, Identifiable {
        let vital: Vital
        /// The latest reading within the carry limit, nil when none.
        let value: Double?
        /// The wake day it is from.
        let day: String?
        /// From the latest night (today's or the one before), so it counts toward today's tally.
        let isCurrent: Bool
        /// The usual range, in the scale `value` is shown in.
        let interval: Interval?
        let verdict: Verdict
        /// Skin temperature is a change from the usual value (true) or an absolute temperature (false).
        let isDeviation: Bool
        var id: String { vital.rawValue }

        /// Within the range or near it: a green check.
        var isFine: Bool { verdict == .within || verdict == .near }

        /// Whether it is part of the "n of N within range" tally.
        var counts: Bool {
            guard isCurrent else { return false }
            switch verdict {
            case .within, .near, .above, .below: return true
            case .learning, .noData: return false
            }
        }
    }

    /// Every tracked vital from the merged daily rows, judged against `todayKey` (the logical day).
    static func statuses(days: [DailyMetric], todayKey: String) -> [Status] {
        let sorted = days.sorted { $0.day < $1.day }
        // Yoop: once today's night is scored, a reading left over from the night before is an old one, not the
        // latest night's, so a vital that night did not produce reads "From 16 Oct" instead of passing as current.
        let tonightIn = PuffinExperiment.whoopScoresEnabled
            && sorted.contains { $0.day == todayKey && ($0.totalSleepMin ?? 0) >= WhoopAge.minNightMinutes }
        return tracked.map { status($0, sorted: sorted, todayKey: todayKey, tonightIn: tonightIn) }
    }

    private static func pick(_ vital: Vital) -> (DailyMetric) -> Double? {
        switch vital {
        case .hrv: return { $0.avgHrv }
        case .restingHr: return { $0.restingHr.map(Double.init) }
        case .respiratoryRate: return { $0.respRateBpm }
        case .bloodOxygen: return { $0.spo2Pct }
        case .skinTemperature: return { $0.skinTempDevC }
        }
    }

    private static func status(_ vital: Vital, sorted: [DailyMetric], todayKey: String, tonightIn: Bool) -> Status {
        if vital == .skinTemperature { return skinStatus(sorted, todayKey: todayKey, tonightIn: tonightIn) }
        let read = pick(vital)
        let points = sorted.compactMap { d in read(d).flatMap { $0 > 0 ? (day: d.day, value: $0) : nil } }
        guard let latest = Baselines.freshestCarried(points, todayKey: todayKey) else {
            return Status(vital: vital, value: nil, day: nil, isCurrent: false, interval: nil,
                          verdict: .noData, isDeviation: false)
        }
        let current = isCurrent(latest.day, todayKey: todayKey, tonightIn: tonightIn)
        if vital == .bloodOxygen {
            let v = latest.value
            return Status(vital: vital, value: v, day: latest.day, isCurrent: current, interval: nil,
                          verdict: bloodOxygenVerdict(v), isDeviation: false)
        }
        let prior = WhoopDayFigures.normalValues(days: sorted.filter { $0.day < latest.day }, excluding: nil, read)
        return judged(vital, value: latest.value, day: latest.day, current: current, prior: prior, isDeviation: false)
    }

    /// Blood oxygen against fixed bands. Yoop, as on WHOOP: 95% and above is typical, 90% and above is fine, under
    /// 90% is flagged, judged on the whole percent that is shown (95% shown is not "below 95%"). Otherwise the
    /// usual lower limit of 95%.
    static func bloodOxygenVerdict(_ percent: Double) -> Verdict {
        guard PuffinExperiment.whoopScoresEnabled else { return percent >= bloodOxygenFloor ? .within : .below }
        let whole = percent.rounded()
        return whole >= bloodOxygenFloor ? .within : (whole >= bloodOxygenFlagBelow ? .near : .below)
    }

    /// Skin temperature. The stored column holds an absolute temperature (a WHOOP export) or a change from the
    /// usual one (Yoop's own nights); a change is the figure WHOOP shows, and it is judged on the absolute
    /// history, which is longer and on the same scale: Yoop's change is the night's absolute minus the mean of the
    /// nights before it. A night with only a change and fewer than `minNights` of them has no verdict yet.
    private static func skinStatus(_ sorted: [DailyMetric], todayKey: String, tonightIn: Bool) -> Status {
        func absolute(_ d: DailyMetric) -> Double? {
            if let a = d.skinTempC, VitalBands.isAbsoluteSkinTemp(a) { return a }
            if let v = d.skinTempDevC, VitalBands.isAbsoluteSkinTemp(v) { return v }
            return nil
        }
        func change(_ d: DailyMetric) -> Double? {
            d.skinTempDevC.flatMap { VitalBands.isAbsoluteSkinTemp($0) ? nil : $0 }
        }
        let points = sorted.compactMap { d in (change(d) ?? absolute(d)).map { (day: d.day, value: $0) } }
        guard let latest = Baselines.freshestCarried(points, todayKey: todayKey) else {
            return Status(vital: .skinTemperature, value: nil, day: nil, isCurrent: false, interval: nil,
                          verdict: .noData, isDeviation: false)
        }
        let row = sorted.first { $0.day == latest.day }
        let shownChange = row.flatMap(change)
        let current = isCurrent(latest.day, todayKey: todayKey, tonightIn: tonightIn)
        let history = sorted.filter { $0.day < latest.day }
        if let shownChange {
            // Judge the change on the absolute history when this night has an absolute too.
            if let night = row.flatMap(absolute) {
                let prior = history.compactMap(absolute).suffix(windowNights).map { $0 }
                if let range = interval(of: prior) {
                    return Status(vital: .skinTemperature, value: shownChange, day: latest.day, isCurrent: current,
                                  interval: range.shifted(by: range.mean),
                                  verdict: verdict(.skinTemperature, value: night, range: range), isDeviation: true)
                }
            }
            let prior = history.compactMap(change).map { $0 }
            return judged(.skinTemperature, value: shownChange, day: latest.day, current: current,
                          prior: Array(prior.suffix(windowNights)), isDeviation: true)
        }
        let prior = history.compactMap(absolute).map { $0 }
        return judged(.skinTemperature, value: latest.value, day: latest.day, current: current,
                      prior: Array(prior.suffix(windowNights)), isDeviation: false)
    }

    /// Which way a reading is a warning: HRV falling, the others rising.
    private static func warnsLow(_ vital: Vital) -> Bool { vital == .hrv }

    /// The verdict of `value` against `range`. Under the prediction interval rule, outside is above or below. Yoop:
    /// inside the typical range is within; outside it is near, unless it is past the flag limit on the harmful side.
    private static func verdict(_ vital: Vital, value: Double, range: Interval) -> Verdict {
        guard PuffinExperiment.whoopScoresEnabled, let flagLow = range.flagLow, let flagHigh = range.flagHigh else {
            return value < range.low ? .below : (value > range.high ? .above : .within)
        }
        if value >= range.low && value <= range.high { return .within }
        if warnsLow(vital) { return value < flagLow ? .below : .near }
        return value > flagHigh ? .above : .near
    }

    private static func judged(_ vital: Vital, value: Double, day: String, current: Bool,
                               prior: [Double], isDeviation: Bool) -> Status {
        guard let range = interval(of: prior) else {
            return Status(vital: vital, value: value, day: day, isCurrent: current, interval: nil,
                          verdict: .learning(nights: prior.count), isDeviation: isDeviation)
        }
        return Status(vital: vital, value: value, day: day, isCurrent: current, interval: range,
                      verdict: verdict(vital, value: value, range: range), isDeviation: isDeviation)
    }

    /// The reading is from today's night or the one before it, the latest a wearer can have at any hour. With
    /// today's night already scored (`tonightIn`), only today's own reading is the latest.
    static func isCurrent(_ day: String, todayKey: String, tonightIn: Bool = false) -> Bool {
        tonightIn ? day >= todayKey : day >= Baselines.cutoffKey(todayKey: todayKey, carryDays: 1)
    }

    // MARK: Tally

    struct Summary: Equatable {
        /// Vitals with a verdict from the latest night.
        let counted: Int
        let within: Int
        /// Vitals with a reading that is not from the latest night, or no verdict yet.
        let notCounted: Int
        var allWithin: Bool { counted > 0 && within == counted }
        var isEmpty: Bool { counted == 0 }
    }

    /// What the tally says in a word, shared by every card that states it.
    enum Headline: Equatable {
        /// Every counted vital is inside its range.
        case within
        /// At least one counted vital is outside it.
        case outOfRange
        /// Nothing is counted yet because the ranges still need nights.
        case learning
        /// There are readings but none from the latest night.
        case waiting
        /// No reading at all.
        case noData
    }

    static func headline(_ statuses: [Status]) -> Headline {
        let tally = summary(statuses)
        if tally.counted > 0 { return tally.allWithin ? .within : .outOfRange }
        if statuses.contains(where: { if case .learning = $0.verdict { return true } else { return false } }) { return .learning }
        return statuses.contains(where: { $0.value != nil }) ? .waiting : .noData
    }

    static func summary(_ statuses: [Status]) -> Summary {
        let counted = statuses.filter(\.counts)
        return Summary(counted: counted.count,
                       within: counted.filter(\.isFine).count,
                       notCounted: statuses.filter { !$0.counts && $0.value != nil }.count)
    }
}
