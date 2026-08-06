import Foundation
import SwiftData

/// What triggered a check. Useful when diagnosing "why didn't it update overnight?" —
/// a morning with no `.background` entries means iOS never ran the refresh task.
enum CheckTrigger: String, Codable, Sendable, CaseIterable {
    case nightly
    case background
    case foreground
    case manual

    var label: String {
        switch self {
        case .nightly: "Nightly"
        case .background: "Background"
        case .foreground: "App opened"
        case .manual: "Manual"
        }
    }
}

enum CheckOutcome: String, Codable, Sendable, CaseIterable {
    case scheduled
    case movedEarlier
    case movedLater
    case held
    case rejectedLocked
    case rejectedImplausible
    case noChange
    case failed

    var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .movedEarlier: "Moved earlier"
        case .movedLater: "Moved later"
        case .held: "Held"
        case .rejectedLocked: "Rejected (locked)"
        case .rejectedImplausible: "Rejected (implausible)"
        case .noChange: "No change"
        case .failed: "Check failed"
        }
    }

    var symbolName: String {
        switch self {
        case .scheduled: "alarm"
        case .movedEarlier: "arrow.up.circle.fill"
        case .movedLater: "arrow.down.circle.fill"
        case .held: "pause.circle"
        case .rejectedLocked: "lock.fill"
        case .rejectedImplausible: "exclamationmark.triangle"
        case .noChange: "equal.circle"
        case .failed: "wifi.exclamationmark"
        }
    }

    var isFailure: Bool {
        self == .failed || self == .rejectedImplausible
    }
}

/// One row per check, successful or not. This is both the History screen's data source and
/// the first place to look when the alarm does something surprising.
@Model
final class CheckLog {
    var timestamp: Date
    var targetDayStart: Date
    var phaseRaw: String
    var outcomeRaw: String
    var triggerRaw: String
    var detail: String

    var travelSeconds: Double?
    var wakeDate: Date?
    var leaveByDate: Date?
    var conditionRaw: String
    var estimateSourceRaw: String
    var errorText: String?
    /// True when the estimate blew past this route's historical p90.
    var wasAnomalous: Bool = false

    init(
        timestamp: Date = .now,
        targetDayStart: Date,
        phase: SchedulePhase,
        outcome: CheckOutcome,
        trigger: CheckTrigger,
        detail: String,
        travelSeconds: Double? = nil,
        wakeDate: Date? = nil,
        leaveByDate: Date? = nil,
        condition: TrafficCondition = .unknown,
        estimateSource: TravelEstimateSource = .predictive,
        errorText: String? = nil,
        wasAnomalous: Bool = false
    ) {
        self.timestamp = timestamp
        self.targetDayStart = targetDayStart
        phaseRaw = phase.rawValue
        outcomeRaw = outcome.rawValue
        triggerRaw = trigger.rawValue
        self.detail = detail
        self.travelSeconds = travelSeconds
        self.wakeDate = wakeDate
        self.leaveByDate = leaveByDate
        conditionRaw = condition.rawValue
        estimateSourceRaw = estimateSource.rawValue
        self.errorText = errorText
        self.wasAnomalous = wasAnomalous
    }
}

extension CheckLog {
    var phase: SchedulePhase { SchedulePhase(rawValue: phaseRaw) ?? .idle }
    var outcome: CheckOutcome { CheckOutcome(rawValue: outcomeRaw) ?? .noChange }
    var trigger: CheckTrigger { CheckTrigger(rawValue: triggerRaw) ?? .background }
    var condition: TrafficCondition { TrafficCondition(rawValue: conditionRaw) ?? .unknown }
    var estimateSource: TravelEstimateSource {
        TravelEstimateSource(rawValue: estimateSourceRaw) ?? .predictive
    }

    var travelMinutes: Int? {
        travelSeconds.map { Int(($0 / 60).rounded()) }
    }
}
