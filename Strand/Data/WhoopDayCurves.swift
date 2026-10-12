import Foundation

/// Yoop: a closed day's steps and active energy as they built up through the day, kept at 15 minute marks.
///
/// Today is only part of a day, so comparing it with a whole-day normal says it is behind for most of the
/// day. The fair comparison is what the same days had reached by this time of day. These curves are what
/// that is read from: the cumulative figure at the end of each quarter hour, from the day's window start.
/// A closed day never changes, so its curve is computed once and kept (`WhoopDayCurveBook`).
struct WhoopDayCurve: Codable, Equatable {
    /// The width of one mark, in seconds.
    static let slotSeconds = 900

    enum Series { case steps, kcal }

    let day: String
    /// What the curve was computed from (the day's stored totals and window), so a re-scored day is read again.
    let sig: String
    /// The day's window, epoch seconds.
    let from: Int
    let to: Int
    /// Epoch seconds at the start of the first mark.
    let origin: Int
    /// Cumulative steps, or active kcal, at the end of each mark; nil when the day has no such data.
    let steps: [Double]?
    let kcal: [Double]?
    /// The strap was recording from the start of the window, so the curve is a whole day's and not the end
    /// of one that began mid-day.
    let stepsFromStart: Bool
    let kcalFromStart: Bool

    /// The cumulative figures of the per-minute values (keyed `ts / 60`) over `[from, to)`.
    static func make(day: String, sig: String, from: Int, to: Int, stepsByMinute: [Int: Double]?,
                     kcalByMinute: [Int: Double]?, stepsFromStart: Bool, kcalFromStart: Bool) -> WhoopDayCurve {
        let origin = from - ((from % slotSeconds) + slotSeconds) % slotSeconds
        let slots = max(1, (to - origin + slotSeconds - 1) / slotSeconds)
        func cumulative(_ minutes: [Int: Double]?) -> [Double]? {
            guard let minutes else { return nil }
            var sums = Array(repeating: 0.0, count: slots)
            for (minute, value) in minutes {
                // The minute holding the window's start counts, from its start onwards.
                let ts = max(minute * 60, from)
                guard minute * 60 + 60 > from, ts < to else { continue }
                sums[min(slots - 1, (ts - origin) / slotSeconds)] += value
            }
            var running = 0.0
            return sums.map { running += $0; return running }
        }
        return WhoopDayCurve(day: day, sig: sig, from: from, to: to, origin: origin, steps: cumulative(stepsByMinute),
                             kcal: cumulative(kcalByMinute), stepsFromStart: stepsFromStart,
                             kcalFromStart: kcalFromStart)
    }

    private func values(_ series: Series) -> [Double]? { series == .steps ? steps : kcal }

    func fromStart(_ series: Series) -> Bool { series == .steps ? stepsFromStart : kcalFromStart }

    /// The whole day's figure.
    func total(_ series: Series) -> Double? { values(series)?.last }

    /// What the day had reached at epoch second `t`: nothing before its window, the whole day after it,
    /// and in between a straight line across the quarter hour `t` falls in.
    func cumulative(_ series: Series, at t: Int) -> Double? {
        guard let values = values(series), !values.isEmpty else { return nil }
        if t <= origin { return 0 }
        let position = Double(t - origin) / Double(Self.slotSeconds)
        let index = Int(position)
        if index >= values.count { return values[values.count - 1] }
        let before = index == 0 ? 0 : values[index - 1]
        return before + (position - Double(index)) * (values[index] - before)
    }
}

/// Yoop: today against its own normal BY NOW.
enum WhoopByNow {
    /// Complete closed days needed before the by-now normal is used; with fewer the whole-day normal stands.
    static let minDays = 7

    /// The mean of what each prior day had reached by the same time of day as `asOf` on `todayKey`: the
    /// days' own windows, read at the same clock time on their own dates. Only days that were recorded from
    /// the start of their window and ended above `floor` count, as the whole-day normal skips a barely
    /// recorded day. Nil with fewer than `minDays` of them.
    static func normal(_ series: WhoopDayCurve.Series, curves: [WhoopDayCurve], asOf: Int, todayKey: String,
                       floor: Double, minDays: Int = WhoopByNow.minDays, calendar: Calendar = .current) -> Double? {
        guard let today = WhoopDayFigures.date(of: todayKey) else { return nil }
        let offset = asOf - Int(calendar.startOfDay(for: today).timeIntervalSince1970)
        var reached: [Double] = []
        for curve in curves where curve.day < todayKey && curve.fromStart(series) {
            guard let total = curve.total(series), total > floor,
                  let date = WhoopDayFigures.date(of: curve.day) else { continue }
            let target = Int(calendar.startOfDay(for: date).timeIntervalSince1970) + offset
            if let value = curve.cumulative(series, at: target) { reached.append(value) }
        }
        return reached.count < minDays ? nil : reached.reduce(0, +) / Double(reached.count)
    }
}
