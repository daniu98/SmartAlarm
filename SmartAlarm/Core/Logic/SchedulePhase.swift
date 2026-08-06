import Foundation

enum SchedulePhase: String, Codable, CaseIterable, Sendable, Hashable {
    /// No alarm armed at all.
    case disabled
    /// Too far out to be worth spending battery on traffic checks.
    case idle
    /// Inside the watch window. Checks run; adjustments go both directions.
    case watching
    /// Inside the final cutoff. Checks still run, but only earlier moves are applied.
    case locked
    /// Awake, not yet due to leave. Checks continue, because the drive can still get worse
    /// while you're in the shower — and the leave-by alarm needs to move with it.
    case gettingReady
    /// Past leave-by and still here.
    case overdue
    /// This morning is finished.
    case done

    var label: String {
        switch self {
        case .disabled: "Off"
        case .idle: "Idle"
        case .watching: "Watching"
        case .locked: "Locked"
        case .gettingReady: "Getting ready"
        case .overdue: "Leave now"
        case .done: "Done"
        }
    }

    var detail: String {
        switch self {
        case .disabled: "No alarm is armed."
        case .idle: "Too early to check traffic. The alarm is set from your usual times."
        case .watching: "Re-checking traffic. The alarm can still move either way."
        case .locked: "Close to wake-up. The alarm can only move earlier from here."
        case .gettingReady: "You're up. Still watching traffic until you leave."
        case .overdue: "You're past your leave-by time."
        case .done: "This morning is done."
        }
    }

    var symbolName: String {
        switch self {
        case .disabled: "moon.zzz"
        case .idle: "clock"
        case .watching: "antenna.radiowaves.left.and.right"
        case .locked: "lock.fill"
        case .gettingReady: "figure.walk"
        case .overdue: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle"
        }
    }

    var performsChecks: Bool {
        switch self {
        case .watching, .locked, .gettingReady: true
        case .disabled, .idle, .overdue, .done: false
        }
    }

    /// After the wake alarm has fired, the wake time is history. Checks keep running, but they
    /// may only move the *leave-by* time and its alarm.
    var isAfterWake: Bool {
        self == .gettingReady || self == .overdue
    }
}

struct PhaseWindow: Sendable, Hashable {
    /// The earliest wake time these settings could possibly produce (worst-case traffic).
    /// Watching starts relative to this, not to the currently scheduled time, so that a
    /// deteriorating commute is caught before it is too late to react.
    var earliestPossibleWake: Date
    var scheduledWake: Date
    var leaveBy: Date
}

/// A pure function of `(now, window, settings)`. No stored state, so the phase can never
/// drift out of sync with reality — it is recomputed rather than transitioned.
struct PhaseCalculator: Sendable, Hashable {
    var refreshWindowStartMinutes: Int
    var lockLaterAdjustmentsInsideMinutes: Int
    /// How long after leave-by the morning is still considered live.
    var overdueGraceMinutes: Int

    init(
        refreshWindowStartMinutes: Int,
        lockLaterAdjustmentsInsideMinutes: Int,
        overdueGraceMinutes: Int = 45
    ) {
        self.refreshWindowStartMinutes = refreshWindowStartMinutes
        self.lockLaterAdjustmentsInsideMinutes = lockLaterAdjustmentsInsideMinutes
        self.overdueGraceMinutes = overdueGraceMinutes
    }

    func watchStart(for window: PhaseWindow) -> Date {
        window.earliestPossibleWake.addingTimeInterval(-Double(refreshWindowStartMinutes) * 60)
    }

    func lockStart(for window: PhaseWindow) -> Date {
        window.scheduledWake.addingTimeInterval(-Double(lockLaterAdjustmentsInsideMinutes) * 60)
    }

    func doneAfter(for window: PhaseWindow) -> Date {
        window.leaveBy.addingTimeInterval(Double(overdueGraceMinutes) * 60)
    }

    func phase(now: Date, window: PhaseWindow?, isEnabled: Bool) -> SchedulePhase {
        guard isEnabled, let window else { return .disabled }

        if now >= doneAfter(for: window) { return .done }
        if now >= window.leaveBy { return .overdue }
        if now >= window.scheduledWake { return .gettingReady }
        if now >= lockStart(for: window) { return .locked }
        if now >= watchStart(for: window) { return .watching }
        return .idle
    }

    /// When the next background check should be requested.
    ///
    /// Checks continue through the locked phase — a commute that falls apart at 6:40 still
    /// needs to pull the alarm earlier — and through getting-ready, where they keep the
    /// leave-by alarm honest.
    func nextCheckDate(
        now: Date,
        window: PhaseWindow?,
        isEnabled: Bool,
        refreshIntervalMinutes: Int
    ) -> Date? {
        guard let window else { return nil }
        switch phase(now: now, window: window, isEnabled: isEnabled) {
        case .disabled, .overdue, .done:
            return nil
        case .idle:
            return watchStart(for: window)
        case .watching, .locked:
            let next = now.addingTimeInterval(Double(refreshIntervalMinutes) * 60)
            return next < window.scheduledWake ? next : nil
        case .gettingReady:
            let next = now.addingTimeInterval(Double(refreshIntervalMinutes) * 60)
            return next < window.leaveBy ? next : nil
        }
    }
}
