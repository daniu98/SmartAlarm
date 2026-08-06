import Foundation
import WeatherKit

protocol WeatherProviding: Sendable {
    /// Forecast conditions at `date`, at the departure point.
    func impact(at coordinate: Coordinate, on date: Date) async -> WeatherImpact
}

/// WeatherKit-backed forecast lookup.
///
/// Total rather than throwing, like the calendar provider: weather is an *enhancement* to the
/// estimate, never a precondition. WeatherKit needs its own capability on the App ID, so on an
/// unsigned build it simply fails — and failing means "no extra padding", which is the same
/// answer as a clear morning. It can never block a check.
struct WeatherKitProvider: WeatherProviding {
    func impact(at coordinate: Coordinate, on date: Date) async -> WeatherImpact {
        do {
            let forecast = try await WeatherService.shared.weather(
                for: coordinate.clLocation,
                including: .hourly
            )
            guard let hour = Self.closestHour(in: Array(forecast), to: date) else {
                return .clear
            }
            let weather = Self.classify(hour)
            guard weather.affectsDriving else { return .clear }
            return WeatherImpact(
                weather: weather,
                detail: "\(hour.condition.description) at \(hour.date.formatted(date: .omitted, time: .shortened))"
            )
        } catch {
            AppLogger.traffic.notice(
                "Weather unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return .clear
        }
    }

    static func closestHour(in hours: [HourWeather], to date: Date) -> HourWeather? {
        hours.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    /// Maps WeatherKit's 30-odd conditions onto the handful that change a drive time.
    /// Worst-case wins: sleet mixed with rain is treated as ice.
    static func classify(_ hour: HourWeather) -> DrivingWeather {
        switch hour.condition {
        case .freezingRain, .freezingDrizzle, .sleet, .hail, .wintryMix, .frigid:
            return .ice
        case .snow, .heavySnow, .blizzard, .blowingSnow, .flurries, .sunFlurries:
            return .snow
        case .heavyRain, .thunderstorms, .strongStorms, .isolatedThunderstorms,
             .scatteredThunderstorms, .tropicalStorm, .hurricane:
            return .heavyRain
        case .foggy, .haze, .smoky, .blowingDust:
            return .fog
        case .rain, .drizzle, .sunShowers:
            return .wet
        case .windy, .breezy:
            return .wind
        default:
            // Rain can be forecast without the condition itself saying so.
            return hour.precipitationChance >= 0.5 ? .wet : .clear
        }
    }
}

/// Used when the weather feature is switched off.
struct DisabledWeatherProvider: WeatherProviding {
    func impact(at coordinate: Coordinate, on date: Date) async -> WeatherImpact { .clear }
}
