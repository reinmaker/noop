import SwiftUI
import StrandDesign

// WHOOP-style fork: WHOOP Age and Pace of Aging, the Health tab's headline. The figures are `WhoopAgeSnapshot`'s
// (`WhoopAgeLoader`), the same ones the Coach reads; nothing on this page computes a number of its own. It is
// Yoop's estimate on the method WHOOP published, calibrated against one WHOOP readout, and says so in the note at the foot.

// MARK: - Wording

/// The texts a contributor row states, kept apart from the views so they can be tested.
enum WhoopAgeText {
    static func label(_ key: WhoopAge.Key) -> String {
        switch key {
        case .sleepDuration: return String(localized: "SLEEP DURATION")
        case .sleepConsistency: return String(localized: "SLEEP CONSISTENCY")
        case .steps: return String(localized: "STEPS")
        case .zones13: return String(localized: "HEART RATE ZONES 1-3")
        case .zones45: return String(localized: "HEART RATE ZONES 4-5")
        case .strength: return String(localized: "STRENGTH ACTIVITY")
        case .vo2max: return String(localized: "VO₂ MAX")
        case .restingHr: return String(localized: "RESTING HEART RATE")
        case .leanBodyMass: return String(localized: "LEAN BODY MASS")
        }
    }

    static func icon(_ key: WhoopAge.Key) -> String {
        switch key {
        case .sleepDuration: return "bed.double"
        case .sleepConsistency: return "clock.arrow.2.circlepath"
        case .steps: return "shoeprints.fill"
        case .zones13: return "figure.run"
        case .zones45: return "bolt.heart"
        case .strength: return "dumbbell"
        case .vo2max: return "lungs"
        case .restingHr: return "heart"
        case .leanBodyMass: return "scalemass"
        }
    }

    /// A value as the row prints it.
    static func value(_ key: WhoopAge.Key, _ v: Double) -> String {
        switch key {
        case .sleepDuration: return String(localized: "\(String(format: "%.1f", v)) hrs")
        case .sleepConsistency, .leanBodyMass: return "\(Int(v.rounded()))%"
        case .steps: return String(localized: "\(Int(v.rounded()).formatted()) a day")
        case .zones13, .zones45, .strength: return String(localized: "\(Int(v.rounded()).formatted()) min a week")
        case .vo2max: return "\(Int(v.rounded())) ml/kg/min"
        case .restingHr: return "\(Int(v.rounded())) bpm"
        }
    }

    /// The target as the row prints it: what adds nothing.
    static func target(_ key: WhoopAge.Key, _ t: Double) -> String {
        switch key {
        case .sleepDuration: return String(localized: "7 to 9 hrs")
        case .restingHr: return String(localized: "\(Int(t.rounded())) bpm or lower")
        case .leanBodyMass:
            let percent = "\(Int(t.rounded()))%"
            return String(localized: "\(percent) or more")
        default: return value(key, t)
        }
    }

    /// Years as printed: "-0.6 YRS" younger, "+0.4 YRS" older.
    static func years(_ y: Double) -> String {
        if abs(y) < 0.05 { return String(localized: "0.0 YRS") }
        return String(localized: "\(String(format: "%+.1f", y)) YRS")
    }

    /// What a lever asks for, with its amount rounded to a number a person can act on.
    static func lever(_ lever: WhoopAge.Lever) -> String {
        func rounded(_ v: Double, to step: Double) -> String { Int((max(v, step) / step).rounded() * step).formatted() }
        switch lever.key {
        case .steps: return String(localized: "About \(rounded(lever.amount, to: 100)) more steps a day")
        case .zones13: return String(localized: "About \(rounded(lever.amount, to: 5)) more minutes a week in heart rate zones 1 to 3")
        case .zones45: return String(localized: "About \(rounded(lever.amount, to: 5)) more minutes a week in heart rate zones 4 to 5")
        case .strength: return String(localized: "About \(rounded(lever.amount, to: 5)) more minutes a week of strength activity")
        case .sleepDuration: return String(localized: "About \(String(format: "%.1f", lever.amount)) more hours of sleep a night")
        case .sleepConsistency: return String(localized: "About \(Int(lever.amount.rounded())) points more sleep consistency")
        case .vo2max: return String(localized: "VO₂ max up by about \(Int(lever.amount.rounded()))")
        case .restingHr: return String(localized: "Resting heart rate down by about \(Int(lever.amount.rounded())) bpm")
        case .leanBodyMass: return label(.leanBodyMass)
        }
    }

