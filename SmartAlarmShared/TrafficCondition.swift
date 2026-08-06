import Foundation

/// MapKit exposes no congestion field, so "how bad is traffic" is derived by comparing the
/// live estimate against a cached free-flow baseline for the same route.
/// See `RouteBaseline` for how the baseline is captured.
enum TrafficCondition: String, Codable, Hashable, Sendable, CaseIterable {
    case light
    case moderate
    case heavy
    case unknown

    /// Ratio thresholds against free-flow travel time.
    static let moderateThreshold = 1.15
    static let heavyThreshold = 1.40

    static func classify(observedSeconds: Double, freeFlowSeconds: Double?) -> TrafficCondition {
        guard let freeFlowSeconds, freeFlowSeconds > 0 else { return .unknown }
        let ratio = observedSeconds / freeFlowSeconds
        if ratio < moderateThreshold { return .light }
        if ratio < heavyThreshold { return .moderate }
        return .heavy
    }

    var label: String {
        switch self {
        case .light: "Light traffic"
        case .moderate: "Moderate traffic"
        case .heavy: "Heavy traffic"
        case .unknown: "Traffic unknown"
        }
    }

    var shortLabel: String {
        switch self {
        case .light: "Light"
        case .moderate: "Moderate"
        case .heavy: "Heavy"
        case .unknown: "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .light: "car"
        case .moderate: "car.2"
        case .heavy: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}
