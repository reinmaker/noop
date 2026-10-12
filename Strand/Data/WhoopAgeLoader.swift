import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// Yoop: loads the WHOOP Age window from the repository. See `WhoopAge` and `WhoopAgeWindow.swift`.
// MARK: - Loading

@MainActor
enum WhoopAgeLoader {
    private static var cache: (key: String, snapshot: WhoopAgeSnapshot)?

    /// The snapshot for today's logical day. Cached against the repository's refresh counter, so the Health
    /// tab, the screen and the Coach in one refresh share one read.
    static func load(repo: Repository, age: Double, sex: String) async -> WhoopAgeSnapshot {
        let today = Repository.logicalDayKey(Date())
        let key = "\(repo.refreshSeq)|\(today)|\(Int(age))|\(sex)"
        if let cache, cache.key == key { return cache.snapshot }
        let snapshot = await build(repo: repo, today: today, age: age, sex: sex)
        cache = (key, snapshot)
        return snapshot
    }

    /// The profile the Coach holds (UserDefaults), for callers without a `ProfileStore`.
    static func load(repo: Repository, defaults: UserDefaults = .standard) async -> WhoopAgeSnapshot {
        let age = Double(defaults.integer(forKey: "profile.age"))
        let sex = defaults.string(forKey: "profile.sex") ?? "male"
        return await load(repo: repo, age: age, sex: sex)
    }

    private static func build(repo: Repository, today: String, age: Double, sex: String) async -> WhoopAgeSnapshot {
        let keys = WhoopAge.dayKeys(endingOn: today, count: WhoopAge.windowDays)
        let first = keys.first ?? today
        var days: [String: WhoopAge.Day] = [:]
        func update(_ day: String, _ change: (inout WhoopAge.Day) -> Void) {
            var d = days[day] ?? WhoopAge.Day(day: day)
            change(&d)
            days[day] = d
        }

        // The strap's days, one row per day by the app's source precedence (an import wins).
        let strapRows = repo.vitalMetricRows
            .filter { $0.metric.day >= first && $0.metric.day <= today && $0.source != .appleHealth }
            .sorted { $0.source.vitalPriority > $1.source.vitalPriority }   // lowest priority first, so the import overwrites
        for row in strapRows {
            let m = row.metric
            update(m.day) { d in
                if let s = m.totalSleepMin, s > 0 { d.sleepMin = s }
                if let r = m.restingHr, r > 0 { d.restingHr = Double(r) }
                if m.recovery != nil { d.hasRecovery = true }
                if let s = m.steps, s > 0 { d.steps = Double(s) }
            }
        }
        // Consistency: WHOOP's own figure when the export has it, else Yoop's fit of it for the nights it has.
        let fitted = SleepModel.consistencyByWakeDay(repo.sleeps)
        for key in keys {
            let value = repo.importedSleep[key]?.consistencyPct ?? fitted[key]
            if let value, days[key]?.isStrapDay == true { update(key) { $0.consistency = value } }
        }
        // Steps from the phone for days the strap did not count.
        let apple = await repo.appleDailyRows(days: WhoopAge.windowDays + 7)
        for row in apple where row.day >= first && row.day <= today {
            if let s = row.steps, s > 0, days[row.day]?.steps == nil { update(row.day) { $0.steps = Double(s) } }
        }
        // Logged activities: zone minutes and strength minutes on the days the strap recorded.
        let workouts = await repo.workoutRows(days: WhoopAge.windowDays + 7)
        for w in workouts {
            let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs)))
            guard day >= first, day <= today, days[day]?.isStrapDay == true else { continue }
            let duration = w.durationS ?? Double(w.endTs - w.startTs)
            var bands: [Double]?
            if WorkoutZones.percents(w.zonesJSON) == nil {
                let rest = WhoopActivityZones.restingHR(dayKey: day, days: repo.days)
                let samples = await repo.workoutHrSamples(from: w.startTs, to: w.endTs, source: w.source)
                bands = WhoopActivityZones.bandSeconds(samples, from: w.startTs, to: w.endTs, restingHR: rest)
            }
            if let z = WhoopAge.zoneMinutes(durationS: duration, importedPercents: WorkoutZones.percents(w.zonesJSON),
                                            bandSeconds: bands) {
                update(day) { $0.zones13Min += z.z13; $0.zones45Min += z.z45 }
            }
            if WhoopAge.isStrengthSport(w.sport), duration > 0 {
                update(day) { $0.strengthMin += duration / 60 }
            }
        }

        let all = Array(days.values)
        let coverage = WhoopAge.coverage(days: all, endingOn: today)
        let vo2 = await Vo2Resolver.load(repo: repo, sex: sex)
        guard age > 0 else {
            return WhoopAgeSnapshot(day: today, coverage: coverage, vo2: vo2, result: nil, recent: nil, pace: nil)
        }
        let window = WhoopAge.inputs(days: all, endingOn: today, span: WhoopAge.windowDays, age: age, sex: sex, vo2: vo2)
        let recent = WhoopAge.inputs(days: all, endingOn: today, span: WhoopAge.recentDays, age: age, sex: sex, vo2: vo2)
        let result = coverage.isUnlocked ? WhoopAge.compute(window) : nil
        let pace = result == nil ? nil : WhoopAge.pace(window: window, recent: recent)
        return WhoopAgeSnapshot(day: today, coverage: coverage, vo2: vo2, result: result, recent: recent, pace: pace)
    }
}

// MARK: - VO2 max

@MainActor
enum Vo2Resolver {
    /// The choice for today's logical day, from Apple Health's newest reading and Yoop's newest estimate.
    static func load(repo: Repository, sex: String = UserDefaults.standard.string(forKey: "profile.sex") ?? "male") async -> Vo2Choice? {
        let today = Repository.logicalDayKey(Date())
        let apple = await repo.appleDailyRows(days: 200)
            .compactMap { row in row.vo2max.map { (day: row.day, value: $0) } }
            .filter { $0.day <= today }
            .max { $0.day < $1.day }
            .map { Vo2Choice.Reading(value: $0.value, day: $0.day, estimator: nil) }
        var yoop: Vo2Choice.Reading?
        let resolved = await repo.resolvedSeries(key: "vo2max_est", source: "my-whoop")
        if let point = resolved.points.last(where: { $0.day <= today }) {
            let tag = await repo.scoreProvenanceTag(resolvedSource: point.source, day: point.day, metricKey: "vo2max_est")
            yoop = Vo2Choice.Reading(value: point.value, day: point.day, estimator: tag)
        }
        return Vo2Choice.choose(apple: apple, yoop: yoop, today: today, sex: sex)
    }
}
