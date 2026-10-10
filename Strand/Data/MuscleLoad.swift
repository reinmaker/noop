import Foundation
import StrandAnalytics
import WhoopStore

// Yoop: the muscular load of a strength session, from the user's rating of how hard it was. Strain is
// scored from heart rate alone, and heart rate underrates resistance training because the muscle work
// barely shows in the pulse: a 45 minute weightlifting session on 2026-10-10 scored 11.0. A rated strength
// session adds the load its rating implies beyond what heart rate measured, to its own Strain and to its
// day's. Pure, so tests pin every step without a store; `Repository` owns the ratings and the one
// `StrainBook` every Strain readout resolves through.

/// The method, on published sources rather than on any vendor's numbers:
///
/// 1. Session RPE (Foster et al. 2001, "A new approach to monitoring exercise training", J Strength Cond
///    Res 15(1):109-115): the athlete rates the whole session on Borg's CR-10 (0 to 10) about 30 minutes
///    after it, and the session's load is rating x minutes. Validated for resistance training by Day et
///    al. 2004 (J Strength Cond Res 18(2):353-358) and Sweet et al. 2004 (J Strength Cond Res
///    18(4):796-802). Yoop cannot see sets or weights, so the one rating is the input.
/// 2. The rating is placed on the SAME curve heart-rate Strain uses (`StrainScorer.whoopMinuteLoad`), so
///    heart and muscle load share one unit. CR-10 maps to a fraction of heart-rate reserve through the
///    ACSM intensity classes (Garber et al. 2011, ACSM position stand, Med Sci Sports Exerc
///    43(7):1334-1359, Table 2: light 30-39 % HRR, moderate 40-59 %, vigorous 60-89 %, near maximal 90 %
///    and up), and a session's rated load L_rpe is its minutes x the load of one minute at that fraction.
/// 3. The heart load L_hr of a session is the load behind its stored Strain (`StrainScorer.whoopInverseLoad`),
///    so it is exactly the figure its page shows.
/// 4. Personal calibration k: on a rated session that is not strength, heart rate sees the whole effort,
///    so L_hr / L_rpe says how this user's ratings map to their heart load (`calibration`).
/// 5. A rated strength session's muscle load is max(0, k x L_rpe - L_hr). An unrated one gets none.
enum MuscleLoad {

    // MARK: Rating to load

    /// CR-10 rating to fraction of heart-rate reserve, joined by straight lines: 2 is ACSM's light class,
    /// 4 moderate, 6 and 8 vigorous and 10 near maximal.
    static let reserveAnchors: [(effort: Double, reserve: Double)] = [
        (0, 0), (2, 0.35), (4, 0.50), (6, 0.70), (8, 0.85), (10, 0.95),
    ]

    /// The fraction of heart-rate reserve a rating stands for; a rating off the scale reads as its end.
    static func reserveFraction(effort: Double) -> Double {
        let e = min(10, max(0, effort))
        for (lo, hi) in zip(reserveAnchors, reserveAnchors.dropFirst()) where e <= hi.effort {
            return lo.reserve + (hi.reserve - lo.reserve) * (e - lo.effort) / (hi.effort - lo.effort)
        }
        return reserveAnchors[reserveAnchors.count - 1].reserve
    }

    /// L_rpe: the load of a session rated `effort` that lasted `minutes`, each minute at the rating's share
    /// of the reserve on Strain's own curve, sitting floor included. Foster's rating x minutes, with the
    /// rating turned into the unit heart-rate load is counted in.
    static func ratedLoad(effort: Int, minutes: Double) -> Double {
        guard minutes > 0 else { return 0 }
        return minutes * StrainScorer.whoopMinuteLoad(reserve: reserveFraction(effort: Double(effort)))
    }

    /// L_hr: the load behind a Strain as stored (NOOP's 0-100 axis), zero for none.
    static func heartLoad(storedStrain: Double?) -> Double {
        guard let stored = storedStrain, stored > 0 else { return 0 }
        return StrainScorer.whoopInverseLoad(strain: UnitFormatter.effortValue(stored, scale: .whoop))
    }

    /// A load as Strain on the stored 0-100 axis, capped at 21 on WHOOP's.
    static func storedStrain(load: Double) -> Double {
        StrainScorer.effortValue(fromWhoopStrain: StrainScorer.whoopStrain(load: load))
    }

