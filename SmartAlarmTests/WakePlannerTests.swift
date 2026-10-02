import Foundation
import SwiftData
import Testing

@testable import SmartAlarm

/// End-to-end behaviour of one check: does a real `AlarmPlan` come out the other side with the
/// right time, and — more importantly — does a failed check leave a good alarm alone?
@MainActor
@Suite("Wake planner")
struct WakePlannerTests {
    private let home = Coordinate(latitude: 37.7749, longitude: -122.4194)
    private let work = Coordinate(latitude: 37.3861, longitude: -122.0839)

    private struct Harness {
        var container: ModelContainer
        var context: ModelContext
        var planner: WakePlanner
        var traffic: MockTrafficProvider
        var alarms: MockAlarmScheduler
        var weather: MockWeatherProvider
        var clock: DateProvider
        var settings: UserSettings
    }

    /// `now` is Thursday 2026-08-06 at 03:00 — a weekday, well before the watch window opens,
    /// so checks only happen when a trigger explicitly forces one.
    private func makeHarness(
        nowHour: Int = 3,
        minutes: Double = 30,
        weather: WeatherImpact = .clear,
        isPro: Bool = true
    ) throws -> Harness {
        let schema = Schema([
            UserSettings.self, AlarmPlan.self, CheckLog.self, TravelSample.self, RouteBaseline.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let settings = UserSettings()
        settings.homeAddress = "Home"
        settings.workAddress = "Work"
        settings.setHomeCoordinate(home)
        settings.setWorkCoordinate(work)
        settings.isEnabled = true
        settings.defaultArrivalMinuteOfDay = 9 * 60
        context.insert(settings)
        try context.save()

        let clock = DateProvider()
        clock.offset = Fixture.date(hour: nowHour).timeIntervalSince(.now)

        let traffic = MockTrafficProvider(minutes: minutes)
        let alarms = MockAlarmScheduler()
        let weatherProvider = MockWeatherProvider(impact: weather)

        let planner = WakePlanner(
            modelContext: context,
            traffic: traffic,
            alarms: alarms,
            calendarProvider: DisabledCalendarProvider(),
            weather: weatherProvider,
            clock: clock,
            calendar: Fixture.calendar
        )
        planner.isPro = isPro

        return Harness(
            container: container, context: context, planner: planner,
            traffic: traffic, alarms: alarms, weather: weatherProvider,
            clock: clock, settings: settings
        )
    }

    private func logs(_ harness: Harness) throws -> [CheckLog] {
        try harness.context
            .fetch(FetchDescriptor<CheckLog>())
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Happy path

    @Test("A successful check produces a plan and schedules the alarm")
    func schedulesFromSuccessfulCheck() async throws {
        let harness = try makeHarness()

        await harness.planner.refresh(trigger: .manual)

        let plan = try #require(harness.planner.currentPlan)
        #expect(plan.isAlarmScheduled)
        #expect(harness.alarms.alarms[plan.alarmIdentifier]?.date == plan.wakeDate)

        // wake = arrival − padded drive − arrival buffer − get-ready.
        let drive = try #require(plan.lastGoodTravelSeconds)
        let expectedLeaveBy = plan.arrivalDeadline
            .addingTimeInterval(-(drive + Double(harness.settings.arrivalBufferMinutes) * 60))
        #expect(plan.leaveByDate == expectedLeaveBy)
        #expect(plan.wakeDate == expectedLeaveBy.addingTimeInterval(-Double(harness.settings.getReadyMinutes) * 60))

        let entries = try logs(harness)
        #expect(entries.last?.outcome == .scheduled)
    }

    @Test("Rescheduling reuses the same identifiers instead of stacking alarms")
    func reschedulingReusesIdentifier() async throws {
        let harness = try makeHarness(minutes: 20)
        await harness.planner.refresh(trigger: .manual)
        let wakeID = try #require(harness.planner.currentPlan?.alarmIdentifier)
        let leaveID = try #require(harness.planner.currentPlan?.leaveAlarmIdentifier)

        await harness.traffic.setMinutes(50)
        await harness.planner.refresh(trigger: .manual)

        #expect(harness.planner.currentPlan?.alarmIdentifier == wakeID)
        #expect(harness.planner.currentPlan?.leaveAlarmIdentifier == leaveID)
        // Many schedule calls, but never more than the two alarms a morning needs, and never
        // a cancel-then-add window where the user has no alarm at all.
        #expect(harness.alarms.scheduleCallCount > 2)
        #expect(harness.alarms.alarms.count == 2)
        #expect(harness.alarms.cancelled.isEmpty)
    }

    /// AlarmKit republishes its alarm list on every write, including the planner's own
    /// rescheduling, and the app listens to that stream to catch Lock Screen taps. Without a
    /// way to recognise its own echo, each check would trigger another check for as long as
    /// the app stayed open inside the watch window.
    @Test("The planner can tell its own AlarmKit writes apart from an outside change")
    func ownAlarmWritesAreRecognisedAsEchoes() async throws {
        let harness = try makeHarness(minutes: 20)
        #expect(harness.planner.lastAlarmWriteAt == nil)
        // Nothing written yet, so nothing can be mistaken for an echo.
        #expect(!harness.planner.isEchoOfOwnWrite(at: harness.clock.now))

        await harness.planner.refresh(trigger: .manual)

        let wroteAt = try #require(harness.planner.lastAlarmWriteAt)
        // The update the planner's own reschedule provokes arrives immediately.
        #expect(harness.planner.isEchoOfOwnWrite(at: wroteAt))
        #expect(harness.planner.isEchoOfOwnWrite(
            at: wroteAt.addingTimeInterval(WakePlanner.selfWriteEchoWindow - 0.5)
        ))
        // A Stop tapped on the Lock Screen a moment later is real news, not an echo.
        #expect(!harness.planner.isEchoOfOwnWrite(
            at: wroteAt.addingTimeInterval(WakePlanner.selfWriteEchoWindow + 0.5)
        ))
    }

    // MARK: - The leave-by backstop

    @Test("Every morning gets both a wake alarm and a leave-by alarm")
    func schedulesBothAlarms() async throws {
        let harness = try makeHarness()
        await harness.planner.refresh(trigger: .manual)

        let plan = try #require(harness.planner.currentPlan)
        let wake = try #require(harness.alarms.alarms[plan.alarmIdentifier])
        let leave = try #require(harness.alarms.alarms[plan.leaveAlarmIdentifier])

        #expect(wake.kind == .wake)
        #expect(wake.date == plan.wakeDate)
        #expect(leave.kind == .leave)
        #expect(leave.date == plan.leaveByDate)
        #expect(plan.isLeaveAlarmScheduled)
    }

    /// Three nine-minute snoozes eat a thirty-minute get-ready window entirely. The cap is what
    /// stops "five more minutes" from quietly becoming a missed meeting.
    @Test("Snooze is capped by the slack left before leave-by")
    func snoozeCappedBySlack() async throws {
        let harness = try makeHarness()
        harness.settings.snoozeMinutes = 20
        harness.settings.getReadyMinutes = 12
        await harness.planner.refresh(trigger: .manual)

        let plan = try #require(harness.planner.currentPlan)
        let wake = try #require(harness.alarms.alarms[plan.alarmIdentifier])
        // 12 minutes of get-ready, minus five to actually leave.
        #expect(wake.snoozeMinutes == 7)
        #expect(wake.snoozeMinutes < harness.settings.snoozeMinutes)
    }

    @Test("A generous get-ready window leaves the preferred snooze intact")
    func snoozeUncappedWhenSlackIsPlentiful() async throws {
        let harness = try makeHarness()
        harness.settings.snoozeMinutes = 9
        harness.settings.getReadyMinutes = 60
        await harness.planner.refresh(trigger: .manual)

        let plan = try #require(harness.planner.currentPlan)
        #expect(harness.alarms.alarms[plan.alarmIdentifier]?.snoozeMinutes == 9)
    }

    /// After the alarm has fired the wake time is history — but the drive can still fall apart
    /// while you're in the shower, and the leave-by alarm has to move with it.
    @Test("While getting ready, checks move leave-by but never the wake time")
    func gettingReadyMovesLeaveByOnly() async throws {
        let harness = try makeHarness(minutes: 20)
        await harness.planner.refresh(trigger: .manual)
        let plan = try #require(harness.planner.currentPlan)
        let wake = plan.wakeDate

        // Step to just after the alarm fired, then let traffic get worse.
        harness.clock.offset = wake.addingTimeInterval(Fixture.minutes(2)).timeIntervalSince(.now)
        let originalLeaveBy = plan.leaveByDate
        await harness.traffic.setMinutes(30)
        await harness.planner.refresh(trigger: .background)

        #expect(harness.planner.currentPhase == .gettingReady)
        #expect(plan.wakeDate == wake)                  // the wake time is history, untouched
        #expect(plan.leaveByDate < originalLeaveBy)     // but leave-by moved earlier...
        // ...and the system alarm moved with it.
        #expect(harness.alarms.alarms[plan.leaveAlarmIdentifier]?.date == plan.leaveByDate)
    }

    /// If traffic collapses badly enough, the moment you needed to leave is already behind you.
    /// The alarm still sitting in the system points at the old, later time — it would go off and
    /// tell you to leave long after you needed to, which is worse than saying nothing.
    @Test("A leave-by that has already passed cancels the stale alarm rather than misleading")
    func stalePastLeaveAlarmIsCancelled() async throws {
        let harness = try makeHarness(minutes: 20)
        await harness.planner.refresh(trigger: .manual)
        let plan = try #require(harness.planner.currentPlan)
        let staleAlarmDate = try #require(harness.alarms.alarms[plan.leaveAlarmIdentifier]?.date)

        harness.clock.offset = plan.wakeDate.addingTimeInterval(Fixture.minutes(2))
            .timeIntervalSince(.now)
        await harness.traffic.setMinutes(90)
        await harness.planner.refresh(trigger: .background)

        // The recomputed departure is now in the past...
        #expect(plan.leaveByDate < harness.clock.now)
        // ...so the alarm pointing at the old, later time is gone rather than left to fire.
        #expect(staleAlarmDate > harness.clock.now)
        #expect(harness.alarms.alarms[plan.leaveAlarmIdentifier] == nil)
        #expect(!plan.isLeaveAlarmScheduled)
        // The wake alarm is never cancelled this way — it may be ringing.
        #expect(harness.alarms.alarms[plan.alarmIdentifier] != nil)
    }

    @Test("Disabling cancels both alarms")
    func disablingCancelsBoth() async throws {
        let harness = try makeHarness()
        await harness.planner.refresh(trigger: .manual)
        let plan = try #require(harness.planner.currentPlan)
        let wakeID = plan.alarmIdentifier
        let leaveID = plan.leaveAlarmIdentifier

        await harness.planner.disableAlarm()

        #expect(harness.alarms.cancelled.contains(wakeID))
        #expect(harness.alarms.cancelled.contains(leaveID))
        #expect(harness.alarms.alarms.isEmpty)
    }

    // MARK: - Traffic classification

    /// MapKit has no congestion field, so a live ETA means nothing without a free-flow
    /// reference to compare it against. Before the baseline was captured on foreground it was
    /// only ever written by the 22:00 nightly task, which left a fresh install reporting
    /// "unknown" forever.
    @Test("A captured baseline turns a raw ETA into a traffic condition")
    func baselineEnablesClassification() async throws {
        let harness = try makeHarness(minutes: 45)
        harness.context.insert(
            RouteBaseline(
                routeKey: Coordinate.routeKey(from: home, to: work),
                freeFlowSeconds: Fixture.minutes(30),
                distanceMeters: 50_000
            )
        )
        try harness.context.save()

        await harness.planner.refresh(trigger: .manual)

        // 45 against a 30-minute free-flow is a ratio of 1.5 — heavy.
        #expect(harness.planner.currentPlan?.lastCondition == .heavy)
    }

    @Test("Without a baseline the condition is reported as unknown, not guessed")
    func missingBaselineIsHonest() async throws {
        let harness = try makeHarness(minutes: 45)
        await harness.planner.refresh(trigger: .manual)
        #expect(harness.planner.currentPlan?.lastCondition == .unknown)
    }

    @Test("The baseline is captured once and then left alone")
    func baselineIsCapturedAndCached() async throws {
        let harness = try makeHarness(minutes: 40)

        await harness.planner.refreshRouteBaselineIfNeeded()
        let baselines = try harness.context.fetch(FetchDescriptor<RouteBaseline>())
        #expect(baselines.count == 1)
        let callsAfterFirst = await harness.traffic.callCount

        // A second call inside the refresh window costs nothing.
        await harness.planner.refreshRouteBaselineIfNeeded()
        #expect(await harness.traffic.callCount == callsAfterFirst)
        #expect(try harness.context.fetch(FetchDescriptor<RouteBaseline>()).count == 1)
    }

    /// Confidence and traffic condition come from data already on disk. If they were only
    /// refreshed inside `runCheck`, every launch that skips a check — which is most of them —
    /// would report "no history" and "traffic unknown" despite both being known.
    @Test("Derived state is populated even when the check is skipped")
    func derivedStateSurvivesASkippedCheck() async throws {
        let harness = try makeHarness(minutes: 45)
        harness.context.insert(
            RouteBaseline(
                routeKey: Coordinate.routeKey(from: home, to: work),
                freeFlowSeconds: Fixture.minutes(30),
                distanceMeters: 50_000
            )
        )
        for index in 0..<8 {
            harness.context.insert(
                TravelSample(
                    routeKey: Coordinate.routeKey(from: home, to: work),
                    weekday: 2 + (index % 5),
                    minuteOfDay: 8 * 60,
                    seconds: Fixture.minutes(40 + Double(index)),
                    recordedAt: .now
                )
            )
        }
        try harness.context.save()

        await harness.planner.refresh(trigger: .manual)
        #expect(harness.planner.routeSampleCount == 8)
        #expect(harness.planner.currentPlan?.lastCondition == .heavy)

        // An idle background trigger does no check at all — and must still report both.
        let callsBefore = await harness.traffic.callCount
        await harness.planner.refresh(trigger: .background)

        #expect(await harness.traffic.callCount == callsBefore)
        #expect(harness.planner.currentPhase == .idle)
        #expect(harness.planner.routeSampleCount == 8)
        #expect(harness.planner.currentPlan?.lastCondition == .heavy)
    }

    // MARK: - Settings changes

    /// Editing get-ready time changes the arithmetic, not the traffic. Re-querying MapKit for
    /// every stepper tap would be pure waste — and before this path existed, editing a setting
    /// didn't recompute the plan at all, leaving a stale time on screen.
    @Test("A settings change recomputes from the cached estimate without a network call")
    func settingsChangeRecomputesOffline() async throws {
        let harness = try makeHarness(minutes: 30)
        await harness.planner.refresh(trigger: .manual)
        let originalWake = try #require(harness.planner.currentPlan?.wakeDate)
        let callsBefore = await harness.traffic.callCount

        harness.settings.getReadyMinutes += 30
        await harness.planner.refresh(trigger: .manual, useCachedEstimate: true)

        #expect(await harness.traffic.callCount == callsBefore)
        let newWake = try #require(harness.planner.currentPlan?.wakeDate)
        #expect(newWake == originalWake.addingTimeInterval(-Fixture.minutes(30)))
        #expect(harness.planner.currentPlan?.lastEstimateSource == .lastKnownGood)
    }

    @Test("Everything that moves the wake time is covered by the settings signature")
    func planSignatureCoversTheInputs() throws {
        let harness = try makeHarness()
        let settings = harness.settings

        // Each of these must produce a different signature, or editing it would silently
        // leave a stale wake time on the Today screen.
        let mutations: [(String, () -> Void)] = [
            ("arrival", { settings.defaultArrivalMinuteOfDay += 15 }),
            ("getReady", { settings.getReadyMinutes += 5 }),
            ("buffer", { settings.arrivalBufferMinutes += 5 }),
            ("lock", { settings.lockLaterAdjustmentsInsideMinutes += 5 }),
            ("window", { settings.refreshWindowStartMinutes += 30 }),
            ("maxTravel", { settings.maxTravelTimeMinutes += 15 }),
            ("minTravel", { settings.minTravelTimeMinutes += 1 }),
            ("posture", { settings.posture = .cautious }),
            ("floor", { settings.earliestAcceptableWakeMinuteOfDay += 15 }),
            ("snooze", { settings.snoozeMinutes += 1 }),
            ("weather", { settings.weatherEnabled.toggle() }),
            ("calendar", { settings.calendarEnabled.toggle() }),
            ("weekdays", { settings.activeWeekdays = [2, 3] }),
        ]

        for (name, mutate) in mutations {
            let before = settings.planSignature
            mutate()
            #expect(settings.planSignature != before, "\(name) did not change the signature")
        }
    }

    // MARK: - Weather

    @Test("Forecast snow pads the drive and pulls the alarm earlier")
    func weatherPadsTheEstimate() async throws {
        let clearHarness = try makeHarness(minutes: 30)
        await clearHarness.planner.refresh(trigger: .manual)
        let clearWake = try #require(clearHarness.planner.currentPlan?.wakeDate)

        let snowyHarness = try makeHarness(
            minutes: 30,
            weather: WeatherImpact(weather: .snow, detail: "Snow at 8:00 AM")
        )
        await snowyHarness.planner.refresh(trigger: .manual)
        let snowyPlan = try #require(snowyHarness.planner.currentPlan)

        #expect(snowyPlan.weather == .snow)
        #expect(snowyPlan.wakeDate < clearWake)
    }

    @Test("Weather can be switched off entirely")
    func weatherRespectsSetting() async throws {
        let harness = try makeHarness(
            minutes: 30,
            weather: WeatherImpact(weather: .ice, detail: nil)
        )
        harness.settings.weatherEnabled = false
        await harness.planner.refresh(trigger: .manual)

        #expect(harness.planner.currentPlan?.weather == .clear)
        #expect(harness.planner.lastBreakdown?.padding.weatherSeconds == 0)
    }

    // MARK: - Outcome feedback

    @Test("A finished morning is offered for grading, then stops being offered")
    func outcomePromptLifecycle() async throws {
        let harness = try makeHarness()
        await harness.planner.refresh(trigger: .manual)
        let plan = try #require(harness.planner.currentPlan)

        #expect(harness.planner.planAwaitingOutcome() == nil) // not finished yet

        harness.clock.offset = plan.leaveByDate.addingTimeInterval(Fixture.minutes(30))
            .timeIntervalSince(.now)
        #expect(harness.planner.planAwaitingOutcome()?.targetDayStart == plan.targetDayStart)

        harness.planner.record(outcome: .late, for: plan)
        #expect(harness.planner.planAwaitingOutcome() == nil)
        #expect(harness.planner.recentOutcomes() == [.late])
    }

    @Test("Days you didn't travel are excluded from calibration")
    func skippedMorningsAreNotCalibrationData() async throws {
        let harness = try makeHarness()
        await harness.planner.refresh(trigger: .manual)
        let plan = try #require(harness.planner.currentPlan)

        harness.planner.record(outcome: .didNotTravel, for: plan)
        #expect(harness.planner.recentOutcomes().isEmpty)
    }

    @Test("Worse traffic pulls the alarm earlier")
    func worseTrafficMovesEarlier() async throws {
        let harness = try makeHarness(minutes: 20)
        await harness.planner.refresh(trigger: .manual)
        let originalWake = try #require(harness.planner.currentPlan?.wakeDate)

        await harness.traffic.setMinutes(60)
        await harness.planner.refresh(trigger: .manual)

        let newWake = try #require(harness.planner.currentPlan?.wakeDate)
        #expect(newWake < originalWake)
        #expect(try logs(harness).last?.outcome == .movedEarlier)
    }

    @Test("An unchanged estimate re-checks without churning the alarm")
    func unchangedEstimateIsNoChange() async throws {
        let harness = try makeHarness(minutes: 30)
        await harness.planner.refresh(trigger: .manual)
        #expect(try logs(harness).last?.outcome == .scheduled)

        await harness.planner.refresh(trigger: .manual)
        #expect(try logs(harness).last?.outcome == .noChange)
    }

    /// If the policy keyed off AlarmKit acceptance rather than off having computed a time, a
    /// scheduling failure would make every later check look like a first-time schedule — and
    /// a first-time schedule bypasses the lock window entirely. That is the worst possible
    /// moment to accept a later wake time, so it gets its own test.
    @Test("A scheduling failure does not let later moves bypass the lock window")
    func schedulingFailureDoesNotBypassLock() async throws {
        let harness = try makeHarness(minutes: 60)
        harness.alarms.authorization = .denied
        await harness.planner.refresh(trigger: .manual)

        let plan = try #require(harness.planner.currentPlan)
        #expect(!plan.isAlarmScheduled)     // AlarmKit refused...
        #expect(plan.hasComputedWake)       // ...but we still have a wake time.
        let lockedWake = plan.wakeDate

        // Jump inside the lock window, then hand back a much better drive time.
        harness.clock.offset = lockedWake.addingTimeInterval(-Fixture.minutes(10))
            .timeIntervalSince(.now)
        await harness.traffic.setMinutes(15)
        await harness.planner.refresh(trigger: .manual)

        #expect(harness.planner.currentPlan?.wakeDate == lockedWake)
        #expect(try logs(harness).last?.outcome == .rejectedLocked)
    }

    @Test("Granting permission later registers the existing plan without a fresh query")
    func permissionGrantedLaterSchedulesExistingPlan() async throws {
        let harness = try makeHarness()
        harness.alarms.authorization = .denied
        await harness.planner.refresh(trigger: .manual)

        let plan = try #require(harness.planner.currentPlan)
        let wake = plan.wakeDate
        let callsBefore = await harness.traffic.callCount

        harness.alarms.authorization = .authorized
        await harness.planner.refresh(trigger: .background) // idle phase, no query expected

        #expect(await harness.traffic.callCount == callsBefore)
        #expect(plan.isAlarmScheduled)
        #expect(harness.alarms.alarms[plan.alarmIdentifier]?.date == wake)
    }

    // MARK: - Failure handling (the contract that matters)

    @Test("A failed check keeps the last known-good alarm time")
    func failureKeepsLastKnownGood() async throws {
        let harness = try makeHarness(minutes: 30)
        await harness.planner.refresh(trigger: .manual)

        let goodWake = try #require(harness.planner.currentPlan?.wakeDate)
        let goodDrive = try #require(harness.planner.currentPlan?.lastGoodTravelSeconds)

        await harness.traffic.setFailure(TrafficProviderError.network("offline"))
        await harness.planner.refresh(trigger: .manual)

        let plan = try #require(harness.planner.currentPlan)
        #expect(plan.wakeDate == goodWake)
        #expect(plan.lastGoodTravelSeconds == goodDrive)
        #expect(plan.isAlarmScheduled)
        #expect(plan.consecutiveFailureCount == 1)

        let last = try #require(try logs(harness).last)
        #expect(last.outcome == .failed)
        #expect(last.errorText != nil)
        #expect(last.detail.contains("last known-good"))
    }

    @Test("An implausible estimate is rejected, not clamped, and logged as such")
    func implausibleEstimateRejected() async throws {
        let harness = try makeHarness(minutes: 30)
        await harness.planner.refresh(trigger: .manual)
        let goodWake = try #require(harness.planner.currentPlan?.wakeDate)

        // Far beyond the 120-minute sanity ceiling.
        await harness.traffic.setMinutes(400)
        await harness.planner.refresh(trigger: .manual)

        #expect(harness.planner.currentPlan?.wakeDate == goodWake)
        #expect(try logs(harness).last?.outcome == .rejectedImplausible)
    }

    /// "Keep last known-good" has nothing to keep on the very first run. Leaving the user with
    /// no alarm at all would be the worst possible outcome, so a fallback is scheduled instead.
    @Test("A cold start with no network still schedules an alarm")
    func coldStartFailureStillSchedules() async throws {
        let harness = try makeHarness()
        await harness.traffic.setFailure(TrafficProviderError.network("offline"))

        await harness.planner.refresh(trigger: .nightly)

        let plan = try #require(harness.planner.currentPlan)
        #expect(plan.isAlarmScheduled)
        #expect(plan.wakeDate < plan.arrivalDeadline)
        #expect(plan.lastEstimateSource == .historical)
        #expect(harness.alarms.alarms[plan.alarmIdentifier] != nil)

        let last = try #require(try logs(harness).last)
        #expect(last.outcome == .failed)
    }

    @Test("Recovering from a failure resets the failure counter")
    func recoveryResetsFailureCount() async throws {
        let harness = try makeHarness()
        await harness.planner.refresh(trigger: .manual)

        await harness.traffic.setFailure(TrafficProviderError.network("offline"))
        await harness.planner.refresh(trigger: .manual)
        #expect(harness.planner.currentPlan?.consecutiveFailureCount == 1)

        await harness.traffic.setMinutes(35)
        await harness.planner.refresh(trigger: .manual)
        #expect(harness.planner.currentPlan?.consecutiveFailureCount == 0)
    }

    // MARK: - Phase behaviour

    @Test("While idle, a background trigger does not hit the network")
    func idleBackgroundDoesNotQuery() async throws {
        let harness = try makeHarness(nowHour: 3)
        await harness.planner.refresh(trigger: .manual)
        let callsAfterSetup = await harness.traffic.callCount

        // 03:00 is well before the 04:20 watch window opens.
        await harness.planner.refresh(trigger: .background)

        #expect(await harness.traffic.callCount == callsAfterSetup)
        #expect(harness.planner.currentPhase == .idle)
    }

    @Test("Inside the watch window, a background trigger does check")
    func watchingBackgroundQueries() async throws {
        let harness = try makeHarness(nowHour: 3)
        await harness.planner.refresh(trigger: .manual)
        let callsAfterSetup = await harness.traffic.callCount

        harness.clock.offset = Fixture.date(hour: 5).timeIntervalSince(.now)
        await harness.planner.refresh(trigger: .background)

        #expect(await harness.traffic.callCount > callsAfterSetup)
        #expect(harness.planner.currentPhase == .watching)
    }

    // MARK: - Manual override & disabling

    @Test("A manual override freezes the time but keeps logging checks")
    func manualOverrideFreezesTime() async throws {
        let harness = try makeHarness(minutes: 20)
        await harness.planner.refresh(trigger: .manual)

        let override = Fixture.date(hour: 6, minute: 15)
        await harness.planner.setManualOverride(override)
        #expect(harness.planner.currentPlan?.wakeDate == override)

        // Even a big traffic swing leaves the chosen time alone.
        await harness.traffic.setMinutes(90)
        await harness.planner.refresh(trigger: .manual)
        #expect(harness.planner.currentPlan?.wakeDate == override)

        await harness.planner.setManualOverride(nil)
        await harness.planner.refresh(trigger: .manual)
        #expect(harness.planner.currentPlan?.wakeDate != override)
    }

    @Test("An unconfigured route never schedules anything")
    func unconfiguredRouteDoesNothing() async throws {
        let harness = try makeHarness()
        harness.settings.setWorkCoordinate(nil)

        await harness.planner.refresh(trigger: .manual)

        #expect(harness.planner.currentPhase == .disabled)
        #expect(harness.alarms.alarms.isEmpty)
    }

    // MARK: - Solver integration

    @Test("The solver asks about future departure times, not the present")
    func queriesFutureDepartures() async throws {
        let harness = try makeHarness()
        await harness.planner.refresh(trigger: .manual)

        let departures = await harness.traffic.requestedDepartures
        #expect(!departures.isEmpty)
        // Every query is about the morning's departure, hours after the 03:00 "now".
        for departure in departures {
            #expect(departure > harness.clock.now)
        }
    }

    // MARK: - Running cost

    /// The whole point of gating weather behind Pro: a free user must never cost money. This
    /// asserts it at the planner rather than trusting the UI to hide a toggle.
    @Test("A free user never triggers a WeatherKit call")
    func freeUserCostsNothing() async throws {
        let harness = try makeHarness(
            weather: WeatherImpact(weather: .snow, detail: nil),
            isPro: false
        )
        harness.settings.weatherEnabled = true // even with the setting on

        await harness.planner.refresh(trigger: .manual)
        await harness.planner.refresh(trigger: .manual)

        #expect(harness.weather.callCount == 0)
        #expect(harness.planner.currentPlan?.weather == .clear)
        #expect(harness.planner.lastBreakdown?.padding.weatherSeconds == 0)
    }

    /// Before caching, the forecast was refetched on every fifteen-minute check — which
    /// exhausted WeatherKit's free allowance at around a thousand users.
    @Test("The forecast is fetched once per morning, not once per check")
    func weatherIsCachedAcrossChecks() async throws {
        let harness = try makeHarness(weather: WeatherImpact(weather: .wet, detail: nil))

        for _ in 0..<5 {
            await harness.planner.refresh(trigger: .manual)
        }

        #expect(harness.weather.callCount == 1)
        #expect(harness.planner.currentPlan?.weather == .wet)
    }

    @Test("A stale forecast is refetched")
    func staleWeatherIsRefreshed() async throws {
        let harness = try makeHarness(weather: WeatherImpact(weather: .wet, detail: nil))
        await harness.planner.refresh(trigger: .manual)
        #expect(harness.weather.callCount == 1)

        harness.clock.offset += WakePlanner.weatherCacheInterval + 60
        await harness.planner.refresh(trigger: .manual)

        #expect(harness.weather.callCount == 2)
    }

    /// Idle background checks do no work, so they must not spend a metered call either.
    @Test("An idle background check costs nothing")
    func idleCheckSpendsNoWeatherCall() async throws {
        let harness = try makeHarness(nowHour: 3, weather: WeatherImpact(weather: .wet, detail: nil))
        await harness.planner.refresh(trigger: .manual)
        let callsAfterSetup = harness.weather.callCount

        await harness.planner.refresh(trigger: .background) // idle phase
        #expect(harness.weather.callCount == callsAfterSetup)
    }

    @Test("Calendar data is ignored without Pro, however the toggle is set")
    func calendarIsGatedInThePlanner() async throws {
        let harness = try makeHarness(isPro: false)
        harness.settings.calendarEnabled = true
        // The planner is handed a live provider, but must not act on Pro-only data.
        harness.planner.calendarProvider = DisabledCalendarProvider()

        await harness.planner.refresh(trigger: .manual)

        #expect(harness.planner.currentPlan?.arrivalSource == .settings)
        #expect(harness.planner.currentPlan?.destinationFromCalendar == false)
    }
}
