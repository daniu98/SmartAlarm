import Foundation
import Testing

@testable import SmartAlarm

@Suite("Sleep target")
struct SleepTargetTests {
    @Test("Asleep-by is the wake time minus the target")
    func asleepByArithmetic() {
        let wake = Fixture.date(hour: 7, minute: 0)
        #expect(SleepTarget.asleepBy(wake: wake, sleepTargetMinutes: 8 * 60)
            == Fixture.date(hour: 23, minute: 0, day: 5))
        #expect(SleepTarget.asleepBy(wake: wake, sleepTargetMinutes: 450)
            == Fixture.date(hour: 23, minute: 30, day: 5))
    }

    @Test("Targets are clamped to something a human could actually sleep")
    func targetsAreClamped() {
        #expect(SleepTarget.clamp(60) == SleepTarget.minMinutes)
        #expect(SleepTarget.clamp(24 * 60) == SleepTarget.maxMinutes)
        #expect(SleepTarget.clamp(480) == 480)
    }

    @Test("Available sleep never reports a negative number")
    func availableSleepFloorsAtZero() {
        let wake = Fixture.date(hour: 7)
        #expect(SleepTarget.availableMinutes(from: Fixture.date(hour: 1), wake: wake) == 360)
        // Going to bed after the alarm is nonsense, not negative sleep.
        #expect(SleepTarget.availableMinutes(from: Fixture.date(hour: 9), wake: wake) == 0)
    }

    @Test("An asleep-by time that has passed is flagged as unreachable")
    func unreachableTarget() {
        let asleepBy = Fixture.date(hour: 23, day: 5)
        #expect(SleepTarget.isUnreachable(asleepBy: asleepBy, now: Fixture.date(hour: 0, day: 6)))
        #expect(!SleepTarget.isUnreachable(asleepBy: asleepBy, now: Fixture.date(hour: 22, day: 5)))
    }

    @Test("Durations read naturally")
    func durationText() {
        #expect(SleepTarget.text(480) == "8h")
        #expect(SleepTarget.text(450) == "7h 30m")
    }
}

@Suite("Widget snapshot")
struct WakePlanSnapshotTests {
    private func snapshot(updatedAt: Date) -> WakePlanSnapshot {
        WakePlanSnapshot(
            wakeDate: Fixture.date(hour: 7),
            leaveByDate: Fixture.date(hour: 7, minute: 30),
            arrivalDeadline: Fixture.date(hour: 9),
            driveMinutes: 40,
            condition: .moderate,
            destinationLabel: "Work",
            phaseLabel: "Idle",
            phaseSymbolName: "clock",
            isArmed: true,
            updatedAt: updatedAt
        )
    }

    @Test("Round-trips through JSON")
    func codableRoundTrip() throws {
        let original = snapshot(updatedAt: Fixture.date(hour: 3))
        let decoded = try JSONDecoder().decode(
            WakePlanSnapshot.self,
            from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }

    /// A widget quietly showing yesterday's drive estimate is worse than one admitting it
    /// doesn't know.
    @Test("A snapshot older than the freshness window is flagged stale")
    func stalenessIsDetected() {
        let fresh = snapshot(updatedAt: Fixture.date(hour: 6))
        #expect(!fresh.isStale(now: Fixture.date(hour: 7)))

        let old = snapshot(updatedAt: Fixture.date(hour: 6, day: 5))
        #expect(old.isStale(now: Fixture.date(hour: 12)))
    }

    /// The App Group can legitimately be missing — unsigned builds, a bad provisioning
    /// profile. Every path has to degrade rather than trap, because a crashed alarm app is
    /// infinitely worse than a missing widget.
    @Test("Sharing degrades quietly when the App Group is unavailable")
    func sharingDegradesGracefully() {
        if SharedStore.isAvailable {
            SharedStore.save(snapshot(updatedAt: .now))
            #expect(SharedStore.load() != nil)
            SharedStore.save(nil)
            #expect(SharedStore.load() == nil)
        } else {
            // Must not trap.
            SharedStore.save(snapshot(updatedAt: .now))
            #expect(SharedStore.load() == nil)
        }
    }
}
