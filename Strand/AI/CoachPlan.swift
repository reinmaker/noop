import Foundation

/// Today's plan, WHOOP-style: the activity the wearer committed to from one of the Coach's suggestion
/// cards. Device-local; Home shows it as "MY PLAN" for the rest of that day.
struct CoachPlan: Codable, Equatable {
    var day: String
    var name: String
    var why: String
    var done = false

    static let storageKey = "coach.plan.v1"

    static func decode(_ raw: String) -> CoachPlan? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CoachPlan.self, from: data)
    }

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// Record a commitment for today.
    @MainActor static func commit(name: String, why: String) {
        let plan = CoachPlan(day: Repository.logicalDayKey(Date()), name: name, why: why)
        UserDefaults.standard.set(plan.encoded, forKey: storageKey)
    }
}
