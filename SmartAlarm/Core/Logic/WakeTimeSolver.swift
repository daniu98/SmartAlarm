import Foundation

enum WakeTimeError: Error, Equatable {
    /// The provider returned something outside the sanity bounds. Deliberately *rejected*
    /// rather than clamped: a 4-minute or 3-hour answer means the data is wrong, and acting
    /// on wrong data is worse than keeping yesterday's good answer.
    case implausibleTravelTime(seconds: Double, minimum: Double, maximum: Double)
    case noEstimateAvailable
}

/// Every component of the wake-time calculation, kept so the Today screen can show its work.
/// An alarm the user doesn't trust is an alarm they set a backup for.
struct PaddingBreakdown: Sendable, Hashable {
    /// What the provider actually said.
    var baseSeconds: Double
    /// Insurance bought against this route's historical unpredictability.
    var spreadSeconds: Double
    /// Insurance bought against the estimate being a far-future prediction.
    var horizonSeconds: Double
    /// Insurance bought against forecast rain, snow or ice on the route.
    var weatherSeconds: Double
    /// base + spread + horizon + weather, after clamping to the sanity bounds.
    var totalSeconds: Double
    var wasClamped: Bool
}

struct WakeTimeBreakdown: Sendable, Hashable {
    var arrivalDeadline: Date
    var estimate: TravelEstimate
    var padding: PaddingBreakdown
    var arrivalBufferSeconds: Double
    var extraBufferSeconds: Double
    var getReadySeconds: Double
    var leaveBy: Date
    var wakeTime: Date
    /// What the arithmetic asked for before the wake floor was applied.
    var uncappedWakeTime: Date
    var clampedToFloor: Bool
    var iterations: Int

    var travelMinutes: Int { Int((padding.totalSeconds / 60).rounded()) }
}

struct WakeTimeInputs: Sendable, Hashable {
    var arrivalDeadline: Date
    var arrivalBufferMinutes: Int
    var getReadyMinutes: Int
    /// Added by calendar importance. Only ever positive.
    var extraBufferMinutes: Int
    var minTravelMinutes: Int
    var maxTravelMinutes: Int
    var posture: ReliabilityPosture
    /// Absolute floor on how early the app is allowed to wake you.
    var earliestAcceptableWake: Date?
    /// Extra fraction of the drive time bought by the morning's forecast. See `DrivingWeather`.
    var weatherPadFraction: Double

    init(
        arrivalDeadline: Date,
        arrivalBufferMinutes: Int,
        getReadyMinutes: Int,
        extraBufferMinutes: Int = 0,
        minTravelMinutes: Int,
        maxTravelMinutes: Int,
        posture: ReliabilityPosture,
        earliestAcceptableWake: Date? = nil,
        weatherPadFraction: Double = 0
    ) {
        self.arrivalDeadline = arrivalDeadline
        self.arrivalBufferMinutes = arrivalBufferMinutes
        self.getReadyMinutes = getReadyMinutes
        self.extraBufferMinutes = extraBufferMinutes
        self.minTravelMinutes = minTravelMinutes
        self.maxTravelMinutes = maxTravelMinutes
        self.posture = posture
        self.earliestAcceptableWake = earliestAcceptableWake
        self.weatherPadFraction = weatherPadFraction
    }
}

/// Solves `leaveBy = arrival − driveTime(leaveBy) − buffer` for `leaveBy`.
///
/// The spec's formula is circular: the drive time you need depends on when you leave, which
/// depends on the drive time. Rather than pretend "now" is a good proxy for departure, this
/// iterates to a fixed point — ask for a departure time, get a drive time, derive a better
/// departure time, ask again. It settles in one or two rounds because drive time changes far
/// more slowly than the departure time does.
///
/// No MapKit, no SwiftData, no clock of its own: the provider arrives as a closure and `now`
/// is passed in, so every branch here is reachable from a unit test.
struct WakeTimeSolver: Sendable {
    var inputs: WakeTimeInputs
    var calendar: Calendar

    /// MapKit throttles aggressively, so the loop is capped hard.
    static let maxIterations = 3
    /// Two minutes of movement isn't worth another network round trip.
    static let convergenceToleranceSeconds: TimeInterval = 120
    /// Used only to place the very first query when there is no history at all.
    static let coldStartSeedMinutes: Double = 25

    /// Predictive ETAs are softer the further out they are, so they get padded more.
    /// This pad shrinks as the morning approaches, which naturally produces *later*
    /// proposals as confidence rises — exactly what the lock window exists to gate.
    static let horizonPadFraction = 0.08
    static let horizonPadRampMinutes: Double = 180

    init(inputs: WakeTimeInputs, calendar: Calendar = .current) {
        self.inputs = inputs
        self.calendar = calendar
    }

