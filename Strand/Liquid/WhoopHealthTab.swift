import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore

// Yoop: the Health tab and the Healthspan page as WHOOP lays them out, read from WHOOP's own screens on 7 and 12
// Oct 2026 (layout only). The tab: the WHOOP Age bubble on its own, Pace of Aging as a ruler, Advanced Labs, a
// compact Health Monitor, Stress Monitor. The page: the same bubble and ruler, then Sleep, Strain and Fitness as
// rows of a ten-step bar with the six-month value, the 30-day value and the years each adds or takes off.
// Every figure is `WhoopAgeSnapshot`'s, `HealthMonitorRule`'s or the stress day's; nothing here computes one.

// MARK: - The backdrop

/// The green glow WHOOP lays over the top of the Health tab, fading into the page.
struct WhoopHealthGlow: View {
    var body: some View {
        LinearGradient(colors: [WhoopStyle.rangeGreen.opacity(0.28), WhoopStyle.rangeGreen.opacity(0.08), Color.clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 420)
    }
}

// MARK: - The bubble

/// The bubble's outline: a circle with a slow wobble that drifts with `phase`, so the blob keeps changing shape.
struct WhoopBlobShape: Shape {
    var phase: Double = 0

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * 0.9
        let steps = 120
        var path = Path()
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * Double.pi
            let wobble = 1 + 0.07 * sin(3 * t + 0.6 + phase * 0.9) + 0.045 * sin(5 * t + 2.1 - phase * 1.3)
                + 0.03 * sin(2 * t + 4.0 + phase * 0.7)
            let r = Double(radius) * wobble
            let point = CGPoint(x: center.x + CGFloat(cos(t) * r), y: center.y + CGFloat(sin(t) * r))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// The specks inside the bubble, thickest near the rim. Each drifts round the centre at its own pace, in and out
/// a little, and brightens and fades on its own beat, so the whole bubble is plainly alive. The same specks every
/// time they start: they come from a fixed seed. `time` is seconds.
private struct WhoopBlobParticles: View {
    let tint: Color
    let time: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(seed >> 11) / Double(UInt64(1) << 53)
            }
            for _ in 0..<210 {
                let angle0 = next() * 2 * Double.pi
                let reach0 = 0.5 + 0.5 * pow(next(), 0.55)
                let dot = 1.4 + next() * 3.8
                let phase = next() * 2 * Double.pi
                let alpha = 0.55 + 0.45 * next()
                let drift = (next() - 0.5) * 0.3
                let beat = 0.5 + next() * 1.1
                let angle = angle0 + time * drift
                let reach = min(0.97, max(0.42, reach0 + 0.04 * sin(time * 0.35 + phase)))
                let glow = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * beat + phase))
                let x = center.x + CGFloat(cos(angle) * reach) * radius * 0.92
                let y = center.y + CGFloat(sin(angle) * reach) * radius * 0.92
                let rect = CGRect(x: x - CGFloat(dot) / 2, y: y - CGFloat(dot) / 2, width: CGFloat(dot), height: CGFloat(dot))
                context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(alpha * glow)))
            }
        }
    }
}

