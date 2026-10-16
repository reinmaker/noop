import SwiftUI
import StrandDesign

// Yoop: the Healthspan page's contributors as WHOOP lays them out, in three sections (Sleep, Strain, Fitness). Each
// row is a ten-step bar from the unhealthy end to the healthy one, the six-month value marked above it, the 30-day
// value below it, and the years the contributor adds or takes off at the right. The figures are the snapshot's
// (`WhoopAge.Impact` for the six months, `WhoopAge.Inputs` for the 30 days); the bar's ends are for reading only.

// MARK: - The bar's scale

/// How one contributor is drawn: the span of its bar, its two end labels, whether the healthy end is the left one,
/// and how its value reads above the marker.
struct WhoopHealthspanScale {
    let lower: Double
    let upper: Double
    let lowLabel: String?
    let highLabel: String?
    /// The healthy end is the low one (resting heart rate).
    let reversed: Bool
    let valueText: (Double) -> String

    private static func hoursAndMinutes(_ minutes: Double, unit: Bool = true) -> String {
        let total = Int(minutes.rounded())
        let text = String(format: "%d:%02d", total / 60, total % 60)
        return unit ? text + " h" : text
    }

    static func scale(_ key: WhoopAge.Key) -> WhoopHealthspanScale {
        switch key {
        case .sleepConsistency:
            return .init(lower: 40, upper: 100, lowLabel: "40%", highLabel: "100%", reversed: false) { "\(Int($0.rounded()))%" }
        case .sleepDuration:
            return .init(lower: 5, upper: 8, lowLabel: "5h", highLabel: "8h", reversed: false) { hoursAndMinutes($0 * 60) }
        case .steps:
            return .init(lower: 0, upper: 16_000, lowLabel: "0K", highLabel: "16K", reversed: false) {
                String(localized: "\(Int($0.rounded()).formatted()) Steps")
            }
        case .zones13:
            return .init(lower: 0, upper: 210, lowLabel: "0h", highLabel: nil, reversed: false) { hoursAndMinutes($0) }
        case .zones45:
            return .init(lower: 0, upper: 60, lowLabel: "0h", highLabel: "1h", reversed: false) { hoursAndMinutes($0) }
        case .strength:
            return .init(lower: 0, upper: 120, lowLabel: "0h", highLabel: "2h", reversed: false) { hoursAndMinutes($0) }
        case .vo2max:
            return .init(lower: 15, upper: 70, lowLabel: "15", highLabel: "70", reversed: false) { "\(Int($0.rounded())) ml/kg/min" }
        case .restingHr:
            return .init(lower: 40, upper: 80, lowLabel: "40bpm", highLabel: "80bpm", reversed: true) { "\(Int($0.rounded())) bpm" }
        case .leanBodyMass:
            return .init(lower: 0, upper: 100, lowLabel: nil, highLabel: nil, reversed: false) { "\(Int($0.rounded()))%" }
        }
    }

    /// Where a value sits along the bar, 0 to 1, clamped.
    func fraction(_ value: Double) -> Double {
        guard upper > lower else { return 0 }
        return min(1, max(0, (value - lower) / (upper - lower)))
    }

    /// How healthy the step at `index` (0 to 9, left to right) is, 0 to 1.
    func goodness(step index: Int) -> Double {
        let f = Double(index) / 9
        return reversed ? 1 - f : f
    }
}

/// What the row says under its title once opened, from the years it adds.
enum WhoopHealthspanWords {
    static func sentence(years: Double) -> String {
        if years < -0.05 { return String(localized: "Outperforming. This is taking years off your WHOOP Age.") }
        if years > 0.05 { return String(localized: "Holding you back. This is adding years to your WHOOP Age.") }
        return String(localized: "On target. This adds nothing and takes nothing.")
    }

    /// The years as the row's right edge prints them: "-0.2", "0.0".
    static func years(_ y: Double) -> String { abs(y) < 0.05 ? "0.0" : String(format: "%.1f", y) }
}

// MARK: - The bar

/// Ten steps from the unhealthy end (amber) to the healthy one (green), the six-month value above it on a white
/// triangle and the 30-day value under it on a grey one.
struct WhoopHealthspanBar: View {
    let scale: WhoopHealthspanScale
    let sixMonth: Double?
    let thirtyDay: Double?

