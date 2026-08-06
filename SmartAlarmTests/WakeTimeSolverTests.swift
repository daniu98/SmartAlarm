import Foundation
import Testing

@testable import SmartAlarm

@Suite("Wake time solver")
struct WakeTimeSolverTests {
    /// `now` at the arrival deadline makes every departure "in the past", zeroing the horizon
    /// pad so the core arithmetic can be asserted exactly. Horizon padding gets its own test.
    private let now = Fixture.date(hour: 9)

    @Test("Works backwards from arrival through buffer, drive and get-ready")
    func basicArithmetic() async throws {
        let solver = Fixture.solver(Fixture.inputs())

        let result = try await solver.solve(
            now: now,
            history: Fixture.emptyHistory,
            estimate: Fixture.constantProvider(minutes: 30)
        )

        // 9:00 arrival − 30 drive − 10 buffer = 8:20 leave-by; − 30 get-ready = 7:50 wake.
        #expect(result.leaveBy == Fixture.date(hour: 8, minute: 20))
        #expect(result.wakeTime == Fixture.date(hour: 7, minute: 50))
        #expect(result.padding.totalSeconds == Fixture.minutes(30))
        #expect(!result.clampedToFloor)
    }

    @Test("Converges when drive time depends on departure time")
    func fixedPointConverges() async throws {
        let solver = Fixture.solver(Fixture.inputs())
        let rushHourStart = Fixture.date(hour: 8, minute: 0)

        // Leaving before 8:00 is quick; leaving after is slow. The seed lands in one regime
        // and the answer has to settle in the other.
        let result = try await solver.solve(now: now, history: Fixture.emptyHistory) { departure in
            let minutes: Double = departure < rushHourStart ? 20 : 30
            return TravelEstimate(
                seconds: minutes * 60,
                distanceMeters: 15_000,
                departureDate: departure,
                source: .predictive
            )
        }

        // The self-consistent answer: leave 8:20, drive 30, arrive 8:50, +10 buffer = 9:00.
        #expect(result.leaveBy == Fixture.date(hour: 8, minute: 20))
        #expect(result.iterations >= 2)
        #expect(result.iterations <= WakeTimeSolver.maxIterations)
    }

    @Test("Stops iterating even when the estimate never settles")
    func iterationIsBounded() async throws {
        let solver = Fixture.solver(Fixture.inputs())
        nonisolated(unsafe) var callCount = 0

        let result = try await solver.solve(now: now, history: Fixture.emptyHistory) { departure in
            callCount += 1
            // Alternates wildly, so the loop can never converge.
            let minutes: Double = callCount.isMultiple(of: 2) ? 20 : 60
            return TravelEstimate(
                seconds: minutes * 60,
                distanceMeters: 15_000,
                departureDate: departure,
                source: .predictive
            )
        }

        #expect(callCount == WakeTimeSolver.maxIterations)
        #expect(result.iterations == WakeTimeSolver.maxIterations)
    }

