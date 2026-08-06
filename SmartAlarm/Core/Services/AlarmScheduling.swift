import AlarmKit
import Foundation
import SwiftUI

enum AlarmAuthorization: String, Sendable {
    case notDetermined
    case denied
    case authorized

    var isAuthorized: Bool { self == .authorized }
}

enum AlarmSchedulingError: LocalizedError {
    case notAuthorized
    case limitReached
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "SmartyAlarm needs permission to set alarms."
        case .limitReached: "Too many alarms are already scheduled."
        case .failed(let detail): "Couldn't set the alarm: \(detail)"
        }
    }
}

/// The two alarms a morning needs. The wake alarm gets you up; the leave alarm is the
/// backstop that stops "just five more minutes" from turning into a missed meeting.
enum AlarmKind: Sendable {
    case wake
    case leave
    /// A throwaway alarm a minute out, so you can hear it ring through a silenced phone
    /// before trusting it with a Tuesday.
    case test

    var title: LocalizedStringResource {
        switch self {
        case .wake: "Time to get up"
        case .leave: "Time to leave"
        case .test: "Test alarm"
        }
    }

    /// The leave alarm deliberately offers no snooze. There is nothing left to trade.
    var allowsSnooze: Bool { self == .wake }

    /// Matches the app icon's amber. Spelled out rather than named, because the attributes
    /// travel into the widget extension, which doesn't share the app's asset catalog.
    var tint: Color {
        switch self {
        case .wake, .test: Color(red: 1.0, green: 0.69, blue: 0.29)
        case .leave: Color(red: 0.93, green: 0.36, blue: 0.29)
        }
    }
}

protocol AlarmScheduling: Sendable {
    var authorization: AlarmAuthorization { get }
    func requestAuthorization() async throws -> AlarmAuthorization
    /// Schedules or updates the alarm identified by `id`.
    func schedule(
        id: UUID,
        at date: Date,
        kind: AlarmKind,
        metadata: WakeAlarmMetadata,
        snoozeMinutes: Int
    ) async throws
    func cancel(id: UUID) throws
    func stop(id: UUID) throws
    func scheduledAlarmIdentifiers() -> [UUID]
}

/// AlarmKit-backed scheduling.
///
/// The key behaviour the app depends on: `schedule(id:configuration:)` with an identifier that
/// already exists *replaces* that alarm rather than adding a second one. Every reschedule
/// therefore reuses `AlarmPlan.alarmIdentifier`, and duplicates are structurally impossible —
/// no cancel-then-add window where the user could be left with no alarm at all.
struct AlarmKitScheduler: AlarmScheduling {
    private var manager: AlarmManager { AlarmManager.shared }

    var authorization: AlarmAuthorization {
        switch manager.authorizationState {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .notDetermined
        }
    }

    func requestAuthorization() async throws -> AlarmAuthorization {
        switch try await manager.requestAuthorization() {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .notDetermined
        }
    }

    func schedule(
        id: UUID,
        at date: Date,
        kind: AlarmKind,
        metadata: WakeAlarmMetadata,
        snoozeMinutes: Int
    ) async throws {
        guard authorization.isAuthorized else { throw AlarmSchedulingError.notAuthorized }

        let alert = AlarmPresentation.Alert(
            title: kind.title,
            secondaryButton: kind.allowsSnooze
                ? AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
                : nil,
            // `.countdown` hands snoozing to the system: it re-alerts after the
            // `postAlert` duration below without the app needing to be running.
            secondaryButtonBehavior: kind.allowsSnooze ? .countdown : nil
        )

        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: metadata,
            tintColor: kind.tint
        )

        let configuration = AlarmManager.AlarmConfiguration<WakeAlarmMetadata>(
            countdownDuration: kind.allowsSnooze
                ? Alarm.CountdownDuration(preAlert: nil, postAlert: Double(snoozeMinutes) * 60)
                : nil,
            // A one-shot alarm at an exact instant. Not `.relative`, because the whole
            // point is that this time is different every morning.
            schedule: .fixed(date),
            attributes: attributes
        )

        do {
            _ = try await manager.schedule(id: id, configuration: configuration)
            AppLogger.alarm.info("Scheduled alarm \(id, privacy: .public) for \(date, privacy: .public)")
        } catch AlarmManager.AlarmError.maximumLimitReached {
            throw AlarmSchedulingError.limitReached
        } catch {
            throw AlarmSchedulingError.failed(error.localizedDescription)
        }
    }

    func cancel(id: UUID) throws {
        try manager.cancel(id: id)
        AppLogger.alarm.info("Cancelled alarm \(id, privacy: .public)")
    }

    func stop(id: UUID) throws {
        try manager.stop(id: id)
    }

    func scheduledAlarmIdentifiers() -> [UUID] {
        (try? manager.alarms.map(\.id)) ?? []
    }

    /// Fires whenever AlarmKit's alarm list changes — including when the user stops or snoozes
    /// from the Lock Screen, which happens entirely outside this process. Erased to a plain
    /// stream so callers don't have to import AlarmKit.
    static func alarmUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in AlarmManager.shared.alarmUpdates {
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
