#if DEBUG
import Foundation
import SwiftData

/// Fills in a plausible commute without going through the Setup screen.
///
/// Reachable two ways: the button on the Debug tab, or `-seedDemoRoute` as a launch argument
/// (`xcrun simctl launch <device> com.danielxiao.SmartAlarm -seedDemoRoute`), which is how the
/// screens get exercised with real data in an automated run.
enum DebugSeed {
    static let launchArgument = "-seedDemoRoute"

    /// San Francisco → Palo Alto: a real commute, long enough that traffic actually matters.
    static let home = Coordinate(latitude: 37.7936, longitude: -122.3965)
    static let work = Coordinate(latitude: 37.4419, longitude: -122.1430)

    /// iOS folds `-key value` launch arguments into `UserDefaults`, which is more reliable
    /// than parsing `CommandLine.arguments` by hand.
    /// `xcrun simctl launch <device> com.danielxiao.SmartAlarm -seedDemoRoute YES`
    static var isRequestedAtLaunch: Bool {
        UserDefaults.standard.bool(forKey: "seedDemoRoute")
            || CommandLine.arguments.contains(launchArgument)
    }

    /// `-startTab setup|history|debug` opens straight to that tab, so a screen can be
    /// exercised from the command line without driving the UI.
    /// `-showPaywall YES` opens the upgrade sheet on launch.
    static var showsPaywallAtLaunch: Bool {
        UserDefaults.standard.bool(forKey: "showPaywall")
    }

    static var initialTab: String {
        UserDefaults.standard.string(forKey: "startTab")?.lowercased() ?? "today"
    }

    @MainActor
    static func apply(to settings: UserSettings, context: ModelContext) {
        settings.homeAddress = "1 Market St, San Francisco, CA"
        settings.workAddress = "1 Hacker Way, Palo Alto, CA"
        settings.setHomeCoordinate(home)
        settings.setWorkCoordinate(work)
        settings.defaultArrivalMinuteOfDay = 9 * 60
        settings.isEnabled = true
        settings.updatedAt = .now
        try? context.save()
    }
}
#endif