    @Test("Rejects an absurdly long estimate rather than clamping it")
    func rejectsTooSlow() async {
        let solver = Fixture.solver(Fixture.inputs(maxTravelMinutes: 120))

        await #expect(throws: WakeTimeError.self) {
            try await solver.solve(
                now: now,
                history: Fixture.emptyHistory,
                estimate: Fixture.constantProvider(minutes: 240)
            )
        }
    }

    @Test("Rejects an impossibly short estimate")
    func rejectsTooFast() async {
        let solver = Fixture.solver(Fixture.inputs(minTravelMinutes: 5))

        await #expect(throws: WakeTimeError.self) {
            try await solver.solve(
                now: now,
                history: Fixture.emptyHistory,
                estimate: Fixture.constantProvider(minutes: 1)
            )
        }
    }

    @Test("Never wakes earlier than the floor, and says so")
    func clampsToWakeFloor() async throws {
        let floor = Fixture.date(hour: 4, minute: 30)
        let solver = Fixture.solver(
            Fixture.inputs(arrivalHour: 6, earliestAcceptableWake: floor)
        )

        let result = try await solver.solve(
            now: Fixture.date(hour: 6),
            history: Fixture.emptyHistory,
            estimate: Fixture.constantProvider(minutes: 60)
        )

        // Arithmetic wants 4:20; the floor holds it at 4:30 and flags the shortfall.
        #expect(result.uncappedWakeTime == Fixture.date(hour: 4, minute: 20))
        #expect(result.wakeTime == floor)
        #expect(result.clampedToFloor)
    }

    @Test("Balanced posture buys padding equal to the route's historical spread")
    func spreadPaddingApplied() async throws {
        // p50 = 30 min, p80 = 40 min → 10 minutes of spread.
        let history = Fixture.history(
            secondsValues: [
                Fixture.minutes(30), Fixture.minutes(30), Fixture.minutes(30),
                Fixture.minutes(30), Fixture.minutes(30), Fixture.minutes(30),
                Fixture.minutes(40), Fixture.minutes(40),
            ]
        )
        let solver = Fixture.solver(Fixture.inputs(posture: .balanced))

        let result = try await solver.solve(
            now: now,
            history: history,
            estimate: Fixture.constantProvider(minutes: 30)
        )

        #expect(result.padding.baseSeconds == Fixture.minutes(30))
        #expect(result.padding.spreadSeconds > 0)
        #expect(result.padding.totalSeconds > Fixture.minutes(30))
        // Padding pushes the wake time earlier than the unpadded 7:50.
        #expect(result.wakeTime < Fixture.date(hour: 7, minute: 50))
    }

    @Test("Relaxed posture declines the spread padding")
    func relaxedPostureSkipsSpread() async throws {
        let history = Fixture.history(
            secondsValues: [
                Fixture.minutes(30), Fixture.minutes(30), Fixture.minutes(30),
                Fixture.minutes(30), Fixture.minutes(45), Fixture.minutes(45),
            ]
        )
        let solver = Fixture.solver(Fixture.inputs(posture: .relaxed))

        let result = try await solver.solve(
            now: now,
            history: history,
            estimate: Fixture.constantProvider(minutes: 30)
        )

        #expect(result.padding.spreadSeconds == 0)
        #expect(result.wakeTime == Fixture.date(hour: 7, minute: 50))
    }

    @Test("A far-future departure is padded more than an imminent one")
    func horizonPaddingScalesWithDistance() {
        let base = Fixture.minutes(30)
        let reference = Fixture.date(hour: 5)

        let imminent = WakeTimeSolver.horizonPad(
            baseSeconds: base,
            now: reference,
            departure: reference.addingTimeInterval(Fixture.minutes(10))
        )
        let distant = WakeTimeSolver.horizonPad(
            baseSeconds: base,
            now: reference,
            departure: reference.addingTimeInterval(Fixture.minutes(180))
        )
        let past = WakeTimeSolver.horizonPad(
            baseSeconds: base,
            now: reference,
            departure: reference.addingTimeInterval(-Fixture.minutes(10))
        )

        #expect(past == 0)
        #expect(imminent > 0)
        #expect(distant > imminent)
        #expect(distant == base * WakeTimeSolver.horizonPadFraction)
    }

    @Test("Extra buffer from calendar importance moves the alarm earlier")
    func extraBufferMovesEarlier() async throws {
        let plain = try await Fixture.solver(Fixture.inputs())
            .solve(now: now, history: Fixture.emptyHistory, estimate: Fixture.constantProvider(minutes: 30))
        let important = try await Fixture.solver(Fixture.inputs(extraBufferMinutes: 20))
            .solve(now: now, history: Fixture.emptyHistory, estimate: Fixture.constantProvider(minutes: 30))

        #expect(important.wakeTime == plain.wakeTime.addingTimeInterval(-Fixture.minutes(20)))
    }

    @Test("Earliest possible wake assumes worst-case traffic")
    func earliestPossibleWakeUsesMaxTravel() {
        let solver = Fixture.solver(Fixture.inputs(maxTravelMinutes: 120))
        // 9:00 − 120 drive − 10 buffer − 30 get-ready = 6:20.
        #expect(solver.earliestPossibleWake() == Fixture.date(hour: 6, minute: 20))
    }
}
