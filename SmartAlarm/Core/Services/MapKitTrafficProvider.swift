import Foundation
import MapKit

/// MapKit-backed travel time estimates.
///
/// An actor because `MKDirections` is throttled server-side: fire several requests at once and
/// some come back as `MKError.loadingThrottled`. Serialising them behind a minimum spacing is
/// cheaper than retrying, and the fixed-point solve only needs two or three calls anyway.
actor MapKitTrafficProvider: TrafficProviding {
    private var lastRequestFinishedAt: Date?

    /// Minimum gap between outbound requests.
    private let minimumSpacing: TimeInterval = 0.6
    /// One retry after a throttle, then give up and let the caller keep last-known-good.
    private let throttleBackoff: TimeInterval = 2.0

    func estimate(
        from origin: Coordinate,
        to destination: Coordinate,
        departingAt: Date
    ) async throws -> TravelEstimate {
        try await waitForSlot()

        do {
            return try await performRequest(from: origin, to: destination, departingAt: departingAt)
        } catch let error as MKError where error.code == .loadingThrottled {
            AppLogger.traffic.notice("MapKit throttled us; backing off once")
            try? await Task.sleep(for: .seconds(throttleBackoff))
            do {
                return try await performRequest(from: origin, to: destination, departingAt: departingAt)
            } catch {
                throw TrafficProviderError.throttled
            }
        } catch let error as MKError where error.code == .directionsNotFound || error.code == .placemarkNotFound {
            throw TrafficProviderError.noRouteFound
        } catch {
            throw TrafficProviderError.network(error.localizedDescription)
        }
    }

    private func performRequest(
        from origin: Coordinate,
        to destination: Coordinate,
        departingAt: Date
    ) async throws -> TravelEstimate {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin.clLocation, address: nil)
        request.destination = MKMapItem(location: destination.clLocation, address: nil)
        request.transportType = .automobile
        // MapKit ignores a departure date in the past, so never send it one.
        request.departureDate = max(departingAt, Date.now)
        request.requestsAlternateRoutes = true

        let directions = MKDirections(request: request)
        // Stamped however the request ends. Recording it only on success would mean a
        // throttled request left no trace, so the *next* call would skip the spacing wait
        // entirely and fire immediately into the throttle that just rejected us — the one
        // moment the spacing is actually needed.
        defer { lastRequestFinishedAt = .now }
        // `calculate()` rather than the lighter `calculateETA()`: same request count against
        // MapKit's throttle, but it also returns `advisoryNotices` ("Avoid during winter
        // storms") and the alternate routes — signal we were previously paying for and
        // discarding.
        let response = try await directions.calculate()

        let sorted = response.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
        guard let best = sorted.first, best.expectedTravelTime > 0 else {
            throw TrafficProviderError.noRouteFound
        }

        let alternatePenalty = sorted.dropFirst().first.map {
            $0.expectedTravelTime - best.expectedTravelTime
        }

        return TravelEstimate(
            seconds: best.expectedTravelTime,
            distanceMeters: best.distance,
            departureDate: departingAt,
            source: .forDeparture(departingAt, now: .now),
            advisories: best.advisoryNotices,
            routeName: best.name.isEmpty ? nil : best.name,
            alternateRoutePenaltySeconds: alternatePenalty
        )
    }

    private func waitForSlot() async throws {
        guard let lastRequestFinishedAt else { return }
        let elapsed = Date.now.timeIntervalSince(lastRequestFinishedAt)
        if elapsed < minimumSpacing {
            try? await Task.sleep(for: .seconds(minimumSpacing - elapsed))
        }
    }
}
