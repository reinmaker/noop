import XCTest
import Foundation
@testable import Strand

/// WHOOP Age: the calibration (WHOOP's own readout for one member and the white paper's Table 2, which the fitted
/// scales of `WhoopAge.scale` are fitted to, so these tests hold the code to what it was fitted to and say nothing
/// of anyone else's WHOOP Age), each curve's shape and limits, Pace of Aging against its definition, the
/// six-month window, the decimal age and the VO2 max source. Every birth date here is made up.
final class WhoopAgeTests: XCTestCase {

    private func male30(sleep: Double, consistency: Double, steps: Double, z13: Double, z45: Double,
                        strength: Double, vo2: Double, rhr: Double, lean: Double?) -> WhoopAge.Inputs {
        WhoopAge.Inputs(age: 30, sex: "male", sleepHours: sleep, sleepConsistency: consistency, steps: steps,
                        zones13PerWeek: z13, zones45PerWeek: z45, strengthPerWeek: strength, vo2max: vo2,
                        restingHr: rhr, leanBodyMassPct: lean)
    }

    // MARK: Calibration

    private func female30(sleep: Double, consistency: Double, steps: Double, z13: Double, z45: Double,
                          strength: Double, vo2: Double, rhr: Double, lean: Double?) -> WhoopAge.Inputs {
        WhoopAge.Inputs(age: 30, sex: "female", sleepHours: sleep, sleepConsistency: consistency, steps: steps,
                        zones13PerWeek: z13, zones45PerWeek: z45, strengthPerWeek: strength, vo2max: vo2,
                        restingHr: rhr, leanBodyMassPct: lean)
    }

    /// The typical 30 year old male WHOOP member (white paper Table 2): about -1.6 years.
    func testTypicalWhoopMemberLandsNearMinus1Point6() {
        let inputs = male30(sleep: 7.0, consistency: 67, steps: 10_900, z13: 141, z45: 6, strength: 46,
                            vo2: 46.8, rhr: 58, lean: 81)
        XCTAssertEqual(WhoopAge.compute(inputs).totalYears, -1.6, accuracy: 0.3)
    }

    /// The typical US 30 year old male (Table 2, "about +6 years"; the US column gives a range for sleep and
    /// consistency, taken at its middle).
    func testTypicalAmericanLandsNearPlus6() {
        let inputs = male30(sleep: 6.35, consistency: 65, steps: 5_200, z13: 69, z45: 0, strength: 0,
                            vo2: 42.4, rhr: 67, lean: 73.9)
        XCTAssertEqual(WhoopAge.compute(inputs).totalYears, 6.0, accuracy: 0.6)
    }

    /// The two female columns of Table 2: members -1.6 years, the typical US adult +7.5.
    func testFemaleTable2Anchors() {
        let member = female30(sleep: 7.3, consistency: 68, steps: 11_500, z13: 124, z45: 7, strength: 56,
                              vo2: 40.0, rhr: 63, lean: 73)
        XCTAssertEqual(WhoopAge.compute(member).totalYears, -1.6, accuracy: 0.3)
        let american = female30(sleep: 6.35, consistency: 65, steps: 5_000, z13: 46, z45: 0, strength: 0,
                                vo2: 30.2, rhr: 72, lean: 62.2)
        XCTAssertEqual(WhoopAge.compute(american).totalYears, 7.5, accuracy: 0.6)
    }

    /// One member's own WHOOP readout, as the app printed it (six-month averages), fed back as
    /// inputs: the total within half a year of what WHOOP printed and every contributor within 0.3 years. The scales
    /// are fitted to this readout, so this is a check that they were applied, not a validation.
    static let readoutInputs = WhoopAge.Inputs(
        age: 43.0, sex: "male", sleepHours: 7 + 13.0 / 60, sleepConsistency: 71, steps: 9_599,
        zones13PerWeek: 180, zones45PerWeek: 20, strengthPerWeek: 90, vo2max: 48, restingHr: 51)

    func testWhoopsOwnReadoutIsReproducedWithinAThirdOfAYearEach() {
        let printed: [WhoopAge.Key: Double] = [
            .sleepDuration: -0.1, .sleepConsistency: -0.2, .steps: -0.3, .zones13: -0.6, .zones45: 0.0,
            .strength: -1.3, .vo2max: -2.8, .restingHr: -1.1, .leanBodyMass: 0.0,
        ]
        let result = WhoopAge.compute(Self.readoutInputs)
        for impact in result.impacts {
            XCTAssertEqual(impact.years, printed[impact.key] ?? .nan, accuracy: 0.3, impact.key.rawValue)
        }
        XCTAssertEqual(result.totalYears, -6.4, accuracy: 0.5)
    }

    /// The fitted scales are the documented ones: sleep and strength carry their fit in the curve (scale 1), and no
    /// contributor is left on one shared factor.
    func testScalesAreTheDocumentedOnes() {
        let expected: [WhoopAge.Key: Double] = [
            .sleepDuration: 1.0, .sleepConsistency: 1.0, .strength: 1.0, .steps: 0.37, .zones13: 0.70,
            .zones45: 0.25, .vo2max: 0.73, .restingHr: 1.43, .leanBodyMass: 0.32,
        ]
        XCTAssertEqual(Set(expected.keys), Set(WhoopAge.Key.allCases))
        for (key, scale) in expected { XCTAssertEqual(WhoopAge.scale(key), scale, accuracy: 1e-12, key.rawValue) }
    }

    /// The readout's resting heart rate is steeper than the cited RR 1.09 per 10 bpm, and the zone 4 to 5 target is
    /// the readout's 20 minutes at every age, not 10 falling to 7.
    func testFittedShapesFollowTheReadout() {
        let perBpm = WhoopAge.restingHrYears(bpm: 61, sex: "male") * WhoopAge.scale(.restingHr)
        XCTAssertEqual(perBpm, 0.12, accuracy: 0.01, "about 0.12 years per bpm")
        XCTAssertEqual(WhoopAge.zones45Target(age: 25), 20, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.zones45Target(age: 80), 20, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.strengthYears(minutesPerWeek: 90), -1.3, accuracy: 0.05)
    }

    /// Both anchors move the right way when one behaviour changes: more steps never add years, fewer never
    /// subtract them.
    func testStepsAreMonotone() {
        var last = Double.infinity
        for steps in stride(from: 0.0, through: 16_000, by: 500) {
            let years = WhoopAge.stepsYears(steps: steps, age: 35)
            XCTAssertLessThanOrEqual(years, last + 1e-9)
            last = years
        }
    }

    // MARK: Curves

