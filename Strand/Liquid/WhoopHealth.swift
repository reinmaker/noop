import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// WHOOP-style fork: the pieces of the Health tab and the Health Monitor screen that Home's HEALTH MONITOR card
// opens. Both read one resolver, `HealthMonitorRule`, so the tally Home states, the rows on the tab and the rows
// on the screen are the same figures judged by the same rule, against the same 30-day normal Home's rows print.

// MARK: - Words

enum WhoopVitalText {
    static func title(_ status: HealthMonitorRule.Status) -> String {
        switch status.vital {
        case .respiratoryRate: return String(localized: "RESPIRATORY RATE")
        case .bloodOxygen: return String(localized: "BLOOD OXYGEN")
        case .restingHr: return String(localized: "RESTING HEART RATE")
        case .hrv: return String(localized: "HEART RATE VARIABILITY")
        case .skinTemperature:
            return status.isDeviation ? String(localized: "SKIN TEMP (FROM BASELINE)") : String(localized: "SKIN TEMP")
        }
    }

    static func icon(_ vital: HealthMonitorRule.Vital) -> String {
        switch vital {
        case .respiratoryRate: return "lungs"
        case .bloodOxygen: return "drop"
        case .restingHr: return "heart"
        case .hrv: return "waveform.path.ecg"
        case .skinTemperature: return "thermometer.medium"
        }
    }

    private static func number(_ v: Double, _ vital: HealthMonitorRule.Vital, isDeviation: Bool, fahrenheit: Bool) -> String {
        switch vital {
        case .hrv, .restingHr, .bloodOxygen: return String(Int(v.rounded()))
        case .respiratoryRate: return String(format: "%.1f", v)
        case .skinTemperature:
            return SkinTempDisplay.numberString(v, kind: isDeviation ? .deviation : .absolute, fahrenheit: fahrenheit, decimals: 1)
        }
    }

    static func unit(_ status: HealthMonitorRule.Status, fahrenheit: Bool) -> String {
        switch status.vital {
        case .hrv: return "ms"
        case .restingHr: return "bpm"
        case .respiratoryRate: return "rpm"
        case .bloodOxygen: return "%"
        case .skinTemperature:
            return SkinTempDisplay.unitSymbol(kind: status.isDeviation ? .deviation : .absolute, fahrenheit: fahrenheit)
        }
    }

    static func value(_ status: HealthMonitorRule.Status, fahrenheit: Bool) -> String? {
        status.value.map { number($0, status.vital, isDeviation: status.isDeviation, fahrenheit: fahrenheit) }
    }

    /// "62-111": the range around the usual value, in the scale the value is shown in.
    static func range(_ status: HealthMonitorRule.Status, fahrenheit: Bool) -> String? {
        guard let r = status.interval else { return nil }
        let low = number(r.low, status.vital, isDeviation: status.isDeviation, fahrenheit: fahrenheit)
        let high = number(r.high, status.vital, isDeviation: status.isDeviation, fahrenheit: fahrenheit)
        return status.isDeviation ? String(localized: "\(low) to \(high)") : "\(low)-\(high)"
    }

    static func chip(_ verdict: HealthMonitorRule.Verdict, isCurrent: Bool) -> String {
        guard isCurrent else { return String(localized: "NOT COUNTED") }
        switch verdict {
        case .within: return String(localized: "WITHIN RANGE")
        case .above: return String(localized: "ABOVE RANGE")
        case .below: return String(localized: "BELOW RANGE")
        case .learning: return String(localized: "LEARNING")
        case .noData: return String(localized: "NO DATA")
        }
    }

    static func headline(_ h: HealthMonitorRule.Headline) -> String {
        switch h {
        case .within: return String(localized: "WITHIN RANGE")
        case .outOfRange: return String(localized: "OUT OF RANGE")
        case .learning: return String(localized: "LEARNING YOUR RANGE")
        case .waiting: return String(localized: "WAITING FOR LAST NIGHT")
        case .noData: return String(localized: "CALIBRATING")
        }
    }

