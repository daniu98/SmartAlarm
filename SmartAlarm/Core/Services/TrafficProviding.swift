import Foundation

enum TrafficProviderError: LocalizedError, Equatable {
    case noRouteFound
    case throttled
    case network(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .noRouteFound: "No driving route between those two places."
        case .throttled: "Too many map requests — the system asked us to back off."
        case .network(let detail): "Network problem: \(detail)"
        case .unavailable(let detail): detail
        }
    }
}

/// The seam that keeps MapKit swappable.
///
/// Everything upstream of this protocol deals in `Coordinate` and `TravelEstimate`, never in
/// `MKMapItem` or `MKRoute`. Dropping in a Google Directions implementation means writing one
/// new conformance and changing one line in `AppEnvironment` — nothing else in the app moves.
protocol TrafficProviding: Sendable {
    /// Estimates driving time for a departure at `departingAt`, which is normally in the
    /// future. Asking about the future is the entire point: "how long will it take when I
    /// actually leave", not "how long would it take right now".
    func estimate(
        from origin: Coordinate,
        to destination: Coordinate,
        departingAt: Date
    ) async throws -> TravelEstimate
}
