import Foundation

/// One thing the Coach remembers about the wearer (WHOOP-style "My Memory"): a health condition or
/// injury, a goal, an upcoming event, or how they like to be coached. Stored on-device only and sent to
/// the Coach as part of its context, so its advice accounts for them.
struct CoachMemory: Codable, Identifiable, Equatable {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case health = "Health condition"
        case goal = "Goal"
        case event = "Event"
        case preference = "Coaching preference"

        var id: String { rawValue }

        /// Tolerant parse of the category name the Coach writes on a "Memory:" line.
        static func parse(_ raw: String) -> Category {
            let lower = raw.lowercased()
            if lower.contains("goal") { return .goal }
            if lower.contains("event") { return .event }
            if lower.contains("prefer") || lower.contains("coach") { return .preference }
            return .health
        }
    }

    var id = UUID()
    var category: Category
    var title: String
    var detail: String
    var start = Date()
    var active = true
}

/// The memory list, persisted as JSON in UserDefaults (device-local, like the chat transcript).
@MainActor
final class CoachMemoryStore: ObservableObject {
    static let shared = CoachMemoryStore()

    private static let key = "coach.memories.v1"
    private static let nameKey = "coach.firstName"

    @Published private(set) var items: [CoachMemory] = []

    private static let oldSeedDetail =
        "Data-driven coaching with a mix of tough love and motivation, with the detail behind each recommendation."
    private static let seedDetail =
        "Data-driven coaching with a mix of tough love and motivation, kept short and to the point."
    /// The first name the Coach uses for the wearer ("Daniel, you hit your strain target...").
    @Published var firstName: String {
        didSet { UserDefaults.standard.set(firstName, forKey: Self.nameKey) }
    }

    private init() {
        firstName = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([CoachMemory].self, from: data) {
            items = decoded
        } else {
            // A sensible starting style, editable or removable on the Memory screen.
            items = [CoachMemory(category: .preference, title: "Prefers data and tough love",
                                 detail: Self.seedDetail)]
            save()
        }
        // The first seed asked for detail; the wearer asked for short answers instead (2026-10-07).
        if let i = items.firstIndex(where: { $0.detail == Self.oldSeedDetail }) {
            items[i].detail = Self.seedDetail
            save()
        }
    }

    func add(_ memory: CoachMemory) {
        // The Coach may restate something it already knows; keep one copy per title.
        if let i = items.firstIndex(where: { $0.title.caseInsensitiveCompare(memory.title) == .orderedSame }) {
            items[i].detail = memory.detail
            items[i].category = memory.category
            items[i].active = true
        } else {
            items.insert(memory, at: 0)
            // WHOOP-style Conversational Check-In: follow up tomorrow evening on anything but a preference.
            if memory.category != .preference {
                WhoopNotifications.scheduleCheckIn(title: memory.title, category: memory.category.rawValue)
            }
        }
        save()
    }

    func remove(_ id: CoachMemory.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    func setActive(_ id: CoachMemory.ID, _ active: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].active = active
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// The memory block for the Coach's context, or nil when there is nothing to tell it.
    func contextBlock() -> String? {
        var lines: [String] = []
        let name = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { lines.append("The user's first name is \(name).") }
        let active = items.filter(\.active)
        if !active.isEmpty {
            lines.append("What you remember about the user (take these into account in every answer):")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d MMM yyyy"
            for m in active {
                lines.append("- [\(m.category.rawValue), since \(f.string(from: m.start))] \(m.title): \(m.detail)")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
