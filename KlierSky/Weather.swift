import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession on Linux, so the portable checks also run off the Mac
#endif

struct Place: Codable, Identifiable, Hashable {
    var id: String { "\(latitude),\(longitude)" }
    let name: String
    let latitude: Double
    let longitude: Double
    static let presets = [Place(name: "Denver", latitude: 39.7392, longitude: -104.9903), Place(name: "Milwaukee", latitude: 43.0389, longitude: -87.9065), Place(name: "Seattle", latitude: 47.6062, longitude: -122.3321), Place(name: "New York", latitude: 40.7128, longitude: -74.006)]
}
enum FrameKind: String, Codable { case observed, nowcast, forecast }
struct WeatherFrame: Codable, Identifiable, Equatable {
    let id: String
    let validTime: Date
    let issuedTime: Date
    let kind: FrameKind
    let tileURL: String
    let attribution: String
    let maxZoom: Int
    var minZoom: Int? = nil
    var timeLabel: String? = nil
    var expiresAt: Date? = nil
    var tileSize: Int? = nil
    var isStale: Bool { Date().timeIntervalSince(issuedTime) > 3600 }
}
protocol RadarProvider { func frames() async throws -> [WeatherFrame] }
struct RainViewerProvider: RadarProvider {
    struct Response: Decodable {
        struct Radar: Decodable { let past: [Frame] }
        struct Frame: Decodable { let time: Double; let path: String }
        let host: String; let generated: Double; let radar: Radar
    }
    func frames() async throws -> [WeatherFrame] {
        let r: Response = try await Network.get(URL(string: "https://api.rainviewer.com/public/weather-maps.json")!)
        guard URL(string: r.host)?.scheme == "https" else { throw URLError(.badServerResponse) }
        return r.radar.past.sorted { $0.time < $1.time }.map {
            WeatherFrame(id: $0.path, validTime: Date(timeIntervalSince1970: $0.time), issuedTime: Date(timeIntervalSince1970: r.generated), kind: .observed, tileURL: "\(r.host)\($0.path)/512/{z}/{x}/{y}/2/1_1.png", attribution: "RainViewer", maxZoom: 7, tileSize: 512)
        }
    }
}
// A licensed server normalizes provider capabilities and holds all vendor credentials.
// This adapter deliberately never synthesizes future frames from observations.
struct LicensedRadarProvider: RadarProvider {
    let endpoint: URL
    func frames() async throws -> [WeatherFrame] {
        guard endpoint.scheme == "https" else { throw URLError(.secureConnectionFailed) }
        let frames: [WeatherFrame] = try await Network.get(endpoint)
        guard frames.count <= 300, frames.allSatisfy({ URL(string: $0.tileURL.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))?.scheme == "https" && (0...22).contains($0.maxZoom) && ($0.kind != .observed || $0.validTime <= Date()) }) else { throw URLError(.cannotParseResponse) }
        return frames.sorted { $0.validTime < $1.validTime }
    }
}
enum Network {
    static let userAgent = "KlierSky/0.4 personal testing"
    static func get<T: Decodable>(_ url: URL, bearer: String? = nil, timeout: TimeInterval = 20, accept: String? = nil) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let bearer, !bearer.isEmpty { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        guard status == 200 else { throw HTTPFailure(status: status, code: HTTPFailure.code(in: data)) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
/// A non-200 reply. `code` is the service's short machine-readable reason when it sent one.
struct HTTPFailure: Error, Equatable {
    let status: Int
    let code: String
    static func code(in data: Data) -> String {
        struct Body: Decodable { let error: String? }
        guard data.count <= 4096, let value = try? JSONDecoder().decode(Body.self, from: data).error else { return "" }
        return String(value.prefix(64))
    }
}
struct Forecast: Codable {
    struct Current: Codable { let temperature_2m: Double; let apparent_temperature: Double; let weather_code: Int; let wind_speed_10m: Double; let is_day: Int?; var summary: String? = nil
        var relative_humidity_2m: Double? = nil
        var dew_point_2m: Double? = nil
        var wind_gusts_10m: Double? = nil
        var wind_direction_10m: Double? = nil
        var pressure_msl: Double? = nil
        var cloud_cover: Double? = nil
        var visibility: Double? = nil
    }
    struct Hourly: Codable { let time: [Double]; let temperature_2m: [Double?]; let precipitation_probability: [Double?]; let precipitation: [Double?]; let weather_code: [Int?]?; let is_day: [Int?]?
        var relative_humidity_2m: [Double?]? = nil
        var dew_point_2m: [Double?]? = nil
        var wind_speed_10m: [Double?]? = nil
        var wind_gusts_10m: [Double?]? = nil
        var wind_direction_10m: [Double?]? = nil
        var pressure_msl: [Double?]? = nil
        var cloud_cover: [Double?]? = nil
        var visibility: [Double?]? = nil
        var uv_index: [Double?]? = nil
        var apparent_temperature: [Double?]? = nil
    }
    var timezone: String? = nil
    var utc_offset_seconds: Int? = nil
    var daily: Daily? = nil
    var dailyRows: [DayForecast]? = nil
    var source: String? = nil
    let current: Current
    let hourly: Hourly
    var hours: [Hour] { hours(relativeTo: Date()) }
    func hours(relativeTo now: Date) -> [Hour] {
        hourly.time.indices.compactMap { i in
            guard hourly.temperature_2m.indices.contains(i), hourly.precipitation.indices.contains(i), hourly.precipitation_probability.indices.contains(i), let t = hourly.temperature_2m[i], let rain = hourly.precipitation[i], let chance = hourly.precipitation_probability[i] else { return nil }
            return Hour(time: Date(timeIntervalSince1970: hourly.time[i]), temperature: t, rain: rain, chance: chance, code: hourly.weather_code.flatMap { $0.indices.contains(i) ? $0[i] : nil }, daylight: hourly.is_day.flatMap { $0.indices.contains(i) ? $0[i] : nil } != 0, source: source ?? "Open-Meteo", humidity: hourly.relative_humidity_2m.at(i), dewPoint: hourly.dew_point_2m.at(i), wind: hourly.wind_speed_10m.at(i), gust: hourly.wind_gusts_10m.at(i), windDirection: hourly.wind_direction_10m.at(i), pressure: hourly.pressure_msl.at(i), clouds: hourly.cloud_cover.at(i), visibility: hourly.visibility.at(i), uv: hourly.uv_index.at(i), feels: hourly.apparent_temperature.at(i))
        }.filter { $0.time > now.addingTimeInterval(-3600) }.prefix(168).map { $0 }
    }
    func validated(now: Date = Date()) throws -> Forecast {
        let count = hourly.time.count
        guard count > 0, count <= 400, hourly.temperature_2m.count == count, hourly.precipitation.count == count, hourly.precipitation_probability.count == count,
              zip(hourly.time, hourly.time.dropFirst()).allSatisfy({ $0 < $1 }),
              current.temperature_2m.isFinite, current.apparent_temperature.isFinite, current.wind_speed_10m.isFinite,
              hours(relativeTo: now).count >= 12,
              hours(relativeTo: now).allSatisfy({ $0.temperature.isFinite && $0.rain.isFinite && $0.chance.isFinite && $0.rain >= 0 && (0...100).contains($0.chance) }) else { throw URLError(.cannotParseResponse) }
        return self
    }
    static func load(_ place: Place, days: Int = 14, detailed: Bool = true, timeout: TimeInterval = 20) async throws -> Forecast {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let current = "temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day" + (detailed ? ",relative_humidity_2m,wind_gusts_10m,wind_direction_10m,pressure_msl,cloud_cover" : "")
        let hourly = "temperature_2m,precipitation_probability,precipitation,weather_code,is_day" + (detailed ? ",apparent_temperature,relative_humidity_2m,dew_point_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m,pressure_msl,cloud_cover,visibility,uv_index" : "")
        let daily = "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max" + (detailed ? ",apparent_temperature_max,apparent_temperature_min,sunrise,sunset,daylight_duration,uv_index_max,wind_speed_10m_max,wind_gusts_10m_max" : "")
        components.queryItems = ["latitude":String(place.latitude), "longitude":String(place.longitude), "current":current, "hourly":hourly, "daily":daily, "temperature_unit":"fahrenheit", "wind_speed_unit":"mph", "timeformat":"unixtime", "timezone":"auto", "forecast_days":String(min(14,max(2,days)))].map { URLQueryItem(name:$0.key,value:$0.value) }
        let value: Forecast = try await Network.get(components.url!, timeout: timeout)
        return try value.validated()
    }
}
struct Hour: Codable, Identifiable { var id: Date { time }; let time: Date; var temperature: Double; let rain: Double; let chance: Double; let code: Int?; let daylight: Bool; var source: String? = nil
    var humidity: Double? = nil; var dewPoint: Double? = nil
    var wind: Double? = nil; var gust: Double? = nil; var windDirection: Double? = nil
    var pressure: Double? = nil; var clouds: Double? = nil; var visibility: Double? = nil; var uv: Double? = nil
    var feels: Double? = nil
}

/// Which forecast is shown and how it is labelled. Pure, so provider switching is covered by the portable checks.
enum ProviderChoice {
    struct Result: Equatable {
        let source: String?         // nil: nothing arrived this refresh
        let status: String          // label shown under each section
        let isFallback: Bool        // the preferred source was expected and did not arrive
    }
    /// - Parameters:
    ///   - available: sources that returned a valid forecast this refresh, in arrival order.
    ///   - preferred: the source the user asked for.
    ///   - forecaConnected: this install holds usable access to the Foreca service.
    ///   - saved: source of a saved forecast still on screen, if any.
    static func pick(available: [String], preferred: String, forecaConnected: Bool, saved: String? = nil) -> Result {
        guard let chosen = available.contains(preferred) ? preferred : available.first else {
            // Nothing arrived. A saved forecast keeps its real source name; it is never relabelled.
            return Result(source: nil, status: saved.map { $0 + " · saved" } ?? "Offline", isFallback: false)
        }
        if chosen == preferred { return Result(source: chosen, status: chosen, isFallback: false) }
        // "Fallback" only when the preferred source was actually expected and did not arrive.
        if preferred != "Foreca" || forecaConnected { return Result(source: chosen, status: chosen + " · fallback", isFallback: true) }
        return Result(source: chosen, status: chosen + " · Foreca not connected", isFallback: false)
    }
}

// Select actual provider frames; never invent intermediate weather images.
enum ForecastTimeline {
    static func select(_ frames: [WeatherFrame], now: Date = Date()) -> [WeatherFrame] {
        let candidates = frames.filter { $0.kind != .observed && $0.validTime >= now && $0.validTime <= now.addingTimeInterval(24 * 3600) && ($0.expiresAt == nil || $0.expiresAt! > now) }.sorted { $0.validTime < $1.validTime }
        var result: [WeatherFrame] = []
        for frame in candidates {
            let lead = frame.validTime.timeIntervalSince(now)
            let spacing: TimeInterval = lead <= 3600 ? 300 : lead <= 6 * 3600 ? 900 : 3600
            if let last = result.last, frame.validTime.timeIntervalSince(last.validTime) < spacing { continue }
            result.append(frame)
        }
        return Array(result.prefix(72))
    }
}

// Optional fields remain missing when a provider does not supply them.
extension Optional where Wrapped == [Double?] {
    func at(_ index: Int) -> Double? { guard let values = self, values.indices.contains(index), let value = values[index], value.isFinite else { return nil }; return value }
}
struct DayForecast: Codable, Identifiable {
    var id: String { dateKey }
    let dateKey: String
    var low: Double? = nil; var high: Double? = nil; var code: Int? = nil
    var rain: Double? = nil; var chance: Double? = nil
    var wind: Double? = nil; var gust: Double? = nil; var uv: Double? = nil
    var sunrise: Double? = nil; var sunset: Double? = nil; var daylightSeconds: Double? = nil
    var sunriseLocal: String? = nil; var sunsetLocal: String? = nil
    var feelsLow: Double? = nil; var feelsHigh: Double? = nil
    var source: String? = nil
    var probabilityLabel: String = "Provider daily probability"
    var highP25: Double? = nil; var highP75: Double? = nil
    var summary: String? = nil
    var date: Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: dateKey)
    }
}
extension Forecast {
    struct Daily: Codable {
        let time: [Double]
        var temperature_2m_max: [Double?]? = nil; var temperature_2m_min: [Double?]? = nil
        var weather_code: [Int?]? = nil
        var precipitation_sum: [Double?]? = nil; var precipitation_probability_max: [Double?]? = nil
        var wind_speed_10m_max: [Double?]? = nil; var wind_gusts_10m_max: [Double?]? = nil
        var uv_index_max: [Double?]? = nil
        var sunrise: [Double?]? = nil; var sunset: [Double?]? = nil; var daylight_duration: [Double?]? = nil
        var apparent_temperature_min: [Double?]? = nil; var apparent_temperature_max: [Double?]? = nil
    }
    var forecastTimeZone: TimeZone { timezone.flatMap(TimeZone.init(identifier:)) ?? utc_offset_seconds.flatMap(TimeZone.init(secondsFromGMT:)) ?? .current }
    var days: [DayForecast] {
        if let dailyRows { return dailyRows.filter { $0.date != nil }.sorted { $0.dateKey < $1.dateKey } }
        guard let daily else { return [] }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = forecastTimeZone; formatter.dateFormat = "yyyy-MM-dd"
        return daily.time.indices.map { i in
            DayForecast(dateKey: formatter.string(from: Date(timeIntervalSince1970: daily.time[i])), low: daily.temperature_2m_min.at(i), high: daily.temperature_2m_max.at(i), code: daily.weather_code.flatMap { $0.indices.contains(i) ? $0[i] : nil }, rain: daily.precipitation_sum.at(i), chance: daily.precipitation_probability_max.at(i), wind: daily.wind_speed_10m_max.at(i), gust: daily.wind_gusts_10m_max.at(i), uv: daily.uv_index_max.at(i), sunrise: daily.sunrise.at(i), sunset: daily.sunset.at(i), daylightSeconds: daily.daylight_duration.at(i), feelsLow: daily.apparent_temperature_min.at(i), feelsHigh: daily.apparent_temperature_max.at(i), source: source ?? "Open-Meteo", probabilityLabel: "Peak hourly rain probability")
        }
    }
    func hours(on day: DayForecast) -> [Hour] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = forecastTimeZone; formatter.dateFormat = "yyyy-MM-dd"
        return hours.filter { formatter.string(from: $0.time) == day.dateKey }
    }
}

