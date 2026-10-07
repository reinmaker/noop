#if os(iOS)
import SwiftUI
import UserNotifications
import StrandDesign

/// WHOOP-style notification switches (WHOOP's App Settings > Notifications, plus its morning Daily
/// Outlook and evening Day In Review).
struct WhoopNotificationsView: View {
    @AppStorage("coachBrief.enabled") private var dailyOutlook = true
    @AppStorage(WhoopNotifications.dayReviewKey) private var dayReview = true
    @AppStorage(WhoopNotifications.stressSummaryKey) private var stressSummary = true
    @AppStorage(WhoopNotifications.checkInsKey) private var checkIns = true
    @AppStorage(WhoopNotifications.offBodyKey) private var offBody = true
    @AppStorage(WhoopNotifications.travelKey) private var travel = true
    @State private var permissionDenied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space5) {
                if permissionDenied {
                    Text("Notifications are off for Yoop in iPhone Settings. Turn them on there to get these.")
                        .font(WhoopStyle.body)
                        .foregroundStyle(WhoopStyle.rangeAmber)
                }
                row(String(localized: "DAILY OUTLOOK"),
                    String(localized: "Your Coach's plan for the day, each morning."), $dailyOutlook)
                row(String(localized: "DAY IN REVIEW"),
                    String(localized: "A look back at your day every evening at 8:30pm."), $dayReview)
                row(String(localized: "DAILY STRESS SUMMARY"),
                    String(localized: "A summary of your stress for the day at 9pm."), $stressSummary)
                row(String(localized: "CONVERSATIONAL CHECK INS"),
                    String(localized: "Follow-ups based on conversations you've had with your Coach."), $checkIns)
                row(String(localized: "DEVICE OFF-BODY"),
                    String(localized: "Get notified if your strap is off-body for over 10 minutes."), $offBody)
                row(String(localized: "TRAVEL INSIGHTS"),
                    String(localized: "Tips to adjust when you change time zones."), $travel)
            }
            .padding(NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: dayReview) { _, _ in WhoopNotifications.scheduleDayReview() }
        .task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            permissionDenied = await center.notificationSettings().authorizationStatus == .denied
            WhoopNotifications.scheduleDayReview()
        }
    }

    private func row(_ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(WhoopStyle.smallLabel)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .tint(WhoopStyle.rangeGreen)
            Text(detail)
                .font(WhoopStyle.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Rectangle().fill(WhoopStyle.cardStroke).frame(height: 1).padding(.top, NoopMetrics.space2)
        }
    }
}
#endif