    var minTravelSeconds: Double { Double(inputs.minTravelMinutes) * 60 }
    var maxTravelSeconds: Double { Double(inputs.maxTravelMinutes) * 60 }
    var arrivalBufferSeconds: Double { Double(inputs.arrivalBufferMinutes) * 60 }
    var extraBufferSeconds: Double { Double(inputs.extraBufferMinutes) * 60 }
    var getReadySeconds: Double { Double(inputs.getReadyMinutes) * 60 }

    func validate(rawSeconds: Double) throws {
        guard rawSeconds >= minTravelSeconds, rawSeconds <= maxTravelSeconds else {
            throw WakeTimeError.implausibleTravelTime(
                seconds: rawSeconds,
                minimum: minTravelSeconds,
                maximum: maxTravelSeconds
            )
        }
    }

    static func horizonPad(baseSeconds: Double, now: Date, departure: Date) -> Double {
        let minutesOut = max(0, departure.timeIntervalSince(now) / 60)
        let ramp = min(1, minutesOut / horizonPadRampMinutes)
        return baseSeconds * horizonPadFraction * ramp
    }

    func padding(
        for estimate: TravelEstimate,
        now: Date,
        departure: Date,
        history: HistoricalTravelModel
    ) -> PaddingBreakdown {
        let base = estimate.seconds
        let weekday = calendar.component(.weekday, from: departure)
        let minuteOfDay = Self.minuteOfDay(departure, calendar: calendar)

        let spread = history.spread(posture: inputs.posture, weekday: weekday, minuteOfDay: minuteOfDay)
            * inputs.posture.spreadWeight
        let horizon = Self.horizonPad(baseSeconds: base, now: now, departure: departure)
        let weather = base * inputs.weatherPadFraction

        let uncapped = base + spread + horizon + weather
        let capped = min(max(uncapped, minTravelSeconds), maxTravelSeconds)
        return PaddingBreakdown(
            baseSeconds: base,
            spreadSeconds: spread,
            horizonSeconds: horizon,
            weatherSeconds: weather,
            totalSeconds: capped,
            wasClamped: capped != uncapped
        )
    }

    /// The seed only decides where the *first* query lands; the iteration corrects it.
    func seedTravelSeconds(history: HistoricalTravelModel) -> Double {
        let approximateDeparture = inputs.arrivalDeadline.addingTimeInterval(-arrivalBufferSeconds)
        let weekday = calendar.component(.weekday, from: approximateDeparture)
        let minuteOfDay = Self.minuteOfDay(approximateDeparture, calendar: calendar)
        let seeded = history.expectedSeconds(
            posture: inputs.posture,
            weekday: weekday,
            minuteOfDay: minuteOfDay
        )
        let seconds = seeded ?? (Self.coldStartSeedMinutes * 60)
        return min(max(seconds, minTravelSeconds), maxTravelSeconds)
    }

    func solve(
        now: Date,
        history: HistoricalTravelModel,
        estimate: (Date) async throws -> TravelEstimate
    ) async throws -> WakeTimeBreakdown {
        var departure = inputs.arrivalDeadline
            .addingTimeInterval(-(seedTravelSeconds(history: history) + arrivalBufferSeconds + extraBufferSeconds))

        var iterations = 0
        var lastEstimate: TravelEstimate?
        var lastPadding: PaddingBreakdown?

        while iterations < Self.maxIterations {
            iterations += 1
            let candidate = try await estimate(departure)
            try validate(rawSeconds: candidate.seconds)

            let pad = padding(for: candidate, now: now, departure: departure, history: history)
            let next = inputs.arrivalDeadline
                .addingTimeInterval(-(pad.totalSeconds + arrivalBufferSeconds + extraBufferSeconds))

            lastEstimate = candidate
            lastPadding = pad

            let movement = abs(next.timeIntervalSince(departure))
            departure = next
            if movement <= Self.convergenceToleranceSeconds { break }
        }

        guard let lastEstimate, let lastPadding else {
            throw WakeTimeError.noEstimateAvailable
        }

        let leaveBy = departure
        let uncappedWake = leaveBy.addingTimeInterval(-getReadySeconds)
        var wake = uncappedWake
        var clampedToFloor = false
        if let floor = inputs.earliestAcceptableWake, wake < floor {
            wake = floor
            clampedToFloor = true
        }

        return WakeTimeBreakdown(
            arrivalDeadline: inputs.arrivalDeadline,
            estimate: lastEstimate,
            padding: lastPadding,
            arrivalBufferSeconds: arrivalBufferSeconds,
            extraBufferSeconds: extraBufferSeconds,
            getReadySeconds: getReadySeconds,
            leaveBy: leaveBy,
            wakeTime: wake,
            uncappedWakeTime: uncappedWake,
            clampedToFloor: clampedToFloor,
            iterations: iterations
        )
    }

    /// The earliest wake time the settings could *possibly* produce, used to decide when
    /// background watching should begin. Assumes worst-case traffic.
    func earliestPossibleWake() -> Date {
        inputs.arrivalDeadline.addingTimeInterval(
            -(maxTravelSeconds + arrivalBufferSeconds + extraBufferSeconds + getReadySeconds)
        )
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
