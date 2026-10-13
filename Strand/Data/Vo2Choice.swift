import Foundation

/// Yoop: the one VO2 max every screen states: Home's VO2 MAX row, the VO2 page behind it, WHOOP Age. It is never a
/// single point from the weakest source. VO2 max is not measured by the strap and cannot be derived from a WHOOP
/// export (no VO2, no body size, no pace or distance), so what is held is estimates, and the page shows the
/// estimate as the range it is.
///
/// The source is the best one there is, in this order:
/// 0. A VO2 max the wearer read from the WHOOP app and typed in under Settings, with the day (`whoopAppMaxAgeDays`
///    old at most). It is WHOOP's own estimate for this person, so it is used as it stands, with the spread Yoop gives
///    its waist-based estimate, `whoopAppSigma` (Yoop's assumption: WHOOP does not state an error for it). Nothing in
///    the code writes it: it is there only when the person entered it.
/// 1. Apple Health's reading, when it is no more than `appleMaxAgeDays` old. The wearer's Apple Watch measures it
///    on outdoor walks and runs. Against a lab test it reads low by about 6 on average and misses by about 6 (Lambe
///    et al. 2025, PLoS ONE 20:e0323741, 30 adults on a treadmill: lab minus watch +6.1, 95% limits of agreement
///    -6.1 to +18.3; a 2024 JMIR Biomedical Engineering study of Series 7 watches, 45.9 against 41.4, and a conference
///    abstract, 5.5 low, agree). So the number used is the reading plus that mean difference, with the same spread:
///    an Apple reading of 38 is used as 44, in a range of 38 to 50. That is Yoop's assumption, from those studies.
/// 2. Yoop's Nes et al. 2011 estimate (HUNT, Med Sci Sports Exerc 43:2024), which needs the waist. SEE 5.70 men,
///    5.14 women, no bias to correct.
/// 3. Yoop's Uth et al. 2004 heart-rate ratio (15.3 x HRmax / HRrest, Eur J Appl Physiol 91:111), marked rough:
///    its own SEE is 4.7 with an age-predicted HRmax, in well-trained men aged 21 to 51 only, and Yoop feeds it the
///    sleeping heart rate, which is lower than the resting rate it was built on, so it reads high. The band is
///    `uthSigma`, wider than its published error (Yoop's assumption).
///
/// The NOOP Keytel calorie path still takes the Uth figure, on purpose; `Vo2Resolver.load` exposes this choice and
/// its source so that path can adopt it when that is decided. Yoop's calorie estimate takes no VO2 max at all: it
/// is the heart-rate line fitted to the wearer's WHOOP workouts (`Calories.yoopActiveKcalPerBpm`).
struct Vo2Choice: Equatable {
    enum Source: String, Equatable { case whoopApp, appleHealth, nes, uth }

    struct Reading: Equatable {
        let value: Double
        let day: String
        /// Yoop's estimator ("uth" or "nes"); nil for Apple Health's and the WHOOP app's.
        let estimator: String?
    }

    let source: Source
    /// The chosen source's own reading, as that source states it.
    let reading: Double
    let day: String
    /// The number used: the reading less the source's known mean error.
    let used: Double
    /// 1 standard deviation of `used`, ml/kg/min.
    let sigma: Double
    /// Every reading held, for the page that explains the choice.
    let apple: Reading?
    let yoop: Reading?
    /// The reading typed in from the WHOOP app, when there is one (used while it is recent).
    var whoop: Reading? = nil
    /// Whether the Apple Health reading is recent enough to count (`appleMaxAgeDays`), so the page can say whether it
    /// was passed over for a better source or is simply too old.
    var appleIsRecent = false

    var isRough: Bool { source == .uth }
    var low: Double { max(0, used - sigma) }
    var high: Double { used + sigma }

    /// A reading typed in from the WHOOP app goes stale after this (WHOOP re-estimates VO2 max as the wearer trains).
    static let whoopAppMaxAgeDays = 90
    /// Spread of the WHOOP app's reading, ml/kg/min (Yoop's assumption: that of the waist-based estimate).
    static let whoopAppSigma = 5.0
    /// An Apple Health reading older than this does not describe today's fitness.
    static let appleMaxAgeDays = 60
    /// Yoop's own estimate, weekly, goes stale after this.
    static let yoopMaxAgeDays = 90
    /// Apple Watch against a lab test: lab minus watch, mean and standard deviation.
    static let appleMeanDifference = 6.1
    static let appleSigma = 6.2
    static let nesSigmaMen = 5.70
    static let nesSigmaWomen = 5.14
    static let uthSigma = 8.0

    static func choose(whoop: Reading? = nil, apple: Reading?, yoop: Reading?, today: String, sex: String) -> Vo2Choice? {
        let whoopCutoff = WhoopAge.dayKeys(endingOn: today, count: whoopAppMaxAgeDays + 1).first ?? ""
        let appleCutoff = WhoopAge.dayKeys(endingOn: today, count: appleMaxAgeDays + 1).first ?? ""
        let yoopCutoff = WhoopAge.dayKeys(endingOn: today, count: yoopMaxAgeDays + 1).first ?? ""
        let appleRecent = apple.map { $0.day >= appleCutoff && $0.day <= today } ?? false
        if let w = whoop, w.value > 0, w.day >= whoopCutoff, w.day <= today {
            return Vo2Choice(source: .whoopApp, reading: w.value, day: w.day, used: w.value, sigma: whoopAppSigma,
                             apple: apple, yoop: yoop, whoop: whoop, appleIsRecent: appleRecent)
        }
        if let a = apple, appleRecent {
            return Vo2Choice(source: .appleHealth, reading: a.value, day: a.day, used: a.value + appleMeanDifference,
                             sigma: appleSigma, apple: apple, yoop: yoop, whoop: whoop, appleIsRecent: true)
        }
        guard let y = yoop, y.day >= yoopCutoff, y.day <= today else { return nil }
        if y.estimator == "nes" {
            let sigma = sex.lowercased() == "female" ? nesSigmaWomen : nesSigmaMen
            return Vo2Choice(source: .nes, reading: y.value, day: y.day, used: y.value, sigma: sigma,
                             apple: apple, yoop: yoop, whoop: whoop, appleIsRecent: false)
        }
        return Vo2Choice(source: .uth, reading: y.value, day: y.day, used: y.value, sigma: uthSigma,
                         apple: apple, yoop: yoop, whoop: whoop, appleIsRecent: false)
    }
}