enum TrendMetric: String {
    case rain, wind, temperature, probability
    static func isComplete(_ hours: [Hour]) -> Bool {
        guard hours.count == 12 else { return false }
        for index in 1..<hours.count {
            let spacing = hours[index].time.timeIntervalSince(hours[index - 1].time)
            if abs(spacing - 3600) >= 60 { return false }
        }
        return true
    }
    static func choose(_ hours: [Hour]) -> TrendMetric {
        guard isComplete(hours) else { return .rain }
        let peak = hours.map(\.rain).max() ?? 0
        let chance = hours.map(\.chance).max() ?? 0
        if peak > 0 { return .rain }
        if chance >= 20 { return .probability }
        return hours.allSatisfy { TrendMetric.wind.value($0,celsius:false) != nil } ? .wind : .temperature
    }
    func value(_ hour: Hour, celsius: Bool) -> Double? {
        switch self {
        case .rain: return hour.rain
        case .wind: return hour.wind.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        case .temperature: return celsius ? (hour.temperature-32)*5/9 : hour.temperature
        case .probability: return hour.chance
        }
    }
}

/// Presentation of provider condition codes (WMO-style). One mapping for app and widgets.
enum WeatherCode {
    enum Kind: String { case clear, mostlyClear, partlyCloudy, overcast, fog, drizzle, rain, heavyRain, sleet, snow, showers, snowShowers, thunder, unknown }
    static func kind(_ code: Int?) -> Kind {
        guard let code, code >= 0 else { return .unknown }
        switch code {
        case 0: return .clear
        case 1: return .mostlyClear
        case 2: return .partlyCloudy
        case 3: return .overcast
        case 4...49: return .fog
        case 50...59: return .drizzle
        case 60...63: return .rain
        case 64, 65: return .heavyRain
        case 66...69: return .sleet
        case 70...79: return .snow
        case 80: return .showers
        case 81...84: return .heavyRain
        case 85...94: return .snowShowers
        default: return .thunder
        }
    }
    static func symbol(_ code: Int?, day: Bool = true) -> String {
        switch kind(code) {
        case .clear: return day ? "sun.max.fill" : "moon.stars.fill"
        case .mostlyClear, .partlyCloudy: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain, .showers: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .sleet: return "cloud.sleet.fill"
        case .snow, .snowShowers: return "cloud.snow.fill"
        case .thunder: return "cloud.bolt.rain.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    static func text(_ code: Int?) -> String {
        switch kind(code) {
        case .clear: return "Clear"
        case .mostlyClear: return "Mostly clear"
        case .partlyCloudy: return "Partly cloudy"
        case .overcast: return "Overcast"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy rain"
        case .sleet: return "Wintry mix"
        case .snow: return "Snow"
        case .showers: return "Showers"
        case .snowShowers: return "Snow showers"
        case .thunder: return "Thunderstorms"
        case .unknown: return "Conditions unavailable"
        }
    }
    /// Word used in outlook sentences for the precipitation type the provider's code indicates.
    static func precipitationWord(_ code: Int?) -> String {
        switch kind(code) {
        case .snow, .snowShowers: return "Snow"
        case .sleet: return "Wintry mix"
        case .thunder: return "Thunderstorms"
        default: return "Rain"
        }
    }
}

/// One plain sentence about the next hours, taken directly from the provider's
/// hourly values. Hour granularity only: it never implies minute-level timing.
enum Outlook {
    static func sentence(_ hours: [Hour], label: (Date) -> String) -> String? {
        let window = Array(hours.prefix(12))
        guard window.count >= 6 else { return nil }
        func wet(_ h: Hour) -> Bool { h.rain >= 0.1 }
        let span = window.count == 12 && TrendMetric.isComplete(window) ? "the next 12 hours" : "the hours shown"
        if wet(window[0]) {
            let word = WeatherCode.precipitationWord(window[0].code)
            if let end = window.dropFirst().first(where: { !wet($0) && $0.chance < 30 }) { return "\(word) this hour, easing around \(label(end.time))." }
            return "\(word) continuing through \(span)."
        }
        if let start = window.dropFirst().first(where: { wet($0) || $0.chance >= 50 }) {
            return "\(WeatherCode.precipitationWord(start.code)) \(start.chance >= 50 ? "likely" : "possible") around \(label(start.time)) (\(Int(start.chance.rounded()))%)."
        }
        if let maybe = window.dropFirst().first(where: { $0.chance >= 30 }) {
            return "Chance of \(WeatherCode.precipitationWord(maybe.code).lowercased()) around \(label(maybe.time)) (\(Int(maybe.chance.rounded()))%)."
        }
        return "No precipitation expected in \(span)."
    }
}
