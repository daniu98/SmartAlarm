import Foundation
import SwiftData

/// A recorded drive-time observation, keyed by route, weekday and time of day.
///
/// Samples come from the check taken closest to departure, which is the nearest thing to
/// ground truth this app has without tracking your location.
@Model
final class TravelSample {
    var routeKey: String
    /// Calendar convention: 1 = Sunday ... 7 = Saturday.
    var weekday: Int
    var minuteOfDay: Int
    var seconds: Double
    var recordedAt: Date

    init(routeKey: String, weekday: Int, minuteOfDay: Int, seconds: Double, recordedAt: Date = .now) {
        self.routeKey = routeKey
        self.weekday = weekday
        self.minuteOfDay = minuteOfDay
        self.seconds = seconds
        self.recordedAt = recordedAt
    }

    /// Samples older than this are pruned: a commute changes, and a two-year-old observation
    /// is worse than no observation.
    static let retentionWeeks = 12
    static var retentionInterval: TimeInterval { Double(retentionWeeks) * 7 * 24 * 60 * 60 }

    var modelSample: HistoricalTravelModel.Sample {
        HistoricalTravelModel.Sample(
            weekday: weekday,
            minuteOfDay: minuteOfDay,
            seconds: seconds,
            recordedAt: recordedAt
        )
    }
}

/// Cached free-flow travel time for a route, used to turn a raw ETA into a light/moderate/heavy
/// classification. MapKit has no congestion field, so this comparison is the only honest way
/// to say how bad traffic actually is.
@Model
final class RouteBaseline {
    @Attribute(.unique) var routeKey: String
    var freeFlowSeconds: Double
    var distanceMeters: Double
    var updatedAt: Date

    init(routeKey: String, freeFlowSeconds: Double, distanceMeters: Double, updatedAt: Date = .now) {
        self.routeKey = routeKey
        self.freeFlowSeconds = freeFlowSeconds
        self.distanceMeters = distanceMeters
        self.updatedAt = updatedAt
    }

    static let refreshInterval: TimeInterval = 30 * 24 * 60 * 60

    func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.refreshInterval
    }
}
