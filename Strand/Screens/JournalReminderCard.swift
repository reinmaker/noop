import SwiftUI
import StrandDesign

// MARK: - Journal widget (Today screen) — #627
//
// A persistent Today widget for the Journal: a WHOOP-style strip of the last `JournalDays.stripCount`
// journal days (filled = that day's journal is answered, the day the journal would open on ringed) plus an
// always-present tap-through to the journal.
// The Journal (behavioural logging that feeds Insights / "What Moves You") is otherwise only reachable
// inside the Insights screen, which isn't a primary destination — easy to forget, and the only proactive
// prompt is the once-a-morning sleep sheet — missed on any day you don't open Sleep. This surfaces it on
// Today where it can't be missed, and doubles as the "direct link to Insights" the report (#627) asked for.
//
// Opt-out via `PuffinExperiment.journalReminderKey` (default ON — the same key also gates the Android
// morning sleep sheet twin). Read-only: it never writes a journal entry. Twin of Android
// `JournalReminderCard` (android/.../ui/JournalReminder.kt). Design-Reset compliant — a flat accent-tinted
// NoopCard, NoopMetrics / StrandPalette / StrandFont tokens, matching the other Today cards.

struct JournalReminderCard: View {

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter

    /// Default ON so the reminder works out of the box; the Settings toggle / this key opt out.
    @AppStorage(PuffinExperiment.journalReminderKey) private var reminderEnabled = true

    /// Which stored day keys across the strip carry a journal answer, imported WHOOP or in-app (the same
    /// read as the Home journal strip). nil = still loading / read error → render nothing (never a
    /// misleading all-empty strip).
    @State private var loggedDays: Set<String>?

    var body: some View {
        Group {
            if reminderEnabled, let logged = loggedDays {
                card(logged)
            }
        }
        // Re-read whenever a sync bumps refreshSeq, a journal answer is saved or cleared, the logical day
        // rolls, or the toggle flips (mirrors AutoWorkoutCard's task id), so the strip and the "logged
        // today" state are current the moment the user answers.
        .task(id: JournalReminderLoadKey(seq: repo.refreshSeq, journalSeq: repo.journalSeq,
                                         day: Repository.logicalDayKey(Date()), enabled: reminderEnabled)) {
            await reload()
        }
    }

    private func card(_ logged: Set<String>) -> some View {
        // Bars are journal days (`JournalDays` offsets, six days ago → today): a filled bar means "What
        // happened on that day?" is answered. This morning's journal is yesterday's, as in WHOOP.
        let logicalToday = Repository.logicalDay(Date())
        let offsets = Array((0..<JournalDays.stripCount).reversed())
        let isLogged: (Int) -> Bool = {
            logged.contains(JournalDays.storageKey(offset: $0, logicalToday: logicalToday))
        }
        let due = JournalDays.dueOffset(answered: logged, logicalToday: logicalToday)
        let todayLogged = isLogged(1)
        // A recent PAST day with no entry: surfaces the tap-a-bar-to-backfill interaction once this
        // morning's journal is done (#656). Accent while anything is actionable; calm secondary once
        // fully caught up.
        let hasMissed = (2..<JournalDays.stripCount).contains { !isLogged($0) }
        let subtitle: String = !todayLogged ? String(localized: "Log today's journal")
            : hasMissed ? String(localized: "Tap a day to catch up")
            : String(localized: "Logged today")
        // No outer Button: each bar is its own tap target that deep-links the journal to THAT day (#656),
        // and nested SwiftUI buttons don't work — so header + subtitle carry their own onTapGesture (→
        // the day WHOOP would ask about) and the bars carry theirs. The regions are non-overlapping in the
        // VStack, so a tap lands on exactly one, and a bar's day always wins.
        return NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(String(localized: "Journal"))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .onTapGesture { router.openJournal(day: due) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(String(localized: "Journal")))
                .accessibilityHint(Text(String(localized: "Open journal")))
                // The last-N-days strip: one equal-width bar per day, each its own tap target. Filled =
                // logged; the day the journal would open on is ringed. Tapping a bar deep-links the
                // journal to that day (#656).
                HStack(spacing: 6) {
                    ForEach(offsets, id: \.self) { off in
                        let barLogged = isLogged(off)
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)                    // taller invisible tap target
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(barLogged ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.22))
                                    .frame(height: 10)
                                    .overlay {
                                        if off == due, !barLogged {
                                            RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(StrandPalette.accent, lineWidth: 1)
                                        }
                                    }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { router.openJournal(day: off) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(Self.barLabel(off))
                    }
                }
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle((!todayLogged || hasMissed) ? StrandPalette.accent : StrandPalette.textSecondary)
                    .contentShape(Rectangle())
                    .onTapGesture { router.openJournal(day: due) }
                    .accessibilityAddTraits(.isButton)   // it opens the journal — announce it as one
            }
        }
    }

    /// Screen-reader label for a strip bar (#656): the journal day it deep-links to. Twin of
    /// JournalLogCard's day-picker labels; "%lld days ago" is a String Catalog key so it stays localized.
    private static func barLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    /// Reads which strip days are answered, through the same funnel and day model as the Home strip
    /// (civil-day arithmetic via Calendar inside `JournalDays`, so a DST edge can't mislabel a day).
    private func reload() async {
        guard reminderEnabled else { loggedDays = nil; return }
        let logicalToday = Repository.logicalDay(Date())
        loggedDays = await repo.journalAnsweredDays(
            from: JournalDays.storageKey(offset: JournalDays.stripCount - 1, logicalToday: logicalToday),
            to: JournalDays.storageKey(offset: 0, logicalToday: logicalToday))
    }
}

/// Reload key: a sync (seq), a journal save or clear, a logical-day rollover or a toggle flip re-reads
/// completion. Mirrors `AutoWorkoutLoadKey`.
private struct JournalReminderLoadKey: Equatable {
    let seq: Int
    let journalSeq: Int
    let day: String
    let enabled: Bool
}
