import Foundation

enum AdjustmentDirection: String, Codable, Sendable, Hashable {
    case earlier
    case later
}

/// A later-move that looked too good to act on immediately, parked until a second check agrees.
struct PendingLaterProposal: Sendable, Hashable, Codable {
    var wakeDate: Date
    var travelSeconds: Double
    var proposedAt: Date
}

enum AdjustmentDecision: Sendable, Equatable {
    case scheduleInitial(Date)
    case moveEarlier(to: Date)
    case moveLater(to: Date)
    /// A suspiciously large later-move, held until confirmed. Alarm stays where it is.
    case holdPendingConfirmation(PendingLaterProposal)
    /// A later-move arriving inside the lock window. Discarded.
    case rejectedLocked(proposed: Date)
    /// Movement too small to be worth rescheduling for.
    case noChange

    var appliedDate: Date? {
        switch self {
        case .scheduleInitial(let date), .moveEarlier(let date), .moveLater(let date): date
        case .holdPendingConfirmation, .rejectedLocked, .noChange: nil
        }
    }

    var direction: AdjustmentDirection? {
        switch self {
        case .moveEarlier: .earlier
        case .moveLater, .holdPendingConfirmation, .rejectedLocked: .later
        case .scheduleInitial, .noChange: nil
        }
    }

    var summary: String {
        switch self {
        case .scheduleInitial: "Alarm scheduled"
        case .moveEarlier(let date): "Moved earlier to \(Self.timeText(date))"
        case .moveLater(let date): "Moved later to \(Self.timeText(date))"
        case .holdPendingConfirmation(let pending):
            "Held \(Self.timeText(pending.wakeDate)) — waiting for a second check to agree"
        case .rejectedLocked(let proposed):
            "Ignored later move to \(Self.timeText(proposed)) — inside lock window"
        case .noChange: "No change"
        }
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Decides whether a freshly computed wake time is allowed to replace the scheduled one.
///
/// The asymmetry is the whole point. Moving the alarm earlier costs a few minutes of sleep, so
/// it applies unconditionally. Moving it later risks oversleeping, so it has to pass three
/// gates: it must be outside the lock window, it must be large enough to matter, and if it is
/// suspiciously large it must be confirmed by a second independent check.
struct AdjustmentPolicy: Sendable, Hashable {
    var lockLaterAdjustmentsInsideMinutes: Int
    /// Movements smaller than this are ignored, so the alarm doesn't churn by 30 seconds.
    var minimumMoveSeconds: TimeInterval
    /// A later-move bigger than this is only suspicious if the drive time also collapsed.
    var confirmationJumpMinutes: Int
    /// ...where "collapsed" means the estimate fell by at least this fraction.
    var confirmationDropFraction: Double
    /// How closely a second sample must agree to count as confirmation.
    var confirmationToleranceSeconds: TimeInterval

    init(
        lockLaterAdjustmentsInsideMinutes: Int,
        minimumMoveSeconds: TimeInterval = 60,
        confirmationJumpMinutes: Int = 20,
        confirmationDropFraction: Double = 0.5,
        confirmationToleranceSeconds: TimeInterval = 300
    ) {
        self.lockLaterAdjustmentsInsideMinutes = lockLaterAdjustmentsInsideMinutes
        self.minimumMoveSeconds = minimumMoveSeconds
        self.confirmationJumpMinutes = confirmationJumpMinutes
        self.confirmationDropFraction = confirmationDropFraction
        self.confirmationToleranceSeconds = confirmationToleranceSeconds
    }

    var lockWindowSeconds: TimeInterval { Double(lockLaterAdjustmentsInsideMinutes) * 60 }

    func isLocked(now: Date, currentWake: Date) -> Bool {
        now >= currentWake.addingTimeInterval(-lockWindowSeconds)
    }

    func decide(
        now: Date,
        currentWake: Date?,
        proposedWake: Date,
        previousTravelSeconds: Double?,
        proposedTravelSeconds: Double,
        pending: PendingLaterProposal?
    ) -> AdjustmentDecision {
        guard let currentWake else {
            return .scheduleInitial(proposedWake)
        }

        let delta = proposedWake.timeIntervalSince(currentWake)

        if abs(delta) < minimumMoveSeconds {
            return .noChange
        }

        // Earlier is always safe, and never needs confirming.
        if delta < 0 {
            return .moveEarlier(to: proposedWake)
        }

        if isLocked(now: now, currentWake: currentWake) {
            return .rejectedLocked(proposed: proposedWake)
        }

        let isBigMove = delta > Double(confirmationJumpMinutes) * 60
        let isBigDrop: Bool = {
            guard let previousTravelSeconds, previousTravelSeconds > 0 else { return false }
            return proposedTravelSeconds < previousTravelSeconds * (1 - confirmationDropFraction)
        }()

        if isBigMove, isBigDrop {
            if let pending,
               abs(pending.wakeDate.timeIntervalSince(proposedWake)) <= confirmationToleranceSeconds {
                return .moveLater(to: proposedWake)
            }
            return .holdPendingConfirmation(
                PendingLaterProposal(
                    wakeDate: proposedWake,
                    travelSeconds: proposedTravelSeconds,
                    proposedAt: now
                )
            )
        }

        return .moveLater(to: proposedWake)
    }
}
