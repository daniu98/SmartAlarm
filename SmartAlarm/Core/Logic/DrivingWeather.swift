import Foundation

/// Weather reduced to the only question this app cares about: how much longer will the drive
/// take?
///
/// This matters because map providers' predictive models lean on *historical* patterns for a
/// departure hours away, and history doesn't know that it will be sleeting tomorrow morning.
/// The forecast is the one input that reliably leads the traffic model rather than trailing it.
enum DrivingWeather: String, Codable, Sendable, CaseIterable, Hashable {
    case clear
    case wind
    case wet
    case fog
    case heavyRain
    case snow
    case ice

    /// Fraction added to the drive estimate. Deliberately conservative rather than precise:
    /// these are the difference between arriving early and sliding into a meeting late.
    var padFraction: Double {
        switch self {
        case .clear: 0.0
        case .wind: 0.03
        case .wet: 0.06
        case .fog: 0.10
        case .heavyRain: 0.15
        case .snow: 0.25
        case .ice: 0.35
        }
    }

    var label: String {
        switch self {
        case .clear: "Clear"
        case .wind: "Windy"
        case .wet: "Wet roads"
        case .fog: "Poor visibility"
        case .heavyRain: "Heavy rain"
        case .snow: "Snow"
        case .ice: "Ice"
        }
    }

    var symbolName: String {
        switch self {
        case .clear: "sun.max"
        case .wind: "wind"
        case .wet: "cloud.rain"
        case .fog: "cloud.fog"
        case .heavyRain: "cloud.heavyrain"
        case .snow: "cloud.snow"
        case .ice: "thermometer.snowflake"
        }
    }

    var affectsDriving: Bool { self != .clear }
}

struct WeatherImpact: Sendable, Hashable {
    var weather: DrivingWeather
    /// What the forecast said, for display: "Heavy rain at 7:45 AM".
    var detail: String?

    static let clear = WeatherImpact(weather: .clear, detail: nil)

    var padFraction: Double { weather.padFraction }
}
