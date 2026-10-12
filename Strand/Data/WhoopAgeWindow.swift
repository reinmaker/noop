import Foundation

/// Yoop: the six-month window WHOOP Age reads, built from everything the app holds, and the one place that
/// turns it into a number. The Health tab, the WHOOP Age screen and the Coach all read `WhoopAgeLoader.load`,
/// so they state one figure.
///
/// Where each contributor comes from:
/// - sleep duration, sleep consistency and resting heart rate during sleep: the strap's nights, WHOOP's export
///   and Yoop's own, the one row Home shows for the day (an import wins, as everywhere else in the app);
///   consistency is WHOOP's own figure from the export, else Yoop's fit of it (`SleepModel.consistencyByWakeDay`);
/// - steps: the strap's count, else the phone's (Apple Health), as Home resolves a day's steps;
/// - heart rate zone and strength minutes: the logged activities, with WHOOP's own zone split when the export
///   carried one, else the strap's heart rate against Yoop's zones (`WhoopActivityZones`), counted over the days
///   the strap recorded;
/// - VO2 max: see `WhoopAgeVo2`;
/// - lean body mass: not held, so it adds nothing, as in WHOOP.
extension WhoopAge {

    /// One calendar day's figures.
    struct Day: Equatable {
        let day: String
        var sleepMin: Double?
        var consistency: Double?
        var restingHr: Double?
        var hasRecovery = false
        var steps: Double?
        var zones13Min = 0.0
        var zones45Min = 0.0
        var strengthMin = 0.0

        /// The strap recorded this day: it has a night or a recovery.
        var isStrapDay: Bool { sleepMin != nil || hasRecovery }
    }

    /// How much of the window the figures stand on.
    struct Coverage: Equatable {
        let windowDays: Int
        let strapDays: Int
        let stepDays: Int
        let recoveriesInLast31Days: Int
        var isUnlocked: Bool { WhoopAge.isUnlocked(recoveriesInLast31Days: recoveriesInLast31Days) }
    }

    /// The day keys of the `count` days ending on `day` (inclusive), oldest first, by calendar arithmetic on the
    /// key itself (no time zone, so a daylight saving change cannot move a day).
    static func dayKeys(endingOn day: String, count: Int) -> [String] {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return [day] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let end = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return [day] }
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: end).map { date in
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
        }
    }

    /// Nights shorter than this are a nap or a failed capture, not a night's sleep, and stay out of the average.
    static let minNightMinutes = 120.0
    /// Days below this step count are a day the strap or the phone was not carried (Home's own floor for the
    /// steps normal), and stay out of the average.
    static let minStepsForDay = 1000.0

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// The averages of the `span` days ending on `today` (inclusive).
    ///
    /// Sleep, consistency, resting heart rate and steps are means over the days that have them. The minute
    /// figures are totals per week of strap days: the sum over days the strap recorded, divided by those days
    /// over seven, so a window the strap covered for half the time is not counted as a window of no activity.
    /// They need `minDaysForWeekly` strap days to be stated.
    static func inputs(days: [Day], endingOn today: String, span: Int, age: Double, sex: String,
                       vo2: Vo2Choice?, leanBodyMassPct: Double? = nil) -> Inputs {
        let keys = Set(WhoopAge.dayKeys(endingOn: today, count: span))
        let inWindow = days.filter { keys.contains($0.day) }
        let strap = inWindow.filter(\.isStrapDay)
        var out = Inputs(age: age, sex: sex)
        out.sleepHours = mean(strap.compactMap(\.sleepMin).filter { $0 >= minNightMinutes }.map { $0 / 60 })
        out.sleepConsistency = mean(strap.compactMap(\.consistency))
        out.restingHr = mean(strap.compactMap(\.restingHr).filter { $0 > 0 })
        out.steps = mean(inWindow.compactMap(\.steps).filter { $0 >= minStepsForDay })
        if strap.count >= minDaysForWeekly {
            let weeks = Double(strap.count) / 7
            out.zones13PerWeek = strap.reduce(0) { $0 + $1.zones13Min } / weeks
            out.zones45PerWeek = strap.reduce(0) { $0 + $1.zones45Min } / weeks
            out.strengthPerWeek = strap.reduce(0) { $0 + $1.strengthMin } / weeks
        }
        out.vo2max = vo2?.used
        out.vo2maxSigma = vo2?.sigma
        out.leanBodyMassPct = leanBodyMassPct
        return out
    }

    static func coverage(days: [Day], endingOn today: String) -> Coverage {
        let window = Set(WhoopAge.dayKeys(endingOn: today, count: windowDays))
        let last31 = Set(WhoopAge.dayKeys(endingOn: today, count: unlockSpanDays))
        return Coverage(
            windowDays: windowDays,
            strapDays: days.filter { window.contains($0.day) && $0.isStrapDay }.count,
            stepDays: days.filter { window.contains($0.day) && ($0.steps ?? 0) >= minStepsForDay }.count,
            recoveriesInLast31Days: days.filter { last31.contains($0.day) && $0.hasRecovery }.count)
    }

    /// Whether a logged activity is strength activity time, by WHOOP's list (white paper Table 1): strength
    /// trainer, weightlifting, powerlifting, barre, pilates, yoga, hot yoga, functional fitness, Barry's, F45,
    /// box fitness, HIIT, baby and toddler wearing, rucking, solidcore. Matched on the sport's name, ignoring
    /// case and spaces, so Apple Health's "TraditionalStrengthTraining" counts as well.
    static func isStrengthSport(_ sport: String) -> Bool {
        let name = sport.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" && $0 != "'" }
        let names = ["strength", "weightlift", "powerlift", "barre", "pilates", "yoga", "functionalfitness",
                     "functionalstrength", "barrys", "f45", "boxfitness", "hiit", "highintensityinterval",
                     "babywearing", "toddlerwearing", "rucking", "solidcore"]
        return names.contains { name.contains($0) }
    }

    /// An activity's minutes in zones 1 to 3 and 4 to 5, from WHOOP's imported split when the row has one
    /// (percent of its duration), else from seconds per band (restorative first, as `WhoopActivityZones.bandSeconds`).
    static func zoneMinutes(durationS: Double, importedPercents: [Double]?,
                            bandSeconds: [Double]?) -> (z13: Double, z45: Double)? {
        if let p = importedPercents, p.count == 5, durationS > 0 {
            let minutes = durationS / 60
            return (minutes * (p[0] + p[1] + p[2]) / 100, minutes * (p[3] + p[4]) / 100)
        }
        if let b = bandSeconds, b.count == 6 {
            return ((b[1] + b[2] + b[3]) / 60, (b[4] + b[5]) / 60)
        }
        return nil
    }
}

