import XCTest
import Foundation
@testable import Strand
import StrandAnalytics

/// The Coach's stress line (`AICoachEngine.stressContextLine`) under Yoop stress.
final class WhoopStressCoachLineTests: XCTestCase {

    /// The Coach line is the same sentence as before for the hourly read, and says workouts are left out
    /// only when Yoop stress is on.
    func testCoachLineMentionsWorkoutsOnlyUnderYoopStress() {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: PuffinExperiment.whoopStressKey)
        defer {
            if let prior { defaults.set(prior, forKey: PuffinExperiment.whoopStressKey) }
            else { defaults.removeObject(forKey: PuffinExperiment.whoopStressKey) }
        }
        let points = [0, 300, 600].map {
            DaytimeStress.HourPoint(hour: 0, startTs: $0, level: 1.2, meanHR: 60, rmssd: nil)
        }
        let result = DaytimeStress.Result(hours: points, sustainedHigh: false, sustainedRun: 0, dayMean: nil, peak: nil,
                                          timeline: points)
        let utc = TimeZone(identifier: "UTC") ?? .current
        defaults.set(false, forKey: PuffinExperiment.whoopStressKey)
        XCTAssertEqual(AICoachEngine.stressContextLine(result, timeZone: utc),
                       "Today's stress so far (0-3 scale: low under 1, medium 1-2, high 2 and up), as the Stress screen shows it: "
                       + "current level 1.2 (medium) at 00:10; time in low 0 hr 0 min, medium 0 hr 15 min, high 0 hr 0 min. "
                       + "Say durations in hours and minutes, never as a count of minutes.")
        defaults.set(true, forKey: PuffinExperiment.whoopStressKey)
        XCTAssertTrue(AICoachEngine.stressContextLine(result, timeZone: utc)?.contains("Workouts are left out") == true)
    }
}
