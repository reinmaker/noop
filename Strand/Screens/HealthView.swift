import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Health: WHOOP Age and Pace of Aging, the vitals against the wearer's own range, the live heart rate, the
/// stress chart, the skin-temperature cards, the records and the strap's sync. Every vital and every "within
/// range" on this page comes from one rule (`HealthMonitorRule`), the one Home's HEALTH MONITOR card and the
/// Health Monitor screen read too, and WHOOP Age from the one resolver the Coach reads (`WhoopAgeLoader`).
/// The page is built from the WHOOP-style pieces (`WhoopTitledCard`, `WhoopStyle`) Home and the score screens use.
struct HealthView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: HealthView itself does NOT observe `LiveState`/`AppModel`. A connected strap publishes at ~1 Hz;
    // observing here would re-evaluate the whole page on every tick. The leaves that need them
    // (`WhoopLiveHeartRateCard`, `HealthSyncCard`) own them, so a tick re-renders only those cards.

    var body: some View {
        ScreenScaffold(title: "Health",
                       subtitle: "Your vitals against your normal.",
                       onRefresh: { await repo.refresh() },
                       lazy: true,
                       topBackground: liquidScaffoldSky()) {
            if repo.days.isEmpty {
                HealthFirstRunContent()
            } else {
                HealthSectionsStack()
            }
        }
    }
}

// MARK: - Content stacks

/// The page with history: WHOOP Age first, then the vitals, then the rest in the order of how often they are looked at.
private struct HealthSectionsStack: View {
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            WhoopAgeHealthCard()
            WhoopVitalsSection()
            WhoopLiveHeartRateCard(opensMonitor: true)
            WhoopHealthStressSection()
            SkinTempSection()
            HealthRecordsSection()
            HealthSyncCard()
        }
    }
}

/// No history yet: say so, show the live heart rate if the strap is streaming, and keep the sync control reachable.
private struct HealthFirstRunContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            WhoopTitledCard(title: String(localized: "HEALTH MONITOR"), showsChevron: false) {
                Text("No biometrics yet. Import your WHOOP export (and Apple Health if you have it) in Data Sources to fill this in.")
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WhoopLiveHeartRateCard(opensMonitor: true)
            HealthSyncCard()
        }
    }
}

// MARK: - Sync status + "Sync now" (#364)

