import Foundation

/// Which journal questions are worth asking today. A fixed list asked every day wastes the answer: on the
/// wearer's own 116 WHOOP journal days, "Consumed caffeine?" was Yes 114 times of 114 and "Used tobacco in any
/// form?" Yes once, so answering them told Yoop nothing, while "Ate food close to bedtime?" (77 Yes, 38 No),
/// "Played video games?" (32/76), "Have any alcoholic drinks?" (26/88) and "Consumed protein?" (52/55) were the
/// questions whose answers varied. So a question is asked when its answer is open (it has gone both ways over
/// the last 60 days), when the morning's data points at it (a low Recovery asks about alcohol and a late meal), or
/// when the wearer pinned it; a question nobody has ever answered is asked only when the data points at it, so
/// the starter list does not arrive all at once; one that has gone quiet is asked again every two weeks to see
/// whether it changed. A wearer with no history yet is asked the first few questions of the list so there is
/// something to learn from. Pure, so tests pin it on the wearer's own counts.
enum JournalQuestionPicker {

    /// How a question has been answered over the window.
    struct Stats: Equatable {
        var yes = 0
        var no = 0
        /// Days since the question was last answered, nil when it never was.
        var daysSinceAnswered: Int?
        var answers: Int { yes + no }
    }

    /// What the morning's data says, for the day being logged (the morning after the behaviours).
    struct DayContext: Equatable {
        /// Recovery well under the wearer's usual.
        var lowRecovery = false
        /// A short or restless night.
        var poorSleep = false
        /// A hard day (Strain 14 or more of 21).
        var hardDay = false
        /// Resting heart rate, breathing, skin temperature or the like out of range together.
        var illnessSigns = false
        var isEmpty: Bool { !lowRecovery && !poorSleep && !hardDay && !illnessSigns }
    }

    enum Reason: String, Equatable { case pinned, open, cue, checkIn, starter }

    struct Pick: Equatable {
        let question: String
        let reason: Reason
    }

    /// The window the counts cover, in days.
    static let windowDays = 60
    /// Answers needed before a question's counts mean anything.
    static let minAnswers = 5
    /// Binary information (4 p (1 - p), 1 at an even split) a question needs to be asked for its own sake: the
    /// share of Yes must sit between about 11 % and 89 %. On the wearer's days "Used marijuana?" was Yes 48 times
    /// of 52 (0.34): nearly settled, so no longer asked every day.
    static let minInformation = 0.4
    /// A question that has gone quiet is asked once more after this many days.
    static let checkInAfterDays = 14
    /// Questions asked at most.
    static let maxAsked = 6
    /// Questions asked because of the day's data alone, at most.
    static let maxCued = 2
    /// A wearer with no question answered often enough to count is asked this many, in list order.
    static let coldStartCount = 4

    /// Recovery under this (WHOOP's red zone ends at 33), or this far under the wearer's usual, is low.
    static let lowRecoveryBelow = 34.0
    static let lowRecoveryGap = 20.0
    /// A night under this many minutes asleep, or under this efficiency, is a poor one.
    static let shortSleepMin = 360.0
    static let poorEfficiency = 0.8
    /// A day at or over this Strain (of 21) is a hard one.
    static let hardStrain21 = 14.0
    /// This many vitals out of range together read as illness signs.
    static let illnessFlags = 2

    /// What the morning's numbers say, for `pick`. Every input is optional: a figure that is not there is not
    /// a cue. `usualRecovery` is the mean of the last 30 mornings before this one, nil with too few.
    static func context(recovery: Double?, usualRecovery: Double?, sleepMin: Double?, efficiency: Double?,
                        strain21: Double?, flaggedVitals: Int) -> DayContext {
        var out = DayContext()
        if let recovery {
            out.lowRecovery = recovery < lowRecoveryBelow || (usualRecovery.map { recovery <= $0 - lowRecoveryGap } ?? false)
        }
        out.poorSleep = (sleepMin.map { $0 < shortSleepMin } ?? false) || (efficiency.map { $0 < poorEfficiency } ?? false)
        out.hardDay = strain21.map { $0 >= hardStrain21 } ?? false
        out.illnessSigns = flaggedVitals >= illnessFlags
        return out
    }

