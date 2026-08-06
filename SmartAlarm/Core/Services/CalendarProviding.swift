import EventKit
import Foundation

enum CalendarAuthorization: String, Sendable {
    case notDetermined
    case denied
    case authorized

    var isAuthorized: Bool { self == .authorized }
}

protocol CalendarProviding: Sendable {
    var eventAuthorization: CalendarAuthorization { get }
    var reminderAuthorization: CalendarAuthorization { get }
    func requestEventAccess() async -> CalendarAuthorization
    func requestReminderAccess() async -> CalendarAuthorization
    func commitments(in interval: DateInterval) async -> [CommitmentCandidate]
    func highPriorityReminderTitles(in interval: DateInterval) async -> [String]
}

/// EventKit-backed calendar reads.
///
/// Deliberately total rather than throwing: a calendar the app can't read is a calendar that
/// contributes nothing, which leaves the alarm on the user's configured arrival time. Since
/// calendar data can only ever pull the alarm *earlier*, failing to read it is safe by
/// construction — it can never cause an overslept morning.
struct EventKitCalendarProvider: CalendarProviding {
    /// `EKEventStore` is not thread-safe and not `Sendable`, so it is never stored — each call
    /// makes its own and lets it go. Authorization is a class-level query and needs no store
    /// at all. Calendar reads happen a handful of times per morning, so the allocation is
    /// irrelevant next to getting the concurrency right.
    private func makeStore() -> EKEventStore { EKEventStore() }

    var eventAuthorization: CalendarAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .event))
    }

    var reminderAuthorization: CalendarAuthorization {
        Self.map(EKEventStore.authorizationStatus(for: .reminder))
    }

    private static func map(_ status: EKAuthorizationStatus) -> CalendarAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .fullAccess: .authorized
        case .writeOnly, .restricted, .denied: .denied
        @unknown default: .notDetermined
        }
    }

    func requestEventAccess() async -> CalendarAuthorization {
        do {
            let granted = try await makeStore().requestFullAccessToEvents()
            return granted ? .authorized : .denied
        } catch {
            AppLogger.calendar.error("Calendar access request failed: \(error.localizedDescription)")
            return .denied
        }
    }

    func requestReminderAccess() async -> CalendarAuthorization {
        do {
            let granted = try await makeStore().requestFullAccessToReminders()
            return granted ? .authorized : .denied
        } catch {
            AppLogger.calendar.error("Reminder access request failed: \(error.localizedDescription)")
            return .denied
        }
    }

    func commitments(in interval: DateInterval) async -> [CommitmentCandidate] {
        guard eventAuthorization.isAuthorized else { return [] }

        let store = makeStore()
        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: nil
        )

        return store.events(matching: predicate).map { event in
            let attendees = event.attendees ?? []
            let selfAttendee = attendees.first { $0.isCurrentUser }

            return CommitmentCandidate(
                title: event.title ?? "Untitled event",
                start: event.startDate,
                isAllDay: event.isAllDay,
                // `.notSupported` means the calendar doesn't express availability. Treating
                // it as busy keeps the app conservative.
                isBusy: event.availability != .free,
                isDeclinedBySelf: selfAttendee?.participantStatus == .declined,
                attendeeCount: attendees.count,
                organizerIsSelf: event.organizer?.isCurrentUser ?? true,
                location: event.structuredLocation?.geoLocation.map { Coordinate($0.coordinate) },
                locationText: event.structuredLocation?.title ?? event.location,
                notes: event.notes
            )
        }
    }

    func highPriorityReminderTitles(in interval: DateInterval) async -> [String] {
        guard reminderAuthorization.isAuthorized else { return [] }

        let store = makeStore()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: interval.start,
            ending: interval.end,
            calendars: nil
        )

        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        // EKReminder priority: 0 means unset, 1–4 is "high" in the RFC 5545 scheme.
        return reminders
            .filter { (1...4).contains($0.priority) }
            .compactMap(\.title)
    }
}

/// Used when the calendar feature is switched off, so the planner has no conditional paths.
struct DisabledCalendarProvider: CalendarProviding {
    var eventAuthorization: CalendarAuthorization { .notDetermined }
    var reminderAuthorization: CalendarAuthorization { .notDetermined }
    func requestEventAccess() async -> CalendarAuthorization { .denied }
    func requestReminderAccess() async -> CalendarAuthorization { .denied }
    func commitments(in interval: DateInterval) async -> [CommitmentCandidate] { [] }
    func highPriorityReminderTitles(in interval: DateInterval) async -> [String] { [] }
}
