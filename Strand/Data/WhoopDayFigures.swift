import Foundation
import StrandAnalytics
import WhoopStore

/// Yoop: what a My Dashboard row states, handed to the page the row opens. The page's headline is the
/// row's own number, passed in rather than read a second time, so the two cannot disagree.
struct WhoopRowFigures: Hashable {
    /// Where a day's step count came from, in the order Home resolves it.
    enum StepSource: String, Hashable { case strap, phone, estimate }

    /// The shown day's key (`yyyy-MM-dd`, the wake day).
    let day: String
    /// The open day: its window ends now rather than at the next sleep onset.
    let isToday: Bool
    /// The row's number: steps, ACTIVE calories, the VO₂ max estimate or the night's blood oxygen.
    var value: Double?
    /// The row's 30-day figure, as shown under the number.
    var average: Double?
    /// Energy only: the TOTAL CALORIES row's number and 30-day figure.
    var total: Double?
    var totalAverage: Double?
    /// Energy only: one day of basal energy, Mifflin-St Jeor.
    var basalKcalPerDay: Double?
    /// The day's window as Home resolved it: epoch seconds at its start, and its length.
    var windowFrom: Int?
    var windowSeconds: Int?
    var stepSource: StepSource?
}

/// The figures behind the pages the My Dashboard rows open, shared with Home so a row and its page read
/// one definition of each: the day's step count, the 30-day normal, the week and the best day.
enum WhoopDayFigures {
    /// Home's step count for the shown day: the strap's, else the phone's, else a motion estimate. The
    /// strap leads because it is worn all day and the phone only when carried.
    static func steps(strap: Int?, phone: Int?, estimate: Double?)
        -> (value: Double, source: WhoopRowFigures.StepSource)? {
        if let strap { return (Double(strap), .strap) }
        if let phone { return (Double(phone), .phone) }
        if let estimate { return (estimate, .estimate) }
        return nil
    }

    /// Where the step count a row states came from: the strap's own count, else the phone's total for the
    /// day, else the estimate. The same order `steps(strap:phone:estimate:)` resolves the number in.
    static func stepSource(strap: Int?, phone: Double?, hasValue: Bool) -> WhoopRowFigures.StepSource? {
        guard hasValue else { return nil }
        if strap != nil { return .strap }
        return phone != nil ? .phone : .estimate
    }

    /// The prior 30 days' values for a row, skipping days at or below `floor` (a day the strap barely
    /// recorded would otherwise drag the normal down to nothing). `day` itself is left out.
    static func normalValues(days: [DailyMetric], excluding day: String?, floor: Double = 0,
                             _ pick: (DailyMetric) -> Double?) -> [Double] {
        days.filter { $0.day != day }.suffix(30).compactMap(pick).filter { $0 > floor }
    }

    /// The 30-day normal under a row's number: the mean of `normalValues`, nil with fewer than 3.
    static func normal(days: [DailyMetric], excluding day: String?, floor: Double = 0,
                       _ pick: (DailyMetric) -> Double?) -> Double? {
        let prior = normalValues(days: days, excluding: day, floor: floor, pick)
        return prior.count < 3 ? nil : prior.reduce(0, +) / Double(prior.count)
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A day key's date, at the start of that local day.
    static func date(of key: String) -> Date? { dayParser.date(from: key) }

    /// The day keys of the `count` calendar days ending on `day`, oldest first.
    static func dayKeys(endingOn day: String, count: Int) -> [String] {
        guard let end = date(of: day) else { return [day] }
        return (0..<count).reversed().compactMap { back in
            Calendar.current.date(byAdding: .day, value: -back, to: end).map { dayParser.string(from: $0) }
        }
    }

    /// The last `count` calendar days ending on `day` that have a value, oldest first. `shown` is the
    /// row's own number for `day`; it replaces what the stored day says, since the row is what Home states.
    static func recent(days: [DailyMetric], endingOn day: String, count: Int, shown: Double?,
                       _ pick: (DailyMetric) -> Double?) -> [(day: String, value: Double)] {
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return dayKeys(endingOn: day, count: count).compactMap { key in
            let value = key == day ? (shown ?? byDay[key].flatMap(pick)) : byDay[key].flatMap(pick)
            return value.map { (day: key, value: $0) }
        }
    }

    /// The highest day of `recent`, the earliest on a tie.
    static func best(_ recent: [(day: String, value: Double)]) -> (day: String, value: Double)? {
        var top: (day: String, value: Double)?
        for item in recent where item.value > (top?.value ?? -Double.infinity) { top = item }
        return top
    }

    /// A stored night as the day cycle counts steps against it (`DayCycleIntelligenceIntegration.compute`):
    /// its effective onset, its end and its staged timeline.
    static func sleepSession(_ row: CachedSleepSession) -> SleepSession {
        SleepSession(start: row.effectiveStartTs, end: row.endTs, efficiency: row.efficiency ?? 0,
                     stages: AnalyticsEngine.decodeStages(row.stagesJSON), restingHR: row.restingHr,
                     avgHRV: row.avgHrv)
    }

    /// A closed day's window length in seconds, as Home resolves it for a past day: from its sleep-onset
    /// marker (else its midnight) to the next day's marker (else the next midnight).
    static func windowSeconds(day: String, markers: [String: Int]) -> Int {
        guard let start = date(of: day) else { return 86_400 }
        let cal = Calendar.current
        let from = markers[day] ?? Int(cal.startOfDay(for: start).timeIntervalSince1970)
        guard let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: start)) else { return 86_400 }
        let to = markers[dayParser.string(from: next)] ?? Int(next.timeIntervalSince1970)
        return max(0, to - from)
    }

    /// +1 when `value` is above its normal, -1 below, 0 when level or either is missing: the rule a
    /// My Dashboard row draws its arrow by, so a row and its page point the same way.
    static func direction(value: Double?, normal: Double?) -> Int {
        guard let value, let normal, abs(value - normal) > 0.0001 else { return 0 }
        return value > normal ? 1 : -1
    }

    /// How a number sits against its normal, for the page's one plain sentence. `level` is within 2 %.
    enum Standing: Equatable {
        case above(Double), below(Double), level, unknown
    }

    static func standing(value: Double?, normal: Double?) -> Standing {
        guard let value, let normal, normal > 0 else { return .unknown }
        let gap = value - normal
        return abs(gap) <= normal * 0.02 ? .level : (gap > 0 ? .above(gap) : .below(-gap))
    }
}