    func testContributorsAtTheirTargetAddNothing() {
        let age = 42.0
        XCTAssertEqual(WhoopAge.sleepDurationYears(hours: 7), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.sleepConsistencyYears(percent: 70), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.stepsYears(steps: 8_000, age: age), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.zones13Years(minutesPerWeek: WhoopAge.zones13Target(age: age), age: age), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.zones45Years(minutesPerWeek: WhoopAge.zones45Target(age: age), age: age), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.strengthYears(minutesPerWeek: 40), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxYears(vo2: WhoopAge.vo2maxTarget(age: age, sex: "male"), age: age, sex: "male"), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.restingHrYears(bpm: 60, sex: "male"), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.restingHrYears(bpm: 64, sex: "female"), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.leanBodyMassYears(percent: 80, age: 30, sex: "male"), 0, accuracy: 1e-9)
    }

    /// 7 to 9 hours subtract a little, under 7 add, over 9 do nothing (white paper, "Sleep Duration").
    func testSleepDurationFollowsTheWhitePaper() {
        XCTAssertGreaterThan(WhoopAge.sleepDurationYears(hours: 6), 0)
        XCTAssertGreaterThan(WhoopAge.sleepDurationYears(hours: 5), WhoopAge.sleepDurationYears(hours: 6))
        XCTAssertLessThan(WhoopAge.sleepDurationYears(hours: 8), 0)
        XCTAssertGreaterThan(WhoopAge.sleepDurationYears(hours: 8), -0.5, "a minor reduction, not a large one")
        XCTAssertEqual(WhoopAge.sleepDurationYears(hours: 8), -WhoopAge.sleepBenefitYearsPerHour, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.sleepDurationYears(hours: 9.5), -WhoopAge.sleepBenefitYearsPerHour / 2, accuracy: 1e-9, "tapering between 9 and 10")
        XCTAssertEqual(WhoopAge.sleepDurationYears(hours: 10.5), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.sleepDurationYears(hours: 12), 0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.sleepDurationYears(hours: 6), 10 * log(1.12), accuracy: 1e-9, "HR 1.12 an hour short")
    }

    func testConsistencyBreaksEvenAt70AndIsLimited() {
        XCTAssertGreaterThan(WhoopAge.sleepConsistencyYears(percent: 60), 0)
        XCTAssertLessThan(WhoopAge.sleepConsistencyYears(percent: 80), 0)
        XCTAssertEqual(WhoopAge.sleepConsistencyYears(percent: 0), 4, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.sleepConsistencyYears(percent: 100), -2.5, accuracy: 1e-9)
    }