/// Manual "Sync now" control + honest sync status, mirroring the Android Sync-now button. Its own view
/// depending only on `live` (connection + backfill state) and `model` (the BLE pass-through), so the
/// ~1Hz live HR stream never re-renders the rest of the page. Honesty rules: the button is disabled and the
/// copy explains itself when no strap is connected; while a sync runs it shows the in-progress note + the
/// live chunk count (never a fabricated percent: total pending is unknowable from the protocol); otherwise it
/// shows when history last synced.
private struct HealthSyncCard: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var model: AppModel

    /// The strap link is usable for a manual offload kick (matches BLEManager.syncNow's own gate).
    ///
    /// `historyReady`, not `bonded` alone: the live-HR path sets `bonded` for a 5/MG that has never
    /// completed a handshake, so this enabled itself and beginBackfill then declined it silently.
    private var canSync: Bool { live.connected && live.bonded && live.historyReady && !live.backfilling }

    var body: some View {
        WhoopTitledCard(title: String(localized: "STRAP SYNC"), showsChevron: false) {
            statusRow
            // Reaches the BLE engine's gated entry point directly (same idiom as SettingsView's
            // `model.ble.enableWhoop5DeepData()`); BLEManager.syncNow() is the honest gate: a no-op when no
            // strap is connected or a sync is already running.
            Button { model.ble.syncNow() } label: {
                WhoopActionButtonLabel(title: (live.backfilling ? String(localized: "Syncing…") : String(localized: "Sync now")).uppercased(),
                                       systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .disabled(!canSync)
            .opacity(canSync ? 1 : 0.4)
            .accessibilityLabel("Sync now")
            .accessibilityHint(canSync
                ? "Pulls your strap's stored history immediately, without waiting for the next automatic sync."
                : (live.backfilling ? "A sync is already in progress." : "Connect your strap first."))
            Text(helperText)
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The status line above the button: an in-progress note while syncing (with the live chunk count), else a
    /// last-synced read-out, else an honest "not connected".
    @ViewBuilder private var statusRow: some View {
        if live.backfilling {
            // The shared in-progress affordance, so this matches every other "syncing history" surface.
            SyncingHistoryNote(chunks: live.syncChunksThisSession)
        } else {
            HStack(spacing: NoopMetrics.space2) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(status)
                    .font(WhoopStyle.detail)
                    .foregroundStyle(StrandPalette.textPrimary)
                if live.connected, !live.backfilling, let last = live.lastSyncedAt {
                    Text(relativeAgo(last))
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var dot: Color {
        if !live.connected { return StrandPalette.textTertiary }
        return live.lastSyncedAt != nil || live.historyReady ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber
    }

    private var status: String {
        if !live.connected { return String(localized: "No strap connected") }
        if live.lastSyncedAt != nil { return String(localized: "History synced") }
        // Same condition as the button below it. Keyed on `bonded` this said "Ready to sync" directly above a
        // DISABLED Sync now, on exactly the strap that cannot sync.
        return live.historyReady ? String(localized: "Ready to sync") : String(localized: "Pairing…")
    }

    private var helperText: String {
        if live.backfilling {
            return String(localized: "Pulling your strap's stored history. This drains oldest-first; a deep backlog now continues automatically across passes instead of waiting between syncs.")
        }
        if !live.connected {
            return String(localized: "Connect your strap to sync its stored history. Until then, only imported data shows here.")
        }
        // historyReady, not `bonded`: the same condition as the button and the status, so all three agree.
        if !live.historyReady {
            return String(localized: "Finishing the pairing handshake. Sync now becomes available once the strap is paired.")
        }
        return String(localized: "Syncs your strap's stored history right away, instead of waiting for the next automatic sync.")
    }
}

// MARK: - Illness heads-up, body clock and cycle awareness (v5)

/// The v5 skin-temperature section: the confounder-suppressed illness "heads-up", the body-clock
/// estimate, and the OPT-IN cycle awareness card — each rendered from a pure StrandAnalytics engine
/// result the analytics pass computed and `AppModel` publishes. Honest throughout: the heads-up only
/// shows when the engine returns a non-quiet level; cycle awareness shows the opt-in card until the user
/// turns it on (default OFF); the body clock shows nil-state copy until it can read a rhythm.
private struct SkinTempSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository

    /// The cycle-awareness opt-in (default OFF). The same key AppModel reads, so a flip is consistent.
    @AppStorage(AppModel.cycleAwarenessKey) private var cycleEnabled = false
    /// #hide-cycle: the user's "not for me" opt-out. When set, the cycle opt-in invitation is suppressed
    /// here (the section falls back to the generic skin-temp state); reversible from Automations.
    @AppStorage(AppModel.cycleAwarenessHiddenKey) private var cycleHidden = false
    @State private var cycleTrackerPresented = false

    /// Whether the cycle-awareness opt-in is offered for this profile (#801). Delegates to the shared
    /// ``ProfileStore/cycleAwarenessApplies`` gate so Health + Automations stay in lockstep: cycle phase
    /// is read from the menstrual skin-temperature shift, so the opt-in is NOT shown for male profiles.
    private var cycleOptInApplies: Bool { model.profile.cycleAwarenessApplies && !cycleHidden }

    private var hasCards: Bool {
        (model.illnessSignal.map { $0.level != .quiet } ?? false)
            || model.circadianPhase != nil
            || (cycleEnabled && model.cyclePhase != nil)
            || (!cycleEnabled && cycleOptInApplies)
    }

    var body: some View {
        // No shared heading: the three cards are different signals (the heads-up reads four vitals, the body
        // clock reads the heart-rate rhythm, cycle awareness reads skin temperature), so each carries its own.
        // With none to show the section is absent, not a placeholder.
        if hasCards { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            // 1. Illness heads-up — only when the engine returned something worth surfacing.
            if let illness = model.illnessSignal, illness.level != .quiet {
                HeadsUpCard(result: illness, distance: model.illnessDistance)
            }

            // 2. Body clock — shows nil-state copy via the engine's own confidence handling.
            if let phase = model.circadianPhase {
                BodyClockCard(estimate: phase)
            }

            // 3. Cycle awareness: opt-in, and gated on profile sex (#801). Cycle phase is derived
            // from the menstrual temperature shift, so the opt-in is only offered to profiles it can
            // apply to (female / nonbinary); it is NOT rendered for male profiles. If a profile that
            // previously enabled it later switches to male, we still honour the existing awareness card
            // rather than silently hiding their data; only the OPT-IN invitation is gated.
            if cycleEnabled, let cycle = model.cyclePhase {
                CycleAwarenessCard(result: cycle, curve: model.cycleCurve,
                                   onLogPeriod: {
                                       Task {
                                           await repo.logPeriodStart(day: Repository.localDayKey(Date()))
                                           await model.refreshV5Signals()
                                       }
                                   },
                                   onOpenDetail: { cycleTrackerPresented = true },
                                   // Symmetric off (#801): turn it off in-place, here in Health, where
                                   // it was turned on, not only from Automations.
                                   onTurnOff: {
                                       cycleEnabled = false
                                       model.cycleAwarenessEnabled = false
                                       Task { await model.refreshV5Signals() }
                                   })
            } else if !cycleEnabled && cycleOptInApplies {
                CycleAwarenessOptInCard(onEnable: {
                    cycleEnabled = true
                    model.cycleAwarenessEnabled = true
                    Task { await model.refreshV5Signals() }
                })
            }
        }
        .sheet(isPresented: $cycleTrackerPresented) {
            if let cycle = model.cyclePhase {
                CycleTrackerView(result: cycle, curve: model.cycleCurve)
                    .environmentObject(repo)
                    .environmentObject(model)
            }
        }
    }
}

// MARK: - Records

/// Lab Book and the multi-device fused record: their honest Health home, as two rows. They route via `NavRouter`
/// (the macOS sidebar selects the item; iOS presents the pillar sheet).
private struct HealthRecordsSection: View {
    @EnvironmentObject var router: NavRouter

    var body: some View {
        WhoopTitledCard(title: String(localized: "Records & sources").uppercased(), showsChevron: false) {
            VStack(spacing: 0) {
                row(title: String(localized: "Lab Book"),
                    subtitle: String(localized: "Keep your bloods, BP and body numbers private, on \(Platform.deviceNounPhrase)."),
                    symbol: "books.vertical.fill") { router.openLabBook() }
                Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
                row(title: String(localized: "Your Data, Fused"),
                    subtitle: String(localized: "The best-sourced number per metric across every band you use."),
                    symbol: "square.stack.3d.up.fill") { router.openFusedRecord() }
            }
        }
    }

    private func row(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: symbol)
                    .font(WhoopStyle.icon)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(title).font(WhoopStyle.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(WhoopStyle.detail)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, NoopMetrics.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(subtitle)")
    }
}

/// The Fitness Age not-ready lead: a concrete countdown of nights-of-wear still needed (from the shared
/// `nightsUntilReady`), noting the profile basics only when they're actually missing. File-scope (not a
/// view method) so BOTH the Health hub's `FitnessAgeCard` and the Today card's `MetricDetailView`
/// tap-through render the SAME copy from one source. Kept WORD-FOR-WORD identical to the Android
/// `fitnessReadyLead` so the two platforms match.
func fitnessReadyLeadCopy(rhrDays: Int, hasAge: Bool, hasSex: Bool) -> String {
    let remaining = FitnessAgeEngine.nightsUntilReady(rhrDays: rhrDays)
    let needsBasics = !hasAge || !hasSex
    switch (remaining, needsBasics) {
    case (0, false): return String(localized: "A few more days and we can show your Fitness Age.")
    case (0, true):  return String(localized: "Add your age and sex below and we can show your Fitness Age.")
    case (1, false): return String(localized: "1 more night of wear and we can show your Fitness Age.")
    case (1, true):  return String(localized: "1 more night of wear, plus your age and sex below, and we can show your Fitness Age.")
    case (let n, false): return String(localized: "\(n) more nights of wear and we can show your Fitness Age.")
    case (let n, true):  return String(localized: "\(n) more nights of wear, plus your age and sex below, and we can show your Fitness Age.")
    }
}

/// The symbol a stored Fitness Age needs when it is sitting on a reporting bound (#2173).
///
/// `FitnessAgeEngine` clamps to [minAge, maxAge], so every model output below 20 is stored as
/// exactly 20.0 and every output above 80 as exactly 80.0. A reader cannot tell either from a
/// genuine 20 or 80, and the number looks as exact as every other number on the screen, which is
/// what makes a floored reading read like a sync or scoring fault rather than the end of the scale.
///
/// Decided from the value rather than carried out of the engine, matching the Kotlin twin. The
/// clamp returns the bound constant itself, so equality is exact and needs no tolerance, and
/// deciding here covers the weekly rows already banked, which no flag added today could reach.
/// A reading that is genuinely 20.0 is therefore also called "20 or younger", which is true of it.
/// Saying "<20" would need the unclamped value, and that is gone before anything is stored.
func fitnessAgeBoundSymbol(_ value: Double) -> String {
    if value <= FitnessAgeEngine.minAge { return "≤" }
    if value >= FitnessAgeEngine.maxAge { return "≥" }
    return ""
}
