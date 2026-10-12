import Foundation

/// Yoop: WHOOP Age and Pace of Aging, Yoop's own estimate built on WHOOP's published Healthspan method
/// ("The WHOOP Healthspan Feature", WHOOP with the Buck Institute, 2025, revised 4 Sep 2025; called "the white
/// paper" below). It is not WHOOP's number: WHOOP's overlap correction and several curve scales are not
/// published, so those are fitted (see "Calibration").
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

    // MARK: - Calibration
    //
    // WHOOP corrects the hazard ratios of its contributors with adjustment factors from a structural equation model
    // on its members' data (white paper, "Accounting for Correlated Behaviors and Metrics") and does not publish them
    // or several of the curves' scales. Everything else here is published: the log-linear form t = 10 x ln(HR), the
    // hazard ratios and the targets. What is not is fitted, once, to two things and nothing else:
    //   1. WHOOP's own Healthspan readout for one member (six-month averages): WHOOP Age six years and four tenths
    //      under the member's chronological age, with each contributor's years as the app printed them;
    //   2. the white paper's Table 2: WHOOP members aged 30 (male -1.6 years, female -1.6) and the typical US adult of 30
    //      (male about +6, female about +7.5).
    // Each fitted value says which of the two pins it. `WhoopAgeTests` feeds both back in and holds the result to
    // them (total within 0.5 years of the readout, each contributor within 0.3, Table 2 within 0.3 for members and 0.6
    // for the US adults). This is a calibration against one person's readout and a table of typical values, not a
    // validation: the form stays the published one, only the scales move, and the page says "calibrated against
    // WHOOP's own readout".
    //
    // Pinned by the readout (a printed value is good to 0.05 years):
    //   sleep benefit 0.41 y/h, consistency 0.17 y/point, steps scale 0.37, zones 1-3 scale 0.70, zones 4-5 target 20 min,
    //   strength slope 0.0026 ln(HR) a minute, VO2 max scale 0.73, resting heart rate scale 1.43.
    // Pinned by Table 2 alone (the readout cannot see them: the member sits at the target, or has no lean mass):
    //   zones 4-5 scale 0.25, lean body mass scale 0.32.

    /// The scale each contributor's years are multiplied by after the published curve. 1.0 where the published curve
    /// already matches WHOOP's readout (sleep, consistency and strength carry their fitted slope inside the curve
    /// instead). Below 1 the studies behind the curve overstate a contributor that is correlated with the others
    /// (WHOOP's overlap correction); above 1 WHOOP's readout is steeper than the cited hazard ratio.
    static func scale(_ key: Key) -> Double {
        switch key {
        case .sleepDuration, .sleepConsistency, .strength: return 1.0
        case .steps: return 0.37             // fitted to the readout: -0.3 years at 9,599 steps
        case .zones13: return 0.70           // fitted to the readout: -0.6 years at 180 minutes a week
        case .zones45: return 0.25           // fitted to Table 2 (the readout member sits at the target)
        case .vo2max: return 0.73            // fitted to the readout: -2.8 years at 48 ml/kg/min
        case .restingHr: return 1.43         // fitted to the readout: -1.1 years at 51 bpm (a slope of 12.9% a 10 bpm, steeper than the cited 9%)
        case .leanBodyMass: return 0.32      // fitted to Table 2 (no lean mass in the readout)
        }
    }

    /// Yoop's assumption: each contributor's years carry this relative error from the width of the
    /// confidence intervals of the cited meta-analyses (for example resting heart rate RR 1.09, 95% CI 1.07 to
    /// 1.12; steps and zone time wider). It is combined with the input's own measurement error.
    static let modelRelativeError = 0.25

    // MARK: - Contributors

    enum Key: String, CaseIterable, Identifiable {
        case sleepDuration, sleepConsistency, steps, zones13, zones45, strength, vo2max, restingHr, leanBodyMass
        var id: String { rawValue }

        /// This contributor's calibration scale (`WhoopAge.scale`).
        var scale: Double { WhoopAge.scale(self) }
    }

    /// What the nine contributors read, as the averages of a window.
    struct Inputs: Equatable {
        /// Age in years and fractions of a year (WHOOP counts to a tenth: the readout is a decimal age).
        var age: Double
        /// 1 standard deviation of `age` when the birth date is not known (`ProfileStore.unknownBirthdayFractionSigma`),
        /// else 0. It does not move the years, only how far WHOOP Age can be from the figure stated.
        var ageSigma: Double = 0
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

        init(age: Double, ageSigma: Double = 0, sex: String, sleepHours: Double? = nil, sleepConsistency: Double? = nil,
             steps: Double? = nil, zones13PerWeek: Double? = nil, zones45PerWeek: Double? = nil,
             strengthPerWeek: Double? = nil, vo2max: Double? = nil, vo2maxSigma: Double? = nil,
             restingHr: Double? = nil, leanBodyMassPct: Double? = nil) {
            self.age = age; self.ageSigma = ageSigma; self.sex = sex; self.sleepHours = sleepHours
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

    /// Zone 4 to 5 minutes a week that add nothing. The white paper's Table 1 gives 7 to 10 for a young adult and
    /// lower with age, but WHOOP's own readout prints 0.0 years at 20 minutes a week for that member (the
    /// marker sits in the neutral part of its bar, about 15 to 25 minutes), so the target is fitted to the readout at
    /// 20 minutes, the same for every age and sex: the readout cannot say how it moves.
    static func zones45Target(age: Double) -> Double { 20 }

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
    /// slight, not significant, reduction at 8 to 9 hours). Fitted to the readout: 0.41 years an hour above 7, to 8
    /// hours, flat to 9 (the readout's -0.1 at 7 h 13 min). More than 9 hours: no effect (white paper), tapering to
    /// nothing between 9 and 10.
    static let sleepBenefitYearsPerHour = 0.41

    static func sleepDurationYears(hours: Double) -> Double {
        if hours < sleepRange.lowerBound {
            let short = min(3, sleepRange.lowerBound - hours)
            return yearsPerLnHazard * log(1.12) * short
        }
        if hours <= 9 { return -sleepBenefitYearsPerHour * min(1, hours - sleepRange.lowerBound) }
        if hours < 10 { return -sleepBenefitYearsPerHour * (10 - hours) }
        return 0
    }

    /// Sleep consistency, percent. WHOOP: 70% breaks even, below adds, above subtracts. Windred et al. 2024
    /// (Sleep 47:zsad253), 60,977 UK Biobank adults: the most regular quintile of the sleep regularity index
    /// had 20% to 48% lower all-cause mortality than the least regular. The slope is fitted to the readout: 0.17
    /// years a point (ln(HR) 0.017 a point, inside the 0.012 to 0.022 that reading Windred's spread over 30 to 40
    /// points of the index gives), the readout's -0.2 years at 71%. Limited to +4 and -2.5 years.
    static let consistencyYearsPerPoint = 0.17

    static func sleepConsistencyYears(percent: Double) -> Double {
        let years = consistencyYearsPerPoint * (consistencyTarget - percent)
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

    /// Steps a day against the target, before the contributor's scale (`scale(.steps)`, 0.37, fitted: the readout
    /// prints -0.3 years at 9,599 steps where Paluch's quartiles alone give -0.8). An older adult's target is lower
    /// (`stepsTarget`); their steps are scaled to the same curve (Yoop's assumption, in line with the white paper's
    /// note that fewer steps are needed over 60).
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
    /// week of vigorous activity. Yoop's assumption: ln(HR) falls to ln(0.80) at 75 minutes a week on a log scale,
    /// ln(1 + minutes / 5), and is flat above. The shape is published only as these two points; the target is 20
    /// (`zones45Target`) and the scale 0.25 is fitted to Table 2.
    static let zones45SaturationMinutes = 75.0

    static func zones45LnHazard(_ minutes: Double) -> Double {
        let reach = log(1 + min(max(minutes, 0), zones45SaturationMinutes) / 5)
        return log(0.80) * reach / log(1 + zones45SaturationMinutes / 5)
    }

    static func zones45Years(minutesPerWeek: Double, age: Double) -> Double {
        yearsPerLnHazard * (zones45LnHazard(minutesPerWeek) - zones45LnHazard(zones45Target(age: age)))
    }

    /// Strength activity minutes a week. The white paper: 30 to 60 minutes a week go with 10% to 30% lower all-cause
    /// mortality (Momma et al. 2022, Br J Sports Med 56:755; Shailendra et al. 2022), 40 minutes breaks even, the
    /// shape is U shaped with its optimum between 30 minutes and 2 hours, and nothing more is credited above 2 hours.
    /// The cited studies' effect of 17% at 40 minutes is too steep above the target for WHOOP's readout, which
    /// prints -1.3 years at 90 minutes (HR 0.88 against the target). So the curve is straight in minutes up to the
    /// 2 hours the white paper stops at, ln(HR) = -0.0026 a minute, fitted to that readout. That puts 26% lower
    /// mortality at 2 hours against none, inside the white paper's 10% to 30%. It has no overlap scale
    /// (`scale(.strength)` is 1): the slope is the fit.
    static let strengthLnHazardPerMinute = 0.0026
    static let strengthCapMinutes = 120.0

    static func strengthLnHazard(_ minutes: Double) -> Double {
        -strengthLnHazardPerMinute * min(max(minutes, 0), strengthCapMinutes)
    }

    static func strengthYears(minutesPerWeek: Double) -> Double {
        yearsPerLnHazard * (strengthLnHazard(minutesPerWeek) - strengthLnHazard(strengthTarget))
    }

    /// VO2 max. Kodama et al. 2009 (JAMA 301:2024): 13% lower all-cause mortality for each extra MET (3.5
    /// ml/kg/min), the white paper's figure, before the contributor's scale (`scale(.vo2max)`, 0.73, fitted: the
    /// readout prints -2.8 years at 48 ml/kg/min where the hazard ratio alone gives -3.8). The distance from the
    /// target is limited to four METs either way so that the estimate is not extrapolated (Yoop's assumption).
    static func vo2maxYears(vo2: Double, age: Double, sex: String) -> Double {
        let met = 3.5
        let gap = min(4 * met, max(-4 * met, vo2 - vo2maxTarget(age: age, sex: sex)))
        return yearsPerLnHazard * log(0.87) * gap / met
    }

    /// Resting heart rate during sleep. Zhang et al. 2016 (CMAJ 188:E53, 46 cohorts): all-cause mortality RR
    /// 1.09 (95% CI 1.07 to 1.12) for each 10 bpm, the white paper's figure, before the contributor's scale
    /// (`scale(.restingHr)`, 1.43, fitted: the readout prints -1.1 years at 51 bpm where RR 1.09 gives -0.8, an
    /// effective 12.9% a 10 bpm; WHOOP measures during sleep, and the cited meta-analysis mostly did not).
    /// Limited to 30 bpm either side.
    static func restingHrYears(bpm: Double, sex: String) -> Double {
        let gap = min(30, max(-30, bpm - restingHrReference(sex: sex)))
        return yearsPerLnHazard * log(1.09) * gap / 10
    }

    /// Lean body mass percentage. Jayedi et al. 2022 (Int J Obes 46:1573, 35 cohorts): 11% higher all-cause
    /// mortality for each 10 percentage points of body fat, the white paper's figure, before the contributor's
    /// scale (`scale(.leanBodyMass)`, 0.32, fitted to Table 2). Limited to 15 points either side.
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
        /// Years added (positive) or subtracted (negative), after the contributor's scale.
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

    /// Raw years (before the contributor's scale) for one contributor, nil without a value.
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

    /// Years a unit of the input's own error is worth for this contributor, after the contributor's scale.
    private static func inputSigma(_ key: Key, _ inputs: Inputs) -> Double {
        switch key {
        case .vo2max:
            guard let s = inputs.vo2maxSigma else { return 0 }
            return abs(yearsPerLnHazard * log(0.87)) * s / 3.5 * key.scale
        default: return 0
        }
    }

    static func impact(_ key: Key, _ inputs: Inputs) -> Impact {
        guard let raw = rawYears(key, inputs) else {
            return Impact(key: key, value: nil, target: target(key, inputs), years: 0, sigma: 0)
        }
        let years = raw * key.scale
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
        /// 1 standard deviation of WHOOP Age itself: the contributors' error and, when the birth date is not known,
        /// the error in the age, combined as independent.
        var whoopAgeSigma: Double { (sigma * sigma + inputs.ageSigma * inputs.ageSigma).squareRoot() }
        var whoopAge: Double { inputs.age + totalYears }
        /// Positive: WHOOP Age is younger than the calendar age.
        var yearsYounger: Double { -totalYears }

        /// The years the VO2 max contributor carries at the two ends of its range (the used value less and plus one
        /// standard deviation), after the contributor's scale: the first is the older end, the second the younger.
        var vo2YearsRange: (older: Double, younger: Double)? {
            guard let v = inputs.vo2max, let s = inputs.vo2maxSigma else { return nil }
            func years(_ x: Double) -> Double { WhoopAge.vo2maxYears(vo2: x, age: inputs.age, sex: inputs.sex) * Key.vo2max.scale }
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
        /// Years it would take off, after the contributor's scale.
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
        case .zones45: return zones45SaturationMinutes
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
                let gained = impact.years - raw * impact.key.scale
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