    /// The rule, stated once.
    static var ruleNote: String {
        String(localized: "Within range means inside your own usual range: the span your last 30 nights say a new night falls in 19 times in 20. It needs 14 nights. A reading that is not from last night is shown with its date and left out of the count.")
    }

    static var bloodOxygenNote: String {
        let floor = "\(Int(HealthMonitorRule.bloodOxygenFloor))%"
        return String(localized: "Blood oxygen is imported, from a WHOOP export or Apple Health. Your strap does not measure it as a percentage, so it is judged against the usual lower limit of \(floor) instead of your own range.")
    }
}

// MARK: - Vital rows

/// HEALTH MONITOR as rows: each vital's value, the range around its 30-day normal and where the value sits.
struct WhoopVitalsCard: View {
    let statuses: [HealthMonitorRule.Status]
    var fahrenheit = false
    /// A line about where a reading came from, already worded: blood oxygen "Imported from Apple Health",
    /// respiratory rate "Estimated from your heartbeat intervals" when Yoop made it rather than WHOOP.
    var notes: [HealthMonitorRule.Vital: String] = [:]
    let today: String
    var showsRule = true

    private var headline: HealthMonitorRule.Headline { HealthMonitorRule.headline(statuses) }
    private var summary: HealthMonitorRule.Summary { HealthMonitorRule.summary(statuses) }

    var body: some View {
        let allGood = headline == .within
        let tint = allGood ? WhoopStyle.rangeGreen : (headline == .outOfRange ? WhoopStyle.rangeAmber : StrandPalette.textTertiary)
        WhoopTitledCard(title: String(localized: "HEALTH MONITOR"), showsChevron: false) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: allGood ? "checkmark" : (headline == .outOfRange ? "exclamationmark" : "hourglass"))
                    .font(WhoopStyle.detail)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.18)))
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(WhoopVitalText.headline(headline)).font(WhoopStyle.smallLabel).foregroundStyle(tint)
                    if summary.counted > 0 {
                        let tally = "\(summary.within)/\(summary.counted)"
                        Text(tally + " " + String(localized: "Metrics"))
                            .font(WhoopStyle.detail)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                    row(status)
                    if index < statuses.count - 1 { Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1) }
                }
            }
            if showsRule {
                Text(WhoopVitalText.ruleNote)
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if statuses.contains(where: { $0.vital == .bloodOxygen && $0.value != nil }) {
                    Text(WhoopVitalText.bloodOxygenNote)
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func row(_ status: HealthMonitorRule.Status) -> some View {
        let value = WhoopVitalText.value(status, fahrenheit: fahrenheit)
        let tone = tone(status)
        let content = HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: WhoopVitalText.icon(status.vital))
                .font(WhoopStyle.icon)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(WhoopVitalText.title(status))
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(caption(status))
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space1)
            VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
                // The value and its chip keep their width so the name beside them never shrinks to make room.
                if let value {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                        Text(value)
                            .font(WhoopStyle.number(24))
                            .foregroundStyle(status.isCurrent ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        Text(WhoopVitalText.unit(status, fahrenheit: fahrenheit))
                            .font(WhoopStyle.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                } else {
                    Text("--").font(WhoopStyle.number(24)).foregroundStyle(StrandPalette.textTertiary)
                }
                chip(status, tone: tone)
            }
        }
        .padding(.vertical, NoopMetrics.space3)
        .contentShape(Rectangle())
        if let route = route(status) {
            NavigationLink(value: route) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func tone(_ status: HealthMonitorRule.Status) -> Color {
        guard status.isCurrent else { return StrandPalette.textTertiary }
        switch status.verdict {
        case .within: return WhoopStyle.rangeGreen
        case .above, .below: return WhoopStyle.rangeAmber
        case .learning, .noData: return StrandPalette.textTertiary
        }
    }

    private func chip(_ status: HealthMonitorRule.Status, tone: Color) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            Circle().fill(tone).frame(width: 7, height: 7)
            Text(WhoopVitalText.chip(status.verdict, isCurrent: status.isCurrent))
                .font(WhoopStyle.chevron)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, NoopMetrics.space2)
        .padding(.vertical, NoopMetrics.space1)
        .background(Capsule().fill(WhoopStyle.ringTrack))
        .opacity(status.value == nil ? 0 : 1)
    }

    /// The line under the name: the usual range, or why there is none, or where an imported figure is from.
    private func caption(_ status: HealthMonitorRule.Status) -> String {
        guard status.value != nil, let day = status.day else { return String(localized: "No reading in the last 7 days") }
        var parts: [String] = []
        if !status.isCurrent, let date = WhoopDayFigures.date(of: day) {
            parts.append(String(localized: "From \(date.formatted(.dateTime.day().month(.abbreviated)))"))
        }
        switch status.verdict {
        case .learning(let nights):
            parts.append(String(localized: "Learning your range, \(nights) of \(HealthMonitorRule.minNights) nights"))
        case .within, .above, .below, .noData:
            if status.vital != .bloodOxygen, let range = WhoopVitalText.range(status, fahrenheit: fahrenheit) {
                parts.append(String(localized: "Usual \(range)"))
            }
            if let note = notes[status.vital] { parts.append(note) }
        }
        return parts.joined(separator: " · ")
    }

    private func route(_ status: HealthMonitorRule.Status) -> TabRoute? {
        switch status.vital {
        case .hrv: return .metric("hrv")
        case .restingHr: return .metric("rhr")
        case .respiratoryRate: return .metric("resp_rate")
        case .skinTemperature: return .metric("skin_temp")
        case .bloodOxygen:
            guard let day = status.day, let value = status.value else { return nil }
            return .bloodOxygen(WhoopRowFigures(day: day, isToday: day == today, value: value))
        }
    }
}

