import Foundation
import StrandAnalytics
import WhoopStore

/// Yoop: sleep debt the way WHOOP states it, fitted to the user's WHOOP export (121 nights, 7 June to 6
/// October 2026). It is a fit to that one export, not a published formula.
///
/// A night's debt is half of the previous night's shortfall against that night's own need:
/// `debt(t) = 0.5 x max(0, need(t-1) - asleep(t-1))`. Against WHOOP's own Sleep debt column this one-night
/// rule has an RMSE of 5.7 minutes, and the best decayed sum of up to four nights (scale 0.50, decay 0.05,
/// which is one night in effect) 5.0, where a constant debt of the median is 29 off. A need is the healthy
/// minimum + 7.3 min for each point of the previous day's Strain above 10 + that debt, so the rule runs
/// recursively over a night's own need: over the 121 nights the recursion has a need RMSE of 32 minutes
/// against 44 for a constant need. The NOOP ledger it replaces here (`SleepDebt`: 55% carried over 14
/// nights against a need of 8 h or more) overstated the same debt by about 70 minutes.
///
/// Only a night with a sleep total counts, and a night without one is skipped, never filled with zero.
/// The first night with nothing before it has no debt. An imported WHOOP night keeps WHOOP's own need.
enum WhoopSleepDebt {
    /// The share of a night's shortfall that is carried into the next night.
    static let carryShare = 0.5

    /// The debt a night hands to the next one, in minutes: `carryShare` of how far the sleep fell short of
    /// the night's own need, and none when it met it.
    static func carried(needMin: Double, asleepMin: Double) -> Double {
        carryShare * max(0, needMin - asleepMin)
    }

    /// One night as the chain resolves it.
    struct Night: Equatable {
        /// The day the night ends on.
        let day: String
        let asleepMin: Double
        /// The need Yoop sets for the night, in its parts: the healthy minimum, the previous day's Strain
        /// and the debt carried into the night.
        let planned: NightNeed
        /// Whether the night is measured against WHOOP's own need (`needMin`), which an import carries.
        let hasImportedNeed: Bool
        /// The need the night is measured against: WHOOP's own for an imported night, else `planned`.
        let needMin: Double

        /// The debt the night hands to the next one.
        var leftMin: Double { WhoopSleepDebt.carried(needMin: needMin, asleepMin: asleepMin) }
    }

    /// The nights of a history resolved oldest first, one at a time: each night's need is built from the
    /// days before it only, and its debt from the night before. Feed the days in order of their day key.
    struct Chain {
        private let importedSleep: [String: ImportedSleepFigures]
        /// The totals of the days before `currentDay`, in order, kept as a sum so the healthy minimum is
        /// worked out without a pass over the history for each night.
        private var sum = 0.0
        private var count = 0
        private var currentDay: String?
        /// The totals of `currentDay`, banked into `sum` once the day is over.
        private var pending: [Double] = []
        /// Each day's Strain on WHOOP's 0 to 21 axis, as the Strain ring shows it.
        private var strainByDay: [String: Double] = [:]
        private var last: (needMin: Double, asleepMin: Double)?

        init(importedSleep: [String: ImportedSleepFigures]) {
            self.importedSleep = importedSleep
        }

        /// Banks the days before `day`, so the healthy minimum reads only those.
        private mutating func bank(before day: String) {
            guard currentDay != day else { return }
            for total in pending { sum += total; count += 1 }
            pending.removeAll(keepingCapacity: true)
            currentDay = day
        }

        /// The need of the night ending on `wakeDay` from what the chain has taken in, which must all be
        /// from earlier days: the healthy minimum + 7.3 min for each point of the previous day's Strain
        /// above 10 + the debt the last night with sleep left.
        mutating func need(endingOn wakeDay: String) -> NightNeed {
            bank(before: wakeDay)
            let strain = strainByDay[WeeklyDigestEngine.addDays(wakeDay, -1)] ?? 0
            let baseline = count > 0 ? Swift.max(450, sum / Double(count)) : 450
            return NightNeed(baselineMin: baseline,
                             strainMin: SleepModel.needMinPerStrainPoint * Swift.max(0, strain - SleepModel.needStrainFloor),
                             debtMin: last.map { WhoopSleepDebt.carried(needMin: $0.needMin, asleepMin: $0.asleepMin) } ?? 0)
        }

        /// Takes in the next day. Its night is resolved when it has a sleep total, and nil when it has none,
        /// in which case the debt is carried past it untouched.
        mutating func add(_ d: DailyMetric) -> Night? {
            var night: Night?
            if let asleep = d.totalSleepMin, asleep > 0 {
                let planned = need(endingOn: d.day)
                let imported = importedSleep[d.day]?.needMin
                let n = Night(day: d.day, asleepMin: asleep, planned: planned,
                              hasImportedNeed: imported != nil, needMin: imported ?? planned.needMin)
                last = (n.needMin, asleep)
                night = n
            } else {
                bank(before: d.day)
            }
            strainByDay[d.day] = d.strain.map { UnitFormatter.effortValue($0, scale: .whoop) } ?? 0
            if let total = d.totalSleepMin, total > 0 { pending.append(total) }
            return night
        }
    }

    /// Every night with a sleep total in `days`, oldest first.
    static func nights(days: [DailyMetric], importedSleep: [String: ImportedSleepFigures]) -> [Night] {
        var chain = Chain(importedSleep: importedSleep)
        return days.sorted { $0.day < $1.day }.compactMap { chain.add($0) }
    }

    /// The need of the night ending on `wakeDay`, from the days before it only: the figure the Sleep
    /// Planner sets that evening, which the nights of `nights(days:importedSleep:)` measure themselves
    /// against the next morning.
    static func need(endingOn wakeDay: String, days: [DailyMetric],
                     importedSleep: [String: ImportedSleepFigures]) -> NightNeed {
        var chain = Chain(importedSleep: importedSleep)
        for d in days.filter({ $0.day < wakeDay }).sorted(by: { $0.day < $1.day }) { _ = chain.add(d) }
        return chain.need(endingOn: wakeDay)
    }
}
