import Foundation

/// A flattened copy of the current plan, small enough to hand to the widget.
///
/// The widget extension runs in its own process with its own container, so it can't read the
/// app's SwiftData store. Rather than share the whole database through an App Group — and take
/// on schema-migration coordination between two processes — the app writes this snapshot
/// whenever the plan changes and the widget only ever reads it.
struct WakePlanSnapshot: Codable, Sendable, Hashable {
    var wakeDate: Date
    var leaveByDate: Date
    var arrivalDeadline: Date
    var driveMinutes: Int
    var condition: TrafficCondition
    var destinationLabel: String
    var phaseLabel: String
    var phaseSymbolName: String
    var isArmed: Bool
    var updatedAt: Date

    /// Shown when nothing has been written yet, so the widget always has something sensible.
    static let placeholder = WakePlanSnapshot(
        wakeDate: .now.addingTimeInterval(8 * 3600),
        leaveByDate: .now.addingTimeInterval(8.5 * 3600),
        arrivalDeadline: .now.addingTimeInterval(9.5 * 3600),
        driveMinutes: 42,
        condition: .moderate,
        destinationLabel: "Work",
        phaseLabel: "Idle",
        phaseSymbolName: "clock",
        isArmed: true,
        updatedAt: .now
    )

    /// A snapshot older than this is stale enough that the drive estimate shouldn't be trusted
    /// on the home screen.
    static let freshnessWindow: TimeInterval = 12 * 60 * 60

    func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.freshnessWindow
    }

    /// The regular beat the widget falls back to when nothing more interesting is coming up.
    static let reloadInterval: TimeInterval = 60 * 60
    /// Never ask WidgetKit to come back sooner than this.
    static let minimumReloadInterval: TimeInterval = 60

    /// When the widget should ask for a fresh timeline.
    ///
    /// WidgetKit allows a limited number of reloads per day and throttles a widget that asks
    /// for more, which leaves it showing times from hours ago. So the next reload lands at
    /// the wake time itself — the one moment the displayed time stops being true — or on the
    /// hourly beat, whichever comes first.
    ///
    /// A wake time that has *already* passed is deliberately not a reason to reload sooner.
    /// The morning is over, the next one can only be computed by the app, and clamping a past
    /// date into the future would otherwise ask for a reload every single minute until the
    /// app next ran — spending the whole day's budget before breakfast.
    static func nextReload(after now: Date, wakeDate: Date?) -> Date {
        let beat = now.addingTimeInterval(reloadInterval)
        let candidate = if let wakeDate, wakeDate > now { min(wakeDate, beat) } else { beat }
        return max(candidate, now.addingTimeInterval(minimumReloadInterval))
    }
}

/// The App Group bridge between the app and its widget.
///
/// Every path degrades rather than throws: if the App Group entitlement is missing — an
/// unsigned build, a misconfigured provisioning profile — `defaults` is nil, the app quietly
/// skips writing and the widget shows its placeholder. A missing widget is a far better
/// outcome than an alarm app that crashes because of one.
enum SharedStore {
    static let appGroupID = "group.com.danielxiao.SmartAlarm"
    private static let snapshotKey = "currentPlanSnapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// False when the App Group isn't available, which is how the app knows not to bother.
    static var isAvailable: Bool { defaults != nil }

    static func save(_ snapshot: WakePlanSnapshot?) {
        guard let defaults else { return }
        guard let snapshot else {
            defaults.removeObject(forKey: snapshotKey)
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func load() -> WakePlanSnapshot? {
        guard let defaults, let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WakePlanSnapshot.self, from: data)
    }
}