/// The vitals card with its inputs resolved from the repository, for the tab and the screen.
struct WhoopVitalsSection: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    var showsRule = true

    private var fahrenheit: Bool {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: temperatureRaw) == .fahrenheit
    }

    /// The source the merged day took a figure from, by the app's source precedence.
    private func source(of vital: HealthMonitorRule.Vital, day: String) -> DailyMetricSource? {
        let rows = repo.vitalRows.filter { row in
            guard row.metric.day == day else { return false }
            switch vital {
            case .bloodOxygen: return row.metric.spo2Pct != nil
            case .respiratoryRate: return row.metric.respRateBpm != nil
            default: return false
            }
        }
        return rows.min(by: { $0.source.vitalPriority < $1.source.vitalPriority })?.source
    }

    /// Where a reading came from, worded like the Blood Oxygen page; only for the two that need saying.
    private func notes(_ statuses: [HealthMonitorRule.Status]) -> [HealthMonitorRule.Vital: String] {
        var out: [HealthMonitorRule.Vital: String] = [:]
        if let day = statuses.first(where: { $0.vital == .bloodOxygen })?.day,
           let from = source(of: .bloodOxygen, day: day) {
            switch from {
            case .whoopImport: out[.bloodOxygen] = String(localized: "Imported from your WHOOP export")
            case .appleHealth: out[.bloodOxygen] = String(localized: "Imported from Apple Health")
            case .noopComputed, .localCache: out[.bloodOxygen] = String(localized: "Saved on this device")
            }
        }
        // A night Yoop scored has no respiration sensor behind its rate: it is read off the beat to beat
        // variation (respiratory sinus arrhythmia), so it is an estimate. WHOOP's own is an export's.
        if let day = statuses.first(where: { $0.vital == .respiratoryRate })?.day,
           source(of: .respiratoryRate, day: day) == .noopComputed {
            out[.respiratoryRate] = String(localized: "Estimated from your heartbeat intervals")
        }
        return out
    }

    var body: some View {
        let today = Repository.logicalDayKey(Date())
        let statuses = HealthMonitorRule.statuses(days: repo.days, todayKey: today)
        WhoopVitalsCard(statuses: statuses, fahrenheit: fahrenheit, notes: notes(statuses), today: today, showsRule: showsRule)
    }
}

// MARK: - Live heart rate

