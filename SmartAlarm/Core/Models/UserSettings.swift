import Foundation
import SwiftData

/// A per-weekday arrival time that replaces the default on that day.
struct ArrivalOverride: Codable, Hashable, Sendable, Identifiable {
    /// Calendar convention: 1 = Sunday ... 7 = Saturday.
    var weekday: Int
    var minuteOfDay: Int

    var id: Int { weekday }
}

@Model
final class UserSettings {
    // MARK: Route
    var homeAddress: String
    var homeLatitude: Double?
    var homeLongitude: Double?
    var workAddress: String
    var workLatitude: Double?
    var workLongitude: Double?

    // MARK: Schedule
    /// The usual arrival time, as minutes past midnight.
    var defaultArrivalMinuteOfDay: Int
    var arrivalOverrides: [ArrivalOverride]
    /// Which weekdays the alarm arms itself on. Defaults to Monday–Friday.
    var activeWeekdays: [Int]

    // MARK: Core timings
    var getReadyMinutes: Int
    var arrivalBufferMinutes: Int

    // MARK: Watch/lock behaviour
    var refreshIntervalMinutes: Int
    var refreshWindowStartMinutes: Int
    var lockLaterAdjustmentsInsideMinutes: Int

    // MARK: Sanity bounds
    var maxTravelTimeMinutes: Int
    var minTravelTimeMinutes: Int

    // MARK: Preferences
    var postureRaw: String
    /// Hard floor on how early the app may ever wake you.
    var earliestAcceptableWakeMinuteOfDay: Int
    var snoozeMinutes: Int
    /// How much sleep you're aiming for, used to work out an asleep-by time.
    var sleepTargetMinutes: Int = 8 * 60
    var isEnabled: Bool

    // MARK: Calendar
    var calendarEnabled: Bool
    var weatherEnabled: Bool = true
    var calendarCanOverrideDestination: Bool
    var remindersEnabled: Bool
    var importanceKeywords: [String]

    var updatedAt: Date

    init(
        homeAddress: String = "",
        workAddress: String = "",
        defaultArrivalMinuteOfDay: Int = 9 * 60,
        getReadyMinutes: Int = 30,
        arrivalBufferMinutes: Int = 10,
        refreshIntervalMinutes: Int = 15,
        refreshWindowStartMinutes: Int = 120,
        lockLaterAdjustmentsInsideMinutes: Int = 45,
        maxTravelTimeMinutes: Int = 120,
        minTravelTimeMinutes: Int = 5,
        posture: ReliabilityPosture = .balanced,
        earliestAcceptableWakeMinuteOfDay: Int = 4 * 60 + 30,
        snoozeMinutes: Int = 9,
        isEnabled: Bool = false,
        calendarEnabled: Bool = false,
        calendarCanOverrideDestination: Bool = true,
        remindersEnabled: Bool = false
    ) {
        self.homeAddress = homeAddress
        self.workAddress = workAddress
        self.defaultArrivalMinuteOfDay = defaultArrivalMinuteOfDay
        arrivalOverrides = []
        activeWeekdays = [2, 3, 4, 5, 6] // Mon–Fri
        self.getReadyMinutes = getReadyMinutes
        self.arrivalBufferMinutes = arrivalBufferMinutes
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.refreshWindowStartMinutes = refreshWindowStartMinutes
        self.lockLaterAdjustmentsInsideMinutes = lockLaterAdjustmentsInsideMinutes
        self.maxTravelTimeMinutes = maxTravelTimeMinutes
        self.minTravelTimeMinutes = minTravelTimeMinutes
        postureRaw = posture.rawValue
        self.earliestAcceptableWakeMinuteOfDay = earliestAcceptableWakeMinuteOfDay
        self.snoozeMinutes = snoozeMinutes
        self.isEnabled = isEnabled
        self.calendarEnabled = calendarEnabled
        self.calendarCanOverrideDestination = calendarCanOverrideDestination
        self.remindersEnabled = remindersEnabled
        importanceKeywords = ImportanceScorer.defaultKeywords
        updatedAt = .now
    }
}

extension UserSettings {
    var posture: ReliabilityPosture {
        get { ReliabilityPosture(rawValue: postureRaw) ?? .balanced }
        set { postureRaw = newValue.rawValue }
    }

    var homeCoordinate: Coordinate? {
        guard let homeLatitude, let homeLongitude else { return nil }
        return Coordinate(latitude: homeLatitude, longitude: homeLongitude)
    }

    var workCoordinate: Coordinate? {
        guard let workLatitude, let workLongitude else { return nil }
        return Coordinate(latitude: workLatitude, longitude: workLongitude)
    }

    func setHomeCoordinate(_ coordinate: Coordinate?) {
        homeLatitude = coordinate?.latitude
        homeLongitude = coordinate?.longitude
    }

    func setWorkCoordinate(_ coordinate: Coordinate?) {
        workLatitude = coordinate?.latitude
        workLongitude = coordinate?.longitude
    }

