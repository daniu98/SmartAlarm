import Foundation

enum TravelEstimateSource: String, Codable, Sendable, Hashable {
    /// MapKit, asked about a departure well in the future. Traffic is predicted, not observed.
    case predictive
    /// MapKit, departure imminent enough that the answer is effectively live.
    case nearRealtime
    /// Our own logged history, used when the network is unavailable.
    case historical
    /// Retained from an earlier successful check because this one failed.
    case lastKnownGood
    /// Injected from the debug menu.
    case manual

    /// A departure closer than this is treated as real-time rather than predicted.
    static let nearRealtimeHorizonMinutes: Double = 30

    static func forDeparture(_ departure: Date, now: Date) -> TravelEstimateSource {
        let minutesOut = departure.timeIntervalSince(now) / 60
        return minutesOut <= nearRealtimeHorizonMinutes ? .nearRealtime : .predictive
    }

    var label: String {
        switch self {
        case .predictive: "Predicted"
        case .nearRealtime: "Live"
        case .historical: "From history"
        case .lastKnownGood: "Last known good"
        case .manual: "Manual"
        }
    }
}

struct TravelEstimate: Sendable, Hashable {
    var seconds: Double
    var distanceMeters: Double
    /// The departure time this estimate was actually asked about — not the same as "now".
    var departureDate: Date
    var source: TravelEstimateSource
    /// Route-level warnings from the map provider, e.g. "Avoid during winter storms".
    var advisories: [String]
    /// Name of the chosen route, e.g. "US-101".
    var routeName: String?
    /// How much slower the next-best route was. Nil when no alternate was offered.
    var alternateRoutePenaltySeconds: Double?

    init(
        seconds: Double,
        distanceMeters: Double,
        departureDate: Date,
        source: TravelEstimateSource,
        advisories: [String] = [],
        routeName: String? = nil,
        alternateRoutePenaltySeconds: Double? = nil
    ) {
        self.seconds = seconds
        self.distanceMeters = distanceMeters
        self.departureDate = departureDate
        self.source = source
        self.advisories = advisories
        self.routeName = routeName
        self.alternateRoutePenaltySeconds = alternateRoutePenaltySeconds
    }

    var minutes: Int { Int((seconds / 60).rounded()) }
}
