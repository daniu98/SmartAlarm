import BackgroundTasks
import Foundation

/// Drives the two background tasks.
///
/// `BGAppRefreshTask` is best-effort — iOS decides if and when it runs, and it may not run at
/// all. The design never depends on it: the nightly bootstrap schedules a *safe* alarm before
/// you go to sleep, and refreshes only sharpen it. If every background wakeup is skipped, the
/// alarm still fires at a conservative time. That is why the padding is front-loaded and why
/// later-moves are gated rather than eagerly applied.
@MainActor
final class BackgroundRefreshController {
    static let refreshTaskIdentifier = "com.danielxiao.SmartAlarm.refresh"
    static let nightlyTaskIdentifier = "com.danielxiao.SmartAlarm.nightly"

    private let planner: WakePlanner
    private let clock: DateProvider
    private let calendar: Calendar

    /// Recomputes tomorrow's plan at this hour, local time.
    private let nightlyHour = 22

    init(planner: WakePlanner, clock: DateProvider, calendar: Calendar = .current) {
        self.planner = planner
        self.clock = clock
        self.calendar = calendar
    }

    /// Must run before the app finishes launching, or BGTaskScheduler throws.
    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self?.handle(refreshTask: refreshTask)
            }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.nightlyTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self?.handle(nightlyTask: processingTask)
            }
        }
    }

    // MARK: - Handlers

    private func handle(refreshTask: BGAppRefreshTask) {
        // Chain the next request before doing any work: if this handler is killed, the loop
        // still continues tomorrow rather than dying silently.
        scheduleNextRefresh()

        let work = Task { @MainActor in
            await planner.refresh(trigger: .background)
            refreshTask.setTaskCompleted(success: true)
        }

        refreshTask.expirationHandler = {
            work.cancel()
            refreshTask.setTaskCompleted(success: false)
            AppLogger.background.notice("Refresh task expired before finishing")
        }
    }

    private func handle(nightlyTask: BGProcessingTask) {
        scheduleNightly()

        let work = Task { @MainActor in
            await planner.refreshRouteBaselineIfNeeded()
            await planner.refresh(trigger: .nightly)
            scheduleNextRefresh()
            nightlyTask.setTaskCompleted(success: true)
        }

        nightlyTask.expirationHandler = {
            work.cancel()
            nightlyTask.setTaskCompleted(success: false)
            AppLogger.background.notice("Nightly task expired before finishing")
        }
    }

    // MARK: - Submission

    /// Asks for the next refresh at the time the phase machine says one is due. iOS treats
    /// this as a hint, not a promise.
    func scheduleNextRefresh() {
        let settings = planner.settings()
        let window = planner.currentPlan?.phaseWindow
        let next = settings.phaseCalculator.nextCheckDate(
            now: clock.now,
            window: window,
            isEnabled: settings.isEnabled,
            refreshIntervalMinutes: settings.refreshIntervalMinutes
        )

        guard settings.isEnabled, let next else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = max(next, clock.now.addingTimeInterval(60))
        submit(request)
    }

    func scheduleNightly() {
        let request = BGProcessingTaskRequest(identifier: Self.nightlyTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = nextNightlyDate()
        submit(request)
    }

    private func nextNightlyDate() -> Date {
        var components = DateComponents()
        components.hour = nightlyHour
        components.minute = 0
        return calendar.nextDate(
            after: clock.now,
            matching: components,
            matchingPolicy: .nextTime
        ) ?? clock.now.addingTimeInterval(3600)
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.background.info(
                "Submitted \(request.identifier, privacy: .public) for \(request.earliestBeginDate?.description ?? "asap", privacy: .public)"
            )
        } catch {
            // Simulators reject BG submissions outright; that is expected and not worth
            // surfacing to the user.
            AppLogger.background.notice(
                "Could not submit \(request.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Called whenever the app goes to the background, so the schedule reflects the newest plan.
    func applicationDidEnterBackground() {
        scheduleNextRefresh()
        scheduleNightly()
    }
}