    /// 4 p (1 - p) with a Laplace-smoothed share of Yes, 1 for an even split and near 0 for an answer that never
    /// changes; nil with too few answers to say.
    static func information(_ stats: Stats) -> Double? {
        guard stats.answers >= minAnswers else { return nil }
        let p = (Double(stats.yes) + 1) / (Double(stats.answers) + 2)
        return 4 * p * (1 - p)
    }

    /// 0 to 1: how strongly the day's data points at this question, by what the question is about.
    static func cue(_ question: String, _ context: DayContext) -> Double {
        let q = question.lowercased()
        func has(_ words: String...) -> Bool { words.contains { q.contains($0) } }
        var score = 0.0
        if context.illnessSigns, has("sick", "ill", "unwell", "symptom") { score = max(score, 0.9) }
        if context.lowRecovery {
            if has("alcohol", "drink") { score = max(score, 0.8) }
            if has("bedtime", "late meal", "ate food close", "eat close") { score = max(score, 0.7) }
            if has("caffeine") && has("late", "evening", "afternoon") { score = max(score, 0.7) }
            if has("stress", "anxious", "worried") { score = max(score, 0.6) }
            if has("sick", "ill") { score = max(score, 0.6) }
        }
        if context.poorSleep {
            if (q.contains("screen") && !q.contains("non-screen")) || q.contains("phone") { score = max(score, 0.7) }
            if has("bedtime", "late meal", "ate food close", "eat close") { score = max(score, 0.7) }
            if has("caffeine") && has("late", "evening", "afternoon") { score = max(score, 0.7) }
            if has("alcohol", "drink") { score = max(score, 0.6) }
        }
        // Ranks a question that is already asked; too weak, on its own, to start asking one.
        if context.hardDay, has("protein", "magnesium", "stretch", "massage", "sauna", "hydrat") {
            score = max(score, 0.4)
        }
        return score
    }

    /// What in the morning's data a question is asked because of.
    enum Source: Equatable { case illness, recovery, sleep }

    /// The part of `context` that points hardest at `question`, nil when none does (the first listed wins a tie).
    static func cueSource(_ question: String, _ context: DayContext) -> Source? {
        var best: (source: Source, score: Double)?
        let parts: [(Source, Bool, DayContext)] = [
            (.illness, context.illnessSigns, DayContext(illnessSigns: true)),
            (.recovery, context.lowRecovery, DayContext(lowRecovery: true)),
            (.sleep, context.poorSleep, DayContext(poorSleep: true)),
        ]
        for (source, present, only) in parts where present {
            let score = cue(question, only)
            if score > (best?.score ?? 0) { best = (source, score) }
        }
        return best?.source
    }

    /// What a question is about, so two that ask the same thing ("Have any alcoholic drinks?" from the export and
    /// the starter "Did you drink any alcohol?") are asked once. Nil for a topic with no name here.
    static func topic(_ question: String) -> String? {
        let q = question.lowercased()
        func has(_ words: String...) -> Bool { words.contains { q.contains($0) } }
        if has("alcohol", "drink") { return "alcohol" }
        if has("caffeine") { return "caffeine" }
        if has("bedtime", "late meal", "ate food close", "eat close") { return "lateMeal" }
        if (q.contains("screen") && !q.contains("non-screen")) || q.contains("phone") { return "screen" }
        if has("sick", "unwell") || q.contains(" ill") { return "sick" }
        if has("stress") { return "stress" }
        if has("protein") { return "protein" }
        return nil
    }