    static func paceWord(_ state: WhoopAge.PaceState) -> String {
        switch state {
        case .reversing: return String(localized: "REVERSING")
        case .slowing: return String(localized: "SLOWING")
        case .steady: return String(localized: "STEADY")
        case .accelerated: return String(localized: "ACCELERATED")
        }
    }

    static func paceSentence(_ state: WhoopAge.PaceState) -> String {
        switch state {
        case .reversing:
            return String(localized: "The last 30 days are much healthier than the last 6 months. Kept up for 6 months, your WHOOP Age would fall.")
        case .slowing:
            return String(localized: "Kept up for 6 months, your WHOOP Age would still rise, but more slowly than the calendar.")
        case .steady:
            return String(localized: "The last 30 days look like the last 6 months. Your WHOOP Age would rise as fast as the calendar.")
        case .accelerated:
            return String(localized: "The last 30 days are less healthy than the last 6 months. Kept up for 6 months, your WHOOP Age would rise faster than the calendar.")
        }
    }

    /// A Pace of Aging figure, "0.6x"; "--" without one.
    static func paceNumber(_ pace: Double?) -> String { pace.map { String(format: "%.1fx", $0) } ?? "--" }

    /// The two ends of the Pace of Aging scale.
    static let paceScaleMin = String(format: "%.1fx", WhoopAge.paceRange.lowerBound)
    static let paceScaleMax = String(format: "%.1fx", WhoopAge.paceRange.upperBound)

    /// A range "38 to 50", whole numbers.
    static func vo2Range(_ vo2: Vo2Choice) -> String {
        let low = String(Int(vo2.low.rounded())), high = String(Int(vo2.high.rounded()))
        return String(localized: "\(low) to \(high)")
    }

    /// The range with its unit, "38 to 50 ml/kg/min".
    static func vo2RangeWithUnit(_ vo2: Vo2Choice) -> String { vo2Range(vo2) + " ml/kg/min" }

    /// The years at the two ends of the VO2 max range, "Between +0.2 and -3.0 YRS".
    static func yearsBetween(older: Double, younger: Double) -> String {
        let a = String(format: "%+.1f", older), b = String(format: "%+.1f", younger)
        return String(localized: "Between \(a) and \(b) YRS")
    }

    /// The calendar age under the bubble, to a tenth as WHOOP counts it; marked while the birth date is a guess.
    static func calendarAge(_ age: Double, isExact: Bool) -> String {
        let shown = String(format: "%.1f", age)
        return isExact ? String(localized: "CALENDAR AGE \(shown)") : String(localized: "CALENDAR AGE \(shown) (ESTIMATED)")
    }

    /// The reading typed in from the WHOOP app, as the row names it: "WHOOP app (12 Oct)".
    static func whoopAppLabel(day: String) -> String {
        let date = WhoopDayFigures.date(of: day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day
        return String(localized: "WHOOP app (\(date))")
    }

    /// The gap to the calendar age, as the bubble prints it.
    static func delta(yearsYounger: Double) -> String {
        if abs(yearsYounger) < 0.5 { return String(localized: "ON TRACK") }
        let shown = String(format: "%.1f", abs(yearsYounger))
        return yearsYounger > 0 ? String(localized: "\(shown) YEARS YOUNGER") : String(localized: "\(shown) YEARS OLDER")
    }
}

// MARK: - The caption

/// The line under the bubble: calendar age, typical error and the unlock count while calibrating.
struct WhoopAgeCaption: View {
    let snapshot: WhoopAgeSnapshot?
    /// Age in years and fractions of a year (`ProfileStore.decimalAge`); 0 or less when none is held.
    let calendarAge: Double
    /// False while the birth date has not been entered and the age is a stand-in.
    var ageIsExact = true

