import SwiftUI
import Charts
import StrandDesign

// WHOOP-style fork: the pieces the pages behind My Dashboard's rows share (Steps, Calories, VO₂ Max and
// Blood Oxygen): the title, the headline card, the hour-by-hour bars, a quiet note card and the week bars.
// Values come from NOOP's own on-device data; nothing here computes a number.

/// The page title, as the Recovery and Strain screens give theirs: TODAY, or the weekday and date.
func whoopPageTitle(day: String, isToday: Bool) -> String {
    guard !isToday, let date = WhoopDayFigures.date(of: day) else { return String(localized: "TODAY") }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
}

/// "9 PM", "21:00": a clock hour in the reader's own style.
func whoopHourText(_ ts: Int) -> String {
    Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.dateTime.hour())
}

/// A page's headline: the row's own number big, with the 30-day normal under it and an arrow coloured by
/// whether the move is good for the metric.
struct WhoopPageHero: View {
    let icon: String
    let label: String
    let value: String
    var unit: String?
    /// The normal, formatted; nil hides the line. Its label says which it is: the 30-day whole-day normal,
    /// or today's normal by this time of day.
    var normal: String?
    var normalLabel = String(localized: "30-DAY NORMAL")
    /// +1 above the normal, -1 below, 0 level or unknown.
    var direction: Int = 0
    var higherIsBetter = true
    var caption: String?
    /// A line under the normal, such as the whole-day normal beside a by-now one.
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: NoopMetrics.space2) {
                Image(systemName: icon)
                    .font(WhoopStyle.icon)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(label)
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(value)
                    .font(WhoopStyle.number(56))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let normal {
                HStack(spacing: NoopMetrics.space2) {
                    Text(normalLabel)
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(normal)
                        .font(WhoopStyle.detail)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if direction != 0 {
                        Image(systemName: direction > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(WhoopStyle.chevron)
                            .foregroundStyle((direction > 0) == higherIsBetter ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                    }
                }
            }
            if let detail {
                Text(detail)
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if let caption {
                Text(caption)
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WhoopStyle.cardPadding)
        .whoopCard()
    }
}

/// A line of plain context under a headline.
struct WhoopPageSentence: View {
    let text: String

    var body: some View {
        Text(text)
            .font(WhoopStyle.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A quiet card of small print: how a figure is measured, and what it is not.
struct WhoopPageNote: View {
    let title: String
    let lines: [String]

    var body: some View {
        WhoopTitledCard(title: title, showsChevron: false) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The day's hours as bars, with the sleeping hours dimmed, a hold-and-drag readout, and one line that
/// says whether the bars hold all of the day's number.
struct WhoopHourBarsCard: View {
    let title: String
    let split: WhoopHourly.Split
    let tint: Color
    /// The line over the chart for the hour under the finger: "9 PM: 412 steps".
    let readout: (WhoopHourly.Bar) -> String
    /// What the card says when no hour is held.
    let hint: String
    /// How the bars stand against the day's number (see `WhoopHourReconciliation`).
    let reconciliation: String?

    @State private var selected: Date?

    private var held: WhoopHourly.Bar? {
        guard let selected else { return nil }
        let ts = Int(selected.timeIntervalSince1970)
        return split.bars.first { ts >= $0.start && ts < $0.start + 3_600 }
    }

    var body: some View {
        WhoopTitledCard(title: title, showsChevron: false) {
            Text(held.map(readout) ?? hint)
                .font(WhoopStyle.detail)
                .foregroundStyle(held == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Chart(split.bars) { bar in
                let dimmed = held != nil && held?.id != bar.id
                BarMark(x: .value("Hour", Date(timeIntervalSince1970: TimeInterval(bar.start)), unit: .hour),
                        y: .value("Value", bar.value))
                    .foregroundStyle(tint.opacity(bar.asleep ? 0.3 : (dimmed ? 0.35 : 1)))
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisGridLine().foregroundStyle(WhoopStyle.cardStroke)
                    AxisValueLabel(format: .dateTime.hour())
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .whoopScrub($selected)
            .frame(height: 170)
            if split.bars.contains(where: \.asleep) {
                HStack(spacing: NoopMetrics.space2) {
                    RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.3)).frame(width: 12, height: 8)
                    Text("Asleep")
                        .font(WhoopStyle.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let reconciliation {
                Text(reconciliation)
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Seven calendar days as bars, the shown day at full strength. The days are the calendar's: a day with no
/// value keeps its empty slot, so the week never reaches back a day to fill it (the Strain & Recovery card
/// on Home is keyed the same way).
struct WhoopDayBarsCard: View {
    let title: String
    /// The seven day keys, oldest first.
    let week: [String]
    /// A value per day key; a day without one is an empty slot.
    let values: [String: Double]
    let shownDay: String
    let tint: Color

    @State private var selected: String?

    private func weekday(_ key: String) -> String {
        WhoopDayFigures.date(of: key)?.formatted(.dateTime.weekday(.abbreviated)) ?? key
    }

    var body: some View {
        WhoopTitledCard(title: title, showsChevron: false) {
            let present = week.filter { values[$0] != nil }
            if present.isEmpty {
                Text("Fills in as days are scored.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Chart {
                    ForEach(present, id: \.self) { key in
                        let dimmed = selected != nil ? selected != key : key != shownDay
                        BarMark(x: .value("Day", key), y: .value("Value", values[key] ?? 0), width: .ratio(0.5))
                            .foregroundStyle(tint.opacity(dimmed ? 0.4 : 1))
                            .annotation(position: .top, spacing: 2) {
                                Text(Int((values[key] ?? 0).rounded()).formatted())
                                    .font(selected == key ? WhoopStyle.smallLabel : WhoopStyle.chevron)
                                    .foregroundStyle(tint.opacity(dimmed ? 0.5 : 1))
                            }
                    }
                }
                .chartYScale(domain: 0...(max(1, present.compactMap { values[$0] }.max() ?? 1) * 1.15))
                .chartYAxis(.hidden)
                .chartXScale(domain: week)
                .chartXAxis {
                    AxisMarks(values: week) { value in
                        AxisValueLabel {
                            Text(value.as(String.self).map(weekday) ?? "")
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .whoopScrub($selected)
                .frame(height: 170)
            }
        }
    }
}

/// Seven days as stacked bars, the shown day at full strength: a base layer and a top layer per day (basal
/// and active energy), with the day's whole figure over the bar.
struct WhoopStackedWeekBars: View {
    struct Day: Identifiable {
        let day: String
        let base: Double
        let top: Double
        var id: String { day }
        var total: Double { base + top }
    }

    let title: String
    let days: [Day]
    /// The seven calendar days, oldest first. A day with no entry in `days` keeps its empty slot.
    let week: [String]
    let shownDay: String
    let baseTint: Color
    let topTint: Color
    let baseName: String
    let topName: String

    @State private var selected: String?

    private func weekday(_ key: String) -> String {
        WhoopDayFigures.date(of: key)?.formatted(.dateTime.weekday(.abbreviated)) ?? key
    }

    var body: some View {
        WhoopTitledCard(title: title, showsChevron: false) {
            if days.isEmpty {
                Text("Fills in as days are scored.")
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Chart {
                    ForEach(days) { day in
                        let dimmed = selected != nil ? selected != day.day : day.day != shownDay
                        BarMark(x: .value("Day", day.day), y: .value("Value", day.base), width: .ratio(0.5))
                            .foregroundStyle(by: .value("Layer", baseName))
                            .opacity(dimmed ? 0.4 : 1)
                        BarMark(x: .value("Day", day.day), y: .value("Value", day.top), width: .ratio(0.5))
                            .foregroundStyle(by: .value("Layer", topName))
                            .opacity(dimmed ? 0.4 : 1)
                            .annotation(position: .top, spacing: 2) {
                                Text(Int(day.total.rounded()).formatted())
                                    .font(selected == day.day ? WhoopStyle.smallLabel : WhoopStyle.chevron)
                                    .foregroundStyle(StrandPalette.textPrimary.opacity(dimmed ? 0.5 : 1))
                            }
                    }
                }
                .chartForegroundStyleScale([baseName: baseTint, topName: topTint])
                .chartLegend(.hidden)
                .chartYScale(domain: 0...((days.map(\.total).max() ?? 0) * 1.15))
                .chartYAxis(.hidden)
                .chartXScale(domain: week)
                .chartXAxis {
                    AxisMarks(values: week) { value in
                        AxisValueLabel {
                            Text(value.as(String.self).map(weekday) ?? "")
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .whoopScrub($selected)
                .frame(height: 190)
                HStack(spacing: NoopMetrics.space4) {
                    legend(topTint, topName)
                    legend(baseTint, baseName)
                }
            }
        }
    }

    private func legend(_ color: Color, _ name: String) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(name)
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// A card with one figure, its date and what it is: the best day of the last 30, the 30-day range.
struct WhoopPageFigureCard: View {
    let title: String
    let value: String
    var unit: String?
    let detail: String

    var body: some View {
        WhoopTitledCard(title: title, showsChevron: false) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(value)
                    .font(WhoopStyle.number(32))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit {
                    Text(unit)
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// The scroll page every one of these screens sits in: dark base, inset gutters, a Coach pill at the foot.
struct WhoopDayPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: NoopMetrics.space4) {
                content
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, NoopMetrics.space2)
            .padding(.bottom, NoopMetrics.space10)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text(title))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
