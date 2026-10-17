import SwiftUI
import Charts
import StrandDesign

// Yoop: the "Weekly Trends" cards of the Recovery and Strain screens as WHOOP draws them, read from WHOOP's
// own Recovery screen on 17 Oct 2026 (layout only): the seven calendar days ending on the shown day, each with
// its weekday and date under it, the shown day's column picked out, Recovery and Sleep Performance as bars in
// their colour, HRV, resting heart rate and respiratory rate as a line with a ringed point per day and a soft
// fill under it, and a chevron to the metric's own screen. A day with no figure keeps its slot.

/// One card of the week.
struct WhoopWeekChartCard: View {
    enum Style { case bars, line, stacked }

    /// One slice of a stacked bar.
    struct Segment {
        let value: Double
        let color: Color
    }

    struct Point: Identifiable {
        let key: String
        let value: Double
        let label: String
        /// The bar's colour; a line takes the card's.
        let color: Color
        /// A stacked bar's slices, bottom first; `value` is their total.
        var segments: [Segment] = []
        var id: String { key }
    }

    let title: String
    /// The seven calendar days, oldest first, as day keys.
    let keys: [String]
    let points: [Point]
    var style: Style = .bars
    /// The day the screen shows: its column is picked out.
    var selectedKey: String?
    /// The span of the value axis, with room above for the labels.
    let domain: ClosedRange<Double>
    var lineColor: Color = WhoopStyle.reviewAccent
    /// The metric screen the card opens, nil for none.
    var route: TabRoute?
    /// What a stacked card's slices stand for, drawn as a key above the chart.
    var legend: [(name: String, color: Color)] = []

    var body: some View {
        if let route {
            NavigationLink(value: route) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        WhoopTitledCard(title: title, showsChevron: route != nil) {
            if points.isEmpty {
                Text("Fills in as days are scored.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(height: 60)
            } else {
                if !legend.isEmpty {
                    HStack(spacing: NoopMetrics.space3) {
                        Spacer(minLength: 0)
                        ForEach(Array(legend.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 10, height: 10)
                                Text(item.name).font(WhoopStyle.chevron).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
                chart
            }
        }
    }

    private var chart: some View {
        Chart {
            if let selectedKey, keys.contains(selectedKey) {
                RectangleMark(x: .value("Day", selectedKey),
                              yStart: .value("Low", domain.lowerBound), yEnd: .value("High", domain.upperBound),
                              width: .ratio(0.9))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.08))
            }
            ForEach(points) { point in
                if style == .stacked {
                    let slices = point.segments.isEmpty ? [Segment(value: 0, color: point.color)] : point.segments
                    ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                        BarMark(x: .value("Day", point.key), y: .value("Value", slice.value), width: .fixed(14))
                            .foregroundStyle(slice.color)
                            .annotation(position: .top, spacing: 2) {
                                if index == slices.count - 1 {
                                    Text(point.label)
                                        .font(WhoopStyle.smallLabel)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                }
                            }
                    }
                } else if style == .bars {
                    BarMark(x: .value("Day", point.key), y: .value("Value", point.value), width: .fixed(14))
                        .foregroundStyle(point.color)
                        .annotation(position: .top, spacing: 2) {
                            Text(point.label)
                                .font(WhoopStyle.smallLabel)
                                .foregroundStyle(point.color)
                        }
                } else {
                    AreaMark(x: .value("Day", point.key),
                             yStart: .value("Base", domain.lowerBound), yEnd: .value("Value", point.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(LinearGradient(colors: [lineColor.opacity(0.26), lineColor.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", point.key), y: .value("Value", point.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(lineColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Day", point.key), y: .value("Value", point.value))
                        .foregroundStyle(lineColor)
                        .symbol {
                            Circle()
                                .strokeBorder(lineColor, lineWidth: 2)
                                .background(Circle().fill(StrandPalette.surfaceBase))
                                .frame(width: 10, height: 10)
                        }
                        .annotation(position: .top, spacing: 4) {
                            Text(point.label)
                                .font(WhoopStyle.smallLabel)
                                .foregroundStyle(lineColor)
                        }
                }
            }
        }
        .chartXScale(domain: keys)
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(WhoopStyle.ringTrack)
            }
        }
        .chartXAxis {
            AxisMarks(values: keys) { value in
                AxisValueLabel {
                    if let key = value.as(String.self) { dayLabel(key) }
                }
            }
        }
        .frame(height: 190)
    }

    private func dayLabel(_ key: String) -> some View {
        let picked = key == selectedKey
        return VStack(spacing: 2) {
            Text(Self.weekday(key)).font(WhoopStyle.chevron)
            Text(Self.dayOfMonth(key)).font(WhoopStyle.chevron)
        }
        .foregroundStyle(picked ? StrandPalette.textPrimary : StrandPalette.textSecondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(picked ? StrandPalette.textPrimary.opacity(0.1) : Color.clear))
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Sat", in the reader's language.
    static func weekday(_ key: String) -> String {
        guard let date = parser.date(from: key) else { return key }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// "10".
    static func dayOfMonth(_ key: String) -> String {
        guard let date = parser.date(from: key) else { return "" }
        return date.formatted(.dateTime.day())
    }

    /// The value axis for a line: the points' span with room either side, at least `minSpan` wide, so a flat week
    /// does not stretch to fill the card.
    static func lineDomain(_ values: [Double], minSpan: Double) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...minSpan }
        let span = max(minSpan, (hi - lo) * 1.6)
        let middle = (hi + lo) / 2
        return (middle - span / 2)...(middle + span / 2)
    }
}
