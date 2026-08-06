import Foundation
import SwiftData

/// Wires the app together. The one place that names concrete implementations, so swapping
/// MapKit for Google Directions is a one-line change here.
@MainActor
@Observable
final class AppEnvironment {
    let modelContainer: ModelContainer
    let clock: DateProvider
    let planner: WakePlanner
    let background: BackgroundRefreshController
    let geocoder: any GeocodingProviding
    let alarms: any AlarmScheduling
    let calendarProvider: any CalendarProviding
    let entitlements: EntitlementStore

    private(set) var alarmAuthorization: AlarmAuthorization = .notDetermined
    /// True when the on-disk store could not be opened and the app is running on a temporary
    /// one. Surfaced in the UI, because settings silently vanishing needs explaining.
    private(set) var isRunningOnFallbackStore = false

    static let schema = Schema([
        UserSettings.self,
        AlarmPlan.self,
        CheckLog.self,
        TravelSample.self,
        RouteBaseline.self,
    ])

    /// Pinned explicitly, and deliberately *not* left to SwiftData's default.
    ///
    /// `NSPersistentContainer.defaultDirectoryURL()` prefers an App Group container when the
    /// app has one. Adding the App Groups entitlement for the widget silently relocated the
    /// store — harmless before launch, but on a shipped app any later change to that
    /// entitlement (added, removed, or failing to provision) would move the store and every
    /// user's settings and history would appear to vanish. Naming the path removes that
    /// coupling entirely: the store lives in the app's own container regardless of
    /// entitlements, and the widget reads a snapshot rather than the database.
    static func storeURL() -> URL {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "SmartAlarm.store")
    }

    init(inMemory: Bool = false) {
        let schema = Self.schema
        var fallback = false

        // An alarm app that refuses to launch is worse than one that launches having lost its
        // settings: the first can never ring, the second can be fixed in a minute. So a store
        // that won't open or migrate degrades to in-memory instead of trapping.
        func makeContainer() -> ModelContainer {
            do {
                let configuration = inMemory
                    ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    : ModelConfiguration(schema: schema, url: Self.storeURL())
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                AppLogger.planner.fault(
                    "Persistent store unavailable (\(error.localizedDescription, privacy: .public)); falling back to in-memory."
                )
                fallback = true
                // If even this fails the process genuinely cannot run.
                return try! ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            }
        }

        modelContainer = makeContainer()
        isRunningOnFallbackStore = fallback

        let clock = DateProvider()
        let calendarProvider = EventKitCalendarProvider()

        #if DEBUG
        // Screenshots only: a simulator can't grant AlarmKit permission, and a permission
        // banner in a store screenshot would misrepresent the app on a real device.
        let alarms: any AlarmScheduling = ScreenshotMode.isEnabled
            ? ScreenshotAlarmScheduler()
            : AlarmKitScheduler()
        #else
        let alarms: any AlarmScheduling = AlarmKitScheduler()
        #endif

        self.clock = clock
        self.alarms = alarms
        self.calendarProvider = calendarProvider
        geocoder = MapKitGeocoder()
        entitlements = EntitlementStore(purchases: StoreKitPurchaseProvider())

        planner = WakePlanner(
            modelContext: modelContainer.mainContext,
            traffic: MapKitTrafficProvider(),
            alarms: alarms,
            calendarProvider: calendarProvider,
            weather: WeatherKitProvider(),
            clock: clock
        )
        background = BackgroundRefreshController(planner: planner, clock: clock)

        alarmAuthorization = alarms.authorization
        planner.isPro = entitlements.isPro
    }

    /// The planner only sees a live calendar when the user has switched the feature on *and*
    /// owns Pro. Enforced here rather than in the UI, so a stale toggle can't leak the feature.
    func syncEntitlementGatedFeatures() {
        let settings = planner.settings()
        planner.isPro = entitlements.isPro
        planner.calendarProvider = (settings.calendarEnabled && entitlements.isPro)
            ? calendarProvider
            : DisabledCalendarProvider()
    }

    func refreshAlarmAuthorization() {
        alarmAuthorization = alarms.authorization
    }

    @discardableResult
    func requestAlarmAuthorization() async -> AlarmAuthorization {
        let result = (try? await alarms.requestAuthorization()) ?? .denied
        alarmAuthorization = result
        return result
    }

    private var lastForegroundRefreshAt: Date?
    /// Launch delivers "became active" through both `.task` and the scene-phase change.
    /// Without this, every launch burns two MapKit round trips and writes two identical
    /// History rows.
    private let foregroundDebounce: TimeInterval = 5

    /// Called on launch and on every return to the foreground.
    func handleForeground() async {
        if let lastForegroundRefreshAt,
           Date.now.timeIntervalSince(lastForegroundRefreshAt) < foregroundDebounce {
            return
        }
        lastForegroundRefreshAt = .now
        await performForegroundRefresh()
    }

    private func performForegroundRefresh() async {
        #if DEBUG
        if DebugSeed.isRequestedAtLaunch || ScreenshotMode.isEnabled {
            DebugSeed.apply(to: planner.settings(), context: modelContainer.mainContext)
        }
        if ScreenshotMode.isEnabled {
            ScreenshotMode.seed(
                context: modelContainer.mainContext,
                home: DebugSeed.home,
                work: DebugSeed.work
            )
        }
        #endif
        refreshAlarmAuthorization()
        await entitlements.refresh()
        syncEntitlementGatedFeatures()
        // Without this the free-flow baseline is only ever captured by the 22:00 nightly task,
        // which means a fresh install reports "Traffic unknown" indefinitely — there is nothing
        // to compare a live ETA against. It self-cancels once a baseline under 30 days old
        // exists, so this costs one extra request on first run and nothing thereafter.
        await planner.refreshRouteBaselineIfNeeded()
        await planner.refresh(trigger: .foreground)
        background.scheduleNextRefresh()
        background.scheduleNightly()
    }

    /// Catches purchases made on another device, and Ask-to-Buy approvals.
    func observeEntitlements() async {
        await entitlements.observeUpdates()
    }

    /// Re-applies the gates and recomputes after an upgrade, so Pro features take effect
    /// immediately rather than at the next background check.
    func applyEntitlementChange() async {
        syncEntitlementGatedFeatures()
        await planner.refresh(trigger: .manual)
    }

    /// Keeps app state in step with actions taken from the Lock Screen or Dynamic Island,
    /// which happen entirely outside the app's process.
    func observeAlarmUpdates() async {
        for await _ in AlarmKitScheduler.alarmUpdates() {
            refreshAlarmAuthorization()
            await planner.refresh(trigger: .foreground)
        }
    }
}