/// The big WHOOP Age number on its own, in WHOOP's dark blob with specks, on the Health tab and at the top of the page.
/// The blob changes shape slowly and the specks drift and glow (still, with Reduce Motion on).
struct WhoopAgeBubble: View {
    let snapshot: WhoopAgeSnapshot?
    var diameter: CGFloat = 220
    /// The folded header's small bubble: the age alone.
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let result = snapshot?.isUnlocked == true ? snapshot?.result : nil
        let younger = (result?.yearsYounger ?? 0) >= 0
        let tint = result == nil ? StrandPalette.textTertiary : (younger ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion || compact)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let phase = t * 0.8
                ZStack {
                    WhoopBlobShape(phase: phase)
                        .fill(RadialGradient(gradient: Gradient(stops: [
                            .init(color: StrandPalette.surfaceBase, location: 0),
                            .init(color: StrandPalette.surfaceBase.opacity(0.94), location: 0.42),
                            .init(color: tint.opacity(0.35), location: 0.74),
                            .init(color: tint.opacity(0.8), location: 1),
                        ]), center: .center, startRadius: 0, endRadius: diameter * 0.52))
                    WhoopBlobParticles(tint: tint, time: t)
                        .clipShape(WhoopBlobShape(phase: phase))
                    WhoopBlobShape(phase: phase).stroke(tint.opacity(0.85), lineWidth: 1.5)
                }
            }
            VStack(spacing: NoopMetrics.space1) {
                Text(verbatim: result.map { String(format: "%.1f", $0.whoopAge) } ?? "--")
                    .font(WhoopStyle.number(diameter * 0.2))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Text("WHOOP AGE")
                    .font(compact ? WhoopStyle.chevron : WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let result, !compact {
                    Text(WhoopAgeText.delta(yearsYounger: result.yearsYounger).localizedLowercase)
                        .font(WhoopStyle.detail)
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.center)
                } else if snapshot != nil, result == nil, !compact {
                    Text("CALIBRATING")
                        .font(WhoopStyle.detail)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(result.map { String(localized: "WHOOP Age \(String(format: "%.1f", $0.whoopAge)), \(WhoopAgeText.delta(yearsYounger: $0.yearsYounger))") }
                                 ?? String(localized: "WHOOP Age is calibrating")))
    }
}

// MARK: - The folded header

/// The scroll offset of the Healthspan page's content, read to know when the bubble has left the screen.
struct WhoopScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// What WHOOP's Healthspan page keeps at the top once the bubble has scrolled away: the years younger on the left,
/// a small bubble in the middle and the pace on the right.
struct WhoopHealthspanCompactHeader: View {
    let snapshot: WhoopAgeSnapshot?

