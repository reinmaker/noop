import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// WHOOP-style top of the Health tab: the age bubble (NOOP's Fitness Age against the wearer's real age),
/// the Health Monitor grid (five vitals against their personal ranges), the Stress Monitor and the Lab
/// Book card. NOOP's existing Health sections follow underneath.
struct WhoopHealthHeader: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter
    @State private var fitnessAge: Double?
    @State private var stress: Double?

    var body: some View {
        VStack(spacing: NoopMetrics.space4) {
            ageBubble
            healthMonitor
            WhoopStressChartCard(currentStress: stress)
            Button { router.openLabBook() } label: {
                WhoopTitledCard(title: String(localized: "LAB BOOK")) {
                    Text("Keep your blood tests and lab results next to your strap data.")
                        .font(WhoopStyle.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
        .task(id: repo.refreshSeq) {
            fitnessAge = (await repo.exploreSeries(key: "fitness_age", source: "my-whoop")).last?.value
            // The same 0-3 score Home's Stress Monitor shows.
            let stored = await repo.series(key: "stress", source: "my-whoop")
            stress = StressModel(days: repo.days, stored: stored)?.score
        }
    }

    // MARK: Age bubble

    private var ageBubble: some View {
        let realAge = profile.age
        let difference = fitnessAge.map { Double(realAge) - $0 }
        return VStack(spacing: NoopMetrics.space2) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [WhoopStyle.rangeGreen.opacity(0.55), WhoopStyle.rangeGreen.opacity(0.08)],
                                         center: .center, startRadius: 10, endRadius: 120))
                Circle().strokeBorder(WhoopStyle.rangeGreen.opacity(0.7), lineWidth: 2)
                VStack(spacing: NoopMetrics.space1) {
                    Text(fitnessAge.map { String(format: "%.1f", $0) } ?? "—")
                        .font(WhoopStyle.number(48))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("FITNESS AGE")
                        .font(WhoopStyle.smallLabel)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let difference, realAge > 0 {
                        Text(difference >= 0
                             ? String(localized: "\(String(format: "%.1f", difference)) years younger")
                             : String(localized: "\(String(format: "%.1f", -difference)) years older"))
                            .font(WhoopStyle.detail)
                            .foregroundStyle(difference >= 0 ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                    }
                }
            }
            .frame(width: 230, height: 230)
            NavigationLink(value: TabRoute.metric("fitness_age")) {
                WhoopActionButtonLabel(title: String(localized: "SEE FITNESS AGE TREND"), systemImage: "chart.line.uptrend.xyaxis")
            }
            .buttonStyle(.plain)
        }
        .padding(.top, NoopMetrics.space2)
    }

    // MARK: Health Monitor grid

    private struct VitalCell: Identifiable {
        let key: String
        let label: String
        let icon: String
        var id: String { key }
    }

    private static let gridOrder = [
        VitalCell(key: "resp", label: "RESP", icon: "lungs"), VitalCell(key: "spo2", label: "SPO₂", icon: "drop"),
        VitalCell(key: "rhr", label: "RHR", icon: "heart"), VitalCell(key: "hrv", label: "HRV", icon: "waveform.path.ecg"),
        VitalCell(key: "skin", label: "TEMP", icon: "thermometer.medium"),
    ]

    private var healthMonitor: some View {
        let readings = BodyVitalSigns.readings(days: repo.days, today: nil, temperatureUnit: .celsius,
                                               skinTempPreferred: .deviation)
        let byKey = Dictionary(readings.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let measured = Self.gridOrder.compactMap { byKey[$0.key] }.filter { $0.banding.band != .noData }
        let inRange = measured.filter { $0.banding.band == .inRange }.count

        return NavigationLink(value: TabRoute.healthMonitor) {
            WhoopTitledCard(title: String(localized: "HEALTH MONITOR")) {
                HStack(spacing: 0) {
                    ForEach(Self.gridOrder) { item in
                        let band = byKey[item.key]?.banding.band ?? .noData
                        VStack(spacing: NoopMetrics.space2) {
                            Image(systemName: item.icon)
                                .font(WhoopStyle.icon)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Text(item.label)
                                .font(WhoopStyle.smallLabel)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Image(systemName: band == .inRange ? "checkmark" : (band == .noData ? "minus" : "exclamationmark"))
                                .font(WhoopStyle.chevron)
                                .foregroundStyle(band == .inRange ? WhoopStyle.rangeGreen
                                                 : (band == .noData ? StrandPalette.textTertiary : WhoopStyle.rangeAmber))
                                .frame(width: 22, height: 22)
                                .background(RoundedRectangle(cornerRadius: 5).fill(WhoopStyle.ringTrack))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: measured.count == inRange && !measured.isEmpty ? "checkmark.square.fill" : "exclamationmark.square.fill")
                        .foregroundStyle(measured.count == inRange && !measured.isEmpty ? WhoopStyle.rangeGreen : WhoopStyle.rangeAmber)
                    Text(measured.isEmpty ? String(localized: "Calibrating: wear your strap tonight")
                         : String(localized: "\(inRange)/\(measured.count) metrics within range"))
                        .font(WhoopStyle.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                }
                .padding(NoopMetrics.space3)
                .background(RoundedRectangle(cornerRadius: 10).fill(WhoopStyle.ringTrack.opacity(0.6)))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Health Monitor screen

/// WHOOP's Health Monitor screen: live heart rate from the strap, then the five overnight vitals, each
/// with last night's value and whether it sits within the user's own range. Skin temperature is shown
/// from baseline, as WHOOP does.
struct WhoopHealthMonitorScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    private struct Tile: Identifiable {
        let key: String
        let title: String
        let icon: String
        var id: String { key }
    }

    private static let tiles: [Tile] = [
        Tile(key: "resp", title: String(localized: "RESPIRATORY RATE"), icon: "lungs"),
        Tile(key: "spo2", title: String(localized: "BLOOD OXYGEN (SPO₂)"), icon: "drop"),
        Tile(key: "rhr", title: String(localized: "RHR"), icon: "heart"),
        Tile(key: "hrv", title: String(localized: "HRV"), icon: "waveform.path.ecg"),
        Tile(key: "skin", title: String(localized: "SKIN TEMP (FROM BASELINE)"), icon: "thermometer.medium"),
    ]

    var body: some View {
        let readings = BodyVitalSigns.readings(days: repo.days, today: nil, temperatureUnit: .celsius,
                                               skinTempPreferred: .deviation)
        let byKey = Dictionary(readings.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                liveHeartRate
                LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.space3),
                                    GridItem(.flexible(), spacing: NoopMetrics.space3)],
                          spacing: NoopMetrics.space3) {
                    ForEach(Self.tiles) { tile in
                        vitalTile(tile, reading: byKey[tile.key])
                    }
                }
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

    private var liveHeartRate: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("HEART RATE")
                .font(WhoopStyle.smallLabel)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Image(systemName: "heart.fill")
                    .font(WhoopStyle.icon)
                    .foregroundStyle(StrandPalette.statusCritical)
                Text(model.bpm.map(String.init) ?? "--")
                    .font(WhoopStyle.number(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("BPM")
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Text(model.bpm != nil ? String(localized: "Live from your strap")
                 : (live.connected ? String(localized: "Reading your heart rate…") : String(localized: "Device disconnected")))
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(WhoopStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .whoopCard()
    }

    private func vitalTile(_ tile: Tile, reading: BodyVitalReading?) -> some View {
        let band = reading?.banding.band ?? .noData
        let status: String
        let color: Color
        switch band {
        case .inRange:
            status = String(localized: "Within range")
            color = WhoopStyle.rangeGreen
        case .outOfRange:
            status = String(localized: "Out of range")
            color = WhoopStyle.rangeAmber
        case .noData:
            status = String(localized: "No data")
            color = StrandPalette.textTertiary
        }
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                Image(systemName: tile.icon)
                    .font(WhoopStyle.detail)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(tile.title)
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(reading?.formattedValue ?? "--")
                .font(WhoopStyle.number(28))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: NoopMetrics.space1) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status)
                    .font(WhoopStyle.caption)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .background(Capsule().fill(WhoopStyle.ringTrack))
        }
        .padding(WhoopStyle.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .whoopCard()
    }
}
