import Foundation
import Testing

@testable import SmartAlarm

@Suite("Adjustment policy — the safety rules")
struct AdjustmentPolicyTests {
    private let policy = AdjustmentPolicy(lockLaterAdjustmentsInsideMinutes: 45)
    private let currentWake = Fixture.date(hour: 7, minute: 0)

    private func decide(
        now: Date,
        proposed: Date,
        current: Date? = Fixture.date(hour: 7, minute: 0),
        previousTravel: Double? = Fixture.minutes(30),
        proposedTravel: Double = Fixture.minutes(30),
        pending: PendingLaterProposal? = nil
    ) -> AdjustmentDecision {
        policy.decide(
            now: now,
            currentWake: current,
            proposedWake: proposed,
            previousTravelSeconds: previousTravel,
            proposedTravelSeconds: proposedTravel,
            pending: pending
        )
    }

    @Test("With no alarm yet, anything schedules")
    func initialSchedule() {
        let decision = decide(
            now: Fixture.date(hour: 3),
            proposed: currentWake,
            current: nil
        )
        #expect(decision == .scheduleInitial(currentWake))
    }

    @Test("Earlier always applies, well outside the lock window")
    func earlierOutsideLock() {
        let earlier = currentWake.addingTimeInterval(-Fixture.minutes(15))
        let decision = decide(now: Fixture.date(hour: 5), proposed: earlier)
        #expect(decision == .moveEarlier(to: earlier))
    }

    /// The single most important property in the app: bad traffic discovered at the last
    /// minute must still be able to wake you sooner.
    @Test("Earlier still applies inside the lock window")
    func earlierInsideLock() {
        let earlier = currentWake.addingTimeInterval(-Fixture.minutes(15))
        let decision = decide(now: Fixture.date(hour: 6, minute: 50), proposed: earlier)
        #expect(decision == .moveEarlier(to: earlier))
    }

    @Test("Earlier applies even one minute before the alarm")
    func earlierAtTheLastMoment() {
        let earlier = currentWake.addingTimeInterval(-Fixture.minutes(5))
        let decision = decide(now: Fixture.date(hour: 6, minute: 59), proposed: earlier)
        #expect(decision == .moveEarlier(to: earlier))
    }

    @Test("Later applies while outside the lock window")
    func laterOutsideLock() {
        let later = currentWake.addingTimeInterval(Fixture.minutes(10))
        let decision = decide(now: Fixture.date(hour: 5), proposed: later)
        #expect(decision == .moveLater(to: later))
    }

    @Test("Later is rejected inside the lock window")
    func laterInsideLockRejected() {
        let later = currentWake.addingTimeInterval(Fixture.minutes(10))
        // 6:30 is 30 minutes before a 7:00 alarm — inside the 45-minute lock.
        let decision = decide(now: Fixture.date(hour: 6, minute: 30), proposed: later)
        #expect(decision == .rejectedLocked(proposed: later))
    }

    @Test("The lock boundary is exact")
    func lockBoundary() {
        let later = currentWake.addingTimeInterval(Fixture.minutes(10))
        let justOutside = Fixture.date(hour: 6, minute: 14) // 46 min before
        let justInside = Fixture.date(hour: 6, minute: 15)  // exactly 45 min before

        #expect(decide(now: justOutside, proposed: later) == .moveLater(to: later))
        #expect(decide(now: justInside, proposed: later) == .rejectedLocked(proposed: later))
    }

    @Test("Trivial movement is ignored in both directions")
    func minimumMoveThreshold() {
        let barelyLater = currentWake.addingTimeInterval(30)
        let barelyEarlier = currentWake.addingTimeInterval(-30)
        #expect(decide(now: Fixture.date(hour: 5), proposed: barelyLater) == .noChange)
        #expect(decide(now: Fixture.date(hour: 5), proposed: barelyEarlier) == .noChange)
    }

    @Test("A big later jump on a collapsed estimate is held, not applied")
    func suspiciousLaterMoveHeld() {
        let muchLater = currentWake.addingTimeInterval(Fixture.minutes(30))
        let decision = decide(
            now: Fixture.date(hour: 5),
            proposed: muchLater,
            previousTravel: Fixture.minutes(60),
            proposedTravel: Fixture.minutes(20) // dropped 67%
        )

        guard case .holdPendingConfirmation(let pending) = decision else {
            Issue.record("expected the move to be held, got \(decision)")
            return
        }
        #expect(pending.wakeDate == muchLater)
        #expect(pending.travelSeconds == Fixture.minutes(20))
    }

    @Test("A second agreeing check releases the held move")
    func heldMoveConfirmed() {
        let muchLater = currentWake.addingTimeInterval(Fixture.minutes(30))
        let pending = PendingLaterProposal(
            wakeDate: muchLater,
            travelSeconds: Fixture.minutes(20),
            proposedAt: Fixture.date(hour: 4, minute: 45)
        )

        let decision = decide(
            now: Fixture.date(hour: 5),
            proposed: muchLater,
            previousTravel: Fixture.minutes(60),
            proposedTravel: Fixture.minutes(20),
            pending: pending
        )
        #expect(decision == .moveLater(to: muchLater))
    }

    @Test("A held move that the next check disagrees with stays held")
    func heldMoveNotConfirmedByDifferentAnswer() {
        let firstProposal = currentWake.addingTimeInterval(Fixture.minutes(30))
        let secondProposal = currentWake.addingTimeInterval(Fixture.minutes(50))
        let pending = PendingLaterProposal(
            wakeDate: firstProposal,
            travelSeconds: Fixture.minutes(20),
            proposedAt: Fixture.date(hour: 4, minute: 45)
        )

        let decision = decide(
            now: Fixture.date(hour: 5),
            proposed: secondProposal,
            previousTravel: Fixture.minutes(60),
            proposedTravel: Fixture.minutes(5),
            pending: pending
        )

        guard case .holdPendingConfirmation(let newPending) = decision else {
            Issue.record("expected the move to stay held, got \(decision)")
            return
        }
        #expect(newPending.wakeDate == secondProposal)
    }

    @Test("A big later jump from a gently improving estimate applies immediately")
    func largeMoveWithoutCollapseApplies() {
        let muchLater = currentWake.addingTimeInterval(Fixture.minutes(30))
        let decision = decide(
            now: Fixture.date(hour: 5),
            proposed: muchLater,
            previousTravel: Fixture.minutes(60),
            proposedTravel: Fixture.minutes(45) // only a 25% drop
        )
        #expect(decision == .moveLater(to: muchLater))
    }

    @Test("A small later move on a collapsed estimate still applies")
    func smallMoveWithCollapseApplies() {
        let slightlyLater = currentWake.addingTimeInterval(Fixture.minutes(5))
        let decision = decide(
            now: Fixture.date(hour: 5),
            proposed: slightlyLater,
            previousTravel: Fixture.minutes(60),
            proposedTravel: Fixture.minutes(10)
        )
        #expect(decision == .moveLater(to: slightlyLater))
    }
}
