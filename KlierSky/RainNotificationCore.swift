import Foundation

struct RainNotificationPlan: Equatable {
    let start: Date
    let fire: Date
    let chance: Double
    let source: String
    let precipitation: String

    /// Hourly amounts are hourly forecasts. The alert preserves that precision.
    static func next(hours: [Hour], now: Date, leadMinutes: Int, minimumChance: Double) -> Self? {
        let ordered = hours.sorted { $0.time < $1.time }
        var previous: Hour?
        for hour in ordered {
            defer { previous = hour }
            guard hour.time > now, hour.time <= now.addingTimeInterval(12 * 3600),
                  hour.rain.isFinite, hour.rain >= 0.1,
                  hour.chance.isFinite, hour.chance >= minimumChance else { continue }
            // A wet interval already in progress is not a new onset.
            if let previous, hour.time.timeIntervalSince(previous.time) <= 5400,
               previous.rain >= 0.1, previous.chance >= minimumChance { continue }
            let fire = max(now.addingTimeInterval(5), hour.time.addingTimeInterval(-Double(leadMinutes) * 60))
            return Self(start: hour.time, fire: fire, chance: hour.chance,
                        source: hour.source ?? "Forecast", precipitation: WeatherCode.precipitationWord(hour.code))
        }
        return nil
    }
}