    var body: some View {
        let result = snapshot?.isUnlocked == true ? snapshot?.result : nil
        let younger = (result?.yearsYounger ?? 0) >= 0
        HStack(alignment: .center) {
            VStack(spacing: 2) {
                Text(result.map { String(format: "%.1f", abs($0.yearsYounger)) } ?? "--")
                    .font(WhoopStyle.number(20))
                    .foregroundStyle(younger ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                Text(younger ? String(localized: "YEARS YOUNGER") : String(localized: "YEARS OLDER"))
                    .font(WhoopStyle.chevron)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            WhoopAgeBubble(snapshot: snapshot, diameter: 92, compact: true)
            VStack(spacing: 2) {
                Text(WhoopAgeText.paceNumber(snapshot?.pace))
                    .font(WhoopStyle.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("PACE OF AGING")
                    .font(WhoopStyle.chevron)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space1)
        .background(StrandPalette.surfaceBase.opacity(0.96))
    }
}

// MARK: - Pace of Aging

/// Pace of Aging as WHOOP draws it: a ruler of ticks from -1.0x to 3.0x with the reading's tick standing out and its
/// number above it, "Slow" at one end and "Fast" at the other.
struct WhoopPaceSlider: View {
    let pace: Double?

    private static let range = WhoopAge.paceRange
    private static let tickCount = 81

    private func fraction(_ value: Double) -> CGFloat {
        CGFloat((min(Self.range.upperBound, max(Self.range.lowerBound, value)) - Self.range.lowerBound)
                / (Self.range.upperBound - Self.range.lowerBound))
    }

    var body: some View {
        VStack(spacing: NoopMetrics.space2) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(StrandPalette.textTertiary).frame(width: 12, height: 12)
                    Text("Slow")
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("Fast")
                    Image(systemName: "flame.fill").font(WhoopStyle.chevron)
                }
            }
            .font(WhoopStyle.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            GeometryReader { geo in
                let width = geo.size.width
                VStack(spacing: 4) {
                    ZStack {
                        Color.clear
                        if let pace {
                            Text(WhoopAgeText.paceNumber(pace))
                                .font(WhoopStyle.number(28))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize()
                                .position(x: min(max(fraction(pace) * width, 26), width - 26), y: 15)
                        }
                    }
                    .frame(height: 30)
                    Canvas { context, size in
                        for i in 0..<Self.tickCount {
                            let value = Self.range.lowerBound + Double(i) * 0.05
                            let x = CGFloat(i) / CGFloat(Self.tickCount - 1) * size.width
                            let major = i % 20 == 0
                            let near = pace.map { abs(value - $0) < 0.18 } ?? false
                            let height: CGFloat = major ? 30 : (near ? 26 : 18)
                            let rect = CGRect(x: x - 0.75, y: (size.height - height) / 2, width: 1.5, height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 0.75),
                                         with: .color(StrandPalette.textPrimary.opacity(major ? 0.5 : (near ? 0.85 : 0.28))))
                        }
                        if let pace {
                            let x = fraction(pace) * size.width
                            let rect = CGRect(x: x - 1.25, y: 0, width: 2.5, height: size.height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(StrandPalette.textPrimary))
                        }
                    }
                    .frame(height: 34)
                }
            }
            .frame(height: 68)
            HStack {
                Text(WhoopAgeText.paceScaleMin)
                Spacer()
                Text(WhoopAgeText.paceNumber(1.0))
                Spacer()
                Text(WhoopAgeText.paceScaleMax)
            }
            .font(WhoopStyle.chevron)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(pace.map { String(localized: "Pace of Aging \(String(format: "%.1f", $0)) times, \(WhoopAgeText.paceWord(WhoopAge.paceState($0)))") }
                                 ?? String(localized: "Pace of Aging is calibrating")))
    }
}

/// How this week's pace compares with last week's.
enum WhoopPaceTrend: Equatable {
    case faster, slower, steady

    /// The move that counts as a change, in x.
    static let threshold = 0.05

    init?(now: Double?, lastWeek: Double?) {
        guard let now, let lastWeek else { return nil }
        let move = now - lastWeek
        self = move > Self.threshold ? .faster : (move < -Self.threshold ? .slower : .steady)
    }

    var text: String {
        switch self {
        case .faster: return String(localized: "faster vs. last week")
        case .slower: return String(localized: "slower vs. last week")
        case .steady: return String(localized: "steady vs. last week")
        }
    }

    var color: Color {
        switch self {
        case .faster: return WhoopStyle.rangeAmber
        case .slower: return WhoopStyle.rangeGreen
        case .steady: return WhoopStyle.sufficientGray
        }
    }

    var symbol: String? {
        switch self {
        case .faster: return "arrowtriangle.up.fill"
        case .slower: return "arrowtriangle.down.fill"
        case .steady: return nil
        }
    }
}

/// The wide quiet button WHOOP puts under a card ("GO TO HEALTHSPAN").
struct WhoopWideButtonLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(WhoopStyle.smallLabel)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, NoopMetrics.space3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WhoopStyle.ringTrack))
    }
}

/// "PACE OF AGING": the ruler, how it moved since last week, and the way into the Healthspan page.
struct WhoopPaceCard: View {
    let pace: Double?
    let lastWeek: Double?
    var opensHealthspan = true

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text("PACE OF AGING")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                if let trend = WhoopPaceTrend(now: pace, lastWeek: lastWeek) {
                    HStack(spacing: 4) {
                        if let symbol = trend.symbol { Image(systemName: symbol).font(WhoopStyle.chevron) }
                        Text(trend.text).font(WhoopStyle.chevron)
                    }
                    .foregroundStyle(trend.color)
                    .padding(.horizontal, NoopMetrics.space2)
                    .padding(.vertical, NoopMetrics.space1)
                    .background(Capsule().fill(trend.color.opacity(0.16)))
                }
            }
            WhoopPaceSlider(pace: pace)
            if opensHealthspan {
                NavigationLink(value: TabRoute.whoopAge) {
                    WhoopWideButtonLabel(title: String(localized: "GO TO HEALTHSPAN"))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WhoopStyle.cardPadding)
        .whoopCard()
    }
}