    /// An activity's length in minutes, as its page shows it.
    static func minutes(_ row: WorkoutRow) -> Double {
        (row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60
    }

    // MARK: Personal calibration

    /// How far back the calibration reads rated activities.
    static let calibrationWindowDays = 90
    /// Rated activities that are not strength the calibration needs before it moves from 1.
    static let calibrationMinimum = 3
    /// The calibration never scales a rating's load below half or above double.
    static let calibrationRange = 0.5...2.0

    /// k: the median of L_hr / L_rpe over the rated activities that are not strength, clamped to
    /// `calibrationRange`, once there are `calibrationMinimum` of them; 1 before that.
    static func calibration(ratios: [Double]) -> Double {
        let usable = ratios.filter { $0.isFinite && $0 > 0 }
        guard usable.count >= calibrationMinimum, let median = WhoopActivityZones.median(usable) else { return 1 }
        return min(calibrationRange.upperBound, max(calibrationRange.lowerBound, median))
    }

    /// The muscle load of a rated strength session: the part of its calibrated rated load heart rate did
    /// not already measure, never below zero.
    static func muscleLoad(ratedLoad: Double, heartLoad: Double, calibration k: Double) -> Double {
        max(0, k * ratedLoad - heartLoad)
    }

    // MARK: Which activities

    /// Resistance training, as the app's catalogue, the Lift Log, the WHOOP export and Apple Health name it.
    /// Compared by `WorkoutSource.sportKey`, so case and spacing do not matter.
    static let strengthSports: Set<String> = Set([
        "Weightlifting", "Powerlifting", "Strength Trainer", "Functional Fitness", "CrossFit",
        "Weight Training", "Strength", "Strength Training", "Traditional Strength Training",
        "Functional Strength Training", "Bodybuilding", "Calisthenics",
    ].map(WorkoutSource.sportKey))

    static func isStrength(_ sport: String) -> Bool {
        strengthSports.contains(WorkoutSource.sportKey(sport))
    }

    /// Whether the user can rate an activity: Yoop's own, logged, live or detected. Imported history keeps
    /// its source's Strain, and WHOOP's already holds WHOOP's own muscular load.
    static func isRateable(_ row: WorkoutRow) -> Bool {
        switch WorkoutSource.classify(row.source) {
        case .manual, .detected: return true
        case .whoop, .apple, .lifting, .activityFile: return false
        }
    }
}

/// One rated activity's Strain, split into what heart rate measured and what its rating adds.
struct MuscleSplit: Equatable {
    /// The user's rating, 0 to 10.
    let effort: Int
    let isStrength: Bool
    /// L_hr, from the activity's stored Strain.
    let heartLoad: Double
    /// L_rpe, before calibration.
    let ratedLoad: Double
    /// What the rating adds to the heart load; zero unless a strength session rated above what heart rate saw.
    let muscleLoad: Double

    /// The heart's part on WHOOP's 0-21 axis: the Strain heart rate alone gave.
    var heartStrain: Double { StrainScorer.whoopStrain(load: heartLoad) }
    /// The whole on WHOOP's 0-21 axis.
    var strain: Double { StrainScorer.whoopStrain(load: heartLoad + muscleLoad) }
    /// The muscle's part on WHOOP's 0-21 axis: what it adds on top of the heart's.
    var muscleStrain: Double { strain - heartStrain }
}

/// Today's in-progress Strain as Home works it out from the day's heart rate (stored 0-100 axis), with the
/// day it belongs to. The stored row lags it (`StrainScorer.effectiveEffort`).
struct LiveDayStrain: Equatable {
    let day: String
    let value: Double
}

/// What the ratings add, by activity and by day: the one place a Strain readout learns of muscle load.
/// `Repository.strainBook` holds the current one; `dayStrain`, `activityStrain` and `resolved` are the
/// resolver every Strain screen goes through, so no two can show different Strain for one day or activity.
struct StrainBook: Equatable {
    /// Every rated activity, by start time.
    var splits: [Int: MuscleSplit] = [:]
    /// The muscle load each day gains, by day key. A day that gains none is absent.
    var muscleByDay: [String: Double] = [:]
    /// k (`MuscleLoad.calibration`).
    var calibration: Double = 1

    static let empty = StrainBook()

