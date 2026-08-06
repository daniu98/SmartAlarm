import Foundation
import SwiftData

/// One morning's plan. `targetDayStart` is unique, so re-running the planner updates the
/// existing plan rather than accumulating duplicates — the same principle as reusing the
/// AlarmKit identifier.
@Model
final class AlarmPlan {
    @Attribute(.unique) var targetDayStart: Date

    /// Stable AlarmKit identifier. Rescheduling reuses it so the system alarm is *updated*
    /// in place instead of stacking a second alarm.
    var alarmIdentifier: UUID
    /// Second system alarm at leave-by. Separate identifier so both can exist at once.
    var leaveAlarmIdentifier: UUID = UUID()
    var isLeaveAlarmScheduled: Bool = false

    var arrivalDeadline: Date
    var arrivalSourceRaw: String
    var eventTitle: String?

    var destinationLatitude: Double
    var destinationLongitude: Double
    var destinationLabel: String
    var destinationFromCalendar: Bool = false

    var importanceRaw: String
    var extraBufferMinutes: Int = 0

    var leaveByDate: Date
    var wakeDate: Date
    /// Worst-case wake time for these settings; drives when watching begins.
    var earliestPossibleWake: Date

    // Last successful observation. Retained verbatim so a failed check can fall back to it
    // rather than silently reverting to a default.
    var lastGoodTravelSeconds: Double?
    /// The unpadded provider answer, so a settings change can re-derive the padding offline.
    var lastRawTravelSeconds: Double?
    var lastConditionRaw: String
    var lastEstimateSourceRaw: String
    var lastSuccessfulCheckAt: Date?
    var lastCheckAt: Date?
    var consecutiveFailureCount: Int = 0

    // A large later-move parked until a second check agrees with it.
    var pendingLaterWakeDate: Date?
    var pendingLaterTravelSeconds: Double?
    var pendingLaterProposedAt: Date?

    /// Set by the user on the Today screen. Freezes the plan against automatic adjustment.
    var manualOverrideWake: Date?

    /// Whether AlarmKit has accepted this plan. Distinct from `hasComputedWake` on purpose.
    var isAlarmScheduled: Bool = false
    /// Whether a successful solve has ever produced `wakeDate`.
    ///
    /// The adjustment policy keys off *this*, not off `isAlarmScheduled`. If it used the
    /// latter, an AlarmKit refusal — denied permission, a transient error — would make every
    /// subsequent check look like a first-time schedule and silently bypass the lock window,
    /// letting a later-move through at exactly the moment it's most dangerous.
    var hasComputedWake: Bool = false
    var isDismissed: Bool = false
    /// One historical observation per morning, taken close to departure.
    var hasRecordedSample: Bool = false

    /// The user's own verdict on how the morning went. The only ground truth this app gets
    /// without tracking location, and what `PostureAdvisor` calibrates against.
    var outcomeRaw: String?
    var outcomeRecordedAt: Date?

    /// Forecast conditions for the drive, kept for display and for the History log.
    var weatherRaw: String = DrivingWeather.clear.rawValue
    /// Cached so the forecast isn't refetched on every check. WeatherKit is the app's only
    /// metered dependency, and the forecast for a 7:57 AM departure does not change every
    /// fifteen minutes.
    var weatherPadFraction: Double = 0
    var weatherFetchedAt: Date?
    var routeAdvisories: [String] = []
    var routeName: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        targetDayStart: Date,
        arrivalDeadline: Date,
        arrivalSource: ArrivalSource,
        destination: Coordinate,
        destinationLabel: String,
        destinationFromCalendar: Bool,
        importance: ImportanceLevel,
        extraBufferMinutes: Int,
        leaveByDate: Date,
        wakeDate: Date,
        earliestPossibleWake: Date,
        eventTitle: String? = nil,
        alarmIdentifier: UUID = UUID()
    ) {
        self.targetDayStart = targetDayStart
        self.alarmIdentifier = alarmIdentifier
        self.arrivalDeadline = arrivalDeadline
        arrivalSourceRaw = arrivalSource.rawValue
        self.eventTitle = eventTitle
        destinationLatitude = destination.latitude
        destinationLongitude = destination.longitude
        self.destinationLabel = destinationLabel
        self.destinationFromCalendar = destinationFromCalendar
        importanceRaw = importance.rawValue
        self.extraBufferMinutes = extraBufferMinutes
        self.leaveByDate = leaveByDate
        self.wakeDate = wakeDate
        self.earliestPossibleWake = earliestPossibleWake
        lastConditionRaw = TrafficCondition.unknown.rawValue
        lastEstimateSourceRaw = TravelEstimateSource.predictive.rawValue
        consecutiveFailureCount = 0
        isAlarmScheduled = false
        hasComputedWake = false
        isDismissed = false
        hasRecordedSample = false
        createdAt = .now
        updatedAt = .now
    }
}

