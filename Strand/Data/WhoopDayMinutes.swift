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

    /// The active energy of the window `[from, to)` by minute, priced as the day prices it
    /// (`Calories.yoopActiveKcalByMinute`): from the minute's mean heart rate alone, by the one WHOOP-fitted
    /// line, with no steps, no special minutes and no profile term (the profile enters the basal rate only).
    /// Nil without heart rate.
    static func activeKcal(repo: Repository, from: Int, to: Int) async -> Energy? {
        let hr = await repo.hrSamples(from: from, to: to - 1, limit: 200_000)
        guard !hr.isEmpty else { return nil }
        let byMinute = await Task.detached(priority: .utility) {
            Calories.yoopActiveKcalByMinute(hr)
        }.value
        return byMinute.isEmpty ? nil : Energy(perMinute: byMinute, firstSampleTs: hr.first?.ts)
    }
}
