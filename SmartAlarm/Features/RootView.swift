import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection = RootView.initialTab
    @State private var showingLaunchPaywall = false

    private static var initialTab: String {
        #if DEBUG
        DebugSeed.initialTab
        #else
        "today"
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Today", systemImage: "sun.horizon", value: "today") {
                TodayView()
            }
            Tab("Setup", systemImage: "gearshape", value: "setup") {
                SetupView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: "history") {
                HistoryView()
            }
            #if DEBUG
            // Hidden under -screenshotMode: a Debug tab in a store screenshot looks like a
            // build that shipped by accident.
            if !ScreenshotMode.isEnabled {
                Tab("Debug", systemImage: "ladybug", value: "debug") {
                    DebugView()
                }
            }
            #endif
        }
        .task {
            await appEnvironment.handleForeground()
        }
        .task {
            // Long-lived: keeps the app in step with stop/snooze taps that happen on the
            // Lock Screen, outside this process entirely.
            await appEnvironment.observeAlarmUpdates()
        }
        .task {
            await appEnvironment.observeEntitlements()
        }
        .sheet(isPresented: $showingLaunchPaywall) { PaywallView() }
        .task {
            #if DEBUG
            if DebugSeed.showsPaywallAtLaunch { showingLaunchPaywall = true }
            #endif
        }
        .onChange(of: appEnvironment.entitlements.isPro) { _, _ in
            Task { await appEnvironment.applyEntitlementChange() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await appEnvironment.handleForeground() }
            case .background:
                appEnvironment.background.applicationDidEnterBackground()
            default:
                break
            }
        }
    }
}
