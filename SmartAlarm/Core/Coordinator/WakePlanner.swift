import Foundation
import SwiftData
import WidgetKit

/// Orchestrates one complete check: resolve the morning, ask for a drive time, decide whether
/// the alarm is allowed to move, persist the outcome, and log it either way.
///
/// This is the only place that writes `AlarmPlan`. Everything it decides is delegated to the
/// pure types in `Core/Logic`, so the interesting behaviour is unit-tested and this class stays
/// a coordinator rather than a second implementation of the rules.
@Observable
@MainActor
final class WakePlanner {
    private let modelContext: ModelContext
    private let traffic: any TrafficProviding
    private let alarms: any AlarmScheduling
    private let weather: any WeatherProviding
    private let clock: DateProvider
    private let calendar: Calendar

    /// Swapped for `DisabledCalendarProvider` when the feature is off.
    var calendarProvider: any CalendarProviding
    private(set) var lastWeatherImpact: WeatherImpact = .clear

    // Observable state for the UI.
    private(set) var isChecking = false
    private(set) var lastBreakdown: WakeTimeBreakdown?
    /// A traffic check that didn't produce a usable estimate.
    private(set) var lastErrorMessage: String?
    /// A perfectly good estimate that AlarmKit then refused to schedule. Kept separate
    /// because "we couldn't reach Maps" and "we couldn't set the alarm" need different fixes.
    private(set) var schedulingErrorMessage: String?
    private(set) var currentPhase: SchedulePhase = .disabled
    private(set) var currentPlan: AlarmPlan?
    private(set) var isAnomalousMorning = false
    /// How many recorded mornings the current estimate leans on. Zero means the padding is
    /// running on a cold-start default, which the user deserves to know.
    private(set) var routeSampleCount = 0
    private(set) var testAlarmFiresAt: Date?

    /// Debug hook: when set, replaces the traffic provider for the next checks.
    var injectedTravelMinutes: Double?

    /// Mirrored from `EntitlementStore`. Gates the features that cost money to run.
    var isPro = false

