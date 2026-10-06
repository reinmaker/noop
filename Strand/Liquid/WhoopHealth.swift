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
        let readings = BodyVitalSigns.readings(days: repo.days, today: nil, temperatureUnit: .celsius)
        let byKey = Dictionary(readings.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let measured = Self.gridOrder.compactMap { byKey[$0.key] }.filter { $0.banding.band != .noData }
        let inRange = measured.filter { $0.banding.band == .inRange }.count

        return NavigationLink(value: TabRoute.health) {
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