/// The strap's live heart rate: the spike-filtered figure every screen shows (`AppModel.bpm`), and one plain line
/// on why there is none. It only reads the stream; the Health Monitor screen is what arms it.
struct WhoopLiveHeartRateCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Opens the Health Monitor screen, where the stream is armed.
    var opensMonitor = false

    var body: some View {
        WhoopLiveHeartRateView(bpm: model.bpm, connected: live.connected, opensMonitor: opensMonitor)
    }
}

/// The card from its three inputs, so it can be rendered without the strap.
struct WhoopLiveHeartRateView: View {
    let bpm: Int?
    let connected: Bool
    var opensMonitor = false

    private var line: String {
        if bpm != nil { return String(localized: "Live from your strap") }
        if connected {
            return opensMonitor ? String(localized: "Tap to read your heart rate live") : String(localized: "Reading your heart rate…")
        }
        return String(localized: "Device disconnected")
    }

    var body: some View {
        let card = VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("HEART RATE")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space1)
                if opensMonitor {
                    Image(systemName: "chevron.right")
                        .font(WhoopStyle.detail)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Image(systemName: "heart.fill")
                    .font(WhoopStyle.icon)
                    .foregroundStyle(StrandPalette.statusCritical)
                Text(bpm.map(String.init) ?? "--")
                    .font(WhoopStyle.number(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("BPM")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text(line)
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(WhoopStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .whoopCard()
        if opensMonitor {
            NavigationLink(value: TabRoute.healthMonitor) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }
}

// MARK: - WHOOP Age on the tab

/// The Health tab's headline: WHOOP Age on its own, then Pace of Aging, each opening the Healthspan page.
struct WhoopAgeHealthCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @State private var snapshot: WhoopAgeSnapshot?
    @State private var lastWeekPace: Double?

    var body: some View {
        WhoopAgeHealthCardContent(snapshot: snapshot, lastWeekPace: lastWeekPace, calendarAge: profile.decimalAge,
                                  ageIsExact: profile.dateOfBirthIsEntered)
            .task(id: "\(repo.refreshSeq)|\(profile.dateOfBirth.timeIntervalSince1970)|\(profile.dateOfBirthIsEntered)") {
                let sigma = profile.dateOfBirthIsEntered ? 0 : ProfileStore.unknownBirthdayFractionSigma
                snapshot = await WhoopAgeLoader.load(repo: repo, age: profile.decimalAge, ageSigma: sigma, sex: profile.sex)
                lastWeekPace = await WhoopAgeLoader.paceLastWeek(repo: repo, age: profile.decimalAge, ageSigma: sigma,
                                                                 sex: profile.sex)
            }
    }
}

/// The tab's top from a snapshot alone, so it can be rendered without a repository.
struct WhoopAgeHealthCardContent: View {
    let snapshot: WhoopAgeSnapshot?
    var lastWeekPace: Double?
    let calendarAge: Double
    var ageIsExact = true

    var body: some View {
        VStack(spacing: NoopMetrics.space4) {
            NavigationLink(value: TabRoute.whoopAge) {
                VStack(spacing: NoopMetrics.space3) {
                    WhoopAgeBubble(snapshot: snapshot, diameter: 270)
                    WhoopAgeCaption(snapshot: snapshot, calendarAge: calendarAge, ageIsExact: ageIsExact)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            if let snapshot, snapshot.isUnlocked { WhoopPaceCard(pace: snapshot.pace, lastWeek: lastWeekPace) }
        }
    }
}

// MARK: - Health Monitor screen

/// WHOOP's Health Monitor screen: the strap's live heart rate, then the vitals with last night's value and where it
/// sits in the wearer's own range. The same rows as the Health tab.
struct WhoopHealthMonitorScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                WhoopLiveHeartRateCard()
                WhoopVitalsSection()
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text("HEALTH MONITOR"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Live heart rate needs the strap's realtime stream, which only the screens that show it arm
        // (ref-counted, so leaving here never stops it under the Live screen or a workout).
        .onAppear { model.startRealtimeHR() }
        .onDisappear { model.stopRealtimeHR() }
        // A new connection must be re-armed; the count is unchanged.
        .onChangeCompat(of: live.bonded) { _ in model.rearmRealtimeIfWanted() }
    }
}
