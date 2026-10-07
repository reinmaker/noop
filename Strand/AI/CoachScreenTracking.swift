import SwiftUI

/// WHOOP-style screen awareness: each screen tells the Coach it is on screen, so opening the Coach
/// from it starts a conversation about that screen (`AICoachEngine.openWithScreenContext()`).
/// The screen most recently shown. A plain shared value rather than an environment object, so marking a
/// screen can never fail on a view tree (a sheet, a macOS pane) that was not handed the Coach.
@MainActor
enum CoachScreenState {
    static var current: AICoachEngine.CoachScreen = .home
}

private struct CoachScreenMarker: ViewModifier {
    let screen: AICoachEngine.CoachScreen

    func body(content: Content) -> some View {
        content.onAppear { CoachScreenState.current = screen }
    }
}

extension View {
    /// Mark this view as the given Coach screen while it is visible.
    func coachScreen(_ screen: AICoachEngine.CoachScreen) -> some View {
        modifier(CoachScreenMarker(screen: screen))
    }
}

extension TabRoute {
    /// The Coach screen a pushed route counts as.
    var coachScreen: AICoachEngine.CoachScreen {
        switch self {
        case .metric(let key), .metricSourced(let key, _):
            switch key {
            case HeroRingMetric.charge, "hrv", "rhr", "resp_rate": return .recovery
            case HeroRingMetric.effort: return .strain
            case HeroRingMetric.rest: return .sleep
            default: return .health
            }
        case .sleep: return .sleep
        case .recovery: return .recovery
        case .strain: return .strain
        case .workouts: return .strain
        case .health, .stress, .hydration, .healthMonitor: return .health
        case .fullDayChart, .coupled: return .home
        case .metricExplorer, .dataSources: return .trends
        }
    }
}
