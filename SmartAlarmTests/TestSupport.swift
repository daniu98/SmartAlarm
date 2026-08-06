import Foundation

@testable import SmartAlarm

/// Fixed calendar/timezone so tests behave identically wherever they run.
enum Fixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// 2026-08-06 is a Thursday.
    static func date(
        year: Int = 2026,
        month: Int = 8,
        hour: Int,
        minute: Int = 0,
        day: Int = 6
    ) -> Date {
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )
        return calendar.date(from: components)!
    }

    static func minutes(_ value: Double) -> TimeInterval { value * 60 }

    static func inputs(
        arrivalHour: Int = 9,
        arrivalMinute: Int = 0,
        arrivalBufferMinutes: Int = 10,
        getReadyMinutes: Int = 30,
        extraBufferMinutes: Int = 0,
        minTravelMinutes: Int = 5,
        maxTravelMinutes: Int = 120,
        posture: ReliabilityPosture = .balanced,
        earliestAcceptableWake: Date? = nil,
        weatherPadFraction: Double = 0
    ) -> WakeTimeInputs {
        WakeTimeInputs(
            arrivalDeadline: date(hour: arrivalHour, minute: arrivalMinute),
            arrivalBufferMinutes: arrivalBufferMinutes,
            getReadyMinutes: getReadyMinutes,
            extraBufferMinutes: extraBufferMinutes,
            minTravelMinutes: minTravelMinutes,
            maxTravelMinutes: maxTravelMinutes,
            posture: posture,
            earliestAcceptableWake: earliestAcceptableWake,
            weatherPadFraction: weatherPadFraction
        )
    }

    static func solver(
        _ inputs: WakeTimeInputs
    ) -> WakeTimeSolver {
        WakeTimeSolver(inputs: inputs, calendar: calendar)
    }

    /// A provider that always answers the same, ignoring the departure time it was asked about.
    static func constantProvider(minutes: Double) -> (Date) async throws -> TravelEstimate {
        { departure in
            TravelEstimate(
                seconds: minutes * 60,
                distanceMeters: 15_000,
                departureDate: departure,
                source: .predictive
            )
        }
    }

    static func history(secondsValues: [Double], atHour hour: Int = 8) -> HistoricalTravelModel {
        let minuteOfDay = hour * 60
        return HistoricalTravelModel(
            samples: secondsValues.enumerated().map { index, seconds in
                HistoricalTravelModel.Sample(
                    weekday: 5, // Thursday
                    minuteOfDay: minuteOfDay,
                    seconds: seconds,
                    recordedAt: date(hour: hour, day: 6 - (index % 5))
                )
            }
        )
    }

    static let emptyHistory = HistoricalTravelModel(samples: [])
}
