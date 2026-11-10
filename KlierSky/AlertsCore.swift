import Foundation

// Official alerts from the US National Weather Service public API.
// Coverage is the United States and its territories only. Alerts are checked
// when the app refreshes; this is not push delivery and must not be relied on
// as the only warning channel.
struct WeatherAlert: Codable, Identifiable, Equatable {
    let id: String
    let event: String
    var headline: String? = nil
    var description: String? = nil
    var instruction: String? = nil
    var severity: String = "Unknown"       // Extreme, Severe, Moderate, Minor, Unknown (issuer's value)
    var urgency: String? = nil
    var certainty: String? = nil
    var sender: String? = nil              // issuing office
    var area: String? = nil
    var sent: Date? = nil
    var onset: Date? = nil
    var expires: Date? = nil               // when this message expires
    var ends: Date? = nil                  // when the event itself is expected to end, if the issuer says
    var endTime: Date? { ends ?? expires }
    func isCurrent(_ now: Date) -> Bool { (endTime ?? .distantFuture) > now }
    var rank: Int { ["Extreme": 0, "Severe": 1, "Moderate": 2, "Minor": 3][severity] ?? 4 }
}

struct AlertFeed: Codable, Equatable {
    enum Coverage: String, Codable { case covered, outside, unknown }
    var placeID: String
    var coverage: Coverage = .unknown
    var alerts: [WeatherAlert] = []
    var fetchedAt: Date? = nil             // last successful check
    var failed = false                     // latest check failed; `alerts` may be old
    /// Unexpired alerts, most severe first.
    func current(_ now: Date = Date()) -> [WeatherAlert] {
        alerts.filter { $0.isCurrent(now) }.sorted { ($0.rank, $0.onset ?? $0.sent ?? .distantPast) < ($1.rank, $1.onset ?? $1.sent ?? .distantPast) }
    }
    /// True when the list cannot be trusted as the present situation.
    func isStale(_ now: Date = Date()) -> Bool { failed || fetchedAt == nil || now.timeIntervalSince(fetchedAt!) > 1800 }
}

enum NWSAlerts {
    /// Rough pre-filter so coordinates far from US coverage are never sent to the NWS.
    static func mayCover(latitude: Double, longitude: Double) -> Bool {
        let boxes: [(ClosedRange<Double>, ClosedRange<Double>)] = [
            (24.0...49.6, -125.5...(-66.5)),      // contiguous states
            (51.0...71.6, -180.0...(-129.5)),     // Alaska
            (51.0...55.5, 172.0...180.0),         // western Aleutians
            (18.5...22.6, -160.8...(-154.5)),     // Hawaii
            (17.5...18.7, -67.6...(-64.4)),       // Puerto Rico, US Virgin Islands
            (13.0...20.8, 144.4...146.3),         // Guam, Northern Marianas
            (-14.8...(-10.8), -171.3...(-168.0))  // American Samoa
        ]
        return boxes.contains { $0.0.contains(latitude) && $0.1.contains(longitude) }
    }
    static func activeURL(latitude: Double, longitude: Double) -> URL {
        URL(string: String(format: "https://api.weather.gov/alerts/active?status=actual&point=%.4f,%.4f", latitude, longitude))!
    }
    static func pointURL(latitude: Double, longitude: Double) -> URL {
        URL(string: String(format: "https://api.weather.gov/points/%.4f,%.4f", latitude, longitude))!
    }
    private struct Collection: Decodable {
        struct Feature: Decodable {
            struct Properties: Decodable {
                let id: String?; let event: String?; let headline: String?; let description: String?; let instruction: String?
                let severity: String?; let urgency: String?; let certainty: String?; let senderName: String?; let areaDesc: String?
                let sent: String?; let onset: String?; let expires: String?; let ends: String?
                let status: String?; let messageType: String?
            }
            let properties: Properties
        }
        let features: [Feature]
    }
    /// NWS text is hard-wrapped at about 70 columns. Join wrapped lines; keep paragraph breaks. Wording is unchanged.
    static func unwrap(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.components(separatedBy: "\n\n").map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }.joined(separator: "\n\n")
    }
    /// Decodes an NWS alert collection. Tests, drafts, exercises and cancellations are dropped.
    static func decode(_ data: Data) throws -> [WeatherAlert] {
        let collection = try JSONDecoder().decode(Collection.self, from: data)
        let formatter = ISO8601DateFormatter()
        func date(_ value: String?) -> Date? { value.flatMap { formatter.date(from: $0) } }
        func text(_ value: String?, limit: Int) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return String(value.prefix(limit))
        }
        var seen = Set<String>()
        return collection.features.prefix(60).compactMap { feature in
            let p = feature.properties
            guard p.status == "Actual", p.messageType != "Cancel", let id = text(p.id, limit: 200), let event = text(p.event, limit: 120), seen.insert(id).inserted else { return nil }
            return WeatherAlert(id: id, event: event, headline: text(p.headline, limit: 400), description: unwrap(text(p.description, limit: 8000)), instruction: unwrap(text(p.instruction, limit: 4000)),
                                severity: text(p.severity, limit: 20) ?? "Unknown", urgency: text(p.urgency, limit: 20), certainty: text(p.certainty, limit: 20), sender: text(p.senderName, limit: 120), area: text(p.areaDesc, limit: 600),
                                sent: date(p.sent), onset: date(p.onset), expires: date(p.expires), ends: date(p.ends))
        }
    }
}

/// Modelled air quality from Open-Meteo (CAMS). A regional model estimate, not a nearby sensor.
struct AirQuality: Codable, Equatable {
    let usAQI: Double
    let time: Date
    var category: String {
        switch usAQI {
        case ..<51: return "Good"
        case ..<101: return "Moderate"
        case ..<151: return "Unhealthy for sensitive groups"
        case ..<201: return "Unhealthy"
        case ..<301: return "Very unhealthy"
        default: return "Hazardous"
        }
    }
    private struct Reply: Decodable { struct Current: Decodable { let time: Double; let us_aqi: Double? }; let current: Current }
    static func decode(_ data: Data) -> AirQuality? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), let value = reply.current.us_aqi, value.isFinite, value >= 0 else { return nil }
        return AirQuality(usAQI: value, time: Date(timeIntervalSince1970: reply.current.time))
    }
    static func url(latitude: Double, longitude: Double) -> URL {
        URL(string: String(format: "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=%.3f&longitude=%.3f&current=us_aqi&timeformat=unixtime", latitude, longitude))!
    }
}