// MARK: - Advanced Labs

/// What the Lab Book holds, counted the way the Advanced Labs card states it. Yoop judges no value: a count of
/// Optimal, Sufficient or Out of Range is only there for a marker whose own import carried that word from WHOOP.
struct WhoopLabSummary: Equatable {
    var total = 0
    var optimal = 0
    var sufficient = 0
    var outOfRange = 0
    var lastTakenAt: Int?

    /// Markers that carry a WHOOP status.
    var judged: Int { optimal + sufficient + outOfRange }

    /// The status word in a marker's note ("WHOOP: Out of Range"), nil without one.
    static func status(ofNote note: String?) -> Status? {
        guard let note else { return nil }
        let text = note.lowercased()
        guard text.contains("whoop:") else { return nil }
        if text.contains("out of range") { return .outOfRange }
        if text.contains("sufficient") { return .sufficient }
        if text.contains("optimal") { return .optimal }
        return nil
    }

    enum Status { case optimal, sufficient, outOfRange }

    /// The latest reading of each marker, counted.
    static func make(_ rows: [LabMarkerRow]) -> WhoopLabSummary {
        var latest: [String: LabMarkerRow] = [:]
        for row in rows {
            if let current = latest[row.markerKey], current.takenAt >= row.takenAt { continue }
            latest[row.markerKey] = row
        }
        var out = WhoopLabSummary()
        for row in latest.values {
            out.total += 1
            switch status(ofNote: row.note) {
            case .optimal?: out.optimal += 1
            case .sufficient?: out.sufficient += 1
            case .outOfRange?: out.outOfRange += 1
            case nil: break
            }
            out.lastTakenAt = max(out.lastTakenAt ?? 0, row.takenAt)
        }
        return out
    }
}

