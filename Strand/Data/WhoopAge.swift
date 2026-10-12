import Foundation

/// Yoop: WHOOP Age and Pace of Aging, Yoop's own estimate built on WHOOP's published Healthspan method
/// ("The WHOOP Healthspan Feature", WHOOP with the Buck Institute, 2025, revised 4 Sep 2025; called "the white
/// paper" below). It is not WHOOP's number: WHOOP's overlap correction is not published (see `fitnessShrink`).
///
/// The method, from the white paper:
/// - Every contributor has a hazard ratio (HR) for all-cause mortality against a health-optimised referent,
///   the expert recommendation, not the population average. Mortality risk rises about 10% per year of age
///   (Gompertz; Olshansky and Carnes 1997), so the effective-age difference is t = ln(HR) / 0.1 = 10 x ln(HR)
///   years (Spiegelhalter 2016, BMC Med Inform Decis Mak 16:104). A contributor at its target adds nothing.
/// - WHOOP Age is the chronological age plus the sum of the nine contributors' years, over the last six months.
/// - Pace of Aging projects WHOOP Age six months ahead if the last 30 days' averages held, and compares it
///   with today's: a difference of exactly six months is 1.0x, on a scale of -1.0x to 3.0x.
///
/// Every dose-response curve below states its source. Where the white paper gives only a target, the curve's
/// shape is Yoop's own choice from the study the white paper cites, and is marked "Yoop's assumption".
enum WhoopAge {

    // MARK: - Constants

    /// Years of effective age per unit of ln(HR): 1 / ln(e^0.1) (white paper, "Using All-Cause Mortality Risk
    /// to Calculate an Effective Age").
    static let yearsPerLnHazard = 10.0
    /// The window WHOOP Age reads: the last six months, as 26 weeks.
    static let windowDays = 182
    /// The window Pace of Aging reads.
    static let recentDays = 30
    /// WHOOP unlocks Healthspan after this many recoveries in the last `unlockSpanDays` days (white paper's
    /// product rules, as the WHOOP app states them).
    static let unlockRecoveries = 21
    static let unlockSpanDays = 31
    /// A weekly figure needs this many days of strap data in the window before it is stated.
    static let minDaysForWeekly = 14

    /// Yoop's assumption: the overlap correction. WHOOP multiplies each hazard ratio by adjustment factors
    /// from a structural equation model on its members' data (white paper, "Accounting for Correlated
    /// Behaviors and Metrics") and does not publish them. The studies behind the fitness and activity
    /// contributors (VO2 max, resting heart rate, steps, zone time, strength, lean mass) are adjusted for each
    /// other only in part, so their years are multiplied by this factor. 0.65 is the single value for which the
    /// white paper's two Table 2 anchors both come out near WHOOP's: 30 year old male WHOOP members (-1.6
    /// years) and the typical US 30 year old male (about +6 years). The two sleep contributors, whose studies
    /// adjust for activity and fitness, are left as they are.
    static let fitnessShrink = 0.65
    static let sleepShrink = 1.0

    /// Yoop's assumption: each contributor's years carry this relative error from the width of the
    /// confidence intervals of the cited meta-analyses (for example resting heart rate RR 1.09, 95% CI 1.07 to
    /// 1.12; steps and zone time wider). It is combined with the input's own measurement error.
    static let modelRelativeError = 0.25

    // MARK: - Contributors

    enum Key: String, CaseIterable, Identifiable {
        case sleepDuration, sleepConsistency, steps, zones13, zones45, strength, vo2max, restingHr, leanBodyMass
        var id: String { rawValue }

        var shrink: Double {
            switch self {
            case .sleepDuration, .sleepConsistency: return WhoopAge.sleepShrink
            default: return WhoopAge.fitnessShrink
            }
        }
    }

