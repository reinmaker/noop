import SwiftUI
import StrandDesign
import WhoopStore

/// Native journal logging, yes/no chips and numeric fields for the merged behaviour catalog plus a
/// custom-question field, hosted at the top of Insights. Answers write under
/// `Repository.journalDeviceId` ("noop-journal"), NEVER the imported source, so a CSV re-import can't
/// clobber them and clearing is safe (imported rows are never touched). Tri-state: tapping the selected
/// chip again clears the answer.
///
/// Yoop (WHOOP parity): the card shows one behaviour day and asks "What happened yesterday?" about it.
/// `JournalDays` maps that day to its stored row (the morning after, the importer's wake-day
/// convention), so logged days line up with imported history and with the Home journal strip. A day
/// answered in WHOOP shows its imported picks, and "Use previous answers" fills an empty past day from
/// the most recent earlier journal.
///
/// v2 (#322): items sit under collapsible groups (Nutrition / Supplements / …); an item can be a
/// numeric value (with a unit) instead of a toggle; and custom items can be renamed / regrouped /
/// converted / reordered in edit mode. The stored KEY (`canonical`) never changes on a rename, so all
/// history, logged and imported, stays joined under the original question.
struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    /// The journal catalog is single-user state owned here (UserDefaults-backed), so hosting the card
    /// needs no app-level injection.
    @StateObject private var catalog = JournalCatalogStore()

    /// Distinct imported question strings (from InsightsView's load), adopted into the catalog so
    /// logged answers and imported history group under the same behaviour.
    let importedQuestions: [String]
    /// question → answeredYes for the shown day, native rows only (drives the chip state).
    let answers: [String: Bool]
    /// question → numeric value for the shown day, native rows only (drives the numeric fields).
    let numericAnswers: [String: Double]
    /// The shown day's imported WHOOP answers, keyed by `JournalDays.questionKey`. A question with no
    /// in-app answer shows its WHOOP pick, so a day answered in WHOOP reads as answered here too.
    let importedAnswers: [String: Bool]
    /// The most recent earlier journal's rows: what "Use previous answers" copies onto an empty day.
    let previousAnswers: [JournalEntry]
    /// The stored day key the inputs above were read for. A prefill waits until it matches the shown
    /// day, so switching days can never copy answers onto a day whose own answers have not loaded yet.
    let loadedDayKey: String
    @Binding var dayOffset: Int            // `JournalDays` offset: 0 = today, 1 = yesterday, up to 7
    let onChanged: () -> Void              // parent re-runs load() after a write

    init(importedQuestions: [String], answers: [String: Bool],
         numericAnswers: [String: Double] = [:], importedAnswers: [String: Bool] = [:],
         previousAnswers: [JournalEntry] = [], loadedDayKey: String = "",
         dayOffset: Binding<Int>, onChanged: @escaping () -> Void) {
        self.importedQuestions = importedQuestions
        self.answers = answers
        self.numericAnswers = numericAnswers
        self.importedAnswers = importedAnswers
        self.previousAnswers = previousAnswers
        self.loadedDayKey = loadedDayKey
        self._dayOffset = dayOffset
        self.onChanged = onChanged
    }

    @State private var customDraft = ""
    @State private var customIsNumeric = false
    @State private var customGroup: JournalGroup = .other
    /// Edit mode: swaps the answer controls for rename/group/convert/remove and reveals hidden items.
    @State private var editing = false
    /// Collapsed groups (persisted per group).
    @AppStorage("journal.collapsedGroups") private var collapsedGroupsRaw = ""
    /// The item being renamed (drives the rename sheet).
    @State private var renaming: JournalCatalogItem?
    @State private var renameDraft = ""
    /// "Use previous answers" (WHOOP's toggle, on by default): an empty past day is filled from the most
    /// recent earlier journal, so only what was different needs a tap.
    @AppStorage("journal.usePreviousAnswers") private var usePreviousAnswers = true
    /// Stored day keys "Use previous answers" has already filled, oldest first and capped, so a day the
    /// user empties afterwards is never filled again behind their back.
    @AppStorage("journal.prefilledDays") private var prefilledDaysRaw = ""
    /// Which field has the keyboard: a numeric item's canonical question, or `Self.customFieldFocus`.
    /// One focus for the whole card, so the single keyboard Done button resigns any of its fields.
    @FocusState private var focusedField: String?
    /// What has been typed into a numeric field, held until the field loses focus. The decimal pad has
    /// no Return key, so saving only on submit lost every typed number; leaving the field now saves it.
    @State private var numericDrafts: [String: String] = [:]

    /// Focus tag for the custom-item text field. Starts with a control character, so it is never a question.
    private static let customFieldFocus = "\u{0}custom"
    /// How many filled days `prefilledDaysRaw` remembers, well past the picker's one-week reach.
    private static let prefilledDaysKept = 30

    /// The logical (04:00) today the shown day counts back from: the same clock the Home strip uses.
    private var logicalToday: Date { Repository.logicalDay(Date()) }

    /// The stored row key for the shown day, through the one journal day model (`JournalDays`).
    private var dayKey: String {
        JournalDays.storageKey(offset: dayOffset, logicalToday: logicalToday)
    }

    /// WHOOP's question line for the shown day: "What happened yesterday?", "What happened today?" when
    /// logging ahead, otherwise the dated form ("What happened on Friday, October 9?").
    private var dayQuestion: String {
        switch dayOffset {
        case 0: return String(localized: "What happened today?")
        case 1: return String(localized: "What happened yesterday?")
        default:
            let day = JournalDays.behaviourDay(offset: dayOffset, logicalToday: logicalToday)
            let dayText = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
            return String(localized: "What happened on \(dayText)?")
        }
    }

    /// No answer of any kind on the shown day: no in-app answer (a saved Coach note aside), no number
    /// and no imported WHOOP pick. Only such a day is ever filled from previous answers.
    private var dayIsEmpty: Bool {
        !answers.keys.contains { $0 != JournalDays.coachAdviceQuestion }
            && numericAnswers.isEmpty && importedAnswers.isEmpty
    }

    /// The resolved, grouped catalog for the current imported set. Hidden items included only while
    /// editing (so they can be restored in place).
    private var resolved: [JournalCatalogItem] {
        catalog.resolvedItems(imported: importedQuestions, includeHidden: editing)
    }

    /// Items grouped by their group, each group ordered by sortIndex then display.
    private func items(in group: JournalGroup) -> [JournalCatalogItem] {
        resolved.filter { $0.group == group }
            .sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    private func toggleCollapsed(_ group: JournalGroup) {
        var set = collapsedGroups
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedGroupsRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .center) {
                SectionHeader("Journal", overline: "Log")
                Spacer()
                if editing {
                    pillButton("Done", selected: true) { editing = false }
                } else {
                    pillButton("Edit", selected: false) { editing = true }
                }
            }
            // Day picker (#656): a bounded, scrollable range, today back through the last 7 days, so any
            // recent day can be backfilled. Chronological left→right; snaps to the selected day, so a
            // deep-link from the Home strip or the Today journal widget lands on that day's pill. Only
            // when not editing.
            if !editing {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.journalDayOffsets, id: \.self) { off in
                                dayPill(Self.dayLabel(off), offset: off).id(off)
                            }
                        }
                        .padding(.horizontal, 1)   // don't clip the selected pill's ring
                    }
                    // Defer the initial scroll a tick: scrollTo in onAppear can no-op before the pills lay
                    // out, which would leave the picker on the oldest day instead of the selected one.
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo(dayOffset, anchor: .center) } }
                    // onChangeCompat, not onChange: the zero/two-arg onChange is macOS 14+, and this card
                    // is shared with the macOS 13 target.
                    .onChangeCompat(of: dayOffset) { _ in proxy.scrollTo(dayOffset, anchor: .center) }
                }
            }
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    if editing {
                        Text("Rename, regroup, or remove an item to tidy your list. Renaming keeps the original question behind the scenes, so a WHOOP import still lines up. Custom items are deleted; built-in ones are hidden and can be restored below.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        dayHeader
                    }

                    ForEach(JournalGroup.displayOrder, id: \.self) { group in
                        groupBlock(group)
                    }

                    Divider().overlay(StrandPalette.hairline)
                    addRow
                }
            }
        }
        .sheet(item: $renaming) { item in renameSheet(item) }
        // One Done button on the keyboard for every field in the card (the decimal pad has no Return).
        .keyboardDoneToolbar($focusedField)
        // Leaving a numeric field, by Done or by tapping elsewhere, saves what was typed into it.
        .onChangeCompat(of: focusedField) { now in commitNumericDrafts(except: now) }
        // A reload brings the saved values in: drop the drafts it caught up with, not the one being typed.
        .onChangeCompat(of: numericAnswers) { _ in
            numericDrafts = numericDrafts.filter { $0.key == focusedField }
        }
        .onDisappear { commitNumericDrafts(except: nil) }
        // "Use previous answers": fill an empty past day once its own answers have loaded.
        .task(id: PrefillTrigger(day: dayKey, loadedDay: loadedDayKey,
                                 previousDay: previousAnswers.first?.day ?? "", empty: dayIsEmpty)) {
            prefillFromPreviousIfNeeded(force: false)
        }
        // Turning the toggle on fills the day on screen straight away, if it is still empty.
        .onChangeCompat(of: usePreviousAnswers) { on in
            if on { prefillFromPreviousIfNeeded(force: true) }
        }
    }

    // MARK: - Day header

    /// The shown day's question, the "Use previous answers" toggle (past days only, logging ahead has
    /// nothing earlier to copy), and how the answers are attributed.
    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(dayQuestion)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if dayOffset >= 1 {
                Toggle(isOn: $usePreviousAnswers) {
                    Text("Use previous answers")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.restColor)
            }
            Text("Your answers count toward the next morning's recovery, the same way a WHOOP export lines them up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Use previous answers

    /// Copy the most recent earlier journal onto the shown past day when that day has no answer yet,
    /// saving the copied answers at once (there is no Save button; every answer saves as it is set), so
    /// the user only changes what was different. A day is filled once; `force` (the toggle was just
    /// turned on) fills it again if it is empty. A day with any answer, in-app or WHOOP, is never touched.
    private func prefillFromPreviousIfNeeded(force: Bool) {
        let day = dayKey
        guard usePreviousAnswers, dayOffset >= 1, loadedDayKey == day, dayIsEmpty,
              !previousAnswers.isEmpty else { return }
        var filled = prefilledDaysRaw.split(separator: ",").map(String.init)
        guard force || !filled.contains(day) else { return }
        let items = catalog.resolvedItems(imported: importedQuestions)
            .map { (canonical: $0.canonical, isNumeric: $0.kind.isNumeric) }
        let plan = JournalDays.prefillPlan(items: items, previous: previousAnswers)
        guard !plan.isEmpty else { return }
        filled.removeAll { $0 == day }
        filled.append(day)
        prefilledDaysRaw = filled.suffix(Self.prefilledDaysKept).joined(separator: ",")
        let entries = plan.map {
            JournalEntry(day: day, question: $0.question, answeredYes: $0.answeredYes, notes: nil,
                         numericValue: $0.value)
        }
        Task {
            await repo.saveJournalEntries(entries)
            onChanged()
        }
    }

    // MARK: - Group block

    @ViewBuilder private func groupBlock(_ group: JournalGroup) -> some View {
        let groupItems = items(in: group)
        // Empty groups hidden outside edit mode; in edit mode all six show so items can be moved in.
        if !groupItems.isEmpty || editing {
            let collapsed = collapsedGroups.contains(group.rawValue)
            VStack(alignment: .leading, spacing: 8) {
                Button { toggleCollapsed(group) } label: {
                    HStack(spacing: 6) {
                        Text(group.title.uppercased())
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("\(groupItems.count)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(groupItems.count) items, \(collapsed ? "collapsed" : "expanded")")

                if !collapsed {
                    ForEach(groupItems) { item in itemRow(item) }
                }
            }
        }
    }

    // MARK: - Item row

    @ViewBuilder private func itemRow(_ item: JournalCatalogItem) -> some View {
        HStack {
            Text(verbatim: item.display)   // display = rename ?? canonical; data, not a UI literal
                .font(StrandFont.body)
                .foregroundStyle(item.hidden ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Spacer()
            if editing {
                editControls(item)
            } else if item.kind.isNumeric {
                numericField(item)
            } else {
                answerPill("Yes", q: item.canonical, value: true)
                answerPill("No", q: item.canonical, value: false)
            }
        }
    }

    // MARK: - Numeric field

    private func numericField(_ item: JournalCatalogItem) -> some View {
        let q = item.canonical
        let current = numericAnswers[q]
        return HStack(spacing: 6) {
            stepperButton("minus", q: q, current: current)
            NumericLogField(
                text: numericText(q),
                placeholder: "—",
                focus: $focusedField, id: q,
                onSubmit: { submitNumericDraft(q) })
            .frame(width: 64)
            if let unit = item.kind.unitLabel, !unit.isEmpty {
                Text(verbatim: unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            stepperButton("plus", q: q, current: current)
            if current != nil {
                Button {
                    numericDrafts[q] = nil
                    let day = dayKey
                    Task { await repo.clearJournalAnswer(day: day, question: q); onChanged() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(item.display)")
            }
        }
    }

    private func stepperButton(_ symbol: String, q: String, current: Double?) -> some View {
        Button {
            // Step from what is typed if there is a number in the field, else from the saved value.
            let base = draftValue(q) ?? current ?? 0
            let next = max(0, symbol == "plus" ? base + 1 : base - 1)
            numericDrafts[q] = nil
            commitNumeric(q, value: next)
        } label: {
            Image(systemName: "\(symbol).circle")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }

    private func commitNumeric(_ q: String, value: Double) {
        let day = dayKey   // read now: a day switch right after this tap must not move the write
        Task {
            await repo.saveJournalNumeric(day: day, question: q, value: value)
            onChanged()
        }
    }

    /// The text a numeric field shows: what is being typed, else the saved value.
    private func numericText(_ q: String) -> Binding<String> {
        Binding(get: { numericDrafts[q] ?? numericAnswers[q].map(Self.formatNumeric) ?? "" },
                set: { numericDrafts[q] = $0 })
    }

    /// A typed draft read as a number (a decimal comma is accepted), or nil when it is not one.
    private func draftValue(_ q: String) -> Double? {
        guard let text = numericDrafts[q] else { return nil }
        return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// Save the number typed into one field (Return on a hardware keyboard, or the field losing focus).
    /// An unchanged value is not written again. Returns whether a save was started.
    @discardableResult
    private func submitNumericDraft(_ q: String) -> Bool {
        guard let value = draftValue(q), value != numericAnswers[q] else { return false }
        commitNumeric(q, value: value)
        return true
    }

    /// Save every typed number except the field still being edited. A saved draft stays on screen until
    /// the reload brings its value in (no blank flash); a draft that is not a new number is dropped. Runs
    /// when focus moves (the keyboard's Done included), before a day switch, and when the card goes away.
    private func commitNumericDrafts(except focused: String?) {
        var kept: [String: String] = [:]
        for (q, text) in numericDrafts {
            if q == focused || submitNumericDraft(q) { kept[q] = text }
        }
        numericDrafts = kept
    }

    private static func formatNumeric(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    // MARK: - Edit-mode controls

    private func editControls(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 10) {
            if item.hidden {
                pillButton("Restore", selected: false) { catalog.restore(item.canonical) }
            } else {
                Menu {
                    Button("Rename…") { startRename(item) }
                    Menu("Group") {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Button(g.title) { catalog.setGroup(item.canonical, to: g) }
                        }
                    }
                    if item.kind.isNumeric {
                        Button("Change to Yes/No") { catalog.setKind(item.canonical, to: .bool) }
                    } else {
                        Button("Change to Number") { catalog.setKind(item.canonical, to: .numeric(unitLabel: nil)) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Edit \(item.display)")

                removeButton(item)
            }
        }
    }

    /// Edit-mode control: delete a custom question / hide a built-in one. Tinted red to read as removal.
    private func removeButton(_ item: JournalCatalogItem) -> some View {
        Button { catalog.remove(item.canonical) } label: {
            Image(systemName: "minus.circle.fill")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.statusCritical)
        }
        .buttonStyle(.plain)
        .help(item.custom ? "Delete this custom item" : "Hide this item")
        .accessibilityLabel(item.custom ? "Delete \(item.display)" : "Hide \(item.display)")
    }

    // MARK: - Rename sheet

    private func startRename(_ item: JournalCatalogItem) {
        renameDraft = item.displayName ?? item.canonical
        renaming = item
    }

    private func renameSheet(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Rename item").font(StrandFont.headline)
            TextField("Display name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            Text("History stays under the original question so WHOOP imports still line up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    catalog.rename(item.canonical, to: renameDraft)
                    renaming = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(NoopMetrics.space4)
        .frame(minWidth: 320)
    }

    // MARK: - Add row

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a custom item…", text: $customDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: Self.customFieldFocus)
                pillButton(customIsNumeric ? "Number" : "Yes/No", selected: customIsNumeric) {
                    customIsNumeric.toggle()
                }
                Button("Add") {
                    let t = customDraft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    catalog.addCustom(t,
                                      kind: customIsNumeric ? .numeric(unitLabel: nil) : .bool,
                                      group: customGroup)
                    customDraft = ""
                }
                .buttonStyle(.bordered)
                .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Group", selection: $customGroup) {
                ForEach(JournalGroup.displayOrder, id: \.self) { g in
                    Text(g.title).tag(g)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("New item group")
        }
    }

    // MARK: - Controls

    private func dayPill(_ label: LocalizedStringKey, offset: Int) -> some View {
        pillButton(label, selected: dayOffset == offset) {
            // Save anything typed on the day being left, then clear the fields for the day being opened.
            commitNumericDrafts(except: nil)
            numericDrafts = [:]
            focusedField = nil
            dayOffset = offset
            onChanged()   // reload the selected day's answers
        }
    }

    /// The bounded day-picker range (#656): today plus the 7 prior days, as `JournalDays` offsets,
    /// chronological oldest → newest left-to-right. Bounded on purpose: journal answers feed the
    /// correlation engine, so unbounded backfill of stale days would distort it (matches WHOOP's limited
    /// retroactive window). Same stored rows as before: today's pill is the old "Tomorrow" row.
    private static let journalDayOffsets: [Int] = Array((0...JournalDays.maxOffset).reversed())

    /// Short label for a `JournalDays` offset, shared with the Home journal strip. "%lld days ago" is a
    /// String Catalog key, so 2 to 7 stay localized just like the twin "%lld nights ago" (#527/#656).
    static func dayLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func answerPill(_ label: LocalizedStringKey, q: String, value: Bool) -> some View {
        let native = answers[q]
        // No in-app answer yet: show the day's imported WHOOP pick for the same question.
        let shown = native ?? importedAnswers[JournalDays.questionKey(q)]
        let selected = shown == value
        return pillButton(label, selected: selected) {
            let day = dayKey
            Task {
                // Tri-state: re-tapping the filled chip clears the in-app answer (natural-key delete,
                // scoped to "noop-journal", imported rows can never be removed this way). A chip filled
                // only by a WHOOP pick is saved in-app instead, so it becomes editable here.
                if selected, native != nil {
                    await repo.clearJournalAnswer(day: day, question: q)
                } else {
                    await repo.saveJournalAnswer(day: day, question: q, answeredYes: value)
                }
                onChanged()
            }
        }
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.restColor : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.restColor : StrandPalette.hairline,
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A compact numeric log field: shows the typed text or the saved value (both owned by the card) with a
/// ghost placeholder. The card saves on Return and whenever the field loses focus, the keyboard's Done
/// included. Kept small so the numeric row reads like the yes/no pills.
private struct NumericLogField: View {
    @Binding var text: String
    let placeholder: String
    let focus: FocusState<String?>.Binding
    let id: String
    let onSubmit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(StrandFont.number(15))
            .focused(focus, equals: id)
            .onSubmit(onSubmit)
            .numericKeyboard()
    }
}

/// `.task(id:)` key for "Use previous answers": re-checked whenever the shown day, the day its answers
/// were read for, the earlier journal it would copy, or whether the day is empty changes.
private struct PrefillTrigger: Equatable {
    let day: String
    let loadedDay: String
    let previousDay: String
    let empty: Bool
}