    /// Paluch et al. 2022: the quartile medians' hazard ratios are read back exactly, and the curve is flat
    /// above the top quartile.
    func testStepsCurveReproducesPaluchQuartiles() {
        XCTAssertEqual(WhoopAge.stepsLnHazard(5_801), log(0.60), accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.stepsLnHazard(7_842), log(0.55), accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.stepsLnHazard(10_901), log(0.47), accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.stepsLnHazard(20_000), log(0.47), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(WhoopAge.stepsLnHazard(0), 0.8 + 1e-9)
    }

    /// An older adult's step target is lower, so the same steps count for more.
    func testOlderAdultsNeedFewerSteps() {
        XCTAssertEqual(WhoopAge.stepsTarget(age: 40), 8_000, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.stepsTarget(age: 80), 5_600, accuracy: 1e-9)
        XCTAssertLessThan(WhoopAge.stepsYears(steps: 6_000, age: 80), WhoopAge.stepsYears(steps: 6_000, age: 40))
        XCTAssertEqual(WhoopAge.stepsYears(steps: 5_600, age: 80), 0, accuracy: 1e-9)
    }

    func testZoneTargetsFallWithAge() {
        XCTAssertEqual(WhoopAge.zones13Target(age: 25), 100, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.zones13Target(age: 80), 70, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.zones45Target(age: 25), 20, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.zones45Target(age: 80), 20, accuracy: 1e-9)
        XCTAssertGreaterThan(WhoopAge.zones13Years(minutesPerWeek: 0, age: 30), 0)
        XCTAssertLessThan(WhoopAge.zones13Years(minutesPerWeek: 300, age: 30), 0)
        XCTAssertEqual(WhoopAge.zones13Years(minutesPerWeek: 600, age: 30), WhoopAge.zones13Years(minutesPerWeek: 900, age: 30),
                       accuracy: 1e-9, "flat above 600 minutes")
        XCTAssertGreaterThan(WhoopAge.zones45Years(minutesPerWeek: 0, age: 30), 0)
        XCTAssertLessThan(WhoopAge.zones45Years(minutesPerWeek: 60, age: 30), 0)
        XCTAssertEqual(WhoopAge.zones45Years(minutesPerWeek: 75, age: 30), WhoopAge.zones45Years(minutesPerWeek: 200, age: 30),
                       accuracy: 1e-9, "flat above 75 minutes")
    }

    /// 40 minutes breaks even, none adds, more than two hours adds no more benefit (white paper), and the curve is the
    /// readout's: 90 minutes is 1.3 years younger.
    func testStrengthBreaksEvenAtFortyAndStopsAtTwoHours() {
        XCTAssertEqual(WhoopAge.strengthYears(minutesPerWeek: 0), 1.04, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.strengthYears(minutesPerWeek: 90), -1.3, accuracy: 1e-9)
        XCTAssertLessThan(WhoopAge.strengthYears(minutesPerWeek: 60), 0)
        XCTAssertEqual(WhoopAge.strengthYears(minutesPerWeek: 120), WhoopAge.strengthYears(minutesPerWeek: 400), accuracy: 1e-9)
        XCTAssertEqual(exp(WhoopAge.strengthLnHazard(120)), 0.73, accuracy: 0.01,
                       "about 27% lower mortality at 2 hours, inside the 10% to 30% the white paper gives")
    }

    /// Kodama et al.: 13% lower mortality per MET, so one MET (3.5 ml/kg/min) over the target is 10 x ln(0.87) years.
    func testVo2maxIsThirteenPercentPerMet() {
        let target = WhoopAge.vo2maxTarget(age: 30, sex: "male")
        XCTAssertEqual(target, 44, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxYears(vo2: target + 3.5, age: 30, sex: "male"), 10 * log(0.87), accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxYears(vo2: target + 100, age: 30, sex: "male"), 4 * 10 * log(0.87), accuracy: 1e-9,
                       "limited to four METs so the estimate is not extrapolated")
    }

    /// Figure 4 read between its printed ages, and for both sexes.
    func testVo2maxTargetTable() {
        XCTAssertEqual(WhoopAge.vo2maxTarget(age: 40, sex: "male"), 40, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxTarget(age: 45, sex: "male"), 37, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxTarget(age: 42, sex: "male"), 38.8, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxTarget(age: 30, sex: "female"), 38, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxTarget(age: 100, sex: "female"), 18, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.vo2maxTarget(age: 30, sex: "nonbinary"), 41, accuracy: 1e-9, "the two sexes' mean")
    }

    /// Zhang et al. 2016: RR 1.09 per 10 bpm.
    func testRestingHeartRateIsNinePercentPerTenBpm() {
        XCTAssertEqual(WhoopAge.restingHrYears(bpm: 70, sex: "male"), 10 * log(1.09), accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.restingHrYears(bpm: 50, sex: "male"), -10 * log(1.09), accuracy: 1e-9)
    }

    // MARK: Compute

    /// A contributor with no value adds nothing and says so, as lean body mass does in WHOOP.
    func testMissingContributorHasNoEffect() {
        let result = WhoopAge.compute(WhoopAge.Inputs(age: 42, sex: "male", steps: 8_000))
        let lean = result.impacts.first { $0.key == .leanBodyMass }
        XCTAssertNil(lean?.value)
        XCTAssertEqual(lean?.years, 0)
        XCTAssertEqual(result.impacts.count, 9)
    }

    /// Whoever carries the most years leads the list, and the years sum to the total.
    func testImpactsAreSortedAndSum() {
        let inputs = male30(sleep: 6, consistency: 50, steps: 3_000, z13: 20, z45: 0, strength: 0, vo2: 35, rhr: 70, lean: nil)
        let result = WhoopAge.compute(inputs)
        XCTAssertEqual(result.impacts.map { abs($0.years) }, result.impacts.map { abs($0.years) }.sorted(by: >))
        XCTAssertEqual(result.totalYears, result.impacts.reduce(0) { $0 + $1.years }, accuracy: 1e-9)
        XCTAssertEqual(result.whoopAge, 30 + result.totalYears, accuracy: 1e-9)
        XCTAssertEqual(result.yearsYounger, -result.totalYears, accuracy: 1e-9)
    }

    /// Each contributor's years are its curve times its own scale, never one factor for all.
    func testEachContributorCarriesItsOwnScale() {
        let result = WhoopAge.compute(male30(sleep: 6, consistency: 50, steps: 3_000, z13: 20, z45: 0, strength: 0,
                                             vo2: 35, rhr: 70, lean: 70))
        for impact in result.impacts {
            let raw = WhoopAge.rawYears(impact.key, result.inputs) ?? 0
            XCTAssertEqual(impact.years, raw * WhoopAge.scale(impact.key), accuracy: 1e-9, impact.key.rawValue)
        }
        XCTAssertGreaterThan(Set(WhoopAge.Key.allCases.map { WhoopAge.scale($0) }).count, 4)
    }

    /// The input's own error is the one that shows: a VO2 max with a wide error carries most of the uncertainty,
    /// and the shares add up to 1.
    func testUncertaintyShareNamesTheWeakInput() {
        var inputs = male30(sleep: 7.5, consistency: 75, steps: 9_000, z13: 150, z45: 12, strength: 50, vo2: 52, rhr: 55, lean: nil)
        inputs.vo2maxSigma = 8
        let result = WhoopAge.compute(inputs)
        XCTAssertGreaterThan(result.uncertaintyShare(.vo2max), 0.9)
        let total = WhoopAge.Key.allCases.reduce(0.0) { $0 + result.uncertaintyShare($1) }
        XCTAssertEqual(total, 1, accuracy: 1e-9)
        let years = WhoopAge.Key.allCases.reduce(0.0) { $0 + result.yearsShare($1) }
        XCTAssertEqual(years, 1, accuracy: 1e-9)
    }

    // MARK: Pace of Aging

    /// Last 30 days read like the six months: 1.0x, steady.
    func testSameBehaviourIsSteady() {
        let inputs = male30(sleep: 7, consistency: 70, steps: 8_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        XCTAssertEqual(WhoopAge.pace(window: inputs, recent: inputs), 1.0, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.paceState(1.0), .steady)
    }

    /// Exactly half a year better (a year of "projected age" gap over the half year) is -1.0x... and the
    /// definition holds in between: the projected age less today's, over the half year.
    func testPaceFollowsItsDefinition() {
        let window = male30(sleep: 7, consistency: 70, steps: 5_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        var recent = window
        recent.steps = 9_000
        let now = WhoopAge.compute(window).totalYears
        let projected = WhoopAge.compute(recent).totalYears
        let expected = 1 + (projected - now) / 0.5
        XCTAssertEqual(WhoopAge.pace(window: window, recent: recent), max(-1, min(3, expected)), accuracy: 1e-9)
        XCTAssertLessThan(WhoopAge.pace(window: window, recent: recent), 1)
    }

    func testPaceIsLimitedToTheScale() {
        let good = male30(sleep: 8, consistency: 95, steps: 12_000, z13: 300, z45: 30, strength: 90, vo2: 60, rhr: 45, lean: nil)
        let bad = male30(sleep: 4, consistency: 20, steps: 1_000, z13: 0, z45: 0, strength: 0, vo2: 25, rhr: 85, lean: nil)
        XCTAssertEqual(WhoopAge.pace(window: bad, recent: good), -1, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.pace(window: good, recent: bad), 3, accuracy: 1e-9)
    }

    /// A contributor the last 30 days did not measure keeps its six-month value, so it cannot move the pace.
    func testUnmeasuredRecentContributorDoesNotMovePace() {
        let window = male30(sleep: 7, consistency: 70, steps: 8_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        var recent = window
        recent.strengthPerWeek = nil
        recent.zones13PerWeek = nil
        XCTAssertEqual(WhoopAge.pace(window: window, recent: recent), 1.0, accuracy: 1e-9)
    }

    func testPaceWords() {
        XCTAssertEqual(WhoopAge.paceState(-0.4), .reversing)
        XCTAssertEqual(WhoopAge.paceState(0.5), .slowing)
        XCTAssertEqual(WhoopAge.paceState(1.05), .steady)
        XCTAssertEqual(WhoopAge.paceState(1.8), .accelerated)
    }

    /// The white paper's definition: when the last 30 days' averages equal the six months', the projected WHOOP Age
    /// is exactly 6 months older than today's and Pace of Aging is exactly 1.0x, whatever the inputs are.
    func testEqualAveragesGiveExactlyOnePointZero() {
        let sets: [WhoopAge.Inputs] = [
            Self.readoutInputs,
            male30(sleep: 5.2, consistency: 40, steps: 2_000, z13: 10, z45: 0, strength: 0, vo2: 28, rhr: 78, lean: 60),
            female30(sleep: 8.4, consistency: 92, steps: 13_000, z13: 450, z45: 60, strength: 130, vo2: 52, rhr: 48, lean: nil),
            WhoopAge.Inputs(age: 43.0, sex: "male", sleepHours: 7, steps: 8_000),
        ]
        for inputs in sets {
            XCTAssertEqual(WhoopAge.pace(window: inputs, recent: inputs), 1.0, accuracy: 1e-12)
            var withAgeError = inputs
            withAgeError.ageSigma = 0.29
            XCTAssertEqual(WhoopAge.pace(window: withAgeError, recent: withAgeError), 1.0, accuracy: 1e-12)
        }
    }

    /// Projected age less current age, over half a year. A last month 0.35 years better than the six months gives
    /// 0.3x, the figure WHOOP printed for the member whose readout this is calibrated on: the projected WHOOP Age
    /// is then 0.15 years under 6 months older than today's. A month 0.5 years worse gives 2.0x.
    func testPaceIsTheProjectedAgeLessTodaysOverHalfAYear() {
        let window = Self.readoutInputs
        let perPoint = WhoopAge.consistencyYearsPerPoint
        var better = window
        better.sleepConsistency = 71 + 0.35 / perPoint
        let now = WhoopAge.compute(window)
        let projected = WhoopAge.compute(better)
        // Projected WHOOP Age six months on, from the last month's averages, less today's.
        let difference = (window.age + 0.5 + projected.totalYears) - (window.age + now.totalYears)
        XCTAssertEqual(difference, 0.15, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.pace(window: window, recent: better), 0.3, accuracy: 1e-9)
        XCTAssertEqual(WhoopAge.pace(window: window, recent: better), difference / 0.5, accuracy: 1e-9)
        var worse = window
        worse.sleepConsistency = 71 - 0.5 / perPoint
        XCTAssertEqual(WhoopAge.pace(window: window, recent: worse), 2.0, accuracy: 1e-9)
    }

    /// The member's own last month against the six months (consistency 76% against 71%, steps and zones alike,
    /// zones 4 to 5 lower, resting heart rate 50 against 51): Yoop reads it as its definition gives, a quicker slowing than
    /// the 0.3x WHOOP printed. WHOOP's figure needs the other markers to have been worse by about 0.9 years; the
    /// 30-day values for those are not in the readout, so the difference is reported and not tuned away.
    func testPaceForTheMembersLastMonthFollowsTheDefinition() {
        var recent = Self.readoutInputs
        recent.sleepConsistency = 76
        recent.zones45PerWeek = 10
        recent.restingHr = 50
        let now = WhoopAge.compute(Self.readoutInputs).totalYears
        let projected = WhoopAge.compute(recent).totalYears
        let pace = WhoopAge.pace(window: Self.readoutInputs, recent: recent)
        XCTAssertEqual(pace, 1 + (projected - now) / 0.5, accuracy: 1e-9)
        XCTAssertLessThan(pace, 0.3)
        XCTAssertEqual(WhoopAge.paceState(pace), .reversing)
    }

    // MARK: Levers

    func testLeversNameWhatToDoInTheUnitsOfTheContributor() {
        let inputs = male30(sleep: 6, consistency: 60, steps: 5_000, z13: 40, z45: 2, strength: 0, vo2: 38, rhr: 66, lean: nil)
        let levers = WhoopAge.levers(WhoopAge.compute(inputs))
        let steps = levers.first { $0.key == .steps }
        XCTAssertEqual(steps?.amount ?? 0, 3_000, accuracy: 1e-9)
        let strength = levers.first { $0.key == .strength }
        XCTAssertEqual(strength?.amount ?? 0, 40, accuracy: 1e-9)
        let hr = levers.first { $0.key == .restingHr }
        XCTAssertEqual(hr?.amount ?? 0, 6, accuracy: 1e-9, "bpm lower")
        XCTAssertNil(levers.first { $0.key == .leanBodyMass })
        // The behaviours come before the fitness figures that follow from them.
        let behaviours: Set<WhoopAge.Key> = [.sleepDuration, .sleepConsistency, .steps, .zones13, .zones45, .strength]
        let firstFitness = levers.firstIndex { !behaviours.contains($0.key) } ?? levers.count
        XCTAssertTrue(levers[..<firstFitness].allSatisfy { behaviours.contains($0.key) })
    }

    /// A contributor past its target gets no gap-closing lever, only a stretch while the curve still pays.
    func testStretchLeversStartWhereTheTargetsAreMet() {
        let inputs = male30(sleep: 7.5, consistency: 80, steps: 9_000, z13: 200, z45: 25, strength: 60, vo2: 55, rhr: 50, lean: nil)
        let levers = WhoopAge.levers(WhoopAge.compute(inputs))
        XCTAssertFalse(levers.isEmpty)
        XCTAssertTrue(levers.allSatisfy { $0.isStretch })
        let steps = levers.first { $0.key == .steps }
        XCTAssertEqual(steps?.amount ?? 0, 1_000, accuracy: 1e-9, "from 9,000 to the 10,000 where the curve flattens")
        XCTAssertGreaterThan(steps?.yearsGained ?? 0, 0.15)
        XCTAssertNil(levers.first { $0.key == .strength })
    }

    /// Everything at the top of its curve: nothing left to do.
    func testNoLeversWhenEverythingIsAtTheTop() {
        let inputs = male30(sleep: 8, consistency: 90, steps: 12_000, z13: 400, z45: 60, strength: 60, vo2: 55, rhr: 50, lean: nil)
        XCTAssertTrue(WhoopAge.levers(WhoopAge.compute(inputs)).isEmpty)
    }

    /// Gaps to targets come before stretches.
    func testGapsComeBeforeStretches() {
        let inputs = male30(sleep: 7.5, consistency: 80, steps: 5_000, z13: 200, z45: 25, strength: 60, vo2: 55, rhr: 50, lean: nil)
        let levers = WhoopAge.levers(WhoopAge.compute(inputs))
        XCTAssertEqual(levers.first?.key, .steps)
        XCTAssertEqual(levers.first?.isStretch, false)
        XCTAssertTrue(levers.dropFirst().allSatisfy { $0.isStretch })
    }

    // MARK: Window

    private func day(_ key: String, sleep: Double? = 450, consistency: Double? = 70, rhr: Double? = 55,
                     recovery: Bool = true, steps: Double? = 8_000, z13: Double = 0, z45: Double = 0,
                     strength: Double = 0) -> WhoopAge.Day {
        var d = WhoopAge.Day(day: key)
        d.sleepMin = sleep; d.consistency = consistency; d.restingHr = rhr; d.hasRecovery = recovery
        d.steps = steps; d.zones13Min = z13; d.zones45Min = z45; d.strengthMin = strength
        return d
    }

    func testDayKeysAreCalendarDays() {
        XCTAssertEqual(WhoopAge.dayKeys(endingOn: "2026-03-02", count: 3), ["2026-02-28", "2026-03-01", "2026-03-02"])
        XCTAssertEqual(WhoopAge.dayKeys(endingOn: "2026-10-12", count: 1), ["2026-10-12"])
        XCTAssertEqual(WhoopAge.dayKeys(endingOn: "2026-10-12", count: 182).count, 182)
    }

    /// Means over the days that have a figure; a nap and a day nobody carried a phone are left out.
    func testWindowMeansSkipNapsAndEmptyStepDays() {
        let days = [day("2026-10-10", sleep: 480, steps: 10_000), day("2026-10-11", sleep: 60, steps: 300),
                    day("2026-10-12", sleep: 420, steps: 6_000)]
        let inputs = WhoopAge.inputs(days: days, endingOn: "2026-10-12", span: 30, age: 42, sex: "male", vo2: nil)
        XCTAssertEqual(inputs.sleepHours ?? 0, 7.5, accuracy: 1e-9, "(8 h + 7 h) / 2, the 1 h nap left out")
        XCTAssertEqual(inputs.steps ?? 0, 8_000, accuracy: 1e-9, "(10,000 + 6,000) / 2, the 300 step day left out")
    }

    /// Weekly minutes are per week of strap days: half the window covered by the strap is not half the minutes.
    func testWeeklyMinutesDivideByStrapWeeks() {
        var days: [WhoopAge.Day] = []
        for (i, key) in WhoopAge.dayKeys(endingOn: "2026-10-12", count: 28).enumerated() {
            days.append(day(key, z13: i % 7 == 0 ? 70 : 0, z45: i % 7 == 0 ? 7 : 0, strength: i % 7 == 3 ? 40 : 0))
        }
        let inputs = WhoopAge.inputs(days: days, endingOn: "2026-10-12", span: 28, age: 42, sex: "male", vo2: nil)
        XCTAssertEqual(inputs.zones13PerWeek ?? 0, 70, accuracy: 1e-9)
        XCTAssertEqual(inputs.zones45PerWeek ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(inputs.strengthPerWeek ?? 0, 40, accuracy: 1e-9)
        // A phone-only day (no strap) does not widen the denominator.
        var withPhone = days
        withPhone.append(day("2026-09-01", sleep: nil, consistency: nil, rhr: nil, recovery: false, steps: 5_000))
        let longer = WhoopAge.inputs(days: withPhone, endingOn: "2026-10-12", span: 60, age: 42, sex: "male", vo2: nil)
        XCTAssertEqual(longer.zones13PerWeek ?? 0, 70, accuracy: 1e-9)
    }

    /// Fewer than 14 strap days: no weekly figure rather than a figure from two days of activity.
    func testShortWindowStatesNoWeeklyFigure() {
        let days = WhoopAge.dayKeys(endingOn: "2026-10-12", count: 10).map { day($0, z13: 30) }
        let inputs = WhoopAge.inputs(days: days, endingOn: "2026-10-12", span: 30, age: 42, sex: "male", vo2: nil)
        XCTAssertNil(inputs.zones13PerWeek)
        XCTAssertNil(inputs.strengthPerWeek)
        XCTAssertNotNil(inputs.sleepHours)
    }

    /// WHOOP unlocks Healthspan at 21 recoveries in the last 31 days.
    func testUnlockNeeds21RecoveriesIn31Days() {
        func coverage(recoveries: Int) -> WhoopAge.Coverage {
            let keys = WhoopAge.dayKeys(endingOn: "2026-10-12", count: 31)
            let days = keys.enumerated().map { i, k in day(k, recovery: i < recoveries) }
            return WhoopAge.coverage(days: days, endingOn: "2026-10-12")
        }
        XCTAssertFalse(coverage(recoveries: 20).isUnlocked)
        XCTAssertTrue(coverage(recoveries: 21).isUnlocked)
        XCTAssertEqual(coverage(recoveries: 25).recoveriesInLast31Days, 25)
        XCTAssertFalse(WhoopAge.isUnlocked(recoveriesInLast31Days: 0))
    }

    // MARK: Activities

    func testStrengthSportsFollowTheWhitePaperList() {
        for sport in ["Weightlifting", "Powerlifting", "Yoga", "Hot Yoga", "Pilates", "Barre3", "Functional Fitness",
                      "HIIT", "Rucking", "Box Fitness", "Strength Trainer", "TraditionalStrengthTraining", "F45 Training",
                      "Barry's", "Solidcore", "Baby Wearing"] {
            XCTAssertTrue(WhoopAge.isStrengthSport(sport), sport)
        }
        for sport in ["Running", "Tennis", "Walking", "Basketball", "Dedicated Parenting", "Swimming", "Activity"] {
            XCTAssertFalse(WhoopAge.isStrengthSport(sport), sport)
        }
    }

    func testZoneMinutesFromImportedPercentsOrBands() {
        let imported = WhoopAge.zoneMinutes(durationS: 3_600, importedPercents: [10, 20, 30, 25, 5], bandSeconds: nil)
        XCTAssertEqual(imported?.z13 ?? 0, 36, accuracy: 1e-9)
        XCTAssertEqual(imported?.z45 ?? 0, 18, accuracy: 1e-9)
        let bands = WhoopAge.zoneMinutes(durationS: 3_600, importedPercents: nil, bandSeconds: [600, 600, 600, 600, 600, 600])
        XCTAssertEqual(bands?.z13 ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(bands?.z45 ?? 0, 20, accuracy: 1e-9)
        XCTAssertNil(WhoopAge.zoneMinutes(durationS: 3_600, importedPercents: nil, bandSeconds: nil))
        XCTAssertEqual(WhoopAge.zoneMinutes(durationS: 3_600, importedPercents: [10, 20, 30, 25, 5],
                                            bandSeconds: [3_600, 0, 0, 0, 0, 0])?.z13 ?? 0, 36, accuracy: 1e-9,
                       "WHOOP's own split wins over an on-device one")
    }

    // MARK: VO2 max

    private func apple(_ value: Double, _ day: String) -> Vo2Choice.Reading { .init(value: value, day: day, estimator: nil) }
    private func yoop(_ value: Double, _ day: String, _ estimator: String?) -> Vo2Choice.Reading {
        .init(value: value, day: day, estimator: estimator)
    }

    /// A recent Apple Health reading comes first, adjusted by the mean difference to a lab test (Lambe 2025), as
    /// a range, and the rough Uth figure beside it is not what is used.
    func testRecentAppleReadingIsUsedAsARangeAndUthIsNot() {
        let choice = Vo2Choice.choose(apple: apple(38.26, "2026-10-05"), yoop: yoop(54.1, "2026-10-10", "uth"),
                                      today: "2026-10-12", sex: "male")
        XCTAssertEqual(choice?.source, .appleHealth)
        XCTAssertEqual(choice?.reading ?? 0, 38.26, accuracy: 1e-9)
        XCTAssertEqual(choice?.used ?? 0, 38.26 + 6.1, accuracy: 1e-9)
        XCTAssertEqual(choice?.sigma ?? 0, 6.2, accuracy: 1e-9)
        XCTAssertEqual(choice?.low ?? 0, 38.26 + 6.1 - 6.2, accuracy: 1e-9)
        XCTAssertEqual(choice?.high ?? 0, 38.26 + 6.1 + 6.2, accuracy: 1e-9)
        XCTAssertEqual(choice?.isRough, false)
        XCTAssertEqual(choice?.yoop?.value, 54.1, "the Yoop figure is still held, for the page that explains the choice")
    }

    /// Apple Health's reading counts for 60 days: the 60th still, the 61st not.
    func testAppleReadingStopsCountingAfterSixtyDays() {
        let sixty = WhoopAge.dayKeys(endingOn: "2026-10-12", count: 61).first!
        let sixtyOne = WhoopAge.dayKeys(endingOn: "2026-10-12", count: 62).first!
        XCTAssertEqual(Vo2Choice.choose(apple: apple(40, sixty), yoop: nil, today: "2026-10-12", sex: "male")?.source, .appleHealth)
        XCTAssertNil(Vo2Choice.choose(apple: apple(40, sixtyOne), yoop: nil, today: "2026-10-12", sex: "male"))
        XCTAssertEqual(Vo2Choice.choose(apple: apple(40, sixtyOne), yoop: yoop(50, "2026-10-10", "nes"),
                                        today: "2026-10-12", sex: "male")?.source, .nes)
    }

    /// Without a recent measured reading the waist-based estimate comes next, with its published error and no
    /// adjustment; the heart-rate ratio is last, marked rough and given a wide band.
    func testNesThenUth() {
        let nes = Vo2Choice.choose(apple: nil, yoop: yoop(47, "2026-10-10", "nes"), today: "2026-10-12", sex: "male")
        XCTAssertEqual(nes?.source, .nes)
        XCTAssertEqual(nes?.used, 47)
        XCTAssertEqual(nes?.sigma, 5.70)
        XCTAssertEqual(Vo2Choice.choose(apple: nil, yoop: yoop(40, "2026-10-10", "nes"), today: "2026-10-12", sex: "female")?.sigma, 5.14)
        let uth = Vo2Choice.choose(apple: nil, yoop: yoop(54, "2026-10-10", "uth"), today: "2026-10-12", sex: "male")
        XCTAssertEqual(uth?.source, .uth)
        XCTAssertEqual(uth?.isRough, true)
        XCTAssertEqual(uth?.sigma, 8)
        XCTAssertEqual(uth?.used, 54)
        let unknown = Vo2Choice.choose(apple: nil, yoop: yoop(54, "2026-10-10", nil), today: "2026-10-12", sex: "male")
        XCTAssertEqual(unknown?.source, .uth, "a legacy point with no estimator is treated as the rough one")
    }

    func testNoReadingIsNoChoice() {
        XCTAssertNil(Vo2Choice.choose(apple: nil, yoop: nil, today: "2026-10-12", sex: "male"))
        XCTAssertNil(Vo2Choice.choose(apple: nil, yoop: yoop(50, "2026-05-01", "uth"), today: "2026-10-12", sex: "male"),
                     "a Yoop estimate older than 90 days is stale")
        XCTAssertNil(Vo2Choice.choose(apple: apple(40, "2026-10-20"), yoop: nil, today: "2026-10-12", sex: "male"),
                    "a reading dated after today is not a reading")
    }

    private func whoop(_ value: Double, _ day: String) -> Vo2Choice.Reading { .init(value: value, day: day, estimator: nil) }

    /// A VO2 max typed in from the WHOOP app comes before the Apple adjustment, Nes and Uth, is used as it stands, and
    /// carries a spread of 5 either way, like the waist-based estimate.
    func testWhoopAppReadingComesFirstAsARange() {
        let choice = Vo2Choice.choose(whoop: whoop(48, "2026-10-12"), apple: apple(38.26, "2026-10-05"),
                                      yoop: yoop(47, "2026-10-10", "nes"), today: "2026-10-12", sex: "male")
        XCTAssertEqual(choice?.source, .whoopApp)
        XCTAssertEqual(choice?.used, 48)
        XCTAssertEqual(choice?.reading, 48)
        XCTAssertEqual(choice?.sigma, 5)
        XCTAssertEqual(choice?.low, 43)
        XCTAssertEqual(choice?.high, 53)
        XCTAssertEqual(choice?.isRough, false)
        XCTAssertEqual(choice?.apple?.value, 38.26, "the other readings are still held, for the page that explains the choice")
        XCTAssertEqual(choice?.whoop?.value, 48)
        XCTAssertEqual(choice?.appleIsRecent, true, "the Apple reading is passed over, not too old")
        XCTAssertEqual(Vo2Choice.choose(whoop: whoop(48, "2026-10-12"), apple: apple(40, "2026-05-01"), yoop: nil,
                                        today: "2026-10-12", sex: "male")?.appleIsRecent, false)
        XCTAssertEqual(choice?.sigma ?? 0, Vo2Choice.nesSigmaMen, accuracy: 1.0, "about the spread of the waist-based estimate")
    }

    /// The typed reading counts for 90 days, then the next source takes over; one dated after today is not a reading.
    func testWhoopAppReadingGoesStaleAfterNinetyDays() {
        let ninety = WhoopAge.dayKeys(endingOn: "2026-10-12", count: 91).first!
        let ninetyOne = WhoopAge.dayKeys(endingOn: "2026-10-12", count: 92).first!
        XCTAssertEqual(Vo2Choice.choose(whoop: whoop(48, ninety), apple: apple(40, "2026-10-05"), yoop: nil,
                                        today: "2026-10-12", sex: "male")?.source, .whoopApp)
        let stale = Vo2Choice.choose(whoop: whoop(48, ninetyOne), apple: apple(40, "2026-10-05"), yoop: nil,
                                     today: "2026-10-12", sex: "male")
        XCTAssertEqual(stale?.source, .appleHealth)
        XCTAssertEqual(stale?.whoop?.value, 48, "still held, so the page can say why it is not used")
        XCTAssertNil(Vo2Choice.choose(whoop: whoop(48, ninetyOne), apple: nil, yoop: nil, today: "2026-10-12", sex: "male"))
        XCTAssertNil(Vo2Choice.choose(whoop: whoop(48, "2026-10-20"), apple: nil, yoop: nil, today: "2026-10-12", sex: "male"))
        XCTAssertNil(Vo2Choice.choose(whoop: whoop(0, "2026-10-12"), apple: nil, yoop: nil, today: "2026-10-12", sex: "male"))
    }

    /// WHOOP Age reads the choice: the same member's inputs with the reading typed in come out younger by exactly the
    /// VO2 max contributor's difference, and the Coach is told which reading it was.
    func testWhoopAgeAndCoachReadTheTypedReading() {
        let typed = Vo2Choice.choose(whoop: whoop(48, "2026-10-12"), apple: apple(38.26, "2026-10-05"), yoop: nil,
                                     today: "2026-10-12", sex: "male")
        let adjusted = Vo2Choice.choose(apple: apple(38.26, "2026-10-05"), yoop: nil, today: "2026-10-12", sex: "male")
        func years(_ choice: Vo2Choice?) -> Double {
            var inputs = Self.readoutInputs
            inputs.vo2max = choice?.used
            inputs.vo2maxSigma = choice?.sigma
            return WhoopAge.compute(inputs).totalYears
        }
        XCTAssertLessThan(years(typed), years(adjusted))
        let coverage = WhoopAge.Coverage(windowDays: 182, strapDays: 120, stepDays: 170, recoveriesInLast31Days: 29)
        var inputs = Self.readoutInputs
        inputs.vo2max = typed?.used
        inputs.vo2maxSigma = typed?.sigma
        let snapshot = WhoopAgeSnapshot(day: "2026-10-12", coverage: coverage, vo2: typed, result: WhoopAge.compute(inputs),
                                        recent: inputs, pace: 1.0)
        let text = snapshot.coachLines.joined(separator: " ")
        XCTAssertTrue(text.contains("VO2 max used: 48 ml/kg/min, a range of 43 to 53"), text)
        XCTAssertTrue(text.contains("typed in from the WHOOP app"), text)
        XCTAssertFalse(text.contains("Apple Health"), text)
    }

    /// The typed reading is read back from the defaults only when it is sane and dated; nothing in the code writes one.
    func testStoredWhoopAppReadingNeedsAValueInRangeAndADate() {
        let suite = "WhoopAgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(ProfileStore.storedWhoopAppVo2(defaults: defaults), "nothing is seeded")
        defaults.set(48.0, forKey: "profile.vo2maxWhoopApp")
        XCTAssertNil(ProfileStore.storedWhoopAppVo2(defaults: defaults), "a value without a day is not a reading")
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(day, forKey: "profile.vo2maxWhoopAppDate")
        XCTAssertEqual(ProfileStore.storedWhoopAppVo2(defaults: defaults)?.value, 48)
        XCTAssertEqual(ProfileStore.storedWhoopAppVo2(defaults: defaults)?.date, day)
        for bad in [0.0, 5.0, 14.9, 90.5, 400.0, .nan] {
            defaults.set(bad, forKey: "profile.vo2maxWhoopApp")
            XCTAssertNil(ProfileStore.storedWhoopAppVo2(defaults: defaults), "\(bad)")
        }
    }

    /// The range's ends carry different years, and the result states both: the younger end for the higher VO2 max.
    func testVo2YearsRangeSpansTheBand() {
        var inputs = male30(sleep: 7, consistency: 70, steps: 8_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        inputs.vo2maxSigma = 6
        let range = WhoopAge.compute(inputs).vo2YearsRange
        XCTAssertNotNil(range)
        XCTAssertGreaterThan(range?.older ?? 0, 0)
        XCTAssertLessThan(range?.younger ?? 0, 0)
        XCTAssertEqual(range?.older ?? 0, 10 * log(0.87) * -6 / 3.5 * WhoopAge.scale(.vo2max), accuracy: 1e-9)
        XCTAssertNil(WhoopAge.compute(male30(sleep: 7, consistency: 70, steps: 8_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)).vo2YearsRange)
    }

    /// The same inputs, a rough source: the band on the years is as wide as the source's, and VO2 max carries the
    /// error.
    func testRoughVo2WidensTheWholeBand() {
        let base = male30(sleep: 7, consistency: 70, steps: 8_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        var rough = base
        rough.vo2maxSigma = 8
        var measured = base
        measured.vo2maxSigma = 4
        XCTAssertGreaterThan(WhoopAge.compute(rough).sigma, WhoopAge.compute(measured).sigma)
        XCTAssertGreaterThan(WhoopAge.compute(rough).uncertaintyShare(.vo2max), 0.9)
    }

    // MARK: Decimal age

    private func at(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    /// With a birth date the age is whole years plus the fraction of the year since the last birthday.
    func testDecimalAgeFromAnEnteredBirthDate() {
        let dob = at(1990, 6, 15)
        XCTAssertEqual(ProfileStore.decimalAge(dateOfBirth: dob, isEntered: true, now: at(2026, 6, 15)), 36.0, accuracy: 1e-9)
        XCTAssertEqual(ProfileStore.decimalAge(dateOfBirth: dob, isEntered: true, now: at(2026, 12, 15)), 36.5, accuracy: 0.01)
        XCTAssertEqual(ProfileStore.decimalAge(dateOfBirth: dob, isEntered: true, now: at(2026, 6, 14)), 36.0 - 1.0 / 365, accuracy: 0.01)
        // The age steps by a year at the birthday and moves smoothly between.
        let before = ProfileStore.decimalAge(dateOfBirth: dob, isEntered: true, now: at(2026, 6, 14))
        let after = ProfileStore.decimalAge(dateOfBirth: dob, isEntered: true, now: at(2026, 6, 16))
        XCTAssertEqual(after - before, 2.0 / 365, accuracy: 0.002)
    }

    /// Without one the age is the whole number of years plus half a year, and says its error: a uniform fraction of
    /// a year is 0.29 years either way.
    func testDecimalAgeWithoutABirthDateAssumesHalfAYear() {
        let stand = ProfileStore.dateOfBirth(forAge: 36)
        XCTAssertEqual(ProfileStore.decimalAge(dateOfBirth: stand, isEntered: false, now: Date()), 36.5, accuracy: 1e-9)
        XCTAssertEqual(ProfileStore.unknownBirthdayFraction, 0.5)
        XCTAssertEqual(ProfileStore.unknownBirthdayFractionSigma, 0.2887, accuracy: 1e-4)
    }

    /// The Coach reads the age from the defaults: a birth date entered is exact; one a restore wrote over (stored date
    /// not the entered one), or only an Int age, is the stand-in; nothing is no age.
    func testStoredAgeKnowsWhetherTheBirthDateWasEntered() {
        let suite = "WhoopAgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(ProfileStore.storedAge(defaults: defaults))
        defaults.set(36, forKey: "profile.age")
        let legacy = ProfileStore.storedAge(defaults: defaults, now: at(2026, 12, 15))
        XCTAssertEqual(legacy?.years ?? 0, 36.5, accuracy: 1e-9)
        XCTAssertEqual(legacy?.isExact, false)
        let dob = at(1990, 6, 15)
        defaults.set(dob, forKey: "profile.dateOfBirth")
        defaults.set(dob, forKey: "profile.dateOfBirthEntered")
        let exact = ProfileStore.storedAge(defaults: defaults, now: at(2026, 12, 15))
        XCTAssertEqual(exact?.isExact, true)
        XCTAssertEqual(exact?.years ?? 0, 36.5, accuracy: 0.01)
        // A backup restore rewrites the birth date from an Int age; the entered date no longer matches.
        defaults.set(at(1984, 12, 15), forKey: "profile.dateOfBirth")
        XCTAssertEqual(ProfileStore.storedAge(defaults: defaults, now: at(2026, 12, 15))?.isExact, false)
    }

    /// WHOOP Age states the doubt in the age as well as in the years, and only when the age is a guess.
    func testAgeErrorWidensTheLikelyRangeOfWhoopAge() {
        var inputs = Self.readoutInputs
        let exact = WhoopAge.compute(inputs)
        XCTAssertEqual(exact.whoopAgeSigma, exact.sigma, accuracy: 1e-12)
        inputs.ageSigma = ProfileStore.unknownBirthdayFractionSigma
        let guessed = WhoopAge.compute(inputs)
        XCTAssertEqual(guessed.totalYears, exact.totalYears, accuracy: 1e-12, "the age does not move the years")
        XCTAssertEqual(guessed.sigma, exact.sigma, accuracy: 1e-12)
        XCTAssertGreaterThan(guessed.whoopAgeSigma, exact.whoopAgeSigma)
        XCTAssertEqual(guessed.whoopAgeSigma, (exact.sigma * exact.sigma + 0.2887 * 0.2887).squareRoot(), accuracy: 1e-3)
    }

    /// A decimal age moves the age-dependent targets smoothly: 0.1 years older is not a different person.
    func testDecimalAgeMovesTargetsSmoothly() {
        let a = WhoopAge.compute(WhoopAge.Inputs(age: 40.8, sex: "male", vo2max: 48)).totalYears
        let b = WhoopAge.compute(WhoopAge.Inputs(age: 40.9, sex: "male", vo2max: 48)).totalYears
        XCTAssertEqual(a, b, accuracy: 0.05)
        XCTAssertNotEqual(a, b)
    }

    // MARK: Snapshot and Coach

    func testCoachLinesCarryTheSameFigureAsTheScreen() {
        let inputs = male30(sleep: 7, consistency: 70, steps: 5_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        let result = WhoopAge.compute(inputs)
        let coverage = WhoopAge.Coverage(windowDays: 182, strapDays: 120, stepDays: 170, recoveriesInLast31Days: 29)
        let snapshot = WhoopAgeSnapshot(day: "2026-10-12", coverage: coverage, vo2: nil, result: result, recent: inputs, pace: 1.0)
        let text = snapshot.coachLines.joined(separator: " ")
        XCTAssertTrue(text.contains(String(format: "WHOOP Age %.1f", result.whoopAge)), text)
        XCTAssertTrue(text.contains("Pace of Aging 1.0x (steady)"), text)
        XCTAssertTrue(text.contains("more steps a day"), text)
        XCTAssertTrue(text.contains("120 of the last 182 days"), text)
        XCTAssertTrue(text.contains("calendar age of 30.0"), text)
        XCTAssertFalse(text.contains("birth date not entered"), text)
    }

    /// With no birth date entered the Coach says the age is a stand-in and quotes the wider range.
    func testCoachLinesSayWhenTheBirthDateIsNotEntered() {
        var inputs = male30(sleep: 7, consistency: 70, steps: 5_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        inputs.age = 36.5
        inputs.ageSigma = ProfileStore.unknownBirthdayFractionSigma
        let result = WhoopAge.compute(inputs)
        let coverage = WhoopAge.Coverage(windowDays: 182, strapDays: 120, stepDays: 170, recoveriesInLast31Days: 29)
        let snapshot = WhoopAgeSnapshot(day: "2026-10-12", coverage: coverage, vo2: nil, result: result, recent: inputs, pace: 1.0)
        let text = snapshot.coachLines.joined(separator: " ")
        XCTAssertTrue(text.contains("calendar age of 36.5"), text)
        XCTAssertTrue(text.contains("birth date not entered"), text)
        XCTAssertTrue(text.contains(String(format: "+/- %.1f years", result.whoopAgeSigma)), text)
    }

    /// The Coach is told which VO2 max was used, as a range, so it never quotes another for it.
    func testCoachLinesNameTheVo2MaxUsed() {
        let inputs = male30(sleep: 7, consistency: 70, steps: 5_000, z13: 100, z45: 10, strength: 40, vo2: 44, rhr: 60, lean: nil)
        let choice = Vo2Choice.choose(apple: apple(38.26, "2026-10-05"), yoop: yoop(54.1, "2026-10-10", "uth"),
                                      today: "2026-10-12", sex: "male")
        let coverage = WhoopAge.Coverage(windowDays: 182, strapDays: 120, stepDays: 170, recoveriesInLast31Days: 29)
        let snapshot = WhoopAgeSnapshot(day: "2026-10-12", coverage: coverage, vo2: choice, result: WhoopAge.compute(inputs),
                                        recent: inputs, pace: 1.0)
        let text = snapshot.coachLines.joined(separator: " ")
        XCTAssertTrue(text.contains("VO2 max used: 44 ml/kg/min, a range of 38 to 51"), text)
        XCTAssertTrue(text.contains("Apple Health's reading of 38"), text)
        XCTAssertFalse(text.contains("54"), text)
    }

    func testCalibratingSnapshotHasNoCoachLines() {
        let coverage = WhoopAge.Coverage(windowDays: 182, strapDays: 10, stepDays: 170, recoveriesInLast31Days: 9)
        let snapshot = WhoopAgeSnapshot(day: "2026-10-12", coverage: coverage, vo2: nil, result: nil, recent: nil, pace: nil)
        XCTAssertFalse(snapshot.isUnlocked)
        XCTAssertTrue(snapshot.coachLines.isEmpty)
        XCTAssertTrue(snapshot.levers.isEmpty)
    }
}