    /// The questions to ask, in order, from `candidates` (canonical question strings): pinned first, then those
    /// whose answers are open or that the data points at, best first, then at most one check-in; at most
    /// `maxAsked`. `stats` is keyed by `JournalCatalogStore.norm` of the question.
    static func pick(candidates: [String], stats: [String: Stats], context: DayContext,
                     pinned: Set<String> = []) -> [Pick] {
        func key(_ q: String) -> String { JournalCatalogStore.norm(q) }
        let pinnedKeys = Set(pinned.map(key))
        var scored: [(pick: Pick, score: Double)] = []
        var checkIns: [(question: String, days: Int)] = []
        for q in candidates {
            let s = stats[key(q)] ?? Stats()
            let info = information(s)
            let cueScore = cue(q, context)
            if pinnedKeys.contains(key(q)) {
                scored.append((Pick(question: q, reason: .pinned), 3 + (info ?? 0.5)))
            } else if let info, info >= minInformation {
                scored.append((Pick(question: q, reason: .open), info + cueScore))
            } else if cueScore >= 0.5 {
                scored.append((Pick(question: q, reason: .cue), cueScore))
            } else if let info, info < minInformation, let ago = s.daysSinceAnswered, ago >= checkInAfterDays {
                checkIns.append((q, ago))
            }
        }
        // A new wearer has no counts to go on: ask the first few of the list so the counts can start.
        if !candidates.contains(where: { information(stats[key($0)] ?? Stats()) != nil }) {
            let held = Set(scored.map { key($0.pick.question) })
            var rank = 0
            for q in candidates where !held.contains(key(q)) && rank < coldStartCount {
                scored.append((Pick(question: q, reason: .starter), 0.5 - 0.01 * Double(rank)))
                rank += 1
            }
        }
        // One question a topic: the one the wearer has answers for, else the strongest.
        let rank: [Reason: Int] = [.pinned: 3, .open: 2, .cue: 1, .starter: 1, .checkIn: 0]
        var best: [String: (pick: Pick, score: Double)] = [:]
        for item in scored {
            guard let topic = topic(item.pick.question) else { continue }
            if let held = best[topic],
               (rank[held.pick.reason] ?? 0, held.score) >= (rank[item.pick.reason] ?? 0, item.score) { continue }
            best[topic] = item
        }
        scored = scored.filter { item in
            guard let topic = topic(item.pick.question) else { return true }
            return best[topic]?.pick.question == item.pick.question
        }
        // Questions asked on the data alone are capped, strongest first; the rest wait.
        let cueOnly = scored.filter { $0.pick.reason == .cue }.sorted { $0.score > $1.score }
        let keepCued = Set(cueOnly.prefix(maxCued).map(\.pick.question))
        scored = scored.filter { $0.pick.reason != .cue || keepCued.contains($0.pick.question) }
        var out = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.pick.question < $1.pick.question }
            .map(\.pick)
        if out.count < maxAsked, let oldest = checkIns.max(by: { $0.days < $1.days }) {
            out.append(Pick(question: oldest.question, reason: .checkIn))
        }
        return Array(out.prefix(maxAsked))
    }

    // MARK: - Counts

    /// The counts for one question from the days it was answered Yes and No, over the last `windowDays` before
    /// `today` (a `yyyy-MM-dd` day key), `today` included. Days outside the window, or after today, are not counted.
    static func stats(yesDays: Set<String>, noDays: Set<String>, today: String) -> Stats {
        guard let end = dayNumber(today) else { return Stats() }
        func ago(_ day: String) -> Int? {
            guard let n = dayNumber(day).map({ end - $0 }) else { return nil }
            return n >= 0 && n < windowDays ? n : nil
        }
        let yes = yesDays.compactMap(ago)
        let no = noDays.compactMap(ago)
        return Stats(yes: yes.count, no: no.count, daysSinceAnswered: (yes + no).min())
    }

    /// Days since 1970-01-01 of a `yyyy-MM-dd` key, by arithmetic alone (no calendar, no time zone), nil when the
    /// key is not one.
    static func dayNumber(_ key: String) -> Int? {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let year = m <= 2 ? y - 1 : y
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
    }
}
