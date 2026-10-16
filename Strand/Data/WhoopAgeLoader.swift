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
    /// tab, the screen and the Coach in one refresh share one read. `age` is in years and fractions of a year
    /// (`ProfileStore.decimalAge`); `ageSigma` is its error when the birth date is not known, else 0.
    static func load(repo: Repository, age: Double, ageSigma: Double = 0, sex: String) async -> WhoopAgeSnapshot {
        let today = Repository.logicalDayKey(Date())
        // The VO2 max typed in from the WHOOP app is part of the key, so a new entry is read at once.
        let typed = ProfileStore.storedWhoopAppVo2().map { "\($0.value)@\($0.date.timeIntervalSince1970)" } ?? "-"
        let key = "\(repo.refreshSeq)|\(today)|\(String(format: "%.3f", age))|\(ageSigma)|\(sex)|\(typed)"
        if let cache, cache.key == key { return cache.snapshot }
        let snapshot = await build(repo: repo, today: today, age: age, ageSigma: ageSigma, sex: sex)
        cache = (key, snapshot)
        return snapshot
    }

    private static var lastWeekCache: (key: String, pace: Double?)?

    /// The Pace of Aging as it stood a week ago, for the Health tab's "faster or slower vs. last week": the same
    /// window read as of seven days before today, nil while it was still calibrating then.
    static func paceLastWeek(repo: Repository, age: Double, ageSigma: Double = 0, sex: String) async -> Double? {
        let today = Repository.logicalDayKey(Date())
        guard age > 0, let weekAgo = WhoopAge.dayKeys(endingOn: today, count: 8).first else { return nil }
        let typed = ProfileStore.storedWhoopAppVo2().map { "\($0.value)@\($0.date.timeIntervalSince1970)" } ?? "-"
        let key = "\(repo.refreshSeq)|\(weekAgo)|\(String(format: "%.3f", age))|\(ageSigma)|\(sex)|\(typed)"
        if let lastWeekCache, lastWeekCache.key == key { return lastWeekCache.pace }
        let snapshot = await build(repo: repo, today: weekAgo, age: age, ageSigma: ageSigma, sex: sex)
        let pace = snapshot.isUnlocked ? snapshot.pace : nil
        lastWeekCache = (key, pace)
        return pace
    }

    /// The profile the Coach holds (UserDefaults), for callers without a `ProfileStore`: the same decimal age.
    static func load(repo: Repository, defaults: UserDefaults = .standard) async -> WhoopAgeSnapshot {
        let stored = ProfileStore.storedAge(defaults: defaults)
        let sigma = stored.map { $0.isExact ? 0 : ProfileStore.unknownBirthdayFractionSigma } ?? 0
        let sex = defaults.string(forKey: "profile.sex") ?? "male"
        return await load(repo: repo, age: stored?.years ?? 0, ageSigma: sigma, sex: sex)
    }

    private static func build(repo: Repository, today: String, age: Double, ageSigma: Double, sex: String) async -> WhoopAgeSnapshot {
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
        let window = WhoopAge.inputs(days: all, endingOn: today, span: WhoopAge.windowDays, age: age, ageSigma: ageSigma, sex: sex, vo2: vo2)
        let recent = WhoopAge.inputs(days: all, endingOn: today, span: WhoopAge.recentDays, age: age, ageSigma: ageSigma, sex: sex, vo2: vo2)
        let result = coverage.isUnlocked ? WhoopAge.compute(window) : nil
        let pace = result == nil ? nil : WhoopAge.pace(window: window, recent: recent)
        return WhoopAgeSnapshot(day: today, coverage: coverage, vo2: vo2, result: result, recent: recent, pace: pace)
    }
}

// MARK: - VO2 max

@MainActor
enum Vo2Resolver {
    /// The choice for today's logical day, from the reading typed in from the WHOOP app (Settings), Apple Health's
    /// newest reading and Yoop's newest estimate. Every screen and the Coach read it through here.
    static func load(repo: Repository, sex: String = UserDefaults.standard.string(forKey: "profile.sex") ?? "male",
                     defaults: UserDefaults = .standard) async -> Vo2Choice? {
        let today = Repository.logicalDayKey(Date())
        let whoop = ProfileStore.storedWhoopAppVo2(defaults: defaults).map {
            Vo2Choice.Reading(value: $0.value, day: Repository.localDayKey($0.date), estimator: nil)
        }
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
        return Vo2Choice.choose(whoop: whoop, apple: apple, yoop: yoop, today: today, sex: sex)
    }
}