/// "ADVANCED LABS": the Lab Book's markers as a ring of ticks, one tick a marker, with the three counts beside it.
struct WhoopAdvancedLabsCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @State private var summary: WhoopLabSummary?

    var body: some View {
        Button { router.openLabBook() } label: {
            WhoopTitledCard(title: String(localized: "ADVANCED LABS")) {
                if let summary, summary.total > 0 {
                    HStack(alignment: .center, spacing: NoopMetrics.space3) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            if summary.judged > 0 {
                                pill(String(localized: "Optimal"), count: summary.optimal, tint: WhoopStyle.rangeGreen,
                                     icon: "checkmark")
                                pill(String(localized: "Sufficient"), count: summary.sufficient, tint: WhoopStyle.stressLow,
                                     icon: "circle.fill")
                                pill(String(localized: "Out of Range"), count: summary.outOfRange, tint: WhoopStyle.rangeAmber,
                                     icon: "exclamationmark")
                            }
                            if let last = summary.lastTakenAt {
                                let date = Date(timeIntervalSince1970: TimeInterval(last))
                                    .formatted(.dateTime.day().month(.abbreviated).year())
                                Text("Last updated: \(date)")
                                    .font(WhoopStyle.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                        ring(summary)
                    }
                } else {
                    Text("No lab results yet. Add or import them in your Lab Book.")
                        .font(WhoopStyle.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: repo.refreshSeq) { summary = await Self.load(repo: repo) }
    }

    private static func load(repo: Repository) async -> WhoopLabSummary {
        guard let store = await repo.storeHandle() else { return WhoopLabSummary() }
        var rows: [LabMarkerRow] = []
        for category in LabMarkerCategory.allCases {
            rows += (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
        }
        return WhoopLabSummary.make(rows)
    }

    private func pill(_ title: String, count: Int, tint: Color, icon: String) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(WhoopStyle.chevron)
                Text(title).font(WhoopStyle.chevron)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.16)))
            Text("\(count)")
                .font(WhoopStyle.number(18))
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    /// One tick a marker, clockwise from the lower left: Sufficient, then Out of Range, then Optimal, then the
    /// markers WHOOP gave no status.
    private func ring(_ summary: WhoopLabSummary) -> some View {
        let unjudged = max(0, summary.total - summary.judged)
        let colors: [Color] = Array(repeating: WhoopStyle.stressLow, count: summary.sufficient)
            + Array(repeating: WhoopStyle.rangeAmber, count: summary.outOfRange)
            + Array(repeating: WhoopStyle.rangeGreen, count: summary.optimal)
            + Array(repeating: StrandPalette.textTertiary, count: unjudged)
        return ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = min(size.width, size.height) / 2
                let inner = outer * 0.8
                let count = max(1, colors.count)
                for (i, color) in colors.enumerated() {
                    let turn = 225.0 + Double(i) / Double(count) * 360.0 + 180.0 / Double(count)
                    let angle = (turn - 90) * Double.pi / 180
                    var line = Path()
                    line.move(to: CGPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner))
                    line.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * outer, y: center.y + CGFloat(sin(angle)) * outer))
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            VStack(spacing: 2) {
                Text("\(summary.total)")
                    .font(WhoopStyle.number(34))
                    .foregroundStyle(StrandPalette.textPrimary)
                HStack(spacing: 3) {
                    Text("BIOMARKERS").font(WhoopStyle.chevron)
                    Image(systemName: "chevron.right").font(WhoopStyle.chevron)
                }
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(width: 150, height: 150)
    }
}

// MARK: - Health Monitor

/// "HEALTH MONITOR" on the tab: the five vitals as a row of icons, each with a check when it is within range, and the
/// tally under them. The same `HealthMonitorRule` statuses as Home's card and the Health Monitor screen it opens.
struct WhoopHealthMonitorGridCard: View {
    @EnvironmentObject private var repo: Repository

    private static func shortLabel(_ vital: HealthMonitorRule.Vital) -> String {
        switch vital {
        case .respiratoryRate: return String(localized: "RESP")
        case .bloodOxygen: return String(localized: "SPO2")
        case .restingHr: return String(localized: "RHR")
        case .hrv: return String(localized: "HRV")
        case .skinTemperature: return String(localized: "TEMP")
        }
    }

    var body: some View {
        let today = Repository.logicalDayKey(Date())
        let statuses = HealthMonitorRule.statuses(days: repo.days, todayKey: today)
        let summary = HealthMonitorRule.summary(statuses)
        let headline = HealthMonitorRule.headline(statuses)
        NavigationLink(value: TabRoute.healthMonitor) {
            WhoopTitledCard(title: String(localized: "HEALTH MONITOR")) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(statuses) { status in column(status) }
                }
                tally(summary, headline: headline)
            }
        }
        .buttonStyle(.plain)
    }

    private func column(_ status: HealthMonitorRule.Status) -> some View {
        VStack(spacing: NoopMetrics.space2) {
            Image(systemName: WhoopVitalText.icon(status.vital))
                .font(WhoopStyle.iconLarge)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(height: 24)
            Text(Self.shortLabel(status.vital))
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textPrimary)
            box(status)
        }
        .frame(maxWidth: .infinity)
    }

    /// The tick under a vital: green when within range, amber when not, dashed when it is not counted.
    private func box(_ status: HealthMonitorRule.Status) -> some View {
        let within = status.counts && status.isFine
        let outside = status.counts && !status.isFine
        let tint = within ? WhoopStyle.rangeGreen : (outside ? WhoopStyle.rangeAmber : StrandPalette.textTertiary)
        return Image(systemName: within ? "checkmark" : (outside ? "exclamationmark" : "minus"))
            .font(WhoopStyle.detail)
            .foregroundStyle(within || outside ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(within || outside ? tint : WhoopStyle.ringTrack))
    }

    private func tally(_ summary: HealthMonitorRule.Summary, headline: HealthMonitorRule.Headline) -> some View {
        let good = headline == .within
        let tint = good ? WhoopStyle.rangeGreen : (headline == .outOfRange ? WhoopStyle.rangeAmber : StrandPalette.textTertiary)
        return HStack(spacing: NoopMetrics.space2) {
            Image(systemName: good ? "checkmark" : (headline == .outOfRange ? "exclamationmark" : "minus"))
                .font(WhoopStyle.chevron)
                .foregroundStyle(good || headline == .outOfRange ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(good || headline == .outOfRange ? tint : WhoopStyle.ringTrack))
            Text(summary.counted > 0 ? String(localized: "\(summary.within)/\(summary.tracked) metrics within range")
                                     : WhoopVitalText.headline(headline))
                .font(WhoopStyle.detail)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(NoopMetrics.space3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WhoopStyle.ringTrack.opacity(0.6)))
    }
}