    /// What the nine contributors read, as the averages of a window.
    struct Inputs: Equatable {
        var age: Double
        /// "male", "female" or anything else (the two sets of constants are averaged).
        var sex: String
        /// Average nightly hours asleep.
        var sleepHours: Double?
        /// Average WHOOP-style Sleep Consistency, 0 to 100.
        var sleepConsistency: Double?
        /// Average daily steps.
        var steps: Double?
        /// Minutes per week in heart rate zones 1 to 3 and 4 to 5 of logged activities, and in strength
        /// activities.
        var zones13PerWeek: Double?
        var zones45PerWeek: Double?
        var strengthPerWeek: Double?
        /// VO2 max in ml/kg/min and its error (1 SD) when the source states one.
        var vo2max: Double?
        var vo2maxSigma: Double?
        /// Average heart rate during sleep.
        var restingHr: Double?
        /// Lean body mass as a percentage of body mass. WHOOP and Yoop only use it when it is entered.
        var leanBodyMassPct: Double?

        init(age: Double, sex: String, sleepHours: Double? = nil, sleepConsistency: Double? = nil,
             steps: Double? = nil, zones13PerWeek: Double? = nil, zones45PerWeek: Double? = nil,
             strengthPerWeek: Double? = nil, vo2max: Double? = nil, vo2maxSigma: Double? = nil,
             restingHr: Double? = nil, leanBodyMassPct: Double? = nil) {
            self.age = age; self.sex = sex; self.sleepHours = sleepHours
            self.sleepConsistency = sleepConsistency; self.steps = steps
            self.zones13PerWeek = zones13PerWeek; self.zones45PerWeek = zones45PerWeek
            self.strengthPerWeek = strengthPerWeek; self.vo2max = vo2max; self.vo2maxSigma = vo2maxSigma
            self.restingHr = restingHr; self.leanBodyMassPct = leanBodyMassPct
        }

        /// This window's value for a contributor.
        func value(_ key: Key) -> Double? {
            switch key {
            case .sleepDuration: return sleepHours
            case .sleepConsistency: return sleepConsistency
            case .steps: return steps
            case .zones13: return zones13PerWeek
            case .zones45: return zones45PerWeek
            case .strength: return strengthPerWeek
            case .vo2max: return vo2max
            case .restingHr: return restingHr
            case .leanBodyMass: return leanBodyMassPct
            }
        }

        /// The same inputs with one contributor's value replaced.
        func replacing(_ key: Key, with v: Double) -> Inputs {
            var out = self
            switch key {
            case .sleepDuration: out.sleepHours = v
            case .sleepConsistency: out.sleepConsistency = v
            case .steps: out.steps = v
            case .zones13: out.zones13PerWeek = v
            case .zones45: out.zones45PerWeek = v
            case .strength: out.strengthPerWeek = v
            case .vo2max: out.vo2max = v
            case .restingHr: out.restingHr = v
            case .leanBodyMass: out.leanBodyMassPct = v
            }
            return out
        }

        /// The same inputs with `fallback`'s value wherever this one has none.
        func filling(from fallback: Inputs) -> Inputs {
            var out = self
            out.sleepHours = sleepHours ?? fallback.sleepHours
            out.sleepConsistency = sleepConsistency ?? fallback.sleepConsistency
            out.steps = steps ?? fallback.steps
            out.zones13PerWeek = zones13PerWeek ?? fallback.zones13PerWeek
            out.zones45PerWeek = zones45PerWeek ?? fallback.zones45PerWeek
            out.strengthPerWeek = strengthPerWeek ?? fallback.strengthPerWeek
            if vo2max == nil { out.vo2max = fallback.vo2max; out.vo2maxSigma = fallback.vo2maxSigma }
            out.restingHr = restingHr ?? fallback.restingHr
            out.leanBodyMassPct = leanBodyMassPct ?? fallback.leanBodyMassPct
            return out
        }
    }

    // MARK: - Targets (the referent)

