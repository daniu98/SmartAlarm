import Foundation
import Testing

@testable import SmartAlarm

@Suite("Schedule phase machine")
struct SchedulePhaseTests {
    private let calculator = PhaseCalculator(
        refreshWindowStartMinutes: 120,
        lockLaterAdjustmentsInsideMinutes: 45
    )

    /// Worst-case wake 6:20, actually scheduled for 7:00.
    /// Watch opens at 4:20 (6:20 − 120), lock closes at 6:15 (7:00 − 45).
    private let window = PhaseWindow(
        earliestPossibleWake: Fixture.date(hour: 6, minute: 20),
        scheduledWake: Fixture.date(hour: 7, minute: 0),
        leaveBy: Fixture.date(hour: 7, minute: 45)
    )

    private func phase(at date: Date, isEnabled: Bool = true) -> SchedulePhase {
        calculator.phase(now: date, window: window, isEnabled: isEnabled)
    }

    @Test("Window boundaries are derived from the settings")
    func boundaries() {
        #expect(calculator.watchStart(for: window) == Fixture.date(hour: 4, minute: 20))
        #expect(calculator.lockStart(for: window) == Fixture.date(hour: 6, minute: 15))
    }

    @Test("Idle until the watch window opens")
    func idleBeforeWatch() {
        #expect(phase(at: Fixture.date(hour: 1)) == .idle)
        #expect(phase(at: Fixture.date(hour: 4, minute: 19)) == .idle)
    }

    @Test("Watching from the window opening to the lock cutoff")
    func watchingInsideWindow() {
        #expect(phase(at: Fixture.date(hour: 4, minute: 20)) == .watching)
        #expect(phase(at: Fixture.date(hour: 5, minute: 30)) == .watching)
        #expect(phase(at: Fixture.date(hour: 6, minute: 14)) == .watching)
    }

    @Test("Locked from the cutoff until the alarm fires")
    func lockedBeforeAlarm() {
        #expect(phase(at: Fixture.date(hour: 6, minute: 15)) == .locked)
        #expect(phase(at: Fixture.date(hour: 6, minute: 59)) == .locked)
    }

    @Test("Getting ready between the alarm and leave-by")
    func gettingReadyAfterAlarm() {
        #expect(phase(at: Fixture.date(hour: 7, minute: 0)) == .gettingReady)
        #expect(phase(at: Fixture.date(hour: 7, minute: 44)) == .gettingReady)
    }

    @Test("Overdue past leave-by, done after the grace period")
    func overdueThenDone() {
        #expect(phase(at: Fixture.date(hour: 7, minute: 45)) == .overdue)
        #expect(phase(at: Fixture.date(hour: 8, minute: 29)) == .overdue)
        #expect(phase(at: Fixture.date(hour: 8, minute: 30)) == .done)
    }

    /// Traffic can still fall apart while you're in the shower, and when it does the leave-by
    /// alarm has to move with it.
    @Test("Checks continue while getting ready")
    func checksContinueWhileGettingReady() {
        #expect(SchedulePhase.gettingReady.performsChecks)
        let next = calculator.nextCheckDate(
            now: Fixture.date(hour: 7, minute: 10),
            window: window,
            isEnabled: true,
            refreshIntervalMinutes: 15
        )
        #expect(next == Fixture.date(hour: 7, minute: 25))
    }

    @Test("Post-wake phases are flagged so the wake time is never moved")
    func afterWakeFlag() {
        #expect(SchedulePhase.gettingReady.isAfterWake)
        #expect(SchedulePhase.overdue.isAfterWake)
        #expect(!SchedulePhase.locked.isAfterWake)
    }

    @Test("Disabled overrides everything")
    func disabledWins() {
        #expect(phase(at: Fixture.date(hour: 5), isEnabled: false) == .disabled)
        #expect(calculator.phase(now: Fixture.date(hour: 5), window: nil, isEnabled: true) == .disabled)
    }

    @Test("Both watching and locked run checks; idle does not")
    func checkingPhases() {
        #expect(SchedulePhase.watching.performsChecks)
        #expect(SchedulePhase.locked.performsChecks)
        #expect(!SchedulePhase.idle.performsChecks)
        #expect(!SchedulePhase.done.performsChecks)
        #expect(!SchedulePhase.overdue.performsChecks)
    }

    @Test("While idle, the next check is scheduled for the window opening")
    func nextCheckFromIdle() {
        let next = calculator.nextCheckDate(
            now: Fixture.date(hour: 1),
            window: window,
            isEnabled: true,
            refreshIntervalMinutes: 15
        )
        #expect(next == Fixture.date(hour: 4, minute: 20))
    }

    @Test("While watching, the next check is one interval away")
    func nextCheckFromWatching() {
        let next = calculator.nextCheckDate(
            now: Fixture.date(hour: 5),
            window: window,
            isEnabled: true,
            refreshIntervalMinutes: 15
        )
        #expect(next == Fixture.date(hour: 5, minute: 15))
    }

    /// Checks keep running through the locked phase — deteriorating traffic still needs to
    /// be able to pull the alarm earlier.
    @Test("Checks continue while locked")
    func nextCheckFromLocked() {
        let next = calculator.nextCheckDate(
            now: Fixture.date(hour: 6, minute: 20),
            window: window,
            isEnabled: true,
            refreshIntervalMinutes: 15
        )
        #expect(next == Fixture.date(hour: 6, minute: 35))
    }

    @Test("No check is scheduled past the alarm time")
    func noCheckPastAlarm() {
        let next = calculator.nextCheckDate(
            now: Fixture.date(hour: 6, minute: 50),
            window: window,
            isEnabled: true,
            refreshIntervalMinutes: 15
        )
        #expect(next == nil)
    }

    @Test("Nothing is scheduled when disabled")
    func noCheckWhenDisabled() {
        let next = calculator.nextCheckDate(
            now: Fixture.date(hour: 5),
            window: window,
            isEnabled: false,
            refreshIntervalMinutes: 15
        )
        #expect(next == nil)
    }
}
