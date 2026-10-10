import XCTest
@testable import Strand
import WhoopStore
import StrandAnalytics

/// What the coach is told when a value is missing, and how a screen's existing analysis opens the chat.
///
/// The coach was reporting stored zeros as measurements ("sleep 0.0h", "HRV 0ms", "0 hr 0 min in the
/// high stress zone"), calling yesterday's row today, and skipping silently over days with no data.
/// Separately, tapping a score screen's Coach pill asked the provider for a second analysis of the screen
/// the pill had just analysed. Every helper here is pure, so these run with no repo, key or network.
@MainActor
final class AICoachContextGapsTests: XCTestCase {

    private typealias Screen = AICoachEngine.CoachScreen

    private var dash: String { AICoachEngine.notMeasured }

    private func day(_ key: String, sleep: Double? = nil, hrv: Double? = nil, rhr: Int? = nil,
                     recovery: Double? = nil, strain: Double? = nil, steps: Int? = nil, kcal: Double? = nil,
                     skin: Double? = nil, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleep, efficiency: sleep == nil ? nil : 0.9,
                    deepMin: sleep == nil ? nil : 0, remMin: sleep == nil ? nil : 0, lightMin: sleep == nil ? nil : 0,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: strain,
                    exerciseCount: nil, skinTempDevC: skin, respRateBpm: resp, steps: steps, activeKcalEst: kcal)
    }

    // MARK: - Zero as missing

    func testStoredZerosAreNotMeasurements() {
        let line = AICoachEngine.formatDayLine(day("2026-10-09", sleep: 0, hrv: 0, rhr: 0, recovery: 55, strain: 0))
        XCTAssertTrue(line.contains("strain \(dash),"), line)
        XCTAssertTrue(line.contains("sleep \(dash),"), line)
        XCTAssertTrue(line.contains("HRV \(dash),"), line)
        XCTAssertTrue(line.hasSuffix("RHR \(dash)"), line)
        // A night with no sleep has no stages or efficiency either.
        XCTAssertTrue(line.contains("deep \(dash),"), line)
        XCTAssertTrue(line.contains("eff \(dash),"), line)
        XCTAssertFalse(line.contains("0.0h"), line)
        XCTAssertFalse(line.contains("0ms"), line)
        XCTAssertFalse(line.contains("0bpm"), line)
    }

    /// A real night can hold no minutes of a stage, and that is a measurement.
    func testZeroStageOnARealNightIsKept() {
        let line = AICoachEngine.formatDayLine(day("2026-10-09", sleep: 420, hrv: 50, rhr: 52))
        XCTAssertTrue(line.contains("sleep 7.0h, deep 0.0h"), line)
        XCTAssertTrue(line.contains("HRV 50ms, RHR 52bpm"), line)
    }

    func testOnlyTodaysRowIsMarkedToday() {
        let row = day("2026-10-10", sleep: 450)
        XCTAssertTrue(AICoachEngine.formatDayLine(row, isToday: true).hasPrefix("2026-10-10 (TODAY, in progress): "))
        XCTAssertTrue(AICoachEngine.formatDayLine(row).hasPrefix("2026-10-10: "))
    }

    func testTodaySoFarSaysNothingRecordedInWords() {
        XCTAssertEqual(AICoachEngine.todaySoFarLine(todayKey: "2026-10-10", strain: 0, steps: nil),
                       "Today so far (2026-10-10, in progress), as the Home screen shows it: "
                       + "no Strain recorded yet; no steps recorded or synced yet.")
        let strain = String(format: "%.1f", AICoachEngine.strain21(50))
        XCTAssertEqual(AICoachEngine.todaySoFarLine(todayKey: "2026-10-10", strain: 50, steps: 6512),
                       "Today so far (2026-10-10, in progress), as the Home screen shows it: "
                       + "Strain \(strain) of 21; 6512 steps.")
    }

    func testTodayVsNormalLeavesZerosOut() {
        let days = [
            day("2026-10-06", sleep: 420, hrv: 50, rhr: 50, strain: 40),
            day("2026-10-07", sleep: 0, hrv: 0, rhr: 0, strain: 0),
            day("2026-10-08", sleep: 480, hrv: 70, rhr: 54, strain: 60),
            day("2026-10-09", sleep: 450, hrv: 60, rhr: 0),
        ]
        guard let line = AICoachEngine.todayVsNormalLine(days, todayKey: "2026-10-09") else {
            return XCTFail("expected a line")
        }
        XCTAssertTrue(line.hasPrefix("Today (2026-10-09, in progress) vs prior 30-day normal: "), line)
        XCTAssertTrue(line.contains("HRV 60 ms vs normal 60 ms"), line)
        XCTAssertTrue(line.contains("sleep 7.5h vs normal 7.5h"), line)
        XCTAssertFalse(line.contains("resting HR"), line)
        // The row before the latest is named by its date, and a zero-Strain day stays out of the normal.
        let expected = "Strain on 2026-10-08 " + String(format: "%.1f vs normal %.1f",
                                                         AICoachEngine.strain21(60), AICoachEngine.strain21(40))
        XCTAssertTrue(line.contains(expected), line)
        XCTAssertTrue(AICoachEngine.todayVsNormalLine(days, todayKey: "2026-10-10")?
            .hasPrefix("Latest day (2026-10-09)") == true)
    }

    func testAveragesIgnoreZerosAndAbsoluteSkinTemperatures() {
        let prior = [
            day("2026-10-01", sleep: 480, hrv: 60, rhr: 50, recovery: 70, strain: 50, steps: 8000, kcal: 500,
                skin: 0.2, resp: 15),
            day("2026-10-02", sleep: 0, hrv: 0, rhr: 0, strain: 0, steps: 0, kcal: 0, skin: 34.5, resp: 0),
            day("2026-10-03", sleep: 420, hrv: 40, rhr: 54, recovery: 50, strain: 30, steps: 6000, kcal: 300,
                skin: -0.4, resp: 13),
        ]
        let lines = AICoachEngine.averageLines(prior)
        let strain = String(format: "%.1f", (AICoachEngine.strain21(50) + AICoachEngine.strain21(30)) / 2)
        XCTAssertEqual(lines, [
            "  recovery: 60%, strain: \(strain), sleep: 7.5h, HRV: 50 ms, RHR: 52 bpm",
            "  SpO2: \(dash), respiration: 14.0/min, skin-temp deviation: -0.1°C, steps: 7000/day, "
                + "active energy: 400 kcal/day",
        ])
    }

    func testAveragesWithNothingMeasuredSaySo() {
        let lines = AICoachEngine.averageLines([day("2026-10-02", sleep: 0, hrv: 0, rhr: 0, strain: 0)])
        XCTAssertEqual(lines.first, "  recovery: \(dash), strain: \(dash), sleep: \(dash), HRV: \(dash), RHR: \(dash)")
    }

    // MARK: - Calendar days and today

    func testCalendarDayKeysStepBackAcrossAMonthEnd() {
        XCTAssertEqual(AICoachEngine.calendarDayKeys(endingAt: "2026-03-02", count: 4),
                       ["2026-03-02", "2026-03-01", "2026-02-28", "2026-02-27"])
        XCTAssertEqual(AICoachEngine.calendarDayKeys(endingAt: "not a day", count: 4), [])
    }

    /// A missing date is a "no data" line, not the row before it sliding up, and a today with no row
    /// says so instead of the latest row being called today.
    func testRecentDaysShowGapsAndAMissingToday() {
        let days = [day("2026-10-07", sleep: 450, recovery: 60), day("2026-10-09", sleep: 400, recovery: 40)]
        let lines = AICoachEngine.recentDayLines(days: days, todayKey: "2026-10-10", count: 4)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "2026-10-10 (TODAY): no data yet; nothing has synced for today so far.")
        XCTAssertTrue(lines[1].hasPrefix("2026-10-09: recovery 40%"), lines[1])
        XCTAssertEqual(lines[2], "2026-10-08: no data; nothing was recorded or synced for this date.")
        XCTAssertTrue(lines[3].hasPrefix("2026-10-07: recovery 60%"), lines[3])
    }

    func testTodaysRowIsTheOnlyOneCalledToday() {
        let days = [day("2026-10-09", sleep: 400), day("2026-10-10", sleep: 450)]
        let lines = AICoachEngine.recentDayLines(days: days, todayKey: "2026-10-10", count: 2)
        XCTAssertTrue(lines[0].hasPrefix("2026-10-10 (TODAY, in progress): "), lines[0])
        XCTAssertFalse(lines[1].contains("TODAY"), lines[1])
    }

    func testRecoveryBeforeTodayIsScoredNamesTheLatestByDate() {
        let scoredEarlier = [day("2026-10-08", recovery: 70)]
        XCTAssertEqual(AICoachEngine.recoveryLine(days: scoredEarlier, todayKey: "2026-10-10"),
                       "Today's Recovery is not scored yet; the latest is 70% on 2026-10-08. "
                       + "The optimal Strain range from that Recovery: 14-18 of 21.")
        XCTAssertEqual(AICoachEngine.recoveryLine(days: scoredEarlier + [day("2026-10-10", recovery: 50)],
                                                  todayKey: "2026-10-10"),
                       "Today's Recovery: 50%. Today's optimal Strain range, from today's Recovery: 10-14 of 21.")
        XCTAssertEqual(AICoachEngine.recoveryLine(days: [day("2026-10-10")], todayKey: "2026-10-10"),
                       "Today's Recovery is not scored yet.")
    }

    func testSleepPerformanceIsLastNightsOnlyForTodaysKey() {
        XCTAssertEqual(AICoachEngine.sleepPerformanceLine(series: [(day: "2026-10-10", value: 88)],
                                                          todayKey: "2026-10-10"),
                       "Last night's Sleep Performance: 88% (the figure on Home's Sleep ring).")
        XCTAssertEqual(AICoachEngine.sleepPerformanceLine(series: [(day: "2026-10-08", value: 81),
                                                                   (day: "2026-10-09", value: 77)],
                                                          todayKey: "2026-10-10"),
                       "Last night has no Sleep Performance score yet; the latest is 77% for the night ending "
                       + "2026-10-09.")
        XCTAssertEqual(AICoachEngine.sleepPerformanceLine(series: [(day: "2026-10-10", value: 0)],
                                                          todayKey: "2026-10-10"),
                       "Last night has no Sleep Performance score yet.")
    }

    func testHoursVsNeededIsLastNightsOnlyWhenItIs() {
        XCTAssertEqual(AICoachEngine.hoursVsNeededLine(percent: 92, asleepMin: 441.6, carriedFrom: nil),
                       "Sleep need: about 8.0h a night. Last night's Hours vs Needed: 92% "
                       + "(quote this percentage as is; it is the figure the Sleep screen shows).")
        let carried = AICoachEngine.hoursVsNeededLine(percent: 92, asleepMin: 441.6, carriedFrom: "2026-10-08")
        XCTAssertTrue(carried.contains("for the night ending 2026-10-08 it was 92%"), carried)
        XCTAssertFalse(carried.contains("Last night's"), carried)
    }

    // MARK: - Stress

    private func point(_ ts: Int, _ level: Double?) -> DaytimeStress.HourPoint {
        DaytimeStress.HourPoint(hour: 0, startTs: ts, level: level, meanHR: nil, rmssd: nil)
    }

    private func stress(_ points: [DaytimeStress.HourPoint]) -> DaytimeStress.Result {
        DaytimeStress.Result(hours: points, sustainedHigh: false, sustainedRun: 0, dayMean: nil, peak: nil,
                             timeline: points)
    }

    /// An empty day used to reach the coach as "0 hr 0 min in the high stress zone".
    func testStressNeedsTwoScoredReadings() {
        XCTAssertNil(AICoachEngine.stressContextLine(.empty))
        XCTAssertNil(AICoachEngine.stressContextLine(stress([point(0, 1.2)])))
        XCTAssertNil(AICoachEngine.stressContextLine(stress([point(0, 1.2), point(300, nil)])))
    }

    /// The level is the latest reading and the bands are the TOTAL DAY card's minutes.
    func testStressLineCarriesTheCurrentLevelAndEveryBand() {
        let scored = stress([point(0, 0.5), point(300, 0.5), point(600, 1.5), point(900, 2.5)])
        let utc = TimeZone(identifier: "UTC") ?? .current
        guard let line = AICoachEngine.stressContextLine(scored, timeZone: utc) else {
            return XCTFail("expected a line")
        }
        XCTAssertTrue(line.contains("current level 2.5 (high) at 00:15;"), line)
        XCTAssertTrue(line.contains("time in low 0 hr 10 min, medium 0 hr 5 min, high 0 hr 5 min."), line)
        XCTAssertEqual(WhoopStressHero.minutesByBand(WhoopStressHero.scoredSamples(scored)), [10, 5, 5])
    }

    // MARK: - Sleep plan

    private func plan(strainMin: Double, debtMin: Double) -> WhoopSleepPlan {
        WhoopSleepPlan(baselineMin: 450, strainMin: strainMin, debtMin: debtMin, efficiency: 0.9,
                       wake: Date(timeIntervalSince1970: 0), wakeIsAlarm: false, optimalStart: nil)
    }

    func testSleepPlanLeavesOutZeroParts() {
        let bare = plan(strainMin: 0, debtMin: 0).coachLine
        XCTAssertTrue(bare.contains("sleep need 7h 30m, the healthy minimum;"), bare)
        XCTAssertFalse(bare.contains("0h 0m"), bare)
        let debt = plan(strainMin: 0.4, debtMin: 45).coachLine
        XCTAssertTrue(debt.contains("sleep need 8h 15m = healthy minimum 7h 30m + sleep debt 0h 45m;"), debt)
        XCTAssertFalse(debt.contains("recent Strain"), debt)
    }

    /// A plan shown late in the evening still counts after midnight (the day rolls at 04:00); one from the
    /// day before does not.
    func testShownPlanCountsOnlyOnTheDayItWasShown() {
        let calendar = Calendar.current
        guard let evening = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 23)),
              let nextMorning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 9)) else {
            return XCTFail("dates")
        }
        XCTAssertTrue(WhoopSleepPlan.isFromToday(shownAt: evening, now: evening.addingTimeInterval(2 * 3600)))
        XCTAssertFalse(WhoopSleepPlan.isFromToday(shownAt: evening, now: nextMorning))
    }

    // MARK: - The pill's headline as the opener

    func testPillHeadlineOpensAnEmptyChat() {
        XCTAssertTrue(AICoachEngine.summaryOpenerIsDue("Nice work, a long night.", lastOpener: nil, screen: .sleep,
                                                       withData: true, now: Date(), transcript: []))
    }

    func testSameScreenWithinFifteenMinutesContinues() {
        let now = Date()
        let transcript = [ChatMessage(role: .assistant, text: "Earlier opener")]
        let recent = (screen: Screen.sleep, at: now.addingTimeInterval(-60), withData: true)
        XCTAssertFalse(AICoachEngine.summaryOpenerIsDue("New headline", lastOpener: recent, screen: .sleep,
                                                        withData: true, now: now, transcript: transcript))
        // Another screen, a change of data access, or 15 minutes on: the headline opens the chat.
        XCTAssertTrue(AICoachEngine.summaryOpenerIsDue("New headline", lastOpener: recent, screen: .recovery,
                                                       withData: true, now: now, transcript: transcript))
        XCTAssertTrue(AICoachEngine.summaryOpenerIsDue("New headline", lastOpener: recent, screen: .sleep,
                                                       withData: false, now: now, transcript: transcript))
        XCTAssertTrue(AICoachEngine.summaryOpenerIsDue("New headline", lastOpener: recent, screen: .sleep,
                                                       withData: true, now: now.addingTimeInterval(15 * 60),
                                                       transcript: transcript))
        // Nothing to continue in an empty transcript.
        XCTAssertFalse(AICoachEngine.continuesScreenConversation(last: recent, screen: .sleep, withData: true,
                                                                 now: now, transcriptEmpty: true))
    }

    func testTheSameHeadlineIsNotAddedTwice() {
        let transcript = [ChatMessage(role: .assistant, text: "Nice work, a long night.")]
        XCTAssertFalse(AICoachEngine.summaryOpenerIsDue("  Nice work, a long night.\n", lastOpener: nil,
                                                        screen: .sleep, withData: true, now: Date(),
                                                        transcript: transcript))
        XCTAssertFalse(AICoachEngine.summaryOpenerIsDue("   ", lastOpener: nil, screen: .sleep, withData: true,
                                                        now: Date(), transcript: []))
    }

    func testOpenersCompareByTheirText() {
        XCTAssertEqual(AICoachEngine.Opener.screenSummary("a", .sleep), .screenSummary("a", .sleep))
        XCTAssertNotEqual(AICoachEngine.Opener.screenSummary("a", .sleep), .screenSummary("a", .strain))
        XCTAssertNotEqual(AICoachEngine.Opener.screenSummary("a", .sleep), .dayReview)
    }

    func testInsightCardBecomesOneMessage() {
        XCTAssertEqual(AICoachEngine.insightMessage(.init(title: " Primed to Perform ", body: "Go for 14.")),
                       "**Primed to Perform**\n\nGo for 14.")
        XCTAssertEqual(AICoachEngine.insightMessage(.init(title: "Rest", body: "")), "**Rest**")
    }
}