    /// The book for these activities and ratings (by activity start). `dayKey` names the day an activity
    /// start belongs to; `now` bounds the calibration's window.
    static func build(rows: [WorkoutRow], efforts: [Int: Int], now: Int, dayKey: (Int) -> String) -> StrainBook {
        let rated = rows.filter { MuscleLoad.isRateable($0) && efforts[$0.startTs] != nil }
        guard !rated.isEmpty else { return .empty }
        let since = now - MuscleLoad.calibrationWindowDays * 86_400
        let ratios = rated.compactMap { row -> Double? in
            guard !MuscleLoad.isStrength(row.sport), row.startTs >= since, let effort = efforts[row.startTs] else {
                return nil
            }
            let ratedLoad = MuscleLoad.ratedLoad(effort: effort, minutes: MuscleLoad.minutes(row))
            let heartLoad = MuscleLoad.heartLoad(storedStrain: row.strain)
            guard ratedLoad > 0, heartLoad > 0 else { return nil }
            return heartLoad / ratedLoad
        }
        var book = StrainBook()
        book.calibration = MuscleLoad.calibration(ratios: ratios)
        for row in rated {
            guard let effort = efforts[row.startTs] else { continue }
            let strength = MuscleLoad.isStrength(row.sport)
            let ratedLoad = MuscleLoad.ratedLoad(effort: effort, minutes: MuscleLoad.minutes(row))
            let heartLoad = MuscleLoad.heartLoad(storedStrain: row.strain)
            let muscle = strength
                ? MuscleLoad.muscleLoad(ratedLoad: ratedLoad, heartLoad: heartLoad, calibration: book.calibration)
                : 0
            book.splits[row.startTs] = MuscleSplit(effort: effort, isStrength: strength, heartLoad: heartLoad,
                                                   ratedLoad: ratedLoad, muscleLoad: muscle)
            if muscle > 0 { book.muscleByDay[dayKey(row.startTs), default: 0] += muscle }
        }
        return book
    }

    /// An activity's Strain on the stored 0-100 axis: its own, plus the muscle load its rating adds.
    func activityStrain(_ row: WorkoutRow) -> Double? {
        guard MuscleLoad.isRateable(row), let split = splits[row.startTs], split.muscleLoad > 0 else {
            return row.strain
        }
        return MuscleLoad.storedStrain(load: split.heartLoad + split.muscleLoad)
    }

    /// A day's Strain on the stored 0-100 axis: today's live value when it beats the stored row
    /// (`StrainScorer.effectiveEffort`), plus the muscle load of the day's rated strength sessions.
    func dayStrain(day: String, stored: Double?, live: LiveDayStrain?) -> Double? {
        let base = StrainScorer.effectiveEffort(live: live?.day == day ? live?.value : nil, stored: stored)
        guard let muscle = muscleByDay[day], muscle > 0 else { return base }
        return MuscleLoad.storedStrain(load: MuscleLoad.heartLoad(storedStrain: base) + muscle)
    }

    /// `days` with each day's Strain from `dayStrain`. A day it leaves alone is the same row.
    func resolved(_ days: [DailyMetric], live: LiveDayStrain?) -> [DailyMetric] {
        var touched = Set(muscleByDay.keys)
        if let live { touched.insert(live.day) }
        guard !touched.isEmpty else { return days }
        var out = days
        for i in out.indices where touched.contains(out[i].day) {
            let strain = dayStrain(day: out[i].day, stored: out[i].strain, live: live)
            if strain != out[i].strain { out[i] = out[i].with(strain: strain) }
        }
        return out
    }
}

/// The user's 0-10 rating of each of their own activities, by the activity's start time, in UserDefaults.
/// Owned by `Repository`, which carries a rating across a re-save under a new start and drops it with its
/// activity. Not in the backup whitelist (`BackupSettings` is a Swift/Kotlin byte contract).
struct ActivityEffortStore {
    static let key = "yoop.activityEffort"
    /// Ratings kept, the latest starts first, so the store cannot grow without bound.
    static let capacity = 1000

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every rating, by activity start.
    var all: [Int: Int] {
        var out: [Int: Int] = [:]
        for (key, value) in defaults.dictionary(forKey: Self.key) ?? [:] {
            if let start = Int(key), let effort = value as? Int { out[start] = effort }
        }
        return out
    }

    func effort(startTs: Int) -> Int? {
        all[startTs]
    }

    /// Sets one activity's rating, clamped to 0-10; nil clears it.
    func set(_ effort: Int?, startTs: Int) {
        var map = all
        map[startTs] = effort.map { min(10, max(0, $0)) }
        write(map)
    }

    /// Moves a rating to the activity's new start after a re-save moved it. Nothing rated, nothing moves.
    func move(from old: Int, to new: Int) {
        guard old != new else { return }
        var map = all
        guard let effort = map.removeValue(forKey: old) else { return }
        map[new] = effort
        write(map)
    }

    private func write(_ map: [Int: Int]) {
        let kept = map.keys.sorted(by: >).prefix(Self.capacity)
        let stored = Dictionary(uniqueKeysWithValues: kept.compactMap { start in map[start].map { (String(start), $0) } })
        if stored.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set(stored, forKey: Self.key)
        }
    }
}

extension DailyMetric {
    /// Rebuild with a substituted Strain (the funnel's resolved value), every other field untouched.
    func with(strain s: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: recovery, strain: s, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: skinTempDevC, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: avgSdnn, skinTempC: skinTempC,
                    sleepHrOnly: sleepHrOnly)
    }
}