    var body: some View {
        VStack(spacing: NoopMetrics.space1) {
            if let snapshot {
                if snapshot.isUnlocked, let result = snapshot.result {
                    Text(WhoopAgeText.calendarAge(calendarAge, isExact: ageIsExact))
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textSecondary)
                    let low = String(format: "%.1f", result.whoopAge - result.whoopAgeSigma)
                    let high = String(format: "%.1f", result.whoopAge + result.whoopAgeSigma)
                    Text("LIKELY RANGE \(low) TO \(high)")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else if calendarAge <= 0 {
                    Text("Add your age in Settings to see your WHOOP Age.")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("WHOOP Age needs \(WhoopAge.unlockRecoveries) recoveries in 31 days. You have \(snapshot.coverage.recoveriesInLast31Days).")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

// MARK: - The page

/// The screen: loads the snapshot, hands it to the page.
struct WhoopAgeScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var snapshot: WhoopAgeSnapshot?
    @State private var lastWeekPace: Double?
    @State private var showSettings = false
    @State private var showBirthDate = false

    var body: some View {
        WhoopAgePage(snapshot: snapshot, lastWeekPace: lastWeekPace, calendarAge: profile.decimalAge,
                     ageIsExact: profile.dateOfBirthIsEntered,
                     onAddWaist: profile.waistCm > 0 ? nil : { showSettings = true },
                     onOpenSettings: { showSettings = true },
                     onAddBirthDate: profile.dateOfBirthIsEntered ? nil : { showBirthDate = true })
            // A new birth date, like a new refresh, reads the window again.
            .task(id: "\(repo.refreshSeq)|\(profile.dateOfBirth.timeIntervalSince1970)|\(profile.dateOfBirthIsEntered)") {
                snapshot = await WhoopAgeLoader.load(repo: repo, age: profile.decimalAge,
                                                     ageSigma: profile.dateOfBirthIsEntered ? 0 : ProfileStore.unknownBirthdayFractionSigma,
                                                     sex: profile.sex)
                lastWeekPace = await WhoopAgeLoader.paceLastWeek(
                    repo: repo, age: profile.decimalAge,
                    ageSigma: profile.dateOfBirthIsEntered ? 0 : ProfileStore.unknownBirthdayFractionSigma, sex: profile.sex)
            }
            // The profile card, where the waist and a WHOOP app VO2 max are entered; the estimate is read again when
            // it is closed.
            .sheet(isPresented: $showSettings, onDismiss: { Task { await repo.refresh() } }) {
                NavigationStack { SettingsView() }
                    #if os(macOS)
                    .frame(width: 900, height: 820)
                    #endif
            }
            .sheet(isPresented: $showBirthDate) { WhoopBirthDateSheet() }
    }
}

/// Picks the birth date without leaving the WHOOP Age page: the same field as Settings, saved on this device.
struct WhoopBirthDateSheet: View {
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var picked = ProfileStore.dateOfBirth(forAge: 35)

    var body: some View {
        NavigationStack {
            VStack(spacing: NoopMetrics.space4) {
                Text("Your birth date lets Yoop count your age to a tenth of a year, as WHOOP does. It stays on this device.")
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DatePicker("Date of birth", selection: $picked, in: ProfileStore.dateOfBirthRange,
                           displayedComponents: .date)
                    .labelsHidden()
                    #if os(iOS)
                    .datePickerStyle(.wheel)
                    #else
                    .datePickerStyle(.graphical)
                    #endif
                    .tint(StrandPalette.accent)
                Button {
                    profile.dateOfBirth = picked
                    dismiss()
                } label: {
                    WhoopActionButtonLabel(title: String(localized: "SAVE BIRTH DATE"), systemImage: "checkmark")
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(NoopMetrics.space4)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text("DATE OF BIRTH"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onAppear { if profile.dateOfBirthIsEntered { picked = profile.dateOfBirth } }
        #if os(macOS)
        .frame(width: 420, height: 520)
        #endif
    }
}

/// The page itself, from a snapshot alone, so it can be rendered without a repository.
struct WhoopAgePage: View {
    let snapshot: WhoopAgeSnapshot?
    var lastWeekPace: Double?
    let calendarAge: Double
    var ageIsExact = true
    var onAddWaist: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onAddBirthDate: (() -> Void)?

    var body: some View {
        WhoopDayPage(title: String(localized: "HEALTHSPAN")) {
            WhoopAgeContent(snapshot: snapshot, lastWeekPace: lastWeekPace, calendarAge: calendarAge, ageIsExact: ageIsExact,
                            onAddWaist: onAddWaist, onOpenSettings: onOpenSettings, onAddBirthDate: onAddBirthDate)
        }
    }
}

/// What the page holds, top to bottom.
struct WhoopAgeContent: View {
    let snapshot: WhoopAgeSnapshot?
    var lastWeekPace: Double?
    let calendarAge: Double
    var ageIsExact = true
    /// Opens the profile for the waist; nil when it is entered.
    var onAddWaist: (() -> Void)?
    /// Opens the profile, where a VO2 max from the WHOOP app is entered; nil hides the prompt.
    var onOpenSettings: (() -> Void)?
    /// Opens the birth date picker; nil when the birth date is entered.
    var onAddBirthDate: (() -> Void)?

    var body: some View {
        VStack(spacing: NoopMetrics.space4) {
            VStack(spacing: NoopMetrics.space3) {
                WhoopAgeBubble(snapshot: snapshot, diameter: 280)
                WhoopAgeCaption(snapshot: snapshot, calendarAge: calendarAge, ageIsExact: ageIsExact)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, NoopMetrics.space2)
            if calendarAge > 0, let onAddBirthDate { birthDateCard(onAddBirthDate) }
            if let snapshot, snapshot.isUnlocked, let result = snapshot.result {
                paceCard(snapshot)
                WhoopHealthspanSections(result: result, recent: snapshot.recent, vo2: snapshot.vo2)
                leverCard(snapshot)
                certaintyCard(result, snapshot: snapshot)
                if let vo2 = snapshot.vo2 {
                    WhoopAgeVo2Card(vo2: vo2, onAddWaist: vo2.source == .nes ? nil : onAddWaist, onOpenSettings: onOpenSettings)
                }
            } else if let snapshot {
                calibrationCard(snapshot)
            }
            noteCard
        }
    }

    /// Asks for the birth date, and says what is assumed until it is given.
    private func birthDateCard(_ action: @escaping () -> Void) -> some View {
        WhoopTitledCard(title: String(localized: "ADD YOUR BIRTH DATE"), showsChevron: false) {
            Text("WHOOP counts your age to a tenth of a year. Without your birth date Yoop assumes you are half a year past your last birthday, and your WHOOP Age can be off by up to half a year.")
                .font(WhoopStyle.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                WhoopActionButtonLabel(title: String(localized: "ADD BIRTH DATE"), systemImage: "calendar")
            }
            .buttonStyle(.plain)
        }
    }

    private func paceCard(_ snapshot: WhoopAgeSnapshot) -> some View {
        VStack(spacing: NoopMetrics.space2) {
            WhoopPaceCard(pace: snapshot.pace, lastWeek: lastWeekPace, opensHealthspan: false)
            if let pace = snapshot.pace {
                Text(WhoopAgeText.paceSentence(WhoopAge.paceState(pace)))
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("The last 30 days against the last 6 months")
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func leverCard(_ snapshot: WhoopAgeSnapshot) -> some View {
        let levers = Array(snapshot.levers.prefix(3))
        WhoopTitledCard(title: String(localized: "WHAT TO DO"), showsChevron: false) {
            if levers.isEmpty {
                Text("Every measure is at or past its target. Keep doing what you are doing.")
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: NoopMetrics.space3) {
                    ForEach(levers) { lever in
                        HStack(alignment: .top, spacing: NoopMetrics.space3) {
                            Image(systemName: WhoopAgeText.icon(lever.key))
                                .font(WhoopStyle.icon)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                                Text(WhoopAgeText.lever(lever))
                                    .font(WhoopStyle.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if lever.isStretch {
                                    Text("Beyond your target")
                                        .font(WhoopStyle.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                            Spacer(minLength: NoopMetrics.space2)
                            Text(WhoopAgeText.years(-lever.yearsGained))
                                .font(WhoopStyle.number(16))
                                .foregroundStyle(WhoopStyle.rangeGreen)
                        }
                    }
                }
            }
        }
    }

    /// Says which input carries the doubt, and how much of the total it is.
    @ViewBuilder private func certaintyCard(_ result: WhoopAge.Result, snapshot: WhoopAgeSnapshot) -> some View {
        if let weakest = WhoopAge.Key.allCases.max(by: { result.uncertaintyShare($0) < result.uncertaintyShare($1) }),
           result.uncertaintyShare(weakest) >= 0.5 {
            WhoopTitledCard(title: String(localized: "LEAST CERTAIN INPUT"), showsChevron: false) {
                let years = "\(Int((result.yearsShare(weakest) * 100).rounded()))%"
                let error = "\(Int((result.uncertaintyShare(weakest) * 100).rounded()))%"
                Text("\(WhoopAgeText.label(weakest)) is the least certain input. It is \(years) of your years and \(error) of the possible error of ± \(String(format: "%.1f", result.sigma)) years.")
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func calibrationCard(_ snapshot: WhoopAgeSnapshot) -> some View {
        WhoopTitledCard(title: String(localized: "CALIBRATING"), showsChevron: false) {
            Text("WHOOP Age reads the last 6 months. It unlocks after \(WhoopAge.unlockRecoveries) recoveries in 31 days, so there is a week or two of wearing the strap to go.")
                .font(WhoopStyle.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let fraction = min(1, Double(snapshot.coverage.recoveriesInLast31Days) / Double(WhoopAge.unlockRecoveries))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(WhoopStyle.ringTrack)
                    Capsule().fill(WhoopStyle.rangeGreen).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
    }

    private var noteCard: some View {
        var lines = [
            String(localized: "This is Yoop's estimate on the method WHOOP published in its Healthspan white paper (2025). It is not WHOOP's own number."),
            String(localized: "Each of nine measures is turned into years from the death-risk studies behind it, against a healthy target rather than the average person. Your WHOOP Age is your age plus those years. A measure with no data adds nothing."),
            String(localized: "WHOOP corrects for the overlap between measures with figures it does not publish. Yoop's scales for them, and the curves WHOOP does not publish, are calibrated against WHOOP's own readout for one member and the white paper's published examples. They are fitted to those, not measured, and nothing here has been checked against anyone else's WHOOP Age."),
        ]
        if let snapshot {
            lines.append(String(localized: "Built on \(snapshot.coverage.strapDays) of the last \(snapshot.coverage.windowDays) days the strap recorded. Steps use every day with a count."))
        }
        lines.append(String(localized: "A wellness estimate, not a medical measurement and not a forecast of how long you will live."))
        return WhoopPageNote(title: String(localized: "HOW THIS IS MADE"), lines: lines)
    }
}

// MARK: - VO2 max

/// Which VO2 max the page used and why: the readings held, the source chosen, the range, and the one input that
/// would improve it.
struct WhoopAgeVo2Card: View {
    let vo2: Vo2Choice
    /// Opens the profile where the waist is entered; nil hides the prompt (a waist is already entered).
    var onAddWaist: (() -> Void)?
    /// Opens the profile where a VO2 max read from the WHOOP app is entered; nil hides the prompt.
    var onOpenSettings: (() -> Void)?

    private func date(_ day: String) -> String {
        WhoopDayFigures.date(of: day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day
    }

    private func reading(_ title: String, _ r: Vo2Choice.Reading?, note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(title).font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
                Text(note).font(WhoopStyle.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            if let r {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(Int(r.value.rounded()))).font(WhoopStyle.number(24)).foregroundStyle(StrandPalette.textPrimary)
                    Text(date(r.day)).font(WhoopStyle.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            } else {
                Text("--").font(WhoopStyle.number(24)).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var whoopNote: String {
        if vo2.source == .whoopApp {
            return String(localized: "Typed in from the WHOOP app. WHOOP states no error for it, so Yoop shows it as a range of 5 either way.")
        }
        return String(localized: "Older than 90 days, so not used.")
    }

    private var appleNote: String {
        if vo2.source == .appleHealth {
            return String(localized: "Measured by your Apple Watch on outdoor walks and runs. Reads about 6 low against a lab test, and misses by about 7.")
        }
        if vo2.source == .whoopApp, vo2.appleIsRecent {
            return String(localized: "Not used while a recent WHOOP app reading exists.")
        }
        return String(localized: "Older than 60 days, so not used.")
    }

    private var yoopNote: String {
        let what = vo2.yoop?.estimator == "nes"
            ? String(localized: "From your age, waist, resting heart rate and activity. Typically within 5 to 6 of a lab test.")
            : String(localized: "From your sleeping heart rate (Uth 2004). Tested on well-trained men aged 21 to 51 only, off by 4.7 at best, and a sleeping rate reads high.")
        switch vo2.source {
        case .whoopApp: return what + " " + String(localized: "Not used while a recent WHOOP app reading exists.")
        case .appleHealth: return what + " " + String(localized: "Not used while a recent Apple Health reading exists.")
        case .nes, .uth: return what
        }
    }

    private var why: String {
        switch vo2.source {
        case .whoopApp:
            return String(localized: "The reading you typed in from the WHOOP app comes first: it is WHOOP's own estimate for you, so Yoop uses it as it stands and shows the spread as a range.")
        case .appleHealth:
            return String(localized: "Apple Health's reading is measured, so it comes first. A lab test usually finds about 6 more, so Yoop adds that and shows the spread as a range.")
        case .nes:
            return String(localized: "With no recent Apple Health reading, Yoop uses its waist-based estimate. Typically within 5 to 6 of a lab test.")
        case .uth:
            return String(localized: "Only Yoop's rough heart-rate estimate is available, so the range is wide.")
        }
    }

    var body: some View {
        WhoopTitledCard(title: String(localized: "VO₂ MAX: WHICH NUMBER"), showsChevron: false) {
            if let whoop = vo2.whoop {
                reading(WhoopAgeText.whoopAppLabel(day: whoop.day).uppercased(), whoop, note: whoopNote)
                Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
            }
            reading(String(localized: "Apple Health").uppercased(), vo2.apple, note: appleNote)
            Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
            reading(String(localized: "YOOP ESTIMATE"), vo2.yoop, note: yoopNote)
            Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("USED").font(WhoopStyle.smallLabel).foregroundStyle(StrandPalette.textPrimary)
                if vo2.isRough {
                    Text("ROUGH")
                        .font(WhoopStyle.chevron)
                        .foregroundStyle(WhoopStyle.rangeAmber)
                        .padding(.horizontal, NoopMetrics.space2)
                        .padding(.vertical, NoopMetrics.space1)
                        .background(Capsule().fill(WhoopStyle.rangeAmber.opacity(0.18)))
                }
                Spacer()
                Text(WhoopAgeText.vo2Range(vo2))
                    .font(WhoopStyle.number(24)).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(why)
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onOpenSettings, vo2.whoop == nil {
                Button(action: onOpenSettings) {
                    WhoopActionButtonLabel(title: String(localized: "ADD A VO₂ MAX FROM THE WHOOP APP"), systemImage: "lungs")
                }
                .buttonStyle(.plain)
                Text("If the WHOOP app shows you a VO₂ max, type it in under Profile in Settings. Yoop uses it before any estimate of its own.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onAddWaist {
                Button(action: onAddWaist) {
                    WhoopActionButtonLabel(title: String(localized: "ADD YOUR WAIST"), systemImage: "ruler")
                }
                .buttonStyle(.plain)
                Text("A waist measurement lets Yoop use a published model instead of a rough heart-rate ratio. It is the one input that most improves this number.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
