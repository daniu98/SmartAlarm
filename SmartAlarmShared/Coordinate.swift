import CoreLocation
import Foundation

/// A plain lat/lon pair. Deliberately not `CLLocationCoordinate2D` so that the logic
/// layer, the persistence layer and the widget can all share it without importing MapKit.
struct Coordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    func distance(to other: Coordinate) -> CLLocationDistance {
        clLocation.distance(from: other.clLocation)
    }

    /// Rounded to ~110 m so that trivially different start points (a driveway vs. the street)
    /// still aggregate into the same historical bucket.
    var routeComponent: String {
        String(format: "%.3f,%.3f", latitude, longitude)
    }

    static func routeKey(from origin: Coordinate, to destination: Coordinate) -> String {
        "\(origin.routeComponent)>\(destination.routeComponent)"
    }
}
