import Foundation
import MapKit

struct GeocodeResult: Sendable, Hashable {
    var coordinate: Coordinate
    var formattedAddress: String
    var name: String?

    var displayLabel: String {
        if let name, !name.isEmpty { return name }
        return formattedAddress
    }
}

enum GeocodingError: LocalizedError, Equatable {
    case emptyQuery
    case notFound(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery: "Enter an address first."
        case .notFound(let query): "Couldn't find “\(query)”. Try adding a city or postcode."
        case .failed(let detail): "Lookup failed: \(detail)"
        }
    }
}

protocol GeocodingProviding: Sendable {
    func geocode(_ address: String) async throws -> GeocodeResult
}

/// Address → coordinates via `MKGeocodingRequest`.
///
/// Note this is *not* `CLGeocoder`, which the original spec called for: the whole class is
/// deprecated as of iOS 26 (`API_DEPRECATED("Use MapKit", ios(5.0, 26.0))`) in favour of this.
struct MapKitGeocoder: GeocodingProviding {
    func geocode(_ address: String) async throws -> GeocodeResult {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GeocodingError.emptyQuery }
        guard let request = MKGeocodingRequest(addressString: trimmed) else {
            throw GeocodingError.notFound(trimmed)
        }

        let mapItems: [MKMapItem]
        do {
            mapItems = try await request.mapItems
        } catch {
            throw GeocodingError.failed(error.localizedDescription)
        }

        guard let match = mapItems.first else {
            throw GeocodingError.notFound(trimmed)
        }

        return GeocodeResult(
            coordinate: Coordinate(match.location.coordinate),
            formattedAddress: match.address?.fullAddress ?? trimmed,
            name: match.name
        )
    }
}
