import Foundation

/// How much of the route's historical spread to absorb into the estimate.
///
/// The whole app is built around asymmetric risk: waking early is cheap, waking late is a
/// failure. Posture is the single dial that expresses how much you're willing to pay in
/// sleep for that insurance.
enum ReliabilityPosture: String, Codable, CaseIterable, Sendable {
    /// Median estimate. Maximum sleep; late whenever traffic is worse than typical.
    case relaxed
    /// On time roughly four mornings in five. The default.
    case balanced
    /// Rarely late, routinely early.
    case cautious

    /// The historical percentile this posture targets.
    var percentile: Double {
        switch self {
        case .relaxed: 0.50
        case .balanced: 0.80
        case .cautious: 0.90
        }
    }

    /// Multiplier applied to the observed historical spread (p_target − p50).
    var spreadWeight: Double {
        switch self {
        case .relaxed: 0.0
        case .balanced: 1.0
        case .cautious: 1.0
        }
    }

    /// Used when the calendar flags a high-stakes morning. Importance may only make the
    /// app *more* conservative, never less.
    var escalated: ReliabilityPosture {
        switch self {
        case .relaxed: .balanced
        case .balanced: .cautious
        case .cautious: .cautious
        }
    }

    var label: String {
        switch self {
        case .relaxed: "Relaxed"
        case .balanced: "Balanced"
        case .cautious: "Cautious"
        }
    }

    var detail: String {
        switch self {
        case .relaxed: "Wake at the typical drive time. Most sleep, late more often."
        case .balanced: "On time about 4 mornings in 5."
        case .cautious: "Rarely late, but you'll often arrive early."
        }
    }
}