// MARK: - The snapshot

/// WHOOP Age as the app states it: one resolved figure for every screen and the Coach.
struct WhoopAgeSnapshot: Equatable {
    let day: String
    let coverage: WhoopAge.Coverage
    let vo2: Vo2Choice?
    /// Nil while the window is calibrating, or the profile has no age.
    let result: WhoopAge.Result?
    /// The last 30 days' averages and the Pace of Aging they give.
    let recent: WhoopAge.Inputs?
    let pace: Double?

    var isUnlocked: Bool { coverage.isUnlocked && result != nil }
    var levers: [WhoopAge.Lever] { result.map(WhoopAge.levers) ?? [] }

    /// The Coach's lines about WHOOP Age: the same figures the screen states, nothing recomputed.
    var coachLines: [String] {
        guard let r = result, isUnlocked else { return [] }
        let years = abs(r.yearsYounger)
        let direction = r.yearsYounger >= 0 ? "younger" : "older"
        var parts = [String(format: "WHOOP Age %.1f against a calendar age of %.0f: %.1f years %@ (Yoop's estimate on WHOOP's published Healthspan method, not WHOOP's own number; about +/- %.1f years).",
                            r.whoopAge, r.chronologicalAge, years, direction, r.sigma)]
        if let pace {
            let word = Self.paceWord(WhoopAge.paceState(pace))
            parts.append(String(format: "Pace of Aging %.1fx (%@).", pace, word))
        }
        if let vo2 {
            parts.append(Self.vo2Sentence(vo2))
        }
        let top = levers.prefix(2).map { Self.leverSentence($0) }
        if !top.isEmpty { parts.append("Biggest levers: " + top.joined(separator: "; ") + ".") }
        parts.append("Built on \(coverage.strapDays) of the last \(coverage.windowDays) days the strap recorded.")
        return parts
    }

    /// Which VO2 max WHOOP Age used, so the Coach never quotes another figure for it.
    static func vo2Sentence(_ vo2: Vo2Choice) -> String {
        let source: String
        switch vo2.source {
        case .appleHealth: source = String(format: "Apple Health's reading of %.0f on %@, adjusted for the Apple Watch's usual low reading", vo2.reading, vo2.day)
        case .nes: source = String(format: "Yoop's waist-based estimate (Nes, HUNT) of %.0f", vo2.reading)
        case .uth: source = String(format: "Yoop's rough heart-rate estimate (Uth) of %.0f", vo2.reading)
        }
        return String(format: "VO2 max used: %.0f ml/kg/min, a range of %.0f to %.0f (%@). It is a range, not a measurement.",
                      vo2.used, vo2.low, vo2.high, source)
    }

    static func paceWord(_ state: WhoopAge.PaceState) -> String {
        switch state {
        case .reversing: return "reversing"
        case .slowing: return "slowing"
        case .steady: return "steady"
        case .accelerated: return "accelerated"
        }
    }

    /// "about 1,800 more steps a day would take 0.9 years off", for the Coach.
    static func leverSentence(_ lever: WhoopAge.Lever) -> String {
        let gained = String(format: "%.1f", lever.yearsGained)
        switch lever.key {
        case .steps: return "about \(Int(lever.amount.rounded())) more steps a day (\(gained) years)"
        case .zones13: return "about \(Int(lever.amount.rounded())) more minutes a week in heart rate zones 1 to 3 (\(gained) years)"
        case .zones45: return "about \(Int(lever.amount.rounded())) more minutes a week in zones 4 to 5 (\(gained) years)"
        case .strength: return "about \(Int(lever.amount.rounded())) more minutes a week of strength activity (\(gained) years)"
        case .sleepDuration: return String(format: "about %.1f more hours of sleep a night (%@ years)", lever.amount, gained)
        case .sleepConsistency: return "about \(Int(lever.amount.rounded())) points more sleep consistency (\(gained) years)"
        case .vo2max: return String(format: "VO2 max up by about %.0f ml/kg/min (%@ years)", lever.amount, gained)
        case .restingHr: return String(format: "resting heart rate down by about %.0f bpm (%@ years)", lever.amount, gained)
        case .leanBodyMass: return "lean body mass (\(gained) years)"
        }
    }
}