    /// True once both endpoints are geocoded — until then there is nothing to route.
    var isRouteConfigured: Bool {
        homeCoordinate != nil && workCoordinate != nil
    }

    func isActive(weekday: Int) -> Bool {
        activeWeekdays.contains(weekday)
    }

    func arrivalMinuteOfDay(forWeekday weekday: Int) -> Int {
        arrivalOverrides.first { $0.weekday == weekday }?.minuteOfDay ?? defaultArrivalMinuteOfDay
    }

    // MARK: Derived logic objects

    var adjustmentPolicy: AdjustmentPolicy {
        AdjustmentPolicy(lockLaterAdjustmentsInsideMinutes: lockLaterAdjustmentsInsideMinutes)
    }

    var phaseCalculator: PhaseCalculator {
        PhaseCalculator(
            refreshWindowStartMinutes: refreshWindowStartMinutes,
            lockLaterAdjustmentsInsideMinutes: lockLaterAdjustmentsInsideMinutes
        )
    }

    var postureAdvisor: PostureAdvisor { PostureAdvisor() }

    /// Hash of everything that changes the computed wake time.
    ///
    /// Setup has fifteen-odd controls; wiring a recompute onto each one individually is a
    /// standing invitation to forget one and leave a stale time on screen. Watching this
    /// single value catches all of them, including any added later.
    var planSignature: Int {
        var hasher = Hasher()
        hasher.combine(defaultArrivalMinuteOfDay)
        hasher.combine(arrivalOverrides)
        hasher.combine(activeWeekdays)
        hasher.combine(getReadyMinutes)
        hasher.combine(arrivalBufferMinutes)
        hasher.combine(refreshIntervalMinutes)
        hasher.combine(refreshWindowStartMinutes)
        hasher.combine(lockLaterAdjustmentsInsideMinutes)
        hasher.combine(maxTravelTimeMinutes)
        hasher.combine(minTravelTimeMinutes)
        hasher.combine(postureRaw)
        hasher.combine(earliestAcceptableWakeMinuteOfDay)
        hasher.combine(snoozeMinutes)
        hasher.combine(sleepTargetMinutes)
        hasher.combine(weatherEnabled)
        hasher.combine(calendarEnabled)
        hasher.combine(calendarCanOverrideDestination)
        hasher.combine(remindersEnabled)
        hasher.combine(importanceKeywords)
        hasher.combine(homeLatitude)
        hasher.combine(homeLongitude)
        hasher.combine(workLatitude)
        hasher.combine(workLongitude)
        return hasher.finalize()
    }

    var importanceScorer: ImportanceScorer {
        ImportanceScorer(keywords: importanceKeywords)
    }

    /// The next morning the alarm should arm for: the soonest active weekday whose arrival
    /// deadline still lies ahead of `now`.
    func nextTargetMorning(after now: Date, calendar: Calendar = .current) -> (dayStart: Date, arrival: Date)? {
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            let weekday = calendar.component(.weekday, from: dayStart)
            guard isActive(weekday: weekday) else { continue }
            let minute = arrivalMinuteOfDay(forWeekday: weekday)
            guard let arrival = calendar.date(byAdding: .minute, value: minute, to: dayStart) else { continue }
            if arrival > now { return (dayStart, arrival) }
        }
        return nil
    }

    func earliestAcceptableWake(onDayStarting dayStart: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .minute, value: earliestAcceptableWakeMinuteOfDay, to: dayStart)
    }

    func wakeTimeInputs(
        arrivalDeadline: Date,
        extraBufferMinutes: Int,
        posture: ReliabilityPosture,
        dayStart: Date,
        weatherPadFraction: Double = 0,
        calendar: Calendar = .current
    ) -> WakeTimeInputs {
        WakeTimeInputs(
            arrivalDeadline: arrivalDeadline,
            arrivalBufferMinutes: arrivalBufferMinutes,
            getReadyMinutes: getReadyMinutes,
            extraBufferMinutes: extraBufferMinutes,
            minTravelMinutes: minTravelTimeMinutes,
            maxTravelMinutes: maxTravelTimeMinutes,
            posture: posture,
            earliestAcceptableWake: earliestAcceptableWake(onDayStarting: dayStart, calendar: calendar),
            weatherPadFraction: weatherPadFraction
        )
    }
}

// MARK: - Formatting helpers

enum MinuteOfDay {
    static func date(_ minuteOfDay: Int, onDayStarting dayStart: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .minute, value: minuteOfDay, to: dayStart) ?? dayStart
    }

    static func from(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func text(_ minuteOfDay: Int, calendar: Calendar = .current) -> String {
        let reference = calendar.startOfDay(for: .now)
        return date(minuteOfDay, onDayStarting: reference, calendar: calendar)
            .formatted(date: .omitted, time: .shortened)
    }

    static func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "Day \(weekday)" }
        return symbols[index]
    }

    static func shortWeekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return "\(weekday)" }
        return symbols[index]
    }
}
