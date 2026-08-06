import Foundation

/// What Pro unlocks.
///
/// The split isn't arbitrary. WeatherKit is the app's only metered dependency — MapKit,
/// AlarmKit, EventKit and SwiftData all cost nothing per user, forever. Putting weather behind
/// the paywall means variable cost accrues *only* on paying users, so a free user can never
/// cost money. Everything else here is gated on value, not cost.
///
/// The core promise — a traffic-aware alarm that actually rings — stays free. An alarm app
/// whose free tier oversleeps you is a bad alarm app and a worse advert.
enum ProFeature: String, CaseIterable, Sendable, Hashable, Identifiable {
    case calendar
    case weather
    case perDayArrival
    case extendedHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar-aware mornings"
        case .weather: "Weather padding"
        case .perDayArrival: "A different time each day"
        case .extendedHistory: "Full history"
        }
    }

    var detail: String {
        switch self {
        case .calendar:
            "Wake earlier when your first meeting starts sooner, route to off-site meetings, and add buffer on high-stakes days."
        case .weather:
            "Adds time for rain, snow and ice — the one input that leads the traffic model instead of trailing it."
        case .perDayArrival:
            "Set a different arrival time for each weekday."
        case .extendedHistory:
            "Every check ever run, instead of the last week."
        }
    }

    var symbolName: String {
        switch self {
        case .calendar: "calendar.badge.clock"
        case .weather: "cloud.sun.rain"
        case .perDayArrival: "calendar.day.timeline.left"
        case .extendedHistory: "clock.arrow.circlepath"
        }
    }
}

enum FreeTier {
    /// How far back History goes without Pro.
    static let historyDays = 7
    static var historyInterval: TimeInterval { Double(historyDays) * 24 * 60 * 60 }
}
