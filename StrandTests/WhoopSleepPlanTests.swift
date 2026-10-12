import XCTest
import Foundation
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Tonight's plan (`WhoopSleepPlan`): when to be in bed and when to wake for the day the user had.
///
/// The need says how long to be in bed; the plan places that time on the user's usual middle of the night,
/// within 2 h of their usual wake time and bedtime. One call resolves it (`WhoopSleepPlan.current`) for the
/// Home card, the Sleep Planner, the Alarms screen, the Coach, the wind-down reminder and the Home insight's
/// cache key, so these also pin that nothing else can resolve a second plan.
@MainActor
final class WhoopSleepPlanTests: XCTestCase {

    // MARK: Fixtures

    private let cal = Calendar.current

    /// A local wall-clock time.
    private func at(_ key: String, _ hour: Int, _ minute: Int = 0) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: key)!.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
    }

    private func dayKey(_ date: Date) -> String { Repository.localDayKey(date) }

    private func minutes(_ later: Date, _ earlier: Date) -> Double { later.timeIntervalSince(earlier) / 60 }

    private func clock(_ date: Date) -> (hour: Int, minute: Int) {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? -1, c.minute ?? -1)
    }

    /// A night asleep from 02:30 to 10:00 on `key`, the way this user sleeps (middle of the night 06:15).
    private func night(endingOn key: String) -> CachedSleepSession {
        CachedSleepSession(startTs: Int(at(key, 2, 30).timeIntervalSince1970),
                           endTs: Int(at(key, 10, 0).timeIntervalSince1970),
                           efficiency: 0.9, restingHr: nil, avgHrv: nil, stagesJSON: nil)
    }

    /// A day with 500 min asleep (no debt against the 8 h the debt measures) and `strain21` on WHOOP's 0-21 axis.
    private func day(_ key: String, strain21: Double) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 500, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                    strain: StrainScorer.effortValue(fromWhoopStrain: strain21), exerciseCount: nil)
    }

    private let nightKeys = ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10",
                             "2026-10-11"]

    /// A repository holding the last `nights` nights (ending 11 Oct, 10:00) and `strain21` for 11 Oct, the day
    /// before the night this plans, which ends on 12 Oct.
    private func repo(strain21: Double, nights: Int = 7) -> Repository {
        let repo = Repository(deviceId: "test-sleep-plan")
        repo.days = (28...30).map { day(String(format: "2026-09-%02d", $0), strain21: 5) }
            + (1...10).map { day(String(format: "2026-10-%02d", $0), strain21: 5) }
            + [day("2026-10-11", strain21: strain21)]
        repo.sleeps = nightKeys.suffix(nights).map { night(endingOn: $0) }
        return repo
    }

    /// 11 Oct at noon: the night ending 11 Oct has ended, so tonight's ends on 12 Oct.
    private var noon11: Date { at("2026-10-11", 12) }

    private func plan(_ repo: Repository, alarm: Date? = nil, now: Date? = nil,
                      overrides: [Int: Int] = [:], chosen: Int? = nil) -> WhoopSleepPlan? {
        WhoopSleepPlan.tonight(repo: repo, alarm: alarm, now: now ?? noon11, wakeOverrides: overrides, chosenWake: chosen)
    }

    private func tonight(_ repo: Repository, alarm: Date? = nil, overrides: [Int: Int] = [:],
                         chosen: Int? = nil) throws -> WhoopSleepPlan {
        try XCTUnwrap(plan(repo, alarm: alarm, overrides: overrides, chosen: chosen))
    }

    // MARK: The placement (pure)

    /// The clock on a noon-to-noon axis: a night that runs past midnight stays on one line, and the wake
    /// minute round-trips to its clock time.
    func testTheNoonToNoonClock() {
        XCTAssertEqual(WhoopSleepPlan.noonClock(Int(at("2026-10-11", 10, 0).timeIntervalSince1970)), 1_320)
        XCTAssertEqual(WhoopSleepPlan.noonClock(Int(at("2026-10-11", 0, 30).timeIntervalSince1970)), 750)
        XCTAssertEqual(WhoopSleepPlan.noonClock(Int(at("2026-10-10", 23, 0).timeIntervalSince1970)), 660)
        XCTAssertEqual(WhoopSleepPlan.clockMinute(ofNoonClock: 1_320), 600)
        XCTAssertEqual(WhoopSleepPlan.clockMinute(ofNoonClock: 750), 30)
        XCTAssertEqual(WhoopSleepPlan.clockMinute(ofNoonClock: 660), 23 * 60)
    }

    /// The usual night is the median over the nights: one night in the afternoon cannot drag it.
    func testTheRhythmIsAMedianOfTheNights() throws {
        func ts(_ key: String, _ h: Int, _ m: Int) -> Int { Int(at(key, h, m).timeIntervalSince1970) }
        let nights = [(ts("2026-10-05", 2, 30), ts("2026-10-05", 10, 0)),
                      (ts("2026-10-06", 2, 30), ts("2026-10-06", 10, 0)),
                      (ts("2026-10-07", 2, 30), ts("2026-10-07", 10, 0)),
                      (ts("2026-10-08", 0, 10), ts("2026-10-08", 6, 0)),   // an early night
                      (ts("2026-10-09", 2, 30), ts("2026-10-09", 10, 0))]
        let rhythm = try XCTUnwrap(WhoopSleepPlan.rhythm(of: nights))
        XCTAssertEqual(rhythm.nights, 5)
        XCTAssertEqual(rhythm.wake, 1_320)
        XCTAssertEqual(rhythm.onset, 870)
        XCTAssertEqual(rhythm.midpoint, 1_095)   // 06:15
        XCTAssertNil(WhoopSleepPlan.rhythm(of: []))
    }

    private let usual = WhoopSleepPlan.Rhythm(wake: 1_320, onset: 870, midpoint: 1_095, nights: 7)

    /// The time in bed is centred on the usual middle of the night, so a longer one starts earlier and ends
    /// later by the same amount.
    func testALongerNightIsCentredOnTheMiddleOfTheNight() {
        for inBed in [400.0, 500, 556, 640] {
            let placed = WhoopSleepPlan.placedWake(timeInBedMin: inBed, rhythm: usual)
            XCTAssertEqual(placed.wake - inBed / 2, usual.midpoint, accuracy: 1e-9, "\(inBed)")
            XCTAssertEqual(placed.wake, placed.centred, accuracy: 1e-9, "\(inBed) is inside the limits")
        }
    }

    /// Neither end moves more than 2 h from the usual one.
    func testNeitherEndMovesMoreThanTwoHours() {
        for inBed in stride(from: 360.0, through: 700, by: 10) {
            let placed = WhoopSleepPlan.placedWake(timeInBedMin: inBed, rhythm: usual)
            XCTAssertLessThanOrEqual(abs(placed.wake - usual.wake), WhoopSleepPlan.maxShiftMin + 1e-9, "\(inBed)")
        }
        for inBed in stride(from: 380.0, through: 620, by: 10) {
            let placed = WhoopSleepPlan.placedWake(timeInBedMin: inBed, rhythm: usual)
            let bedtime = placed.wake - inBed
            XCTAssertLessThanOrEqual(abs(bedtime - usual.onset), WhoopSleepPlan.maxShiftMin + 1e-9, "\(inBed)")
        }
    }

    /// A need too long for both limits keeps the wake limit and lets the bedtime go as early as the need
    /// asks; it is never shortened to fit.
    func testATooLongNeedKeepsTheWakeLimitAndMovesTheBedtime() {
        let placed = WhoopSleepPlan.placedWake(timeInBedMin: 760, rhythm: usual)
        XCTAssertEqual(placed.wake, usual.wake + WhoopSleepPlan.maxShiftMin, accuracy: 1e-9)
        XCTAssertGreaterThan(placed.centred, placed.wake)
        XCTAssertEqual(placed.wake - 760, 680, accuracy: 1e-9, "the whole 760 min are still in bed")
    }

    // MARK: Hard day, easy day

    /// The same user, the same nights, a hard day and an easy one: the hard day starts the night earlier and
    /// ends it later, each by half of the extra time, around the same middle.
    func testAHardDayStartsEarlierAndEndsLaterAroundTheSameMiddle() throws {
        let easy = try tonight(repo(strain21: 4))
        let hard = try tonight(repo(strain21: 20))
        XCTAssertEqual(easy.wakeSource, .recommended)
        XCTAssertEqual(hard.wakeSource, .recommended)
        let extra = hard.timeInBedMin - easy.timeInBedMin
        XCTAssertEqual(extra, SleepModel.needMinPerStrainPoint * 10 / 0.9, accuracy: 1e-6, "10 points of Strain above the floor")
        XCTAssertEqual(minutes(easy.bedtime, hard.bedtime), extra / 2, accuracy: 1e-6, "the bedtime moves earlier")
        XCTAssertEqual(minutes(hard.wake, easy.wake), extra / 2, accuracy: 1e-6, "the wake time moves later")
        let easyMiddle = easy.bedtime.addingTimeInterval(easy.timeInBedMin * 30)
        let hardMiddle = hard.bedtime.addingTimeInterval(hard.timeInBedMin * 30)
        XCTAssertEqual(hardMiddle.timeIntervalSince(easyMiddle), 0, accuracy: 1e-6)
        XCTAssertEqual(minutes(hard.wake, hard.bedtime), hard.timeInBedMin, accuracy: 1e-6, "bedtime is the wake minus the time in bed")
    }

    /// The numbers this user sees: mid-sleep 06:15 and a 9 h 15 m night give 01:37 to 10:52.
    func testTheEasyDayTimesOnTheFixture() throws {
        let easy = try tonight(repo(strain21: 4))
        XCTAssertEqual(dayKey(easy.wake), "2026-10-12")
        XCTAssertEqual(easy.timeInBedMin, 500 / 0.9, accuracy: 1e-9)
        let wake = clock(easy.wake), bed = clock(easy.bedtime)
        XCTAssertEqual(wake.hour * 60 + wake.minute, 10 * 60 + 52)
        XCTAssertEqual(bed.hour * 60 + bed.minute, 60 + 37 + 0)
        XCTAssertEqual(easy.recommendedWake, easy.wake)
    }

    /// A day the usual times would not carry: the wake is held within 2 h of the usual one however big the debt.
    func testAHugeDebtCannotMoveTheWakeMoreThanTwoHours() throws {
        let tired = Repository(deviceId: "test-sleep-plan-debt")
        tired.days = (28...30).map { key in
            DailyMetric(day: String(format: "2026-09-%02d", key), totalSleepMin: 120, efficiency: 0.9, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                        strain: StrainScorer.effortValue(fromWhoopStrain: 21), exerciseCount: nil)
        } + (1...11).map { key in
            DailyMetric(day: String(format: "2026-10-%02d", key), totalSleepMin: 120, efficiency: 0.9, deepMin: nil,
                        remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                        strain: StrainScorer.effortValue(fromWhoopStrain: 21), exerciseCount: nil)
        }
        tired.sleeps = nightKeys.map { night(endingOn: $0) }
        let plan = try tonight(tired)
        XCTAssertGreaterThan(plan.needMin, 600, "a large need to hold the limit against")
        XCTAssertLessThanOrEqual(minutes(plan.wake, at("2026-10-12", 10, 0)), WhoopSleepPlan.maxShiftMin + 1e-6)
        XCTAssertEqual(minutes(plan.wake, plan.bedtime), plan.timeInBedMin, accuracy: 1e-6, "the need is never shortened to fit")
    }

    // MARK: Few nights, no nights

    /// Fewer than 3 nights give no rhythm to anchor to: the usual wake time of the nights there are, with the
    /// bedtime counted back from it.
    func testWithTwoNightsItFallsBackToTheUsualWakeTime() throws {
        let plan = try tonight(repo(strain21: 4, nights: 2))
        XCTAssertEqual(plan.wakeSource, .usual)
        XCTAssertNil(plan.recommendedWake)
        XCTAssertEqual(plan.wake, at("2026-10-12", 10, 0))
        XCTAssertEqual(plan.bedtime, plan.wake.addingTimeInterval(-plan.timeInBedMin * 60))
        XCTAssertNotNil(plan.optimalStart, "the window of the nights on record is still drawn, as before")
    }

    /// With three nights the placement starts.
    func testThreeNightsAreEnoughToPlaceTheWindow() throws {
        XCTAssertEqual(try tonight(repo(strain21: 4, nights: 3)).wakeSource, .recommended)
    }

    /// No alarm, nothing chosen and no night: nothing says when the night ends, so there is no plan, and no
    /// stored 07:00 stands in for one.
    func testNoHistoryAndNothingChosenMeansNoPlan() {
        let empty = Repository(deviceId: "test-sleep-plan-empty")
        XCTAssertNil(plan(empty))
    }

    func testNoHistoryNeedsOnlyAWakeTime() throws {
        let empty = Repository(deviceId: "test-sleep-plan-empty-2")
        let chosen = try XCTUnwrap(plan(empty, chosen: 9 * 60))
        XCTAssertEqual(chosen.wakeSource, .chosen)
        XCTAssertEqual(chosen.wake, at("2026-10-12", 9, 0))
        let alarm = try XCTUnwrap(plan(empty, alarm: at("2026-10-12", 7, 30)))
        XCTAssertEqual(alarm.wakeSource, .alarm)
    }

    // MARK: The wake time's sources

    /// With an alarm armed the wake is the alarm and the bedtime counts back from it, as before; the
    /// recommended wake is still there for the button that moves the alarm to it.
    func testAnArmedAlarmIsTheWakeAndTheBedtimeCountsBackFromIt() throws {
        let alarm = at("2026-10-12", 7, 30)
        let plan = try tonight(repo(strain21: 4), alarm: alarm)
        XCTAssertEqual(plan.wakeSource, .alarm)
        XCTAssertTrue(plan.wakeIsAlarm)
        XCTAssertEqual(plan.wake, alarm)
        XCTAssertEqual(plan.bedtime, alarm.addingTimeInterval(-plan.timeInBedMin * 60))
        let recommended = try XCTUnwrap(plan.recommendedWake)
        XCTAssertNotEqual(recommended, alarm)
        XCTAssertEqual(try tonight(repo(strain21: 4)).wake, recommended, "the same recommendation with no alarm")
    }

    /// A weekday alarm that is days away is not tonight's wake.
    func testAnAlarmDaysAwayIsNotTonightsWake() throws {
        let plan = try tonight(repo(strain21: 4), alarm: at("2026-10-14", 7, 0))
        XCTAssertEqual(plan.wakeSource, .recommended)
        XCTAssertEqual(dayKey(plan.wake), "2026-10-12")
    }

    /// A weekday with a time of its own: that is the wake for the night ending on that weekday, and no other.
    func testAWeekdayTimeOfItsOwnFeedsThePlanForThatWeekdayOnly() throws {
        let weekday = cal.component(.weekday, from: at("2026-10-12", 12))
        let other = weekday % 7 + 1
        let own = try tonight(repo(strain21: 4), overrides: [weekday: 6 * 60 + 15])
        XCTAssertEqual(own.wakeSource, .chosen)
        XCTAssertEqual(own.wake, at("2026-10-12", 6, 15))
        XCTAssertEqual(own.bedtime, own.wake.addingTimeInterval(-own.timeInBedMin * 60))
        let elsewhere = try tonight(repo(strain21: 4), overrides: [other: 6 * 60 + 15])
        XCTAssertEqual(elsewhere.wakeSource, .recommended)
    }

    /// A wake time the user chose beats the recommended one; a weekday's own time beats the chosen one.
    func testAChosenWakeBeatsTheRecommendedOne() throws {
        let weekday = cal.component(.weekday, from: at("2026-10-12", 12))
        let chosen = try tonight(repo(strain21: 4), chosen: 8 * 60)
        XCTAssertEqual(chosen.wakeSource, .chosen)
        XCTAssertEqual(chosen.wake, at("2026-10-12", 8, 0))
        let own = try tonight(repo(strain21: 4), overrides: [weekday: 9 * 60], chosen: 8 * 60)
        XCTAssertEqual(own.wake, at("2026-10-12", 9, 0))
    }

    /// An alarm beats everything, including a time the user chose.
    func testTheAlarmBeatsAChosenWake() throws {
        let plan = try tonight(repo(strain21: 4), alarm: at("2026-10-12", 7, 30), chosen: 9 * 60)
        XCTAssertEqual(plan.wakeSource, .alarm)
    }

    /// Tonight is the next night: with today's night already over, today's wake time is not a plan, and an
    /// hour past midnight with the last night yesterday's it still is.
    func testTonightIsTheNextNightNotOneThatHasEnded() throws {
        let woke = try tonight(repo(strain21: 4))
        XCTAssertEqual(dayKey(woke.wake), "2026-10-12", "last night ended today at 10:00")
        // At 09:00, an hour before the usual wake time, with last night over since 08:00 today.
        let early = Repository(deviceId: "test-sleep-plan-early")
        early.days = repo(strain21: 4).days
        early.sleeps = nightKeys.dropLast().map { night(endingOn: $0) }
            + [CachedSleepSession(startTs: Int(at("2026-10-11", 0, 30).timeIntervalSince1970),
                                  endTs: Int(at("2026-10-11", 8, 0).timeIntervalSince1970),
                                  efficiency: 0.9, restingHr: nil, avgHrv: nil, stagesJSON: nil)]
        let upEarly = try XCTUnwrap(plan(early, now: at("2026-10-11", 9, 0)))
        XCTAssertEqual(dayKey(upEarly.wake), "2026-10-12", "the 08:00 wake already ended today's night")
        // Still awake at 01:30 on 11 Oct, last night having ended on the 10th: this night ends on the 11th.
        let late = repo(strain21: 4)
        late.sleeps = nightKeys.dropLast().map { night(endingOn: $0) }
        let upLate = try XCTUnwrap(plan(late, now: at("2026-10-11", 1, 30)))
        XCTAssertEqual(dayKey(upLate.wake), "2026-10-11")
    }

    // MARK: Honest labels

    func testEachWakeSourceHasItsOwnLabel() {
        func label(_ source: WhoopSleepPlan.WakeSource) -> String {
            WhoopSleepPlan(baselineMin: 450, strainMin: 0, debtMin: 0, efficiency: 0.9, wake: Date(),
                           wakeSource: source, optimalStart: nil, recommendedWake: nil).wakeLabel
        }
        let labels = [label(.alarm), label(.chosen), label(.recommended), label(.usual)]
        XCTAssertEqual(Set(labels).count, 4)
        XCTAssertEqual(label(.alarm), "ALARM ON")
        XCTAssertEqual(label(.recommended), "RECOMMENDED WAKE")
    }

    // MARK: One plan for every readout

    /// The Home card, the Sleep Planner, the Alarms hero and the Coach all read the same plan value: the
    /// times each states are the plan's.
    func testEveryReadoutOfThePlanStatesItsTimes() throws {
        let plan = try tonight(repo(strain21: 14))
        let line = plan.coachLine
        XCTAssertTrue(line.contains("get in bed by \(WhoopTime.clock(plan.bedtime)) to wake at \(WhoopTime.clock(plan.wake))"), line)
        XCTAssertTrue(line.contains("recommended wake time"), line)
        let hero = SmartAlarmView.needSummary(plan)
        XCTAssertTrue(hero.contains(WhoopTime.duration(minutes: plan.needMin)), hero)
        XCTAssertTrue(hero.contains(WhoopTime.duration(minutes: plan.baselineMin)), hero)
        XCTAssertTrue(hero.contains(WhoopTime.duration(minutes: plan.strainMin)), hero)
        XCTAssertTrue(hero.contains(WhoopTime.duration(minutes: plan.debtMin)), hero)
        XCTAssertEqual(plan.reminderDate(leadMinutes: 30), plan.bedtime.addingTimeInterval(-30 * 60))
    }

    /// No more training from three hours before bed: the Home row turns into the Day In Review there, and the
    /// Coach is told the same time.
    func testTheTrainingCutoffIsThreeHoursBeforeBed() {
        let plan = WhoopSleepPlan(baselineMin: 450, strainMin: 0, debtMin: 0, efficiency: 0.9,
                                  wake: Date(timeIntervalSince1970: 1_800_000_000), wakeSource: .usual,
                                  optimalStart: nil, recommendedWake: nil)
        XCTAssertEqual(plan.trainingCutoff, plan.bedtime.addingTimeInterval(-3 * 3600))
        XCTAssertTrue(plan.coachLine.contains("last sensible time to train today is \(WhoopTime.clock(plan.trainingCutoff))"),
                      plan.coachLine)
    }

    /// The coach names the wake time's source in words, so it never calls a recommended wake an alarm.
    func testTheCoachLineNamesTheSource() {
        func line(_ source: WhoopSleepPlan.WakeSource) -> String {
            WhoopSleepPlan(baselineMin: 450, strainMin: 0, debtMin: 0, efficiency: 0.9, wake: Date(),
                           wakeSource: source, optimalStart: nil, recommendedWake: nil).coachLine
        }
        XCTAssertTrue(line(.alarm).contains("(alarm)"))
        XCTAssertTrue(line(.usual).contains("(usual wake time)"))
        XCTAssertTrue(line(.chosen).contains("(wake time the user set)"))
        XCTAssertFalse(line(.recommended).contains("(alarm)"))
    }

    /// No plan is resolved anywhere but in the planner file, and no alarm readout resolves the next fire by
    /// itself: the Home card, the Sleep Planner, the Alarms screen (hero, countdown, stamp, reminder line),
    /// the Coach and the reminder all go through `WhoopSleepPlan.current` and `armedAlarm`.
    func testThereIsOneResolverForThePlanAndOneForTheAlarm() throws {
        var tonightCalls: [String] = []
        var alarmCalls: [String] = []
        var lastShown: [String] = []
        for (path, text) in try Self.strandSources() {
            if text.contains("WhoopSleepPlan.tonight(") { tonightCalls.append(path) }
            if text.contains("AppModel.nextSmartAlarmDate(") { alarmCalls.append(path) }
            if text.contains("WhoopSleepPlan.lastShown") || text.contains("shownToday(") { lastShown.append(path) }
        }
        XCTAssertEqual(tonightCalls, [], "no screen, the Coach or the reminder builds a plan of its own: `current` does, in the planner file")
        let planner = try XCTUnwrap(Dictionary(uniqueKeysWithValues: try Self.strandSources())["Liquid/WhoopSleepPlanner.swift"])
        XCTAssertEqual(planner.components(separatedBy: "tonight(repo:").count - 1, 2, "its declaration and the one call in `current`")
        XCTAssertEqual(alarmCalls, ["Liquid/WhoopSleepPlanner.swift"],
                       "every readout of the alarm reads the next fire through `armedAlarm`; the strap itself is armed in AppModel")
        XCTAssertTrue(lastShown.isEmpty, "a plan remembered from when a screen last showed it goes stale: \(lastShown)")
    }

    func testTheScreensTheCoachAndTheReminderReadTheOnePlan() throws {
        let sources = Dictionary(uniqueKeysWithValues: try Self.strandSources())
        for path in ["Liquid/WhoopHomeCards.swift", "Liquid/WhoopSleepPlanner.swift", "Screens/SmartAlarmView.swift"] {
            XCTAssertTrue(try XCTUnwrap(sources[path]).contains("WhoopSleepPlan.current("), "\(path) must read the plan through `current`")
        }
        let wind = try XCTUnwrap(sources["System/WindDownNudge.swift"])
        XCTAssertTrue(wind.contains("WhoopSleepPlan.current("), "the reminder's plans and the Coach's come from `current`")
        XCTAssertTrue(wind.contains("coach.sleepPlan = {"))
        let coach = try XCTUnwrap(sources["AI/AICoach.swift"])
        XCTAssertTrue(coach.contains("sleepPlan?()"))
        XCTAssertFalse(coach.contains("WhoopSleepPlan.tonight("))
    }

    /// Nothing on the Alarms screen or in the planner can show a wake time nobody picked: the stored 07:00 is
    /// gone from every reader.
    func testNoStoredSevenOClockStandsInForAWakeTime() throws {
        let sources = try Self.strandSources()
        for (path, text) in sources {
            XCTAssertFalse(text.contains("WindDownNudge.wakeMinutes"), "\(path) reads the removed default wake time")
            XCTAssertFalse(text.contains("nudgeMinuteOfDay"), "\(path) reads the removed fixed-need nudge time")
            XCTAssertFalse(text.contains("sleepNeedMinutes"), "\(path) reads the removed fixed 8 h need")
        }
        let alarms = try XCTUnwrap(Dictionary(uniqueKeysWithValues: sources)["Screens/SmartAlarmView.swift"])
        XCTAssertFalse(alarms.contains("7 * 60"), "the screen has no 07:00 of its own")
    }

    // MARK: The reminder follows the bedtime

    /// The reminder fires `lead` minutes before the plan's bedtime, an absolute instant.
    func testTheReminderIsTheBedtimeMinusTheLead() throws {
        let plan = try tonight(repo(strain21: 14))
        for lead in [0, 30, 90] {
            XCTAssertEqual(WindDownNudge.fireDate(for: plan, leadMinutes: lead),
                           plan.bedtime.addingTimeInterval(-Double(lead) * 60))
        }
    }

    /// A hard day moves the reminder earlier, with the bedtime.
    func testAHardDayMovesTheReminderEarlier() throws {
        let easy = try tonight(repo(strain21: 4))
        let hard = try tonight(repo(strain21: 20))
        let moved = minutes(WindDownNudge.fireDate(for: easy, leadMinutes: 30), WindDownNudge.fireDate(for: hard, leadMinutes: 30))
        XCTAssertEqual(moved, (hard.timeInBedMin - easy.timeInBedMin) / 2, accuracy: 1e-6)
        XCTAssertGreaterThan(moved, 10, "a day like this is worth a re-plan")
    }

    /// Only reminders still ahead are scheduled, so tonight's never fires late.
    func testOnlyUpcomingRemindersAreScheduled() throws {
        let plan = try tonight(repo(strain21: 4))
        let fire = WindDownNudge.fireDate(for: plan, leadMinutes: 30)
        XCTAssertEqual(WindDownNudge.upcomingFires(plans: [plan], leadMinutes: 30, now: fire.addingTimeInterval(-3_600)), [fire])
        XCTAssertEqual(WindDownNudge.upcomingFires(plans: [plan], leadMinutes: 30, now: fire.addingTimeInterval(60)), [])
    }

    /// A pending reminder is replaced when the day moves it by 10 minutes or more, or the nights differ.
    func testAPendingReminderIsReplacedOnlyWhenTheBedtimeMovesTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fire = now.addingTimeInterval(8 * 3_600)
        XCTAssertFalse(WindDownNudge.needsReplan(scheduled: [fire], desired: [fire.addingTimeInterval(9 * 60)], now: now))
        XCTAssertFalse(WindDownNudge.needsReplan(scheduled: [fire], desired: [fire.addingTimeInterval(-9 * 60)], now: now))
        XCTAssertTrue(WindDownNudge.needsReplan(scheduled: [fire], desired: [fire.addingTimeInterval(10 * 60)], now: now))
        XCTAssertTrue(WindDownNudge.needsReplan(scheduled: [fire], desired: [fire.addingTimeInterval(-25 * 60)], now: now))
        XCTAssertTrue(WindDownNudge.needsReplan(scheduled: [], desired: [fire], now: now), "nothing pending")
        XCTAssertTrue(WindDownNudge.needsReplan(scheduled: [fire], desired: [fire, fire.addingTimeInterval(86_400)], now: now))
        // A reminder that has fired is no longer pending: tonight's gone, tomorrow's is the same.
        let passed = now.addingTimeInterval(-3_600)
        XCTAssertFalse(WindDownNudge.needsReplan(scheduled: [passed, fire], desired: [fire], now: now))
    }

    // MARK: The Home insight follows the bedtime

    private func planAt(bedtimeShift minutes: Double) -> WhoopSleepPlan {
        WhoopSleepPlan(baselineMin: 450, strainMin: 0, debtMin: 0, efficiency: 0.9,
                       wake: Date(timeIntervalSince1970: 1_000_000 + minutes * 60), wakeSource: .recommended,
                       optimalStart: nil, recommendedWake: nil)
    }

    /// The Coach wrote the card about one bedtime and the plan now names another: the cache key changes at
    /// 10 minutes, and holds while the plan holds.
    func testTheInsightKeyChangesWhenTheBedtimeMovesTenMinutes() {
        let base = planAt(bedtimeShift: 0)
        XCTAssertEqual(base.fingerprintToken, planAt(bedtimeShift: 0).fingerprintToken)
        // The 23 minutes by which the card and the insight disagreed on 12 Oct.
        XCTAssertNotEqual(base.fingerprintToken, planAt(bedtimeShift: 23).fingerprintToken)
        // Any move of 10 minutes or more crosses a 10-minute step.
        for shift in stride(from: 10.0, through: 120, by: 7) {
            XCTAssertNotEqual(base.fingerprintToken, planAt(bedtimeShift: shift).fingerprintToken, "\(shift)")
            XCTAssertNotEqual(base.fingerprintToken, planAt(bedtimeShift: -shift).fingerprintToken, "-\(shift)")
        }
    }

    /// The engine hands the key to the card through its plan provider, and says so when there is none.
    func testTheCoachExposesThePlanKey() {
        let coach = AICoachEngine(repo: Repository(deviceId: "test-sleep-plan-coach"))
        XCTAssertEqual(coach.sleepPlanToken, "-")
        var current = planAt(bedtimeShift: 0)
        coach.sleepPlan = { current }
        let before = coach.sleepPlanToken
        XCTAssertEqual(before, current.fingerprintToken)
        current = planAt(bedtimeShift: 23)
        XCTAssertNotEqual(coach.sleepPlanToken, before, "the insight is written again when the plan moves")
    }

    /// The card's key carries the plan's.
    func testTheInsightCardKeyIncludesThePlan() throws {
        let home = try XCTUnwrap(Dictionary(uniqueKeysWithValues: try Self.strandSources())["Liquid/WhoopHome.swift"])
        XCTAssertTrue(home.contains("\\(coach.sleepPlanToken)"), "the insight's cache key must carry tonight's plan")
        XCTAssertTrue(home.contains("\"v4|"), "the key version moves with it, so an old cache is written again once")
    }

    // MARK: The armed alarm

    func testTheAlarmGateAndResolverAreOne() {
        // The store writes through to UserDefaults, so put back exactly what was there, absent keys included.
        let keys = ["behavior.smartAlarmEnabled", "behavior.smartAlarmMinutes", "behavior.smartAlarmWeekdays"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let behavior = BehaviorStore()
        behavior.smartAlarmMinutes = 7 * 60 + 30
        behavior.smartAlarmWeekdays = []
        let now = at("2026-10-11", 12)
        behavior.smartAlarmEnabled = false
        XCTAssertNil(WhoopSleepPlan.armedAlarm(behavior: behavior, canArm: true, overrides: [:], from: now), "off: no promise")
        behavior.smartAlarmEnabled = true
        XCTAssertNil(WhoopSleepPlan.armedAlarm(behavior: behavior, canArm: false, overrides: [:], from: now), "cannot arm: no promise")
        XCTAssertEqual(WhoopSleepPlan.armedAlarm(behavior: behavior, canArm: true, overrides: [:], from: now),
                       at("2026-10-12", 7, 30))
        let weekday = cal.component(.weekday, from: at("2026-10-12", 12))
        XCTAssertEqual(WhoopSleepPlan.armedAlarm(behavior: behavior, canArm: true, overrides: [weekday: 9 * 60], from: now),
                       at("2026-10-12", 9, 0), "a day with its own time resolves to that time")
    }

    // MARK: The strap alarm's first time

    /// Switching the strap alarm on with no time ever chosen would arm the store's 07:00. It takes the plan's
    /// recommended wake instead, the user's own chosen time if they set one, and never a chosen alarm time.
    func testTheStrapAlarmTakesItsFirstTimeFromThePlan() throws {
        let placed = try tonight(repo(strain21: 4))
        XCTAssertEqual(WhoopSleepPlan.strapAlarmSeed(plan: placed, timeIsChosen: false), 10 * 60 + 52)
        XCTAssertNil(WhoopSleepPlan.strapAlarmSeed(plan: placed, timeIsChosen: true), "a time somebody picked stays")
        XCTAssertNil(WhoopSleepPlan.strapAlarmSeed(plan: nil, timeIsChosen: false), "no plan, nothing to take it from")
        let mine = try tonight(repo(strain21: 4), chosen: 8 * 60 + 15)
        XCTAssertEqual(WhoopSleepPlan.strapAlarmSeed(plan: mine, timeIsChosen: false), 8 * 60 + 15)
        let few = try tonight(repo(strain21: 4, nights: 2))
        XCTAssertEqual(WhoopSleepPlan.strapAlarmSeed(plan: few, timeIsChosen: false), 10 * 60, "the usual wake with too few nights to place it")
    }

    /// The alarm's time counts as chosen only once somebody sets it: the store's 07:00 is a placeholder.
    func testTheStrapAlarmTimeIsChosenOnlyOnceSomebodySetsIt() {
        let key = "behavior.smartAlarmMinutes"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        let behavior = BehaviorStore()
        XCTAssertFalse(behavior.smartAlarmTimeIsChosen)
        XCTAssertEqual(behavior.smartAlarmMinutes, 7 * 60, "the placeholder, which no screen may present as a choice")
        behavior.smartAlarmMinutes = 9 * 60
        XCTAssertTrue(behavior.smartAlarmTimeIsChosen)
    }

    // MARK: Source access

    /// Every Swift file under `Strand/`, as (path relative to it, text).
    private static func strandSources(file: StaticString = #filePath) throws -> [(String, String)] {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<4 {
            let strand = dir.appendingPathComponent("Strand")
            if FileManager.default.fileExists(atPath: strand.appendingPathComponent("Liquid/WhoopSleepPlanner.swift").path) {
                let urls = (FileManager.default.enumerator(at: strand, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
                var out: [(String, String)] = []
                for url in urls where url.pathExtension == "swift" {
                    let relative = String(url.path.dropFirst(strand.path.count + 1))
                    out.append((relative, try String(contentsOf: url, encoding: .utf8)))
                }
                return out.sorted { $0.0 < $1.0 }
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(domain: "WhoopSleepPlanTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Strand/ not reachable from \(file)"])
    }
}
