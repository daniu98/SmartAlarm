#if DEBUG
import Foundation
import SwiftData

/// Puts the app into a realistic, photogenic state for App Store screenshots.
///
/// Store screenshots have to depict the app as it looks in ordinary use. A simulator can't
/// grant AlarmKit permission — `simctl privacy` has no alarm service — so without this every
/// screenshot carries a "permission needed" banner and an empty history that a real user on a
/// real phone would never see. Everything seeded here is behaviour the app genuinely produces;
/// it's staged, not invented.
enum ScreenshotMode {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "screenshotMode")
    }

    /// A week of plausible mornings, so the confidence row reads "learned from N mornings"
    /// rather than the cold-start message.
    @MainActor
    static func seed(context: ModelContext, home: Coordinate, work: Coordinate, calendar: Calendar = .current) {
        let routeKey = Coordinate.routeKey(from: home, to: work)

        guard (try? context.fetch(FetchDescriptor<TravelSample>()))?.isEmpty ?? true else { return }

        // Real commute shape: mostly consistent, with a fat tail on a couple of mornings.
        let minutes: [Double] = [48, 51, 53, 49, 55, 62, 50, 52, 47, 58, 54, 51]
        for (index, value) in minutes.enumerated() {
            context.insert(
                TravelSample(
                    routeKey: routeKey,
                    weekday: 2 + (index % 5),
                    minuteOfDay: 7 * 60 + 45 + (index % 3) * 5,
                    seconds: value * 60,
                    recordedAt: .now.addingTimeInterval(-Double(index + 1) * 86_400)
                )
            )
        }

        // A morning's worth of checks, showing the behaviour the History screen exists to
        // explain — including an improvement that was refused because it arrived too late.
        let dayStart = calendar.startOfDay(for: .now)
        let wake = dayStart.addingTimeInterval(7 * 3600 + 27 * 60)
        let leave = dayStart.addingTimeInterval(7 * 3600 + 57 * 60)

        struct Entry {
            let minutesBefore: Double
            let phase: SchedulePhase
            let outcome: CheckOutcome
            let detail: String
            let travel: Double
            let condition: TrafficCondition
        }

        let entries: [Entry] = [
            .init(minutesBefore: 560, phase: .idle, outcome: .scheduled,
                  detail: "Alarm scheduled", travel: 51, condition: .moderate),
            .init(minutesBefore: 180, phase: .watching, outcome: .noChange,
                  detail: "No change", travel: 51, condition: .moderate),
            .init(minutesBefore: 150, phase: .watching, outcome: .movedEarlier,
                  detail: "Moved earlier to 7:19 AM", travel: 59, condition: .heavy),
            .init(minutesBefore: 120, phase: .watching, outcome: .movedLater,
                  detail: "Moved later to 7:27 AM", travel: 51, condition: .moderate),
            .init(minutesBefore: 75, phase: .watching, outcome: .noChange,
                  detail: "No change", travel: 52, condition: .moderate),
            .init(minutesBefore: 40, phase: .locked, outcome: .rejectedLocked,
                  detail: "Ignored later move to 7:36 AM — inside lock window",
                  travel: 44, condition: .light),
            .init(minutesBefore: 25, phase: .locked, outcome: .failed,
                  detail: "Kept last known-good wake time of 7:27 AM",
                  travel: 51, condition: .moderate),
            .init(minutesBefore: 10, phase: .locked, outcome: .movedEarlier,
                  detail: "Moved earlier to 7:23 AM", travel: 56, condition: .heavy),
        ]

        for entry in entries {
            let log = CheckLog(
                timestamp: wake.addingTimeInterval(-entry.minutesBefore * 60),
                targetDayStart: dayStart,
                phase: entry.phase,
                outcome: entry.outcome,
                trigger: entry.phase == .idle ? .nightly : .background,
                detail: entry.detail,
                travelSeconds: entry.travel * 60,
                wakeDate: wake,
                leaveByDate: leave,
                condition: entry.condition,
                estimateSource: entry.outcome == .failed ? .lastKnownGood : .nearRealtime,
                errorText: entry.outcome == .failed ? "The Internet connection appears to be offline." : nil
            )
            context.insert(log)
        }

        try? context.save()
    }
}

/// Reports authorised and keeps its alarms in memory.
///
/// Only ever used under `-screenshotMode`. The simulator cannot grant AlarmKit permission, and
/// a permission banner in a store screenshot would misrepresent the app on a real device.
struct ScreenshotAlarmScheduler: AlarmScheduling {
    var authorization: AlarmAuthorization { .authorized }
    func requestAuthorization() async throws -> AlarmAuthorization { .authorized }
    func schedule(id: UUID, at date: Date, kind: AlarmKind, metadata: WakeAlarmMetadata, snoozeMinutes: Int) async throws {}
    func cancel(id: UUID) throws {}
    func stop(id: UUID) throws {}
    func scheduledAlarmIdentifiers() -> [UUID] { [] }
}
#endif