// MARK: - Stress Monitor

/// "STRESS MONITOR" on the tab: the time spent in high stress so far today, the level now, and the day's line.
struct WhoopHealthStressCard: View {
    @EnvironmentObject private var repo: Repository
    @State private var timeline: [DaytimeStress.HourPoint] = []

    private struct Sample: Identifiable {
        let time: Date
        let level: Double
        var id: Date { time }
    }

    private static func hoursAndMinutes(_ minutes: Double) -> String {
        String(format: "%d:%02d", Int(minutes) / 60, Int(minutes) % 60)
    }

    var body: some View {
        let scored = WhoopStressHero.scoredSamples(timeline)
        let high = WhoopStressHero.minutesByBand(scored)[2]
        let latest = scored.last?.level
        NavigationLink(value: TabRoute.stress) {
            WhoopTitledCard(title: String(localized: "STRESS MONITOR")) {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("TODAY'S HIGH STRESS")
                            .font(WhoopStyle.chevron)
                            .foregroundStyle(StrandPalette.textSecondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(scored.isEmpty ? "--" : Self.hoursAndMinutes(high))
                                .font(WhoopStyle.number(34))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("hrs").font(WhoopStyle.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        if let latest {
                            let band = WhoopStyle.stressBand(latest)
                            Text(band.word)
                                .font(WhoopStyle.chevron)
                                .foregroundStyle(band.color)
                                .padding(.horizontal, NoopMetrics.space2)
                                .padding(.vertical, NoopMetrics.space1)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(band.color.opacity(0.16)))
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    line(scored.map { Sample(time: $0.time, level: $0.level) })
                        .frame(maxWidth: .infinity)
                        .frame(height: 96)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: repo.refreshSeq) {
            let result = await StressDayCurve.today(
                repo: repo, personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled)?.result
            timeline = result?.timeline ?? []
        }
    }

    @ViewBuilder private func line(_ samples: [Sample]) -> some View {
        if samples.count >= 2 {
            Chart {
                RuleMark(y: .value("High", 2))
                    .foregroundStyle(WhoopStyle.ringTrack)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                ForEach(samples) { item in
                    LineMark(x: .value("Time", item.time), y: .value("Stress", item.level))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [WhoopStyle.stressLow, WhoopStyle.stressMedium,
                                                                 WhoopStyle.stressHigh],
                                                        startPoint: .bottom, endPoint: .top))
                }
                if let last = samples.last {
                    PointMark(x: .value("Time", last.time), y: .value("Stress", last.level))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .symbolSize(40)
                }
            }
            .chartYScale(domain: 0...3)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        } else {
            Text("Builds through the day as your strap syncs.")
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}
