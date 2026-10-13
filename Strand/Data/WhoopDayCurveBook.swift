import Foundation
import StrandAnalytics
import WhoopStore

/// Yoop: the closed days' step and energy curves (`WhoopDayCurve`), computed once and kept on the device.
///
/// A closed day never changes, so its curve is read from the store once and kept in the caches directory,
/// keyed by a signature of what it was computed from; a day the engine re-scored reads again. Losing the
/// file costs one recomputation, never data. The by-now normals are read from these curves.
@MainActor
final class WhoopDayCurveBook {
    static let shared = WhoopDayCurveBook()

    /// Today's normals by this time of day, nil where there are not enough complete days (`WhoopByNow.minDays`).
    struct Normals: Equatable {
        var steps: Double?
        var kcal: Double?
        /// The time of day they are read at, epoch seconds, and the day they are today's normals for.
        var asOf: Int
        var dayKey: String
    }

    private var curves: [String: WhoopDayCurve] = [:]
    private var loaded = false
    private var working: Task<Void, Never>?

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("yoop-day-curves-v1.json")
    }

    /// How many prior days the whole-day normal reads, and so how many curves the by-now normal needs.
    static let normalDays = 30

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([WhoopDayCurve].self, from: data) else { return }
        curves = Dictionary(stored.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func persist(keeping days: Set<String>) {
        curves = curves.filter { days.contains($0.key) }
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(Array(curves.values)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// What a day's curve was computed from: its stored totals, its window and the rules that counted it.
    static func signature(_ row: DailyMetric, window: (from: Int, to: Int)) -> String {
        "\(row.steps ?? -1)|\(Int(((row.activeKcalEst ?? -1) * 10).rounded()))|\(window.from)|\(window.to)"
            + "|\(WhoopDayMinutes.onsetDay)|\(PuffinExperiment.whoopScoresEnabled)|energy=whoopfit1"
    }

    /// The by-now normals for the open day `todayKey`, read at `asOf`. Reads and keeps any prior day's
    /// curve that is missing (the first call after install reads up to 30 days, in the background of the
    /// caller's await; later ones read the one new day).
    func normals(repo: Repository, profile: ProfileStore, todayKey: String, asOf: Int) async -> Normals {
        loadIfNeeded()
        if let working { await working.value }
        let rows = Array(repo.days.filter { $0.day < todayKey }.suffix(Self.normalDays))
        let task = Task { @MainActor in
            await self.fill(rows, repo: repo, profile: profile)
        }
        working = task
        await task.value
        working = nil
        let prior = rows.compactMap { curves[$0.day] }
        let yoop = PuffinExperiment.whoopScoresEnabled
        return Normals(
            steps: WhoopByNow.normal(.steps, curves: prior, asOf: asOf, todayKey: todayKey, floor: 1000),
            kcal: yoop ? WhoopByNow.normal(.kcal, curves: prior, asOf: asOf, todayKey: todayKey, floor: 0) : nil,
            asOf: asOf, dayKey: todayKey)
    }

    private func fill(_ rows: [DailyMetric], repo: Repository, profile: ProfileStore) async {
        let markers = Dictionary((await repo.exploreSeries(key: DayCycleIntelligenceIntegration.onsetKey,
                                                           source: "my-whoop")).map { ($0.day, Int($0.value)) },
                                 uniquingKeysWith: { _, last in last })
        var changed = false
        for row in rows {
            let window = WhoopDayFigures.window(day: row.day, markers: markers)
            guard window.to > window.from else { continue }
            let sig = Self.signature(row, window: window)
            if curves[row.day]?.sig == sig { continue }
            // A day the strap never counted has no strap steps or heart rate; its curve says so, once.
            let steps = await WhoopDayMinutes.steps(repo: repo, profile: profile, from: window.from, to: window.to)
            var energy: WhoopDayMinutes.Energy?
            if PuffinExperiment.whoopScoresEnabled {
                energy = await WhoopDayMinutes.activeKcal(repo: repo, from: window.from, to: window.to)
            }
            let recordedFromStart = { (first: Int?) -> Bool in
                first.map { $0 - window.from <= 3_600 } ?? false
            }
            curves[row.day] = WhoopDayCurve.make(
                day: row.day, sig: sig, from: window.from, to: window.to, stepsByMinute: steps?.perMinute,
                kcalByMinute: energy?.perMinute, stepsFromStart: recordedFromStart(steps?.firstSampleTs),
                kcalFromStart: recordedFromStart(energy?.firstSampleTs))
            changed = true
            if Task.isCancelled { break }
        }
        if changed { persist(keeping: Set(rows.map(\.day))) }
    }
}