    private func color(_ step: Int) -> Color {
        let g = scale.goodness(step: step)
        if sixMonth == nil { return StrandPalette.textTertiary.opacity(0.35) }
        return g < 0.5 ? WhoopStyle.rangeAmber.opacity(0.45 + 0.55 * (1 - g / 0.5))
                       : WhoopStyle.rangeGreen.opacity(0.4 + 0.6 * ((g - 0.5) / 0.5))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let place: (Double) -> CGFloat = { CGFloat(scale.fraction($0)) * width }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 2) {
                    ForEach(0..<10, id: \.self) { step in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(color(step))
                            .frame(height: 5)
                    }
                }
                .frame(width: width)
                .offset(y: 30)
                if let sixMonth {
                    VStack(spacing: 2) {
                        Text(scale.valueText(sixMonth))
                            .font(WhoopStyle.detail)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize()
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(WhoopStyle.chevron)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .position(x: min(max(place(sixMonth), 38), max(38, width - 38)), y: 15)
                }
                if let thirtyDay {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(WhoopStyle.chevron)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .position(x: place(thirtyDay), y: 44)
                }
                HStack {
                    Text(scale.lowLabel ?? "")
                        .foregroundStyle(scale.reversed ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                    Spacer()
                    Text(scale.highLabel ?? "")
                        .foregroundStyle(scale.reversed ? WhoopStyle.rangeAmber : WhoopStyle.rangeGreen)
                }
                .font(WhoopStyle.chevron)
                .offset(y: 50)
            }
        }
        .frame(height: 68)
    }
}

// MARK: - The sections

/// Sleep, Strain and Fitness, each a card of rows.
struct WhoopHealthspanSections: View {
    let result: WhoopAge.Result
    /// The last 30 days' averages (the grey triangle).
    let recent: WhoopAge.Inputs?
    var vo2: Vo2Choice?

    @State private var opened: Set<WhoopAge.Key> = [.sleepConsistency]

    private struct Block: Identifiable {
        let id: String
        let title: String
        let keys: [WhoopAge.Key]
    }

    private var sections: [Block] {
        [Block(id: "sleep", title: String(localized: "Sleep"), keys: [.sleepConsistency, .sleepDuration]),
         Block(id: "strain", title: String(localized: "Strain"), keys: [.zones13, .zones45, .strength, .steps]),
         Block(id: "fitness", title: String(localized: "Fitness"), keys: [.vo2max, .restingHr, .leanBodyMass])]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack {
                        Text(section.title)
                            .font(WhoopStyle.sectionTitle)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: NoopMetrics.space2)
                        legend
                    }
                    VStack(spacing: 0) {
                        let impacts = section.keys.compactMap { key in result.impacts.first { $0.key == key } }
                        ForEach(Array(impacts.enumerated()), id: \.element.id) { index, impact in
                            row(impact)
                            if index < impacts.count - 1 { Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1) }
                        }
                    }
                    .padding(.horizontal, WhoopStyle.compactPadding)
                    .whoopCard()
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: NoopMetrics.space2) {
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.down.fill").font(WhoopStyle.chevron)
                Text("6 Month avg.")
            }
            .foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.up.fill").font(WhoopStyle.chevron)
                Text("30 Day avg.")
            }
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .font(WhoopStyle.caption)
    }

    @ViewBuilder private func row(_ impact: WhoopAge.Impact) -> some View {
        let scale = WhoopHealthspanScale.scale(impact.key)
        let isOpen = opened.contains(impact.key)
        let hasValue = impact.value != nil
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Button {
                if isOpen { opened.remove(impact.key) } else { opened.insert(impact.key) }
            } label: {
                HStack(spacing: NoopMetrics.space2) {
                    Text(WhoopAgeText.label(impact.key))
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if impact.key == .vo2max, vo2?.isRough == true {
                        Text("ROUGH")
                            .font(WhoopStyle.chevron)
                            .foregroundStyle(WhoopStyle.rangeAmber)
                            .padding(.horizontal, NoopMetrics.space2)
                            .padding(.vertical, NoopMetrics.space1)
                            .background(Capsule().fill(WhoopStyle.rangeAmber.opacity(0.18)))
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(WhoopStyle.detail)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .buttonStyle(.plain)
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                WhoopHealthspanBar(scale: scale, sixMonth: impact.value, thirtyDay: recent?.value(impact.key))
                VStack(spacing: 0) {
                    Text(hasValue ? WhoopHealthspanWords.years(impact.years) : "--")
                        .font(WhoopStyle.number(22))
                        .foregroundStyle(!hasValue || abs(impact.years) < 0.05 ? StrandPalette.textPrimary
                                         : (impact.years < 0 ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber))
                    Text("years")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(width: 52)
            }
            if isOpen {
                Text(hasValue ? WhoopHealthspanWords.sentence(years: impact.years)
                              : (impact.key == .leanBodyMass
                                 ? String(localized: "Yoop holds no lean body mass, so this adds nothing, as in WHOOP.")
                                 : String(localized: "Needs 14 days of strap data in the window.")))
                    .font(WhoopStyle.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasValue, let target = impact.target {
                    Text("TARGET \(WhoopAgeText.target(impact.key, target))")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .padding(.vertical, NoopMetrics.space3)
    }
}