extension AlarmPlan {
    var destination: Coordinate {
        Coordinate(latitude: destinationLatitude, longitude: destinationLongitude)
    }

    var arrivalSource: ArrivalSource {
        ArrivalSource(rawValue: arrivalSourceRaw) ?? .settings
    }

    var importance: ImportanceLevel {
        ImportanceLevel(rawValue: importanceRaw) ?? .normal
    }

    var lastCondition: TrafficCondition {
        get { TrafficCondition(rawValue: lastConditionRaw) ?? .unknown }
        set { lastConditionRaw = newValue.rawValue }
    }

    var lastEstimateSource: TravelEstimateSource {
        get { TravelEstimateSource(rawValue: lastEstimateSourceRaw) ?? .predictive }
        set { lastEstimateSourceRaw = newValue.rawValue }
    }

    var pendingLaterProposal: PendingLaterProposal? {
        get {
            guard let pendingLaterWakeDate,
                  let pendingLaterTravelSeconds,
                  let pendingLaterProposedAt
            else { return nil }
            return PendingLaterProposal(
                wakeDate: pendingLaterWakeDate,
                travelSeconds: pendingLaterTravelSeconds,
                proposedAt: pendingLaterProposedAt
            )
        }
        set {
            pendingLaterWakeDate = newValue?.wakeDate
            pendingLaterTravelSeconds = newValue?.travelSeconds
            pendingLaterProposedAt = newValue?.proposedAt
        }
    }

    var phaseWindow: PhaseWindow {
        PhaseWindow(
            earliestPossibleWake: earliestPossibleWake,
            scheduledWake: wakeDate,
            leaveBy: leaveByDate
        )
    }

    /// A snooze that would carry you past leave-by is worse than useless, so it's capped by
    /// whatever slack is actually left. Recomputed on every reschedule as the gap narrows.
    func effectiveSnoozeMinutes(preferred: Int) -> Int {
        let slackMinutes = Int(leaveByDate.timeIntervalSince(wakeDate) / 60)
        // Leave at least five minutes between the last snooze and walking out the door.
        return max(1, min(preferred, slackMinutes - 5))
    }

    var isManuallyOverridden: Bool { manualOverrideWake != nil }

    var lastGoodTravelMinutes: Int? {
        lastGoodTravelSeconds.map { Int(($0 / 60).rounded()) }
    }

    var outcome: MorningOutcome? {
        get { outcomeRaw.flatMap(MorningOutcome.init(rawValue:)) }
        set {
            outcomeRaw = newValue?.rawValue
            outcomeRecordedAt = newValue == nil ? nil : .now
        }
    }

    var weather: DrivingWeather {
        get { DrivingWeather(rawValue: weatherRaw) ?? .clear }
        set { weatherRaw = newValue.rawValue }
    }

    func alarmMetadata() -> WakeAlarmMetadata {
        WakeAlarmMetadata(
            leaveByDate: leaveByDate,
            arrivalDeadline: arrivalDeadline,
            driveMinutes: lastGoodTravelMinutes ?? 0,
            condition: lastCondition,
            destinationLabel: destinationLabel
        )
    }
}
