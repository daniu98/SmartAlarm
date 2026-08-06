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

    init(inMemory: Bool = false) {
        let schema = Self.schema
        var fallback = false

        // An alarm app that refuses to launch is worse than one that launches having lost its
        // settings: the first can never ring, the second can be fixed in a minute. So a store
        // that won't open or migrate degrades to in-memory instead of trapping.
        func makeContainer() -> ModelContainer {
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)]
                )
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
        let alarms = AlarmKitScheduler()
        let calendarProvider = EventKitCalendarProvider()

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
        if DebugSeed.isRequestedAtLaunch {
            DebugSeed.apply(to: planner.settings(), context: modelContainer.mainContext)
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
