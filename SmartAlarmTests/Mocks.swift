import Foundation

@testable import SmartAlarm

/// Configurable stand-in for MapKit. Lets a test decide, per call, whether the network
/// "works" — which is the only way to exercise the failure paths deterministically.
actor MockTrafficProvider: TrafficProviding {
    private var fixedSeconds: Double
    private var failure: Error?
    private(set) var callCount = 0
    private(set) var requestedDepartures: [Date] = []

    init(minutes: Double = 30) {
        fixedSeconds = minutes * 60
    }

    func setMinutes(_ minutes: Double) {
        fixedSeconds = minutes * 60
        failure = nil
    }

    func setFailure(_ error: Error?) {
        failure = error
    }

    func estimate(
        from origin: Coordinate,
        to destination: Coordinate,
        departingAt: Date
    ) async throws -> TravelEstimate {
        callCount += 1
        requestedDepartures.append(departingAt)
        if let failure { throw failure }
        return TravelEstimate(
            seconds: fixedSeconds,
            distanceMeters: 15_000,
            departureDate: departingAt,
            source: .predictive
        )
    }
}

/// Records what the planner asked AlarmKit to do, without touching the real system alarm.
final class MockAlarmScheduler: AlarmScheduling, @unchecked Sendable {
    struct ScheduledAlarm: Equatable {
        var id: UUID
        var date: Date
        var kind: AlarmKind
        var snoozeMinutes: Int
    }

    var authorization: AlarmAuthorization = .authorized
    private(set) var scheduleCallCount = 0
    private(set) var cancelled: [UUID] = []
    /// Keyed by identifier, so a reschedule that reuses the id overwrites rather than appends —
    /// mirroring AlarmKit's own update-in-place behaviour.
    private(set) var alarms: [UUID: ScheduledAlarm] = [:]
    var scheduleError: Error?

    func requestAuthorization() async throws -> AlarmAuthorization {
        authorization = .authorized
        return authorization
    }

    func schedule(
        id: UUID, at date: Date, kind: AlarmKind,
        metadata: WakeAlarmMetadata, snoozeMinutes: Int
    ) async throws {
        scheduleCallCount += 1
        if let scheduleError { throw scheduleError }
        alarms[id] = ScheduledAlarm(id: id, date: date, kind: kind, snoozeMinutes: snoozeMinutes)
    }

    func cancel(id: UUID) throws {
        cancelled.append(id)
        alarms[id] = nil
    }

    func stop(id: UUID) throws {
        alarms[id] = nil
    }

    func scheduledAlarmIdentifiers() -> [UUID] {
        Array(alarms.keys)
    }
}


/// AlarmKind needs to be comparable in assertions.
extension AlarmKind: Equatable {}

/// Counts calls, because WeatherKit is the only metered dependency in the app and the
/// difference between calling it per-check and per-morning is the difference between the free
/// tier lasting a thousand users and eleven thousand.
final class MockWeatherProvider: WeatherProviding, @unchecked Sendable {
    let impact: WeatherImpact
    private(set) var callCount = 0

    init(impact: WeatherImpact = .clear) {
        self.impact = impact
    }

    func impact(at coordinate: Coordinate, on date: Date) async -> WeatherImpact {
        callCount += 1
        return impact
    }
}