    /// Linear interpolation through (x, y) knots sorted by x, held flat beyond the ends.
    static func interpolate(_ x: Double, _ knots: [(Double, Double)]) -> Double {
        guard let first = knots.first, let last = knots.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<knots.count where x <= knots[i].0 {
            let (x0, y0) = knots[i - 1], (x1, y1) = knots[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return last.1
    }

    private static func isMale(_ sex: String) -> Bool? {
        switch sex.lowercased() {
        case "male": return true
        case "female": return false
        default: return nil
        }
    }

    /// Blends the male and female constant for a sex that is neither.
    private static func bySex(_ sex: String, male: Double, female: Double) -> Double {
        isMale(sex).map { $0 ? male : female } ?? (male + female) / 2
    }

    /// Minimum VO2 max by age and sex (white paper Figure 4, WHOOP's minimum recommendation), linear between
    /// the five-year ages it prints.
    static let vo2maxTargetMale: [(Double, Double)] = [
        (20, 46), (25, 46), (30, 44), (35, 42), (40, 40), (45, 37), (50, 36), (55, 34), (60, 32), (65, 30),
        (70, 29), (75, 27), (80, 26), (85, 25), (90, 23), (95, 22), (100, 21),
    ]
    static let vo2maxTargetFemale: [(Double, Double)] = [
        (20, 40), (25, 40), (30, 38), (35, 36), (40, 34), (45, 32), (50, 30), (55, 29), (60, 27), (65, 26),
        (70, 25), (75, 23), (80, 22), (85, 21), (90, 20), (95, 19), (100, 18),
    ]

    static func vo2maxTarget(age: Double, sex: String) -> Double {
        let m = interpolate(age, vo2maxTargetMale), f = interpolate(age, vo2maxTargetFemale)
        return bySex(sex, male: m, female: f)
    }

    /// Resting heart rate during sleep that adds nothing: about 60 bpm for males and 64 for females (white
    /// paper, "Resting Heart Rate").
    static func restingHrReference(sex: String) -> Double { bySex(sex, male: 60, female: 64) }

    /// Daily steps that add nothing: 8,000 for a younger adult and 5,600 for an older one (white paper, Table 1).
    /// Yoop's assumption for where the change happens: 8,000 up to age 60, the age Paluch et al. 2022 (Lancet
    /// Public Health 7:e219) split their plateaus at (8,000 to 10,000 below 60, 6,000 to 8,000 from 60), falling
    /// in a straight line to 5,600 at 75.
    static func stepsTarget(age: Double) -> Double {
        interpolate(age, [(60, 8000), (75, 5600)])
    }

    /// Zone 1 to 3 minutes a week that add nothing: 100 for a young adult, 70 for an older one (white paper,
    /// Table 1 "70-100 minutes per week, values decrease with age"). Yoop's assumption: 100 to age 30, falling
    /// in a straight line to 70 at 80.
    static func zones13Target(age: Double) -> Double { interpolate(age, [(30, 100), (80, 70)]) }

    /// Zone 4 to 5 minutes a week that add nothing: 10 for a young adult, 7 for an older one (Table 1). Yoop's
    /// assumption: 10 to age 30, falling in a straight line to 7 at 80.
    static func zones45Target(age: Double) -> Double { interpolate(age, [(30, 10), (80, 7)]) }

    /// Strength activity minutes a week that add nothing: 40 (white paper, "Strength Activity Time").
    static let strengthTarget = 40.0
    /// Sleep consistency, in percent, that adds nothing: 70 (white paper, "Sleep Consistency").
    static let consistencyTarget = 70.0
    /// The sleep duration range WHOOP calls healthy, in hours.
    static let sleepRange = 7.0...9.0

    /// Lean body mass percentage that adds nothing: 80 for a 30 year old male and 67 for a female (white paper,
    /// "Lean Body Mass Percentage"). Yoop's assumption for the change with age: 0.1 percentage points a year
    /// after 30 (the paper says it changes with age and prints no table).
    static func leanBodyMassTarget(age: Double, sex: String) -> Double {
        let base = bySex(sex, male: 80, female: 67)
        return base - 0.1 * max(0, age - 30)
    }

    // MARK: - Dose-response curves (raw years: positive adds, negative subtracts)

    /// Sleep duration, hours a night. Short sleep: Itani et al. 2017 (Sleep Med 32:246), pooled all-cause
    /// mortality HR 1.12 for short sleep (about 6 hours), taken as ln(1.12) per hour under 7, capped at three
    /// hours short. 7 to 9 hours: a minor reduction (white paper; Magee et al. 2013, Sleep Med 14:591, found a
    /// slight, not significant, reduction at 8 to 9 hours); Yoop's assumption: 0.2 years from 8 hours. More than
    /// 9 hours: no effect (white paper), tapering to nothing between 9 and 10.
    static func sleepDurationYears(hours: Double) -> Double {
        if hours < sleepRange.lowerBound {
            let short = min(3, sleepRange.lowerBound - hours)
            return yearsPerLnHazard * log(1.12) * short
        }
        let benefit = 0.2
        if hours <= 9 { return -benefit * min(1, hours - sleepRange.lowerBound) }
        if hours < 10 { return -benefit * (10 - hours) }
        return 0
    }

    /// Sleep consistency, percent. WHOOP: 70% breaks even, below adds, above subtracts. Windred et al. 2024
    /// (Sleep 47:zsad253), 60,977 UK Biobank adults: the most regular quintile of the sleep regularity index
    /// had 20% to 48% lower all-cause mortality than the least regular. Yoop's assumption: that spread, about
    /// ln(0.52) over 40 points of the index, is read as 0.012 ln(HR) per consistency point, limited to
    /// +4 and -2.5 years.
    static func sleepConsistencyYears(percent: Double) -> Double {
        let years = yearsPerLnHazard * 0.012 * (consistencyTarget - percent)
        return min(4, max(-2.5, years))
    }

    /// The ln(HR) of daily steps against the lowest quartile, from Paluch et al. 2022 (Lancet Public Health
    /// 7:e219, 15 cohorts, adults under 60): quartile medians 3,553 / 5,801 / 7,842 / 10,901 steps a day had
    /// HR 1.00 / 0.60 / 0.55 / 0.47 for all-cause mortality. Straight lines between, held flat above the top
    /// quartile (the plateau; Stens et al. 2023 found the lowest risk near 8,763), and below the lowest
    /// quartile continued on the first segment's slope and limited to ln(HR) +0.8 (Yoop's assumption).
    static let stepsKnots: [(Double, Double)] = [
        (3553, 0), (5801, log(0.60)), (7842, log(0.55)), (10901, log(0.47)),
    ]

    static func stepsLnHazard(_ steps: Double) -> Double {
        if steps < stepsKnots[0].0 {
            let slope = (stepsKnots[1].1 - stepsKnots[0].1) / (stepsKnots[1].0 - stepsKnots[0].0)
            return min(0.8, slope * (steps - stepsKnots[0].0))
        }
        return interpolate(steps, stepsKnots)
    }

    /// Steps a day against the target. An older adult's target is lower (`stepsTarget`); their steps are scaled
    /// to the same curve (Yoop's assumption, in line with the white paper's note that fewer steps are needed
    /// over 60).
    static func stepsYears(steps: Double, age: Double) -> Double {
        let scale = 8000 / stepsTarget(age: age)
        return yearsPerLnHazard * (stepsLnHazard(steps * scale) - stepsLnHazard(8000))
    }

    /// Zone 1 to 3 minutes a week. Lee et al. 2022 (Circulation 146:523, 116,221 adults): all-cause mortality
    /// about 0.78 at 150 to 300 minutes a week of moderate activity and no clearer benefit beyond 600 (the
    /// white paper, too: "incrementally up to 600 minutes"). Yoop's assumption: ln(HR) = -0.179 x
    /// ln(1 + minutes / 50), which gives HR 0.78 at 150 minutes, held flat above 600 minutes.
    static func zones13LnHazard(_ minutes: Double) -> Double {
        -0.179 * log(1 + min(max(minutes, 0), 600) / 50)
    }

    static func zones13Years(minutesPerWeek: Double, age: Double) -> Double {
        yearsPerLnHazard * (zones13LnHazard(minutesPerWeek) - zones13LnHazard(zones13Target(age: age)))
    }

    /// Zone 4 to 5 minutes a week. Ahmadi et al. 2022 (Eur Heart J 43:4801): 15 to 20 minutes a week of
    /// vigorous bursts, 18% to 24% lower all-cause mortality; Lee et al. 2022: HR 0.81 at 75 to 149 minutes a
    /// week of vigorous activity, so no further benefit is credited. Yoop's assumption: ln(HR) rises to ln(0.80)
    /// at 20 minutes a week on a log scale, ln(1 + minutes / 5), and is flat above.
    static func zones45LnHazard(_ minutes: Double) -> Double {
        let reach = log(1 + min(max(minutes, 0), 20) / 5)
        return log(0.80) * reach / log(1 + 20.0 / 5)
    }

    static func zones45Years(minutesPerWeek: Double, age: Double) -> Double {
        yearsPerLnHazard * (zones45LnHazard(minutesPerWeek) - zones45LnHazard(zones45Target(age: age)))
    }

    /// Strength activity minutes a week. Momma et al. 2022 (Br J Sports Med 56:755, 16 cohorts): any
    /// muscle-strengthening against none, all-cause mortality RR 0.85, J shaped, lowest at 40 minutes a week
    /// (RR 0.83, 95% CI 0.79 to 0.86); the white paper stops crediting at two hours. Yoop's assumption: ln(RR)
    /// falls straight from 0 at none to ln(0.83) at 40 minutes, then a further 2% to two hours, then is flat.
    static func strengthLnHazard(_ minutes: Double) -> Double {
        let m = max(0, minutes)
        if m <= strengthTarget { return log(0.83) * m / strengthTarget }
        return log(0.83) + log(0.98) * (min(m, 120) - strengthTarget) / 80
    }

    static func strengthYears(minutesPerWeek: Double) -> Double {
        yearsPerLnHazard * (strengthLnHazard(minutesPerWeek) - strengthLnHazard(strengthTarget))
    }

    /// VO2 max. Kodama et al. 2009 (JAMA 301:2024): 13% lower all-cause mortality for each extra MET (3.5
    /// ml/kg/min), the white paper's figure. The distance from the target is limited to four METs either way
    /// so that the estimate is not extrapolated (Yoop's assumption).
    static func vo2maxYears(vo2: Double, age: Double, sex: String) -> Double {
        let met = 3.5
        let gap = min(4 * met, max(-4 * met, vo2 - vo2maxTarget(age: age, sex: sex)))
        return yearsPerLnHazard * log(0.87) * gap / met
    }

    /// Resting heart rate during sleep. Zhang et al. 2016 (CMAJ 188:E53, 46 cohorts): all-cause mortality RR
    /// 1.09 (95% CI 1.07 to 1.12) for each 10 bpm, the white paper's figure. Limited to 30 bpm either side.
    static func restingHrYears(bpm: Double, sex: String) -> Double {
        let gap = min(30, max(-30, bpm - restingHrReference(sex: sex)))
        return yearsPerLnHazard * log(1.09) * gap / 10
    }

    /// Lean body mass percentage. Jayedi et al. 2022 (Int J Obes 46:1573, 35 cohorts): 11% higher all-cause
    /// mortality for each 10 percentage points of body fat, the white paper's figure. Limited to 15 points
    /// either side.
    static func leanBodyMassYears(percent: Double, age: Double, sex: String) -> Double {
        let gap = min(15, max(-15, leanBodyMassTarget(age: age, sex: sex) - percent))
        return yearsPerLnHazard * log(1.11) * gap / 10
    }

    // MARK: - One contributor

    /// One contributor's reading against its target.
    struct Impact: Equatable, Identifiable {
        let key: Key
        /// The window's value, nil when there is no data (no effect, as WHOOP does for lean body mass).
        let value: Double?
        /// The value that adds nothing.
        let target: Double?
        /// Years added (positive) or subtracted (negative), after the overlap correction.
        let years: Double
        /// 1 standard deviation of `years`, from the model error and the input's own error.
        let sigma: Double
        var id: String { key.rawValue }
    }

    static func target(_ key: Key, _ inputs: Inputs) -> Double? {
        switch key {
        case .sleepDuration: return sleepRange.lowerBound
        case .sleepConsistency: return consistencyTarget
        case .steps: return stepsTarget(age: inputs.age)
        case .zones13: return zones13Target(age: inputs.age)
        case .zones45: return zones45Target(age: inputs.age)
        case .strength: return strengthTarget
        case .vo2max: return vo2maxTarget(age: inputs.age, sex: inputs.sex)
        case .restingHr: return restingHrReference(sex: inputs.sex)
        case .leanBodyMass: return leanBodyMassTarget(age: inputs.age, sex: inputs.sex)
        }
    }

    /// Raw years (before the overlap correction) for one contributor, nil without a value.
    static func rawYears(_ key: Key, _ inputs: Inputs) -> Double? {
        guard let v = inputs.value(key), v.isFinite else { return nil }
        switch key {
        case .sleepDuration: return sleepDurationYears(hours: v)
        case .sleepConsistency: return sleepConsistencyYears(percent: v)
        case .steps: return stepsYears(steps: v, age: inputs.age)
        case .zones13: return zones13Years(minutesPerWeek: v, age: inputs.age)
        case .zones45: return zones45Years(minutesPerWeek: v, age: inputs.age)
        case .strength: return strengthYears(minutesPerWeek: v)
        case .vo2max: return vo2maxYears(vo2: v, age: inputs.age, sex: inputs.sex)
        case .restingHr: return restingHrYears(bpm: v, sex: inputs.sex)
        case .leanBodyMass: return leanBodyMassYears(percent: v, age: inputs.age, sex: inputs.sex)
        }
    }

    /// Years a unit of the input's own error is worth for this contributor, after the overlap correction.
    private static func inputSigma(_ key: Key, _ inputs: Inputs) -> Double {
        switch key {
        case .vo2max:
            guard let s = inputs.vo2maxSigma else { return 0 }
            return abs(yearsPerLnHazard * log(0.87)) * s / 3.5 * key.shrink
        default: return 0
        }
    }

    static func impact(_ key: Key, _ inputs: Inputs) -> Impact {
        guard let raw = rawYears(key, inputs) else {
            return Impact(key: key, value: nil, target: target(key, inputs), years: 0, sigma: 0)
        }
        let years = raw * key.shrink
        let sigma = (pow(modelRelativeError * years, 2) + pow(inputSigma(key, inputs), 2)).squareRoot()
        return Impact(key: key, value: inputs.value(key), target: target(key, inputs), years: years, sigma: sigma)
    }

    // MARK: - WHOOP Age

    struct Result: Equatable {
        let inputs: Inputs
        /// The nine contributors, the largest effect first.
        let impacts: [Impact]
        /// The sum of the contributors' years.
        let totalYears: Double
        /// 1 standard deviation of the total, the contributors' errors combined as independent.
        let sigma: Double

        var chronologicalAge: Double { inputs.age }
        var whoopAge: Double { inputs.age + totalYears }
        /// Positive: WHOOP Age is younger than the calendar age.
        var yearsYounger: Double { -totalYears }

        /// The years the VO2 max contributor carries at the two ends of its range (the used value less and plus one
        /// standard deviation), after the overlap correction: the first is the older end, the second the younger.
        var vo2YearsRange: (older: Double, younger: Double)? {
            guard let v = inputs.vo2max, let s = inputs.vo2maxSigma else { return nil }
            func years(_ x: Double) -> Double { WhoopAge.vo2maxYears(vo2: x, age: inputs.age, sex: inputs.sex) * Key.vo2max.shrink }
            return (years(max(0, v - s)), years(v + s))
        }

        /// A contributor's share of the total uncertainty (its variance over the sum of variances), 0 to 1.
        func uncertaintyShare(_ key: Key) -> Double {
            let all = impacts.reduce(0) { $0 + $1.sigma * $1.sigma }
            guard all > 0, let one = impacts.first(where: { $0.key == key }) else { return 0 }
            return one.sigma * one.sigma / all
        }

        /// A contributor's share of the years that move WHOOP Age: |its years| over the sum of |years|.
        func yearsShare(_ key: Key) -> Double {
            let all = impacts.reduce(0) { $0 + abs($1.years) }
            guard all > 0, let one = impacts.first(where: { $0.key == key }) else { return 0 }
            return abs(one.years) / all
        }
    }

    static func compute(_ inputs: Inputs) -> Result {
        let impacts = Key.allCases.map { impact($0, inputs) }
            .sorted { abs($0.years) > abs($1.years) }
        let total = impacts.reduce(0) { $0 + $1.years }
        let sigma = impacts.reduce(0) { $0 + $1.sigma * $1.sigma }.squareRoot()
        return Result(inputs: inputs, impacts: impacts, totalYears: total, sigma: sigma)
    }

    // MARK: - Pace of Aging

    enum PaceState: Equatable {
        case reversing, slowing, steady, accelerated
    }

    /// The scale WHOOP draws, 1.0x being one year of WHOOP Age per year of calendar.
    static let paceRange = -1.0...3.0

    /// Pace of Aging. The projected WHOOP Age six months on, if the last 30 days' averages held for the next six
    /// months, is the age half a year from now plus the years those averages carry; today's is the age now plus
    /// the six-month window's years. Their difference over the half year is
    /// `1 + (recent years - window years) / 0.5`, so 1.0x means the last 30 days read the same as the six months,
    /// and a month a full year better or worse than the window reads -1.0x or 3.0x, the ends of the scale.
    /// Contributors the last 30 days did not measure take the window's value, which adds nothing to the
    /// difference.
    static func pace(window: Inputs, recent: Inputs) -> Double {
        let now = compute(window).totalYears
        let projected = compute(recent.filling(from: window)).totalYears
        let pace = 1 + (projected - now) / 0.5
        return min(paceRange.upperBound, max(paceRange.lowerBound, pace))
    }

    /// The four words WHOOP gives the scale. Yoop's assumption: within 0.1 of 1.0x counts as steady, since the
    /// white paper defines steady as exactly 1.0x and no reading is exactly that.
    static func paceState(_ pace: Double) -> PaceState {
        if pace < 0 { return .reversing }
        if pace < 0.9 { return .slowing }
        if pace <= 1.1 { return .steady }
        return .accelerated
    }

    // MARK: - What to do

    /// A way to take years off: how much more of one thing to do.
    struct Lever: Equatable, Identifiable {
        let key: Key
        /// How much to add: steps a day, minutes a week, hours a night, consistency points, or bpm lower.
        let amount: Double
        /// Years it would take off, after the overlap correction.
        let yearsGained: Double
        /// False: it closes a gap to the target. True: the target is met and this goes on to where the studies
        /// behind the curve stop finding more benefit.
        let isStretch: Bool
        var id: String { key.rawValue }
    }

    /// Where more of a behaviour stops paying, for a contributor already at its target: the top of the
    /// curve (steps, zone minutes), or Yoop's assumption for sleep and consistency.
    private static func stretchGoal(_ key: Key, _ inputs: Inputs) -> Double? {
        switch key {
        case .steps: return 10_000 * stepsTarget(age: inputs.age) / 8_000
        case .zones13: return 300
        case .zones45: return 20
        case .sleepDuration: return 8
        case .sleepConsistency: return 80
        default: return nil
        }
    }

    /// The things that add years and can be moved, then, for the rest, how to go further. Behaviours come
    /// before the fitness figures that follow from them (VO2 max, resting heart rate), and a gap to a target
    /// before a stretch beyond it; the largest first within each.
    static func levers(_ result: Result) -> [Lever] {
        let behaviours: Set<Key> = [.sleepDuration, .sleepConsistency, .steps, .zones13, .zones45, .strength]
        var out: [Lever] = []
        for impact in result.impacts {
            guard let value = impact.value, let target = impact.target else { continue }
            if impact.years > 0.05 {
                switch impact.key {
                case .leanBodyMass: continue
                case .restingHr: out.append(Lever(key: impact.key, amount: value - target, yearsGained: impact.years, isStretch: false))
                default: out.append(Lever(key: impact.key, amount: target - value, yearsGained: impact.years, isStretch: false))
                }
            } else if let goal = stretchGoal(impact.key, result.inputs), goal > value,
                      let raw = rawYears(impact.key, result.inputs.replacing(impact.key, with: goal)) {
                let gained = impact.years - raw * impact.key.shrink
                if gained >= 0.15 {
                    out.append(Lever(key: impact.key, amount: goal - value, yearsGained: gained, isStretch: true))
                }
            }
        }
        return out.sorted {
            if $0.isStretch != $1.isStretch { return !$0.isStretch }
            let a = behaviours.contains($0.key), b = behaviours.contains($1.key)
            return a != b ? a : $0.yearsGained > $1.yearsGained
        }
    }

    // MARK: - Unlock

    /// Whether the window holds enough recoveries to state a number (WHOOP: 21 recoveries in 31 days).
    static func isUnlocked(recoveriesInLast31Days: Int) -> Bool { recoveriesInLast31Days >= unlockRecoveries }
}
