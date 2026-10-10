import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// WHOOP-style fork: one activity's page, opened from Home's ACTIVITIES card and laid out as WHOOP's: the
// sport and its window, where it came from, Activity Strain and steps against the sport's typical, the
// heart-rate line, the time in each heart-rate zone against the sport's typical range, and the key
// statistics against the sport's 30-day average. Values are NOOP's own; the zones and every comparison
// come from `WhoopActivityZones` and `WhoopActivityBaseline`.

/// The Home route to one activity. `WorkoutRow` is not `Hashable`, so the route hashes the row's natural
/// key and window and compares the whole row.
struct WhoopActivityRoute: Hashable {
    let row: WorkoutRow

    static func == (a: WhoopActivityRoute, b: WhoopActivityRoute) -> Bool { a.row == b.row }

    func hash(into hasher: inout Hasher) {
        hasher.combine(row.startTs)
        hasher.combine(row.endTs)
        hasher.combine(row.sport)
        hasher.combine(row.source)
    }
}

struct WhoopActivityScreen: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var profile = ProfileStore()

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""

    /// The activity shown. Changing its type renames it here as well as in the store.
    @State private var row: WorkoutRow
    @State private var figures = Figures()
    /// The time under the reader's finger on the heart-rate graph.
    @State private var hrSelection: Date?
    @State private var retyping = false

    init(row: WorkoutRow) {
        _row = State(initialValue: row)
    }

    /// A figure with no value, as WHOOP shows a missing Strain.
    private static let missing = "---"

    /// Earlier sessions read for the zones' typical ranges and the typical steps, newest first. Each is a
    /// heart-rate read, so the page stays quick on a long history.
    private static let historyReadCap = 20

    /// Everything the page reads besides the row itself.
    private struct Figures {
        /// False until the first load lands, so the zone rows never show a placeholder 0:00:00 as data.
        var loaded = false
        var hr: [HRBucket] = []
        var restingHR: Double = StrainScorer.defaultRestingHR
        /// Seconds in each band, restorative first; nil without heart rate or imported zones.
        var bandSeconds: [Double]?
        var typicalShares: [ClosedRange<Double>?] = Array(repeating: nil, count: WhoopActivityZones.bandCount)
        var steps: Int?
        var typicalStrain: Double?
        var typicalSteps: Double?
        var typicalKcal: Double?
        var typicalAvgHr: Double?
        var typicalMaxHr: Double?
        var typicalDistance: Double?
    }

    /// A figure's typical value as its chip shows it, and whether this activity is above or below it.
    private struct Typical {
        let text: String
        let direction: Int
    }

    private var start: Date { Date(timeIntervalSince1970: TimeInterval(row.startTs)) }
    private var end: Date { Date(timeIntervalSince1970: TimeInterval(max(row.endTs, row.startTs))) }
    private var name: String { WorkoutSource.displaySport(row.sport) }
    private var durationSeconds: Double { row.durationS ?? Double(max(0, row.endTs - row.startTs)) }
    private var strain: Double? { row.strain.map(AICoachEngine.strain21) }
    /// Yoop's own activities can be re-typed and deleted; imported history is read-only.
    private var isOwn: Bool { WorkoutSource.classify(row.source) == .manual }

    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceSystemRaw)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                sourceBlock
                headline
                heartRateChart
                zonesSection
                keyStatistics
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, NoopMetrics.space2)
            .padding(.bottom, NoopMetrics.space10)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text(name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            if isOwn {
                ToolbarItem(placement: .primaryAction) { actionsMenu }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { WhoopCoachPill(screen: .strain) }
        .workoutSelectionCover(isPresented: $retyping) {
            StartWorkoutSheet(title: String(localized: "Change activity"),
                              subtitle: String(localized: "Pick what this was. Yoop learns from your choice for the next ones."),
                              actionVerb: String(localized: "Choose")) { sport in
                retype(to: sport)
            }
        }
        .task(id: "\(row.startTs)|\(row.sport)|\(repo.refreshSeq)") { await load() }
    }

    // MARK: Header

    /// The sport's icon and name over its window, as in WHOOP's top bar.
    private var header: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: sportSymbol(row.sport))
                .font(WhoopStyle.iconLarge)
            VStack(alignment: .leading, spacing: 0) {
                Text(name.uppercased())
                    .font(WhoopStyle.label)
                Text(windowText)
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// "5 Oct 20:39 to 21:18".
    private var windowText: String {
        let from = "\(start.formatted(.dateTime.day().month(.abbreviated))) \(WhoopTime.clock(start))"
        return String(localized: "\(from) to \(WhoopTime.clock(end))")
    }

    private var actionsMenu: some View {
        Menu {
            Button { retyping = true } label: {
                Label("Change activity type", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive, action: delete) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(WhoopStyle.icon)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityLabel(Text("More"))
    }

    /// Where the activity came from, for its "Via" chip: Yoop for its own (live, logged or detected),
    /// else the app or file it was imported from.
    static func sourceName(_ source: String) -> String {
        switch WorkoutSource.classify(source) {
        case .manual, .detected: return "Yoop"
        case .whoop: return "WHOOP"
        case .apple: return "Apple Health"
        case .lifting: return "Hevy / Liftosaur"
        case .activityFile: return "GPX / TCX / FIT"
        }
    }

    private var sourceBlock: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space1) {
                Image(systemName: "link")
                    .font(WhoopStyle.chevron)
                Text(String(localized: "Via \(Self.sourceName(row.source))"))
                    .font(WhoopStyle.caption)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(StrandPalette.textTertiary, lineWidth: 1))
            if repo.isAutoTyped(row) {
                Text("Yoop named this from your heart rate.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: Strain and steps

    private var headline: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space6) {
            bigNumber(value: strain.map { String(format: "%.1f", $0) } ?? Self.missing,
                      color: StrandPalette.effortColor,
                      label: String(localized: "ACTIVITY STRAIN"),
                      typical: typical(strain, figures.typicalStrain, decimals: 1) { String(format: "%.1f", $0) })
            if let steps = figures.steps {
                bigNumber(value: steps.formatted(),
                          color: StrandPalette.textPrimary,
                          label: String(localized: "ACTIVITY STEPS"),
                          typical: typical(Double(steps), figures.typicalSteps, decimals: 0) {
                              Int($0.rounded()).formatted()
                          })
            }
            Spacer(minLength: 0)
        }
    }

    private func bigNumber(value: String, color: Color, label: String, typical: Typical?) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                Text(value)
                    .font(WhoopStyle.number(40))
                    .monospacedDigit()
                    .foregroundStyle(color)
                if let typical { typicalChip(typical) }
            }
            Text(label)
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// The small chip beside a figure: the sport's typical value, with a triangle saying whether this
    /// activity is above or below it.
    private func typicalChip(_ typical: Typical) -> some View {
        HStack(spacing: NoopMetrics.spaceHalf) {
            if typical.direction != 0 {
                Image(systemName: typical.direction > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                    .font(WhoopStyle.chevron)
            }
            Text(typical.text)
                .font(WhoopStyle.number(13))
                .monospacedDigit()
        }
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, NoopMetrics.space1)
        .padding(.vertical, NoopMetrics.spaceHalf)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(WhoopStyle.ringTrack))
    }

    /// The chip for a figure, or nil when either side is missing (WHOOP shows a missing Strain bare).
    private func typical(_ value: Double?, _ typical: Double?, decimals: Int,
                         format: (Double) -> String) -> Typical? {
        guard let value, let typical else { return nil }
        return Typical(text: format(typical),
                       direction: WhoopActivityBaseline.direction(value, typical: typical, decimals: decimals))
    }

    // MARK: Heart rate

    private struct HRPoint: Identifiable {
        let id: Int
        let time: Date
        let bpm: Double
    }

    /// The activity's heart rate with a little either side, dashed lines at its start and end, and the
    /// moment under the reader's finger read out above it.
    private var heartRateChart: some View {
        let pad = TimeInterval(WhoopActivityZones.chartPadding(seconds: row.endTs - row.startTs))
        let points = figures.hr.map {
            HRPoint(id: $0.ts, time: Date(timeIntervalSince1970: TimeInterval($0.ts)), bpm: $0.bpm)
        }
        let picked = hrSelection.flatMap { sel in
            points.min { abs($0.time.timeIntervalSince(sel)) < abs($1.time.timeIntervalSince(sel)) }
        }
        let low = points.isEmpty ? 40 : max(0, (points.map(\.bpm).min() ?? 60) - 10)
        let high = points.isEmpty ? 100 : (points.map(\.bpm).max() ?? 180) + 10
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                if let picked {
                    Text(WhoopTime.clock(picked.time))
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("\(Int(picked.bpm.rounded())) bpm")
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textPrimary)
                } else if points.count >= 2 {
                    Text("Press and hold the graph to see your heart rate")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
            }
            .frame(height: 16)
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Time", p.time), yStart: .value("BPM", low), yEnd: .value("BPM", p.bpm))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [StrandPalette.effortColor.opacity(0.45),
                                                                 StrandPalette.effortColor.opacity(0.04)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", p.time), y: .value("BPM", p.bpm))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(StrandPalette.effortColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                RuleMark(x: .value("Time", start))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                RuleMark(x: .value("Time", end))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if let picked {
                    RuleMark(x: .value("Time", picked.time))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", picked.time), y: .value("BPM", picked.bpm))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .symbolSize(36)
                }
            }
            .whoopScrub($hrSelection)
            .chartXScale(domain: start.addingTimeInterval(-pad)...end.addingTimeInterval(pad))
            .chartYScale(domain: low...high)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
                    AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .chartXAxis {
                // Each time sits inside the span, starting at the start line and ending at the end line,
                // so neither is cut off at the chart's edge.
                AxisMarks(values: [start, end]) { value in
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                        if let date = value.as(Date.self) {
                            Text(WhoopTime.clock(date))
                                .font(WhoopStyle.smallLabel)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                }
            }
            .frame(height: 200)
            .accessibilityLabel(Text(String(localized: "Heart rate during \(name)")))
        }
    }

    // MARK: Zones

    /// TYPICAL RANGE and DURATION over a row per zone, zone 5 first. With no heart rate the rows name
    /// each zone's share of the reserve instead of its bpm, as WHOOP's do.
    private var zonesSection: some View {
        let seconds = figures.bandSeconds
        let shares = seconds.flatMap { WhoopActivityZones.shares($0) }
        let ranges = WhoopActivityZones.bpmRanges(restingHR: figures.restingHR)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                typicalSwatch
                Text("TYPICAL RANGE")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("DURATION")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(WhoopTime.hms(seconds: durationSeconds))
                    .font(WhoopStyle.number(16))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            if figures.loaded {
                ForEach(Array((0..<WhoopActivityZones.bandCount).reversed()), id: \.self) { band in
                    zoneRow(band: band, seconds: seconds?[band], share: shares?[band],
                            range: ranges?[band], typical: figures.typicalShares[band])
                }
            }
        }
    }

    private func zoneRow(band: Int, seconds: Double?, share: Double?, range: WhoopActivityZones.BpmRange?,
                         typical: ClosedRange<Double>?) -> some View {
        let measured = seconds != nil
        let clock = WhoopTime.hmsSplit(seconds: seconds ?? 0)
        let color = Self.bandColor(band)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(Self.bandTitle(band, reservePercents: !measured))
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(measured ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                if measured, let range {
                    Text(Self.bpmText(range))
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Text("\(Int(((share ?? 0) * 100).rounded()))%")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(color.opacity(measured ? 1 : 0.5))
                Spacer(minLength: NoopMetrics.space1)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(clock.main)
                        .font(WhoopStyle.number(20))
                    Text(clock.seconds)
                        .font(WhoopStyle.number(12))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .monospacedDigit()
                .foregroundStyle(measured ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if measured {
                zoneBar(share: share ?? 0, typical: typical, color: color)
            }
        }
        .padding(.horizontal, WhoopStyle.compactPadding)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .whoopCard()
        .accessibilityElement(children: .combine)
    }

    /// The zone's share as a bar on WHOOP's striped track, under the sport's typical range for it.
    private func zoneBar(share: Double, typical: ClosedRange<Double>?, color: Color) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barHeight = geo.size.height * 0.7
            ZStack(alignment: .leading) {
                WhoopHatch()
                    .frame(height: barHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: share > 0 ? max(4, w * CGFloat(min(1, share))) : 0, height: barHeight)
                if let typical {
                    let width = max(3, w * CGFloat(min(1, typical.upperBound) - min(1, typical.lowerBound)))
                    typicalBand
                        .frame(width: width)
                        .offset(x: min(w * CGFloat(min(1, typical.lowerBound)), max(0, w - width)))
                }
            }
        }
        .frame(height: 20)
    }

    /// The typical-range band: a light fill between dashed edges.
    private var typicalBand: some View {
        Rectangle()
            .fill(WhoopStyle.typicalBand)
            .overlay(WhoopRangeEdges().stroke(StrandPalette.textSecondary,
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }

    private var typicalSwatch: some View {
        typicalBand.frame(width: 14, height: 14)
    }

    /// "ZONE 5" or "RESTORATIVE", with the share of the reserve, "ZONE 5 (90-100%)", when asked.
    static func bandTitle(_ band: Int, reservePercents: Bool) -> String {
        let edges = WhoopActivityZones.reserveEdges.map { Int(($0 * 100).rounded()) }
        guard band > 0 else {
            let title = String(localized: "RESTORATIVE")
            return reservePercents ? "\(title) (<\(edges[0])%)" : title
        }
        let title = String(localized: "ZONE \(band)")
        let upper = band < edges.count ? edges[band] : 100
        return reservePercents ? "\(title) (\(edges[band - 1])-\(upper)%)" : title
    }

    /// "162-175 BPM", "176+ BPM", "<120 BPM".
    static func bpmText(_ range: WhoopActivityZones.BpmRange) -> String {
        let unit = String(localized: "BPM")
        switch (range.lower, range.upper) {
        case let (lower?, upper?): return "\(lower)-\(upper) \(unit)"
        case let (lower?, nil): return "\(lower)+ \(unit)"
        case let (nil, upper?): return "<\(upper + 1) \(unit)"
        case (nil, nil): return unit
        }
    }

    /// WHOOP's zone colours: zone 5 red-orange, zone 4 orange, zone 3 green, zone 2 blue, zone 1 grey.
    static func bandColor(_ band: Int) -> Color {
        switch band {
        case 5: return StrandPalette.zone5
        case 4: return StrandPalette.zone4
        case 3: return WhoopStyle.stressMedium
        case 2: return WhoopStyle.stressLow
        case 1: return WhoopStyle.sufficientGray
        default: return StrandPalette.textSecondary
        }
    }

    // MARK: Key statistics

    private struct Statistic: Identifiable {
        let id: String
        let label: String
        let icon: String
        let value: String
        let unit: String?
        let typical: Typical?
    }

    private var statistics: [Statistic] {
        let kcal = row.energyKcal.flatMap { $0 > 0 ? $0 : nil }
        let avg = row.avgHr.flatMap { $0 > 0 ? Double($0) : nil }
        let peak = row.maxHr.flatMap { $0 > 0 ? Double($0) : nil }
        let whole: (Double) -> String = { Int($0.rounded()).formatted() }
        let bpm = String(localized: "bpm")
        var out = [
            Statistic(id: "kcal", label: String(localized: "CALORIES"), icon: "flame",
                      value: kcal.map(whole) ?? Self.missing, unit: nil,
                      typical: typical(kcal, figures.typicalKcal, decimals: 0, format: whole)),
            Statistic(id: "avg", label: String(localized: "AVG HR"), icon: "heart",
                      value: avg.map(whole) ?? Self.missing, unit: avg == nil ? nil : bpm,
                      typical: typical(avg, figures.typicalAvgHr, decimals: 0, format: whole)),
            Statistic(id: "max", label: String(localized: "MAX HR"), icon: "heart.fill",
                      value: peak.map(whole) ?? Self.missing, unit: peak == nil ? nil : bpm,
                      typical: typical(peak, figures.typicalMaxHr, decimals: 0, format: whole)),
        ]
        if let meters = row.distanceM, meters > 0 {
            let system = distanceUnitSystem
            let usual = figures.typicalDistance.map { Typical(
                text: UnitFormatter.distanceFromMeters($0, system: system),
                direction: WhoopActivityBaseline.direction(meters / 1000, typical: $0 / 1000, decimals: 1)) }
            out.append(Statistic(id: "distance", label: String(localized: "DISTANCE"), icon: "ruler",
                                 value: UnitFormatter.distanceFromMeters(meters, system: system), unit: nil,
                                 typical: usual))
        }
        return out
    }

    private var keyStatistics: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack {
                Text("KEY STATISTICS")
                    .font(WhoopStyle.label)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("VS. 30 DAY AVERAGE")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(statistics) { statCard($0) }
                }
            }
        }
    }

    private func statCard(_ s: Statistic) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: s.icon)
                    .font(WhoopStyle.icon)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(s.label)
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(s.value)
                    .font(WhoopStyle.number(28))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = s.unit {
                    Text(unit)
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if let typical = s.typical {
                typicalChip(typical)
            }
        }
        .frame(width: 150, alignment: .topLeading)
        .padding(WhoopStyle.compactPadding)
        .whoopCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    private func retype(to sport: String) {
        let old = row
        let trimmed = sport.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            await repo.changeActivityType(old, to: trimmed)
            row = WorkoutRow(startTs: old.startTs, endTs: old.endTs, sport: trimmed, source: old.source,
                             durationS: old.durationS, energyKcal: old.energyKcal, avgHr: old.avgHr,
                             maxHr: old.maxHr, strain: old.strain, distanceM: old.distanceM,
                             zonesJSON: old.zonesJSON, notes: old.notes, steps: old.steps)
        }
    }

    /// Deletes the activity (and any route recorded with it, as the Workouts list does) and leaves the page.
    private func delete() {
        let target = row
        RouteStore.remove(startTs: target.startTs, sport: target.sport)
        Task {
            await repo.deleteWorkout(target)
            await repo.refresh()
        }
        dismiss()
    }

    // MARK: Load

    private func load() async {
        let row = self.row
        let pad = WhoopActivityZones.chartPadding(seconds: row.endTs - row.startTs)
        let hr = await repo.workoutHrBuckets(from: row.startTs - pad, to: row.endTs + pad, source: row.source)
        let rest = restingHR(for: row)
        let seconds = await bandSeconds(row, restingHR: rest)
        let steps = await sessionSteps(row)

        let history = await repo.workoutRows()
        var pastShares: [[Double]] = []
        var pastSteps: [Int: Double] = [:]
        for past in WhoopActivityBaseline.sessions(for: row, in: history).prefix(Self.historyReadCap) {
            if let s = await bandSeconds(past, restingHR: restingHR(for: past)),
               let shares = WhoopActivityZones.shares(s) {
                pastShares.append(shares)
            }
            if steps != nil, let n = await sessionSteps(past) { pastSteps[past.startTs] = Double(n) }
        }
        guard !Task.isCancelled else { return }

        func typicalOf(_ pick: (WorkoutRow) -> Double?) -> Double? {
            WhoopActivityBaseline.typical(pick, for: row, in: history)
        }
        figures = Figures(
            loaded: true,
            hr: hr,
            restingHR: rest,
            bandSeconds: seconds,
            typicalShares: WhoopActivityZones.typicalRanges(pastShares),
            steps: steps,
            typicalStrain: typicalOf { $0.strain.map(AICoachEngine.strain21) },
            typicalSteps: steps == nil ? nil : typicalOf { pastSteps[$0.startTs] ?? $0.steps.map(Double.init) },
            typicalKcal: typicalOf { $0.energyKcal },
            typicalAvgHr: typicalOf { $0.avgHr.map(Double.init) },
            typicalMaxHr: typicalOf { $0.maxHr.map(Double.init) },
            typicalDistance: typicalOf { $0.distanceM })
    }

    private func restingHR(for row: WorkoutRow) -> Double {
        let day = Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        return WhoopActivityZones.restingHR(dayKey: day, days: repo.days)
    }

    /// Seconds per band for one session: WHOOP's own split when the row was imported with one (never
    /// overwritten by an on-device estimate, as on the workout detail), else the strap's heart rate.
    private func bandSeconds(_ row: WorkoutRow, restingHR: Double) async -> [Double]? {
        let duration = row.durationS ?? Double(row.endTs - row.startTs)
        if duration > 0, let percents = WorkoutZones.percents(row.zonesJSON),
           let shares = WhoopActivityZones.shares(importedPercents: percents) {
            return shares.map { $0 * duration }
        }
        let samples = await repo.workoutHrSamples(from: row.startTs, to: row.endTs, source: row.source)
        return WhoopActivityZones.bandSeconds(samples, from: row.startTs, to: row.endTs, restingHR: restingHR)
    }

    /// A session's steps, read as the workout detail reads them (#398): the row's own count, else for an
    /// on-foot sport the strap's counter, else the phone's pedometer. Nil when none has a count.
    private func sessionSteps(_ row: WorkoutRow) async -> Int? {
        if let own = row.steps, own > 0 { return own }
        guard WorkoutCatalog.isOnFoot(row.sport) else { return nil }
        if let ticks = await repo.strapStepTicks(from: row.startTs, to: row.endTs) {
            let scaled = Int((Double(ticks) / max(profile.stepTicksPerStep, 0.5)).rounded())
            if scaled > 0 { return scaled }
        }
        if let phone = await WorkoutPedometer.steps(fromSec: row.startTs, toSec: row.endTs), phone > 0 {
            return phone
        }
        return nil
    }
}

/// The dashed left and right edges of a typical-range band.
private struct WhoopRangeEdges: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + 0.5, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.maxY))
        return p
    }
}