    init(
        modelContext: ModelContext,
        traffic: any TrafficProviding,
        alarms: any AlarmScheduling,
        calendarProvider: any CalendarProviding,
        weather: any WeatherProviding = DisabledWeatherProvider(),
        clock: DateProvider,
        calendar: Calendar = .current
    ) {
        self.modelContext = modelContext
        self.traffic = traffic
        self.alarms = alarms
        self.weather = weather
        self.calendarProvider = calendarProvider
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - Settings

    func settings() -> UserSettings {
        let descriptor = FetchDescriptor<UserSettings>()
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let created = UserSettings()
        modelContext.insert(created)
        try? modelContext.save()
        return created
    }

    // MARK: - The single entry point

    /// Runs a check. Every trigger — nightly bootstrap, background refresh, app launch, the
    /// debug button — comes through here so there is exactly one code path to reason about.
    /// - Parameter useCachedEstimate: recompute from the last known-good drive time instead of
    ///   querying the provider. Used when a *setting* changes: the traffic data is still valid,
    ///   only the arithmetic moved, so there is nothing to be gained from a network round trip.
    @discardableResult
    func refresh(trigger: CheckTrigger, useCachedEstimate: Bool = false) async -> SchedulePhase {
        guard !isChecking else { return currentPhase }
        isChecking = true
        defer { isChecking = false }

        let now = clock.now
        let settings = settings()

        guard settings.isEnabled,
              let home = settings.homeCoordinate,
              let work = settings.workCoordinate
        else {
            currentPhase = .disabled
            currentPlan = nil
            await cancelAnyScheduledAlarm()
            return .disabled
        }

        guard let (dayStart, defaultArrival) = settings.nextTargetMorning(after: now, calendar: calendar) else {
            currentPhase = .disabled
            return .disabled
        }

        let resolution = await resolveArrival(
            settings: settings,
            dayStart: dayStart,
            defaultArrival: defaultArrival,
            work: work,
            now: now
        )

        let plan = planFor(dayStart: dayStart, resolution: resolution)
        applyResolution(resolution, to: plan)
        currentPlan = plan

        let posture = resolution.importance.escalatesPosture
            ? settings.posture.escalated
            : settings.posture

        func makeSolver(weatherPadFraction: Double) -> WakeTimeSolver {
            WakeTimeSolver(
                inputs: settings.wakeTimeInputs(
                    arrivalDeadline: resolution.deadline,
                    extraBufferMinutes: resolution.extraBufferMinutes,
                    posture: posture,
                    dayStart: dayStart,
                    weatherPadFraction: weatherPadFraction,
                    calendar: calendar
                ),
                calendar: calendar
            )
        }

        // The phase window depends only on the sanity bounds, never on the estimate, so the
        // cached forecast is enough to work out whether a check is even due.
        plan.earliestPossibleWake = makeSolver(weatherPadFraction: plan.weatherPadFraction)
            .earliestPossibleWake()

        let phase = settings.phaseCalculator.phase(
            now: now,
            window: plan.phaseWindow,
            isEnabled: true
        )
        currentPhase = phase

        // A manual override freezes the plan: the user has taken the wheel.
        if let override = plan.manualOverrideWake {
            plan.wakeDate = override
            await ensureAlarmScheduled(plan: plan, settings: settings)
            save()
            log(
                plan: plan, phase: phase, outcome: .noChange, trigger: trigger,
                detail: "Manual override in effect", now: now
            )
            return phase
        }

        // Confidence and traffic condition are derived from data already on disk, so they must
        // be refreshed even when no check runs. Without this the Today screen reports "no
        // history" and "traffic unknown" on every launch that skips a check — which is most of
        // them — despite both being perfectly well known.
        refreshDerivedState(plan: plan, origin: home)

        // Idle means idle — no network, no battery. The exception is the nightly bootstrap,
        // which deliberately runs while idle so a safe alarm exists before you go to sleep.
        let mustQuery = trigger == .nightly || trigger == .manual || !plan.hasComputedWake
        guard phase.performsChecks || mustQuery else {
            // Nothing new to compute — but if AlarmKit refused us earlier (permission not yet
            // granted, transient failure) the existing plan still needs registering. That
            // costs no network, so it's safe to do even while idle.
            if !plan.isAlarmScheduled {
                await ensureAlarmScheduled(plan: plan, settings: settings)
            }
            plan.lastCheckAt = now
            save()
            return phase
        }

        // Only now, with a check definitely happening, is it worth spending a metered
        // WeatherKit call — and even then only if the cached forecast has gone stale.
        let padFraction = await weatherPadFraction(
            plan: plan, settings: settings, origin: home, now: now
        )

        await runCheck(
            plan: plan,
            settings: settings,
            solver: makeSolver(weatherPadFraction: padFraction),
            origin: home,
            phase: phase,
            trigger: trigger,
            now: now,
            useCachedEstimate: useCachedEstimate
        )
        return phase
    }

    // MARK: - Calendar resolution

    private func resolveArrival(
        settings: UserSettings,
        dayStart: Date,
        defaultArrival: Date,
        work: Coordinate,
        now: Date
    ) async -> ArrivalResolution {
        let workLabel = settings.workAddress.isEmpty ? "Work" : settings.workAddress

        guard settings.calendarEnabled else {
            return ArrivalResolver.resolve(
                defaultArrival: defaultArrival,
                commitment: nil,
                importance: .normal,
                workCoordinate: work,
                workLabel: workLabel,
                allowDestinationOverride: false
            )
        }

        // Look from 4 a.m. through a few hours past the usual arrival, which is wide enough
        // to catch an unusually early start without dragging in the afternoon.
        let windowStart = calendar.date(byAdding: .hour, value: 4, to: dayStart) ?? dayStart
        let windowEnd = calendar.date(byAdding: .hour, value: 4, to: defaultArrival) ?? defaultArrival
        guard windowEnd > windowStart else {
            return ArrivalResolver.resolve(
                defaultArrival: defaultArrival, commitment: nil, importance: .normal,
                workCoordinate: work, workLabel: workLabel, allowDestinationOverride: false
            )
        }
        let interval = DateInterval(start: windowStart, end: windowEnd)

        let events = await calendarProvider.commitments(in: interval)
        let commitment = CommitmentSelector.firstCommitment(
            among: events,
            notBefore: windowStart,
            notAfter: windowEnd
        )

        let reminderTitles = settings.remindersEnabled
            ? await calendarProvider.highPriorityReminderTitles(in: interval)
            : []

        let importance = settings.importanceScorer.level(
            for: commitment,
            highPriorityReminderTitles: reminderTitles
        )

        return ArrivalResolver.resolve(
            defaultArrival: defaultArrival,
            commitment: commitment,
            importance: importance,
            workCoordinate: work,
            workLabel: workLabel,
            allowDestinationOverride: settings.calendarCanOverrideDestination
        )
    }

    // MARK: - Derived state

    /// Recomputes everything the UI shows that can be derived from local data alone — no
    /// network, no cost. Safe to call on every refresh, including ones that skip the check.
    private func refreshDerivedState(plan: AlarmPlan, origin: Coordinate) {
        let routeKey = Coordinate.routeKey(from: origin, to: plan.destination)
        let history = historyModel(routeKey: routeKey)
        routeSampleCount = history.sampleCount

        // A baseline captured after the last check leaves the stored condition stale at
        // "unknown". Reclassifying costs nothing because the raw estimate was kept.
        if let raw = plan.lastRawTravelSeconds, let baseline = baselineSeconds(routeKey: routeKey) {
            plan.lastCondition = TrafficCondition.classify(
                observedSeconds: raw,
                freeFlowSeconds: baseline
            )
        }
    }

    // MARK: - Weather

    /// Forecasts are refetched at most this often. WeatherKit's free allowance is 500,000
    /// calls a month across all users, so calling it on every fifteen-minute check would
    /// exhaust it at roughly a thousand users. Cached, it lands nearer eleven thousand.
    static let weatherCacheInterval: TimeInterval = 3 * 60 * 60

    private func weatherPadFraction(
        plan: AlarmPlan,
        settings: UserSettings,
        origin: Coordinate,
        now: Date
    ) async -> Double {
        // Weather is a Pro feature, which is what keeps the only metered dependency in the
        // app from accruing cost on free users at all.
        guard settings.weatherEnabled, isPro else {
            plan.weather = .clear
            plan.weatherPadFraction = 0
            plan.weatherFetchedAt = nil
            lastWeatherImpact = .clear
            return 0
        }

        if let fetchedAt = plan.weatherFetchedAt,
           now.timeIntervalSince(fetchedAt) < Self.weatherCacheInterval {
            return plan.weatherPadFraction
        }

        let departure = plan.arrivalDeadline
            .addingTimeInterval(-Double(settings.arrivalBufferMinutes) * 60)
        let impact = await weather.impact(at: origin, on: departure)
        plan.weather = impact.weather
        plan.weatherPadFraction = impact.padFraction
        plan.weatherFetchedAt = now
        lastWeatherImpact = impact
        return impact.padFraction
    }

    // MARK: - Plan lifecycle

    private func planFor(dayStart: Date, resolution: ArrivalResolution) -> AlarmPlan {
        let descriptor = FetchDescriptor<AlarmPlan>(
            predicate: #Predicate { $0.targetDayStart == dayStart }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }

        let created = AlarmPlan(
            targetDayStart: dayStart,
            arrivalDeadline: resolution.deadline,
            arrivalSource: resolution.source,
            destination: resolution.destination,
            destinationLabel: resolution.destinationLabel,
            destinationFromCalendar: resolution.destinationFromCalendar,
            importance: resolution.importance,
            extraBufferMinutes: resolution.extraBufferMinutes,
            leaveByDate: resolution.deadline,
            wakeDate: resolution.deadline,
            earliestPossibleWake: resolution.deadline,
            eventTitle: resolution.eventTitle
        )
        modelContext.insert(created)
        return created
    }

    private func applyResolution(_ resolution: ArrivalResolution, to plan: AlarmPlan) {
        plan.arrivalDeadline = resolution.deadline
        plan.arrivalSourceRaw = resolution.source.rawValue
        plan.eventTitle = resolution.eventTitle
        plan.destinationLatitude = resolution.destination.latitude
        plan.destinationLongitude = resolution.destination.longitude
        plan.destinationLabel = resolution.destinationLabel
        plan.destinationFromCalendar = resolution.destinationFromCalendar
        plan.importanceRaw = resolution.importance.rawValue
        plan.extraBufferMinutes = resolution.extraBufferMinutes
        plan.updatedAt = clock.now
    }

    // MARK: - Running one check

    private func runCheck(
        plan: AlarmPlan,
        settings: UserSettings,
        solver: WakeTimeSolver,
        origin: Coordinate,
        phase: SchedulePhase,
        trigger: CheckTrigger,
        now: Date,
        useCachedEstimate: Bool = false
    ) async {
        let destination = plan.destination
        let routeKey = Coordinate.routeKey(from: origin, to: destination)
        let history = historyModel(routeKey: routeKey)
        routeSampleCount = history.sampleCount
        plan.lastCheckAt = now

        do {
            let cachedSeconds = useCachedEstimate ? plan.lastRawTravelSeconds : nil
            let breakdown = try await solver.solve(now: now, history: history) { [weak self] departure in
                guard let self else { throw TrafficProviderError.unavailable("Planner went away") }
                if let cachedSeconds {
                    return TravelEstimate(
                        seconds: cachedSeconds,
                        distanceMeters: 0,
                        departureDate: departure,
                        source: .lastKnownGood
                    )
                }
                if let injected = self.injectedTravelMinutes {
                    return TravelEstimate(
                        seconds: injected * 60,
                        distanceMeters: 0,
                        departureDate: departure,
                        source: .manual
                    )
                }
                return try await self.traffic.estimate(
                    from: origin,
                    to: destination,
                    departingAt: departure
                )
            }

            await applySuccess(
                breakdown: breakdown,
                plan: plan,
                settings: settings,
                routeKey: routeKey,
                history: history,
                phase: phase,
                trigger: trigger,
                now: now
            )
        } catch {
            await applyFailure(
                error: error,
                plan: plan,
                settings: settings,
                solver: solver,
                history: history,
                phase: phase,
                trigger: trigger,
                now: now
            )
        }
    }

    private func applySuccess(
        breakdown: WakeTimeBreakdown,
        plan: AlarmPlan,
        settings: UserSettings,
        routeKey: String,
        history: HistoricalTravelModel,
        phase: SchedulePhase,
        trigger: CheckTrigger,
        now: Date
    ) async {
        lastBreakdown = breakdown
        lastErrorMessage = nil

        let baseline = baselineSeconds(routeKey: routeKey)
        let condition = TrafficCondition.classify(
            observedSeconds: breakdown.estimate.seconds,
            freeFlowSeconds: baseline
        )
        let departureMinute = MinuteOfDay.from(breakdown.leaveBy, calendar: calendar)
        let departureWeekday = calendar.component(.weekday, from: breakdown.leaveBy)
        isAnomalousMorning = history.isAnomalous(
            observedSeconds: breakdown.estimate.seconds,
            weekday: departureWeekday,
            minuteOfDay: departureMinute
        )

        let decision = settings.adjustmentPolicy.decide(
            now: now,
            currentWake: plan.hasComputedWake ? plan.wakeDate : nil,
            proposedWake: breakdown.wakeTime,
            previousTravelSeconds: plan.lastGoodTravelSeconds,
            proposedTravelSeconds: breakdown.padding.totalSeconds,
            pending: plan.pendingLaterProposal
        )

        // The estimate itself is always worth recording, even when the alarm is frozen —
        // "you can leave at 8:25 now" is true and useful whether or not the alarm moved.
        plan.leaveByDate = breakdown.leaveBy
        plan.lastGoodTravelSeconds = breakdown.padding.totalSeconds
        plan.lastCondition = condition
        plan.lastEstimateSource = breakdown.estimate.source
        plan.lastSuccessfulCheckAt = now
        plan.consecutiveFailureCount = 0
        plan.routeAdvisories = breakdown.estimate.advisories
        plan.routeName = breakdown.estimate.routeName
        // The *raw* provider answer, kept alongside the padded total: changing a setting
        // changes the arithmetic, not the traffic, so the padding can be recomputed from this
        // without asking MapKit again.
        plan.lastRawTravelSeconds = breakdown.estimate.seconds

        // Once the wake alarm has fired, the wake time is history and moving it is meaningless.
        // Checks keep running because the *drive* can still deteriorate while you're getting
        // ready — and when it does, the leave-by alarm has to move with it.
        if phase.isAfterWake {
            await ensureAlarmScheduled(plan: plan, settings: settings)
            save()
            log(
                plan: plan, phase: phase, outcome: .noChange, trigger: trigger,
                detail: "Leave-by updated to \(Format.time(breakdown.leaveBy)); wake time already passed.",
                now: now,
                travelSeconds: breakdown.padding.totalSeconds,
                condition: condition,
                estimateSource: breakdown.estimate.source,
                anomalous: isAnomalousMorning
            )
            return
        }

        let outcome: CheckOutcome
        switch decision {
        case .scheduleInitial(let date):
            plan.wakeDate = date
            plan.hasComputedWake = true
            plan.pendingLaterProposal = nil
            outcome = .scheduled
        case .moveEarlier(let date):
            plan.wakeDate = date
            plan.pendingLaterProposal = nil
            outcome = .movedEarlier
        case .moveLater(let date):
            plan.wakeDate = date
            plan.pendingLaterProposal = nil
            outcome = .movedLater
        case .holdPendingConfirmation(let pending):
            plan.pendingLaterProposal = pending
            outcome = .held
        case .rejectedLocked:
            outcome = .rejectedLocked
        case .noChange:
            outcome = .noChange
        }

        // Rescheduled on every successful check, not just when the time moved: the metadata
        // carries the drive estimate and traffic condition, and a Lock Screen showing last
        // hour's numbers is worse than no numbers.
        await ensureAlarmScheduled(plan: plan, settings: settings)

        recordSampleIfAppropriate(
            plan: plan,
            routeKey: routeKey,
            rawSeconds: breakdown.estimate.seconds,
            phase: phase,
            now: now
        )

        save()

        log(
            plan: plan, phase: phase, outcome: outcome, trigger: trigger,
            detail: decision.summary, now: now,
            travelSeconds: breakdown.padding.totalSeconds,
            condition: condition,
            estimateSource: breakdown.estimate.source,
            anomalous: isAnomalousMorning
        )
    }

    private func applyFailure(
        error: Error,
        plan: AlarmPlan,
        settings: UserSettings,
        solver: WakeTimeSolver,
        history: HistoricalTravelModel,
        phase: SchedulePhase,
        trigger: CheckTrigger,
        now: Date
    ) async {
        plan.consecutiveFailureCount += 1

        let isImplausible: Bool
        let message: String
        if case WakeTimeError.implausibleTravelTime(let seconds, let minimum, let maximum) = error {
            isImplausible = true
            message = String(
                format: "Estimate of %.0f min is outside the %.0f–%.0f min sanity range; ignored.",
                seconds / 60, minimum / 60, maximum / 60
            )
        } else {
            isImplausible = false
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        lastErrorMessage = message
        AppLogger.planner.error("Check failed: \(message, privacy: .public)")

        var detail: String
        if plan.hasComputedWake {
            // The contract: a failed check never disturbs a good wake time. Keyed off the
            // computed time rather than AlarmKit's acceptance, so a scheduling failure can't
            // trick us into recomputing from scratch.
            detail = "Kept last known-good wake time of \(plan.wakeDate.formatted(date: .omitted, time: .shortened))."
            await ensureAlarmScheduled(plan: plan, settings: settings)
        } else {
            // No alarm exists yet, so "keep last known-good" has nothing to keep. Falling back
            // to the historical model beats leaving the user with no alarm at all.
            detail = await scheduleFallbackAlarm(
                plan: plan, settings: settings, solver: solver, history: history, now: now
            )
        }

        save()

        log(
            plan: plan, phase: phase,
            outcome: isImplausible ? .rejectedImplausible : .failed,
            trigger: trigger,
            detail: detail, now: now,
            travelSeconds: plan.lastGoodTravelSeconds,
            condition: plan.lastCondition,
            estimateSource: .lastKnownGood,
            errorText: message
        )
    }

    /// Cold-start safety net: the very first alarm, computed without a working network.
    private func scheduleFallbackAlarm(
        plan: AlarmPlan,
        settings: UserSettings,
        solver: WakeTimeSolver,
        history: HistoricalTravelModel,
        now: Date
    ) async -> String {
        let approximateDeparture = solver.inputs.arrivalDeadline
            .addingTimeInterval(-solver.arrivalBufferSeconds)
        let weekday = calendar.component(.weekday, from: approximateDeparture)
        let minuteOfDay = MinuteOfDay.from(approximateDeparture, calendar: calendar)

        let fallbackSeconds = history.expectedSeconds(
            posture: solver.inputs.posture,
            weekday: weekday,
            minuteOfDay: minuteOfDay
        )
        let seconds = fallbackSeconds ?? solver.seedTravelSeconds(history: history)
        let usedHistory = fallbackSeconds != nil

        guard let breakdown = try? await solver.solve(now: now, history: history, estimate: { departure in
            TravelEstimate(
                seconds: seconds,
                distanceMeters: 0,
                departureDate: departure,
                source: .historical
            )
        }) else {
            return "No estimate available and no alarm could be computed."
        }

        plan.wakeDate = breakdown.wakeTime
        plan.hasComputedWake = true
        plan.leaveByDate = breakdown.leaveBy
        plan.lastEstimateSource = .historical
        lastBreakdown = breakdown
        await ensureAlarmScheduled(plan: plan, settings: settings)

        let source = usedHistory ? "your recorded history" : "a conservative default"
        return "No live estimate — scheduled \(breakdown.wakeTime.formatted(date: .omitted, time: .shortened)) from \(source)."
    }

    // MARK: - Alarm scheduling

    private func ensureAlarmScheduled(plan: AlarmPlan, settings: UserSettings) async {
        guard alarms.authorization.isAuthorized else {
            // The Today screen already prompts for permission, so this isn't surfaced twice.
            schedulingErrorMessage = nil
            plan.isAlarmScheduled = false
            return
        }
        let now = clock.now
        let metadata = plan.alarmMetadata()
        var failure: String?

        // Same identifiers every time: AlarmKit updates each alarm in place rather than
        // stacking duplicates, and there is never a moment with no alarm scheduled.
        if plan.wakeDate > now {
            do {
                try await alarms.schedule(
                    id: plan.alarmIdentifier,
                    at: plan.wakeDate,
                    kind: .wake,
                    metadata: metadata,
                    // Capped by the slack left before leave-by, so snoozing can never carry
                    // you past the moment you had to be in the car.
                    snoozeMinutes: plan.effectiveSnoozeMinutes(preferred: settings.snoozeMinutes)
                )
                plan.isAlarmScheduled = true
            } catch {
                plan.isAlarmScheduled = false
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        // The backstop. Everything above is about waking you at the right minute; this is what
        // stops "five more minutes" from quietly becoming a missed meeting. It is a real system
        // alarm, so it fires even if the app has been force-quit.
        if plan.leaveByDate > now {
            do {
                try await alarms.schedule(
                    id: plan.leaveAlarmIdentifier,
                    at: plan.leaveByDate,
                    kind: .leave,
                    metadata: metadata,
                    snoozeMinutes: 0
                )
                plan.isLeaveAlarmScheduled = true
            } catch {
                plan.isLeaveAlarmScheduled = false
                failure = failure ?? ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        } else if plan.isLeaveAlarmScheduled {
            // Traffic got bad enough that the leave-by time has already passed. The alarm
            // still sitting in the system points at the *old*, later time — it would go off
            // and cheerfully tell you to leave long after you needed to. A stale alarm that
            // gives false reassurance is worse than none, so it goes.
            //
            // The wake alarm deliberately gets no equivalent treatment: it may be ringing
            // right now, and cancelling a ringing alarm is how you oversleep.
            try? alarms.cancel(id: plan.leaveAlarmIdentifier)
            plan.isLeaveAlarmScheduled = false
        }

        schedulingErrorMessage = failure
        if let failure {
            AppLogger.alarm.error("Scheduling failed: \(failure, privacy: .public)")
        }
    }

    private func cancelAnyScheduledAlarm() async {
        let descriptor = FetchDescriptor<AlarmPlan>(
            predicate: #Predicate { $0.isAlarmScheduled || $0.isLeaveAlarmScheduled }
        )
        guard let plans = try? modelContext.fetch(descriptor) else { return }
        for plan in plans {
            try? alarms.cancel(id: plan.alarmIdentifier)
            try? alarms.cancel(id: plan.leaveAlarmIdentifier)
            plan.isAlarmScheduled = false
            plan.isLeaveAlarmScheduled = false
        }
        currentPlan = nil
        save()
    }

    // MARK: - User actions

    func setManualOverride(_ date: Date?) async {
        guard let plan = currentPlan else { return }
        plan.manualOverrideWake = date
        if let date { plan.wakeDate = date }
        save()
        await refresh(trigger: .manual)
    }

    /// The most recent finished morning that hasn't been graded yet, if any. The Today screen
    /// uses this to ask the one question that closes the calibration loop.
    func planAwaitingOutcome() -> AlarmPlan? {
        let now = clock.now
        let cutoff = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let descriptor = FetchDescriptor<AlarmPlan>(
            predicate: #Predicate {
                $0.outcomeRaw == nil && $0.hasComputedWake
                    && $0.leaveByDate < now && $0.leaveByDate > cutoff
            },
            sortBy: [SortDescriptor(\.leaveByDate, order: .reverse)]
        )
        return try? modelContext.fetch(descriptor).first
    }

    func record(outcome: MorningOutcome, for plan: AlarmPlan) {
        plan.outcome = outcome
        save()
    }

    /// Outcomes from graded mornings, newest first, for `PostureAdvisor`.
    func recentOutcomes(limit: Int = 30) -> [MorningOutcome] {
        var descriptor = FetchDescriptor<AlarmPlan>(
            predicate: #Predicate { $0.outcomeRaw != nil },
            sortBy: [SortDescriptor(\.targetDayStart, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let plans = (try? modelContext.fetch(descriptor)) ?? []
        return plans.compactMap(\.outcome).filter(\.countsTowardCalibration)
    }

    func postureRecommendation() -> PostureAdvisor.Recommendation? {
        let settings = settings()
        return settings.postureAdvisor.recommendation(
            for: recentOutcomes(),
            current: settings.posture
        )
    }

    func applyPosture(_ posture: ReliabilityPosture) async {
        settings().posture = posture
        save()
        await refresh(trigger: .manual)
    }

    func disableAlarm() async {
        let settings = settings()
        settings.isEnabled = false
        save()
        await cancelAnyScheduledAlarm()
        currentPhase = .disabled
    }

    func enableAlarm() async {
        let settings = settings()
        settings.isEnabled = true
        save()
        await refresh(trigger: .manual)
    }

    // MARK: - Test alarm

    /// A stable identifier, so repeated tests replace one another instead of stacking, and so
    /// a test can never collide with the real wake or leave alarms.
    static let testAlarmIdentifier = UUID(uuidString: "7E5F1C40-0000-4000-A000-5A1A2B3C4D5E")!

    /// Schedules a throwaway alarm a minute out.
    ///
    /// This exists because the app's central claim — that it rings through a silenced,
    /// force-quit phone — is one nobody should have to take on faith at 6 a.m. It also gives
    /// an App Store reviewer a sixty-second path to seeing the app work, instead of asking
    /// them to wait until tomorrow morning.
    @discardableResult
    func scheduleTestAlarm(inSeconds seconds: TimeInterval = 60) async -> Bool {
        guard alarms.authorization.isAuthorized else {
            schedulingErrorMessage = "SmartAlarm needs permission to set alarms first."
            return false
        }
        let fireDate = clock.now.addingTimeInterval(seconds)
        do {
            try await alarms.schedule(
                id: Self.testAlarmIdentifier,
                at: fireDate,
                kind: .test,
                metadata: currentPlan?.alarmMetadata() ?? WakeAlarmMetadata(
                    leaveByDate: fireDate,
                    arrivalDeadline: fireDate,
                    driveMinutes: 0,
                    condition: .unknown,
                    destinationLabel: "Test"
                ),
                snoozeMinutes: 0
            )
            testAlarmFiresAt = fireDate
            schedulingErrorMessage = nil
            return true
        } catch {
            schedulingErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func cancelTestAlarm() {
        try? alarms.cancel(id: Self.testAlarmIdentifier)
        testAlarmFiresAt = nil
    }

    // MARK: - History

    private func historyModel(routeKey: String) -> HistoricalTravelModel {
        let cutoff = clock.now.addingTimeInterval(-TravelSample.retentionInterval)
        let descriptor = FetchDescriptor<TravelSample>(
            predicate: #Predicate { $0.routeKey == routeKey && $0.recordedAt >= cutoff }
        )
        let samples = (try? modelContext.fetch(descriptor)) ?? []
        return HistoricalTravelModel(samples: samples.map(\.modelSample))
    }

    /// One sample per morning, taken from the check closest to departure — the locked phase.
    /// That check is the nearest thing to ground truth without tracking the user's location.
    private func recordSampleIfAppropriate(
        plan: AlarmPlan,
        routeKey: String,
        rawSeconds: Double,
        phase: SchedulePhase,
        now: Date
    ) {
        guard phase == .locked, !plan.hasRecordedSample else { return }

        let sample = TravelSample(
            routeKey: routeKey,
            weekday: calendar.component(.weekday, from: plan.leaveByDate),
            minuteOfDay: MinuteOfDay.from(plan.leaveByDate, calendar: calendar),
            seconds: rawSeconds,
            recordedAt: now
        )
        modelContext.insert(sample)
        plan.hasRecordedSample = true
        pruneOldSamples(now: now)
    }

    private func pruneOldSamples(now: Date) {
        let cutoff = now.addingTimeInterval(-TravelSample.retentionInterval)
        try? modelContext.delete(
            model: TravelSample.self,
            where: #Predicate { $0.recordedAt < cutoff }
        )
    }

    private func baselineSeconds(routeKey: String) -> Double? {
        let descriptor = FetchDescriptor<RouteBaseline>(
            predicate: #Predicate { $0.routeKey == routeKey }
        )
        return (try? modelContext.fetch(descriptor).first)?.freeFlowSeconds
    }

    /// Captures a free-flow reference for the route by asking about a 3:30 a.m. Sunday
    /// departure. Without it there is nothing to compare a live ETA against, and traffic
    /// classification would just be a guess. Refreshed monthly, and only on nightly runs so
    /// it never competes with the checks that matter.
    func refreshRouteBaselineIfNeeded(destination explicitDestination: Coordinate? = nil) async {
        let settings = settings()
        guard let home = settings.homeCoordinate,
              let work = explicitDestination ?? settings.workCoordinate
        else { return }
        let routeKey = Coordinate.routeKey(from: home, to: work)

        let descriptor = FetchDescriptor<RouteBaseline>(
            predicate: #Predicate { $0.routeKey == routeKey }
        )
        let existing = try? modelContext.fetch(descriptor).first
        if let existing, !existing.isStale(now: clock.now) { return }

        guard let quietDeparture = nextQuietDeparture(after: clock.now) else { return }
        guard let estimate = try? await traffic.estimate(
            from: home, to: work, departingAt: quietDeparture
        ) else { return }

        if let existing {
            existing.freeFlowSeconds = estimate.seconds
            existing.distanceMeters = estimate.distanceMeters
            existing.updatedAt = clock.now
        } else {
            modelContext.insert(
                RouteBaseline(
                    routeKey: routeKey,
                    freeFlowSeconds: estimate.seconds,
                    distanceMeters: estimate.distanceMeters,
                    updatedAt: clock.now
                )
            )
        }
        save()
    }

    private func nextQuietDeparture(after now: Date) -> Date? {
        var components = DateComponents()
        components.weekday = 1 // Sunday
        components.hour = 3
        components.minute = 30
        return calendar.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime
        )
    }

    // MARK: - Logging & saving

    private func log(
        plan: AlarmPlan,
        phase: SchedulePhase,
        outcome: CheckOutcome,
        trigger: CheckTrigger,
        detail: String,
        now: Date,
        travelSeconds: Double? = nil,
        condition: TrafficCondition = .unknown,
        estimateSource: TravelEstimateSource = .predictive,
        errorText: String? = nil,
        anomalous: Bool = false
    ) {
        let entry = CheckLog(
            timestamp: now,
            targetDayStart: plan.targetDayStart,
            phase: phase,
            outcome: outcome,
            trigger: trigger,
            detail: detail,
            travelSeconds: travelSeconds,
            wakeDate: plan.wakeDate,
            leaveByDate: plan.leaveByDate,
            condition: condition,
            estimateSource: estimateSource,
            errorText: errorText,
            wasAnomalous: anomalous
        )
        modelContext.insert(entry)
        save()
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            AppLogger.planner.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
        publishSnapshot()
    }

    // MARK: - Widget

    private var lastPublishedSnapshot: WakePlanSnapshot?

    /// Hands the widget a flattened copy of the plan.
    ///
    /// Only reloads timelines when something actually changed — `save()` runs several times
    /// per check, and asking WidgetKit to redraw on each one wastes the reload budget iOS
    /// gives the app.
    private func publishSnapshot() {
        guard SharedStore.isAvailable else { return }

        let snapshot: WakePlanSnapshot? = currentPlan.map { plan in
            WakePlanSnapshot(
                wakeDate: plan.wakeDate,
                leaveByDate: plan.leaveByDate,
                arrivalDeadline: plan.arrivalDeadline,
                driveMinutes: plan.lastGoodTravelMinutes ?? 0,
                condition: plan.lastCondition,
                destinationLabel: plan.destinationLabel,
                phaseLabel: currentPhase.label,
                phaseSymbolName: currentPhase.symbolName,
                isArmed: plan.hasComputedWake && currentPhase != .disabled,
                updatedAt: plan.lastSuccessfulCheckAt ?? plan.updatedAt
            )
        }

        guard snapshot != lastPublishedSnapshot else { return }
        lastPublishedSnapshot = snapshot
        SharedStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
