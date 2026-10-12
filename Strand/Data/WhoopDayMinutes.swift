import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Yoop: a day's steps and active energy by minute, read from the store and counted the way the day itself
/// was counted. The Steps and Calories pages split them by hour, and `WhoopDayCurveBook` builds the curves
/// the by-now normal reads from them, so there is one reading of a day's minutes.
@MainActor
enum WhoopDayMinutes {
    /// A window's steps by minute (`ts / 60`).
    struct Steps {
        /// Steps in each minute, after `stepTicksPerStep`.
        var perMinute: [Int: Double]
        /// The day's step count, rounded as the day cycle rounds it.
        var total: Int
        /// When the strap's counter first reported inside the window.
        var firstSampleTs: Int?
    }

    /// A window's active energy by minute.
    struct Energy {
        var perMinute: [Int: Double]
        /// When the first heart-rate sample inside the window was taken.
        var firstSampleTs: Int?
    }

    /// The sleep-onset day counts against the night's sleep; the midnight day counts its own samples.
    static var onsetDay: Bool {
        DayCycleMode.persisted(UserDefaults.standard.string(forKey: DayCycleMode.storageKey)) == .sleepOnset
    }

    /// The steps `[from, to)` counted, nil when no strap counter covers it.
    static func steps(repo: Repository, profile: ProfileStore, from: Int, to: Int) async -> Steps? {
        let onset = onsetDay
        let sessions = onset ? repo.sleeps.map { WhoopDayFigures.sleepSession($0) } : []
        guard let counted = await repo.countedStepMinutes(from: from, toExclusive: to, sleeps: sessions,
                                                          seedsFromBefore: onset) else { return nil }
        let perStep = max(profile.stepTicksPerStep, 0.5)
        let ticks = counted.ticks.values.reduce(0, +)
        return Steps(perMinute: counted.ticks.mapValues { Double($0) / perStep },
                     total: Int((Double(ticks) / perStep).rounded()), firstSampleTs: counted.firstSampleTs)
    }

    /// The active energy of `day`'s window `[from, to)` by minute, priced as the day prices it
    /// (`Calories.yoopActiveKcalByMinute`). The resting heart rate is the main sleep's mean on the
    /// sleep-onset day (`primaryResting`, read here when not given), else the day's resting heart rate.
    /// Nil without heart rate.
    static func activeKcal(repo: Repository, profile: ProfileStore, day: String, from: Int, to: Int,
                           stepsByMinute: [Int: Double], primaryResting: [String: Double]? = nil) async -> Energy? {
        let hr = await repo.hrSamples(from: from, to: to - 1, limit: 200_000)
        guard !hr.isEmpty else { return nil }
        var primary: Double?
        if onsetDay {
            let byDay: [String: Double]
            if let primaryResting { byDay = primaryResting } else {
                byDay = Dictionary((await repo.exploreSeries(key: "rhr_primary_session", source: "my-whoop"))
                    .map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            }
            primary = byDay[day]
        }
        let resting = primary ?? repo.days.last { $0.day == day }?.restingHr.map(Double.init)
            ?? StrainScorer.defaultRestingHR
        let user = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm, age: Double(profile.age),
                               sex: profile.sex)
        let maxHR = profile.effortHRmax
        let byMinute = await Task.detached(priority: .utility) {
            Calories.yoopActiveKcalByMinute(hr, stepsByMinute: stepsByMinute, profile: user, hrmax: maxHR,
                                            restingHR: resting)
        }.value
        return byMinute.isEmpty ? nil : Energy(perMinute: byMinute, firstSampleTs: hr.first?.ts)
    }
}
