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
    /// Present only when this forecast is a weighted blend of several sources.
    var blend: BlendInfo? = nil
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

// MARK: - Multi-source blend
//
// KlierSky can combine every source it can reach into one forecast: each value
// is the weighted average of the sources that actually supplied it for that
// hour. Nothing is invented: a value no source supplied stays missing, and the
// result is always labelled as a blend with its members and their weights.
// Weights start from a stated ranking and are replaced by measured ones when
// the station verification in AdaptiveCore has enough evidence.

/// One hour from one source. Every field is optional: sources differ in what they publish.
struct SeriesHour: Equatable {
    var temperature: Double? = nil, feels: Double? = nil
    var chance: Double? = nil, rain: Double? = nil
    var humidity: Double? = nil, dewPoint: Double? = nil
    var wind: Double? = nil, gust: Double? = nil, windDirection: Double? = nil
    var pressure: Double? = nil, clouds: Double? = nil, visibility: Double? = nil, uv: Double? = nil
    var code: Int? = nil, daylight: Bool? = nil
}
/// A source's forecast in common units: °F, mph, mm, hPa, percent, metres.
struct SourceSeries {
    let source: String
    var hours: [Date: SeriesHour] = [:]
    var current: Forecast.Current? = nil
    var days: [DayForecast] = []
    var timezone: String? = nil
    var utcOffset: Int? = nil
}
extension SourceSeries {
    init(_ forecast: Forecast) {
        source = forecast.source ?? "Open-Meteo"
        current = forecast.current; days = forecast.days; timezone = forecast.timezone; utcOffset = forecast.utc_offset_seconds
        let h = forecast.hourly
        func int(_ values: [Int?]?, _ i: Int) -> Int? { values.flatMap { $0.indices.contains(i) ? $0[i] : nil } }
        for i in h.time.indices {
            let code = int(h.weather_code, i)
            hours[Date(timeIntervalSince1970: h.time[i])] = SeriesHour(
                temperature: Optional(h.temperature_2m).at(i), feels: h.apparent_temperature.at(i), chance: Optional(h.precipitation_probability).at(i), rain: Optional(h.precipitation).at(i),
                humidity: h.relative_humidity_2m.at(i), dewPoint: h.dew_point_2m.at(i), wind: h.wind_speed_10m.at(i), gust: h.wind_gusts_10m.at(i), windDirection: h.wind_direction_10m.at(i),
                pressure: h.pressure_msl.at(i), clouds: h.cloud_cover.at(i), visibility: h.visibility.at(i), uv: h.uv_index.at(i),
                code: code.flatMap { $0 >= 0 ? $0 : nil }, daylight: int(h.is_day, i).map { $0 != 0 })
        }
    }
}

struct BlendInfo: Codable, Equatable {
    struct Member: Codable, Equatable {
        let source: String
        let share: Double       // fraction of the weight for forecasts 0–6 hours ahead, 0...1
        let measured: Bool      // true when the weight comes from scored forecasts, false for the starting ranking
    }
    var members: [Member]
    var dailySources: [String]
    var names: String { members.map(\.source).joined(separator: ", ") }
    var isMeasured: Bool { members.contains { $0.measured } }
    /// "Blend of 5 sources (starting weights)" – shown wherever a blended value appears.
    var summary: String { "Blend of \(members.count) sources (\(isMeasured ? "weights from scored forecasts" : "starting weights"))" }
    var shares: String { members.map { "\($0.source) \(Int(($0.share * 100).rounded()))%" }.joined(separator: " · ") }
}
extension Forecast {
    /// Source line for current and hourly sections.
    var sourceLine: String { blend?.summary ?? (source ?? "Open-Meteo") }
    /// Source line for the daily section: only sources that publish daily values take part there.
    var dailySourceLine: String {
        guard let blend else { return source ?? "Open-Meteo" }
        return blend.dailySources.count > 1 ? "Blend of " + blend.dailySources.joined(separator: " and ") : (blend.dailySources.first ?? "Blend")
    }
}

enum Blend {
    static let name = "Blend"
    /// Starting ranking, used until forecasts have been scored. An assumption, not a measurement:
    /// the owner's preferred commercial source first, national services and the leading global model next.
    static let priors: [String: Double] = ["Foreca": 3, "NWS": 2, "Open-Meteo": 2, "ECMWF": 2, "MET Norway": 1.5, "DWD ICON": 1.5, "NOAA GFS": 1.5, "UK Met Office": 1.5, "Météo-France": 1, "Canada GEM": 1]
    static func prior(_ source: String) -> Double { priors[source] ?? 1 }
    static func startingWeights(_ sources: [String]) -> [String: Double] { Dictionary(sources.map { ($0, prior($0)) }, uniquingKeysWith: { a, _ in a }) }
    static func bucket(_ lead: TimeInterval) -> Int { lead < 6 * 3600 ? 0 : lead < 24 * 3600 ? 1 : lead < 72 * 3600 ? 2 : 3 }

    /// Weighted mean over the members that have a value. nil when none has one.
    static func mean(_ values: [(Double?, Double)]) -> Double? {
        var sum = 0.0, total = 0.0
        for (value, weight) in values { if let value, value.isFinite, weight > 0 { sum += value * weight; total += weight } }
        return total > 0 ? sum / total : nil
    }
    /// Weighted mean of compass directions (a plain average of 350° and 10° would point south).
    static func meanDirection(_ values: [(Double?, Double)]) -> Double? {
        var x = 0.0, y = 0.0, total = 0.0
        for (value, weight) in values { if let value, value.isFinite, weight > 0 { x += cos(value * .pi / 180) * weight; y += sin(value * .pi / 180) * weight; total += weight } }
        guard total > 0, abs(x) + abs(y) > 1e-9 else { return nil }
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Combines sources into one forecast. `weights(bucket)` gives each source's weight for a lead-time
    /// group (0: under 6 h, 1: under 24 h, 2: under 3 days, 3: beyond). `measured` names sources whose
    /// weight comes from scored forecasts. Returns nil when no source can supply current conditions.
    static func combine(_ input: [SourceSeries], weights: (Int) -> [String: Double], measured: Set<String> = [], now: Date = Date()) -> Forecast? {
        // One series per source name, and only sources that carry a positive weight.
        var seen = Set<String>()
        let series = input.filter { seen.insert($0.source).inserted && !$0.hours.isEmpty }
        let near = weights(0)
        func weight(_ source: String, _ table: [String: Double]) -> Double { max(0, table[source] ?? 0) }
        let active = series.filter { weight($0.source, near) > 0 }
        guard !active.isEmpty else { return nil }
        let start = now.addingTimeInterval(-3600)
        // The hour grid comes from the source with the most hours ahead; others join where their hours coincide.
        func ahead(_ s: SourceSeries) -> Int { s.hours.keys.filter { $0 > start }.count }
        guard let anchor = active.max(by: { (ahead($0), weight($0.source, near)) < (ahead($1), weight($1.source, near)) }) else { return nil }
        let grid = anchor.hours.keys.filter { $0 > start }.sorted().prefix(168)
        let tables = (0...3).map(weights)
        let ranked = active.sorted { (weight($0.source, near), $1.source) > (weight($1.source, near), $0.source) }

        var time: [Double] = [], temperature: [Double?] = [], chance: [Double?] = [], rain: [Double?] = [], codes: [Int?] = [], day: [Int?] = []
        var feels: [Double?] = [], humidity: [Double?] = [], dew: [Double?] = [], wind: [Double?] = [], gust: [Double?] = [], direction: [Double?] = []
        var pressure: [Double?] = [], clouds: [Double?] = [], visibility: [Double?] = [], uv: [Double?] = []
        for t in grid {
            let table = tables[bucket(t.timeIntervalSince(now))]
            let rows = active.compactMap { s -> (SeriesHour, Double)? in guard let hour = s.hours[t], weight(s.source, table) > 0 else { return nil }; return (hour, weight(s.source, table)) }
            func blend(_ field: KeyPath<SeriesHour, Double?>) -> Double? { mean(rows.map { ($0.0[keyPath: field], $0.1) }) }
            guard let value = blend(\.temperature) else { continue }
            // Conditions cannot be averaged: they come from the highest-ranked source that reports them for this hour.
            let lead = ranked.first { $0.hours[t]?.code != nil }?.hours[t]
            time.append(t.timeIntervalSince1970); temperature.append(value); chance.append(blend(\.chance)); rain.append(blend(\.rain))
            codes.append(lead?.code); day.append((lead?.daylight ?? ranked.compactMap { $0.hours[t]?.daylight }.first).map { $0 ? 1 : 0 })
            feels.append(blend(\.feels)); humidity.append(blend(\.humidity)); dew.append(blend(\.dewPoint)); wind.append(blend(\.wind)); gust.append(blend(\.gust))
            direction.append(meanDirection(rows.map { ($0.0.windDirection, $0.1) }))
            pressure.append(blend(\.pressure)); clouds.append(blend(\.clouds)); visibility.append(blend(\.visibility)); uv.append(blend(\.uv))
        }
        guard !time.isEmpty else { return nil }

        // Current conditions from the sources that publish them.
        let currents = ranked.compactMap { s -> (Forecast.Current, Double)? in s.current.map { ($0, weight(s.source, near)) } }
        guard let top = currents.first?.0, let nowTemperature = mean(currents.map { ($0.0.temperature_2m, $0.1) }),
              let nowFeels = mean(currents.map { ($0.0.apparent_temperature, $0.1) }), let nowWind = mean(currents.map { ($0.0.wind_speed_10m, $0.1) }) else { return nil }
        func nowValue(_ field: KeyPath<Forecast.Current, Double?>) -> Double? { mean(currents.map { ($0.0[keyPath: field], $0.1) }) }
        let known = currents.first { $0.0.weather_code >= 0 }?.0 ?? top
        var current = Forecast.Current(temperature_2m: nowTemperature, apparent_temperature: nowFeels, weather_code: known.weather_code, wind_speed_10m: nowWind, is_day: known.is_day, summary: nil)
        current.relative_humidity_2m = nowValue(\.relative_humidity_2m); current.dew_point_2m = nowValue(\.dew_point_2m); current.wind_gusts_10m = nowValue(\.wind_gusts_10m)
        current.wind_direction_10m = meanDirection(currents.map { ($0.0.wind_direction_10m, $0.1) })
        current.pressure_msl = nowValue(\.pressure_msl); current.cloud_cover = nowValue(\.cloud_cover); current.visibility = nowValue(\.visibility)

        // Daily values from the sources that publish daily forecasts.
        let dailyTable = tables[2]
        let withDays = ranked.filter { !$0.days.isEmpty && weight($0.source, dailyTable) > 0 }
        let keys = Set(withDays.flatMap { $0.days.map(\.dateKey) }).sorted()
        let days: [DayForecast] = keys.compactMap { key in
            let rows = withDays.compactMap { s -> (DayForecast, Double)? in s.days.first { $0.dateKey == key }.map { ($0, weight(s.source, dailyTable)) } }
            guard let first = rows.first?.0 else { return nil }
            func blend(_ field: KeyPath<DayForecast, Double?>) -> Double? { mean(rows.map { ($0.0[keyPath: field], $0.1) }) }
            var row = DayForecast(dateKey: key)
            row.low = blend(\.low); row.high = blend(\.high); row.rain = blend(\.rain); row.chance = blend(\.chance); row.wind = blend(\.wind); row.gust = blend(\.gust); row.uv = blend(\.uv)
            row.feelsLow = blend(\.feelsLow); row.feelsHigh = blend(\.feelsHigh)
            row.code = rows.compactMap { $0.0.code.flatMap { $0 >= 0 ? $0 : nil } }.first
            let sun = rows.map(\.0).first { $0.sunrise != nil || $0.sunriseLocal != nil } ?? first
            row.sunrise = sun.sunrise; row.sunset = sun.sunset; row.sunriseLocal = sun.sunriseLocal; row.sunsetLocal = sun.sunsetLocal; row.daylightSeconds = rows.compactMap(\.0.daylightSeconds).first
            // An ensemble range belongs to the source that computed it; it is passed through, never averaged.
            let spread = rows.map(\.0).first { $0.highP25 != nil && $0.highP75 != nil }
            row.highP25 = spread?.highP25; row.highP75 = spread?.highP75
            row.source = rows.count > 1 ? name : first.source
            row.probabilityLabel = rows.count > 1 ? "Blended daily probability (sources define it differently)" : first.probabilityLabel
            return row
        }

        let total = active.map { weight($0.source, near) }.reduce(0, +)
        let members = ranked.map { BlendInfo.Member(source: $0.source, share: weight($0.source, near) / total, measured: measured.contains($0.source)) }
        let zone = ranked.first { $0.timezone != nil } ?? ranked.first { $0.utcOffset != nil }
        var hourly = Forecast.Hourly(time: time, temperature_2m: temperature, precipitation_probability: chance, precipitation: rain, weather_code: codes, is_day: day)
        hourly.apparent_temperature = feels; hourly.relative_humidity_2m = humidity; hourly.dew_point_2m = dew; hourly.wind_speed_10m = wind; hourly.wind_gusts_10m = gust
        hourly.wind_direction_10m = direction; hourly.pressure_msl = pressure; hourly.cloud_cover = clouds; hourly.visibility = visibility; hourly.uv_index = uv
        var result = Forecast(timezone: zone?.timezone, utc_offset_seconds: zone?.utcOffset, dailyRows: days, source: active.count > 1 ? name : active[0].source, current: current, hourly: hourly)
        if active.count > 1 { result.blend = BlendInfo(members: members, dailySources: withDays.map(\.source)) }
        return result
    }
}

// MARK: Free sources that need no key

/// MET Norway Locationforecast (global, CC BY 4.0). Hourly for about two days, then coarser steps that are not used.
enum METNorway {
    static let name = "MET Norway"
    private struct Reply: Decodable {
        struct Details: Decodable {
            let air_temperature: Double?; let apparent_air_temperature: Double?; let relative_humidity: Double?; let dew_point_temperature: Double?
            let wind_speed: Double?; let wind_speed_of_gust: Double?; let wind_from_direction: Double?; let air_pressure_at_sea_level: Double?; let cloud_area_fraction: Double?
        }
        struct Next: Decodable { struct Summary: Decodable { let symbol_code: String? }; struct Amounts: Decodable { let precipitation_amount: Double?; let probability_of_precipitation: Double? }; let summary: Summary?; let details: Amounts? }
        struct Entry: Decodable { struct Body: Decodable { struct Instant: Decodable { let details: Details }; let instant: Instant; let next_1_hours: Next? }; let time: String; let data: Body }
        struct Properties: Decodable { let timeseries: [Entry] }
        let properties: Properties
    }
    static func url(_ place: Place) -> URL { URL(string: String(format: "https://api.met.no/weatherapi/locationforecast/2.0/complete?lat=%.2f&lon=%.2f", place.latitude, place.longitude))! }
    static func fahrenheit(_ celsius: Double?) -> Double? { celsius.map { $0 * 9 / 5 + 32 } }
    static func mph(_ metresPerSecond: Double?) -> Double? { metresPerSecond.map { $0 * 2.236936 } }
    /// MET symbol names to the condition codes the app already presents. "_day"/"_night" give daylight.
    static func code(_ symbol: String?) -> (code: Int?, daylight: Bool?) {
        guard let symbol, !symbol.isEmpty else { return (nil, nil) }
        let base = symbol.split(separator: "_").first.map(String.init) ?? symbol
        let daylight: Bool? = symbol.hasSuffix("_day") ? true : symbol.hasSuffix("_night") ? false : nil
        let value: Int?
        if base.contains("thunder") { value = 95 }
        else if base.contains("sleet") { value = 69 }
        else if base.contains("snowshowers") { value = 85 }
        else if base.contains("snow") { value = base.hasPrefix("light") ? 71 : base.hasPrefix("heavy") ? 75 : 73 }
        else if base.contains("rainshowers") { value = base.hasPrefix("light") ? 80 : base.hasPrefix("heavy") ? 82 : 81 }
        else if base.contains("rain") { value = base.hasPrefix("light") ? 61 : base.hasPrefix("heavy") ? 65 : 63 }
        else {
            switch base { case "clearsky": value = 0; case "fair": value = 1; case "partlycloudy": value = 2; case "cloudy": value = 3; case "fog": value = 45; default: value = nil }
        }
        return (value, daylight)
    }
    static func decode(_ data: Data, now: Date = Date()) throws -> SourceSeries {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let formatter = ISO8601DateFormatter()
        var series = SourceSeries(source: name)
        for entry in reply.properties.timeseries {
            // Only entries with a one-hour period are hourly values; later six-hour steps are not spread over hours.
            guard let time = formatter.date(from: entry.time), let next = entry.data.next_1_hours else { continue }
            let d = entry.data.instant.details
            let symbol = code(next.summary?.symbol_code)
            series.hours[time] = SeriesHour(temperature: fahrenheit(d.air_temperature), feels: fahrenheit(d.apparent_air_temperature), chance: next.details?.probability_of_precipitation, rain: next.details?.precipitation_amount,
                                            humidity: d.relative_humidity, dewPoint: fahrenheit(d.dew_point_temperature), wind: mph(d.wind_speed), gust: mph(d.wind_speed_of_gust), windDirection: d.wind_from_direction,
                                            pressure: d.air_pressure_at_sea_level, clouds: d.cloud_area_fraction, code: symbol.code, daylight: symbol.daylight)
            // The entry for the present hour doubles as this source's current conditions.
            if series.current == nil, abs(time.timeIntervalSince(now)) <= 3600, let t = fahrenheit(d.air_temperature), let w = mph(d.wind_speed) {
                var current = Forecast.Current(temperature_2m: t, apparent_temperature: fahrenheit(d.apparent_air_temperature) ?? t, weather_code: symbol.code ?? -1, wind_speed_10m: w, is_day: symbol.daylight.map { $0 ? 1 : 0 })
                current.relative_humidity_2m = d.relative_humidity; current.dew_point_2m = fahrenheit(d.dew_point_temperature); current.wind_gusts_10m = mph(d.wind_speed_of_gust)
                current.wind_direction_10m = d.wind_from_direction; current.pressure_msl = d.air_pressure_at_sea_level; current.cloud_cover = d.cloud_area_fraction
                series.current = current
            }
        }
        return series
    }
}

/// US National Weather Service hourly forecast (United States only, public domain).
enum NWSHourly {
    static let name = "NWS"
    private struct Point: Decodable { struct Properties: Decodable { let forecastHourly: URL }; let properties: Properties }
    private struct Reply: Decodable {
        struct Quantity: Decodable { let value: Double?; let unitCode: String? }
        struct Period: Decodable { let startTime: String; let isDaytime: Bool?; let temperature: Double?; let temperatureUnit: String?; let probabilityOfPrecipitation: Quantity?; let dewpoint: Quantity?; let relativeHumidity: Quantity?; let windSpeed: String?; let windDirection: String?; let shortForecast: String? }
        struct Properties: Decodable { let periods: [Period] }
        let properties: Properties
    }
    static let compass = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    /// "5 mph" or "5 to 10 mph": the mean of the numbers given.
    static func speed(_ text: String?) -> Double? {
        guard let text, text.lowercased().contains("mph") else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        return numbers.isEmpty ? nil : numbers.reduce(0, +) / Double(numbers.count)
    }
    /// Forecast wording to the condition codes the app already presents. Presentation only.
    static func code(_ text: String?) -> Int? {
        guard let phrase = text?.lowercased(), !phrase.isEmpty else { return nil }
        for (word, code) in [("thunder", 95), ("sleet", 69), ("freezing", 69), ("wintry", 69), ("ice", 69), ("snow showers", 85), ("snow", 73), ("drizzle", 51), ("showers", 80), ("rain", 63), ("fog", 45), ("haze", 45),
                             ("mostly cloudy", 3), ("overcast", 3), ("partly", 2), ("mostly sunny", 1), ("mostly clear", 1), ("cloudy", 3), ("sunny", 0), ("clear", 0)] where phrase.contains(word) { return code }
        return nil
    }
    static func decode(_ data: Data) throws -> SourceSeries {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let formatter = ISO8601DateFormatter()
        var series = SourceSeries(source: name)
        for period in reply.properties.periods {
            guard let time = formatter.date(from: period.startTime), let raw = period.temperature else { continue }
            let temperature = period.temperatureUnit == "C" ? raw * 9 / 5 + 32 : raw
            let dew = period.dewpoint.flatMap { q in q.value.map { q.unitCode == "wmoUnit:degF" ? $0 : $0 * 9 / 5 + 32 } }
            // The NWS hourly product has no precipitation amount; that field stays missing for this source.
            series.hours[time] = SeriesHour(temperature: temperature, chance: period.probabilityOfPrecipitation?.value, humidity: period.relativeHumidity?.value, dewPoint: dew, wind: speed(period.windSpeed),
                                            windDirection: period.windDirection.flatMap { compass.firstIndex(of: $0) }.map { Double($0) * 22.5 }, code: code(period.shortForecast), daylight: period.isDaytime)
        }
        return series
    }
    static func load(_ place: Place, timeout: TimeInterval) async throws -> SourceSeries {
        let point: Point = try await Network.get(URL(string: String(format: "https://api.weather.gov/points/%.4f,%.4f", place.latitude, place.longitude))!, timeout: timeout)
        guard point.properties.forecastHourly.scheme == "https", point.properties.forecastHourly.host == "api.weather.gov" else { throw URLError(.badServerResponse) }
        return try decode(try await Network.data(point.properties.forecastHourly, timeout: timeout))
    }
}

/// Individual global weather models, all through one Open-Meteo request (CC BY 4.0, non-commercial API terms).
enum OpenMeteoModels {
    static let models: [(id: String, name: String)] = [("ecmwf_ifs025", "ECMWF"), ("gfs_seamless", "NOAA GFS"), ("icon_seamless", "DWD ICON"), ("ukmo_seamless", "UK Met Office"), ("meteofrance_seamless", "Météo-France"), ("gem_seamless", "Canada GEM")]
    static let variables = ["temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation", "weather_code", "is_day", "relative_humidity_2m", "dew_point_2m", "wind_speed_10m", "wind_gusts_10m", "wind_direction_10m", "pressure_msl", "cloud_cover"]
    static func url(_ place: Place) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = ["latitude": String(place.latitude), "longitude": String(place.longitude), "hourly": variables.joined(separator: ","), "models": models.map(\.id).joined(separator: ","),
                                 "temperature_unit": "fahrenheit", "wind_speed_unit": "mph", "timeformat": "unixtime", "forecast_days": "7"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
    private struct Reply: Decodable { let hourly: [String: [Double?]] }
    /// With several models in one request the service names each column "<variable>_<model>".
    /// A model that returns no temperatures for this location is left out.
    static func decode(_ data: Data) throws -> [SourceSeries] {
        let hourly = try JSONDecoder().decode(Reply.self, from: data).hourly
        guard let times = hourly["time"] else { throw URLError(.cannotParseResponse) }
        return models.compactMap { model in
            func column(_ variable: String) -> [Double?]? { hourly["\(variable)_\(model.id)"] }
            guard let temperatures = column("temperature_2m"), temperatures.count == times.count else { return nil }
            var series = SourceSeries(source: model.name)
            for i in times.indices {
                guard let stamp = times[i], let temperature = temperatures[i], temperature.isFinite else { continue }
                func value(_ variable: String) -> Double? { column(variable).at(i) }
                series.hours[Date(timeIntervalSince1970: stamp)] = SeriesHour(temperature: temperature, feels: value("apparent_temperature"), chance: value("precipitation_probability"), rain: value("precipitation"),
                    humidity: value("relative_humidity_2m"), dewPoint: value("dew_point_2m"), wind: value("wind_speed_10m"), gust: value("wind_gusts_10m"), windDirection: value("wind_direction_10m"),
                    pressure: value("pressure_msl"), clouds: value("cloud_cover"), code: value("weather_code").map { Int($0) }, daylight: value("is_day").map { $0 != 0 })
            }
            return series.hours.isEmpty ? nil : series
        }
    }
}

extension Network {
    /// Raw body of a successful GET, for replies decoded by hand.
    static func data(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        guard status == 200 else { throw HTTPFailure(status: status, code: HTTPFailure.code(in: data)) }
        return data
    }
}

enum FreeSources {
    /// Rough US bounds, so other coordinates are never sent to the US weather service.
    static func mayBeUS(_ place: Place) -> Bool { (17.5...71.6).contains(place.latitude) && (-180.0...(-64.4)).contains(place.longitude) }
    /// Every keyless source that answers for this place. A source that fails or has no data here is simply absent.
    static func load(_ place: Place, timeout: TimeInterval = 12) async -> [SourceSeries] {
        async let models: [SourceSeries] = (try? OpenMeteoModels.decode(await Network.data(OpenMeteoModels.url(place), timeout: timeout))) ?? []
        async let norway: SourceSeries? = try? METNorway.decode(await Network.data(METNorway.url(place), timeout: timeout))
        async let nws: SourceSeries? = mayBeUS(place) ? try? await NWSHourly.load(place, timeout: timeout) : nil
        let found = await [nws, norway].compactMap { $0 } + (await models)
        return found.filter { !$0.hours.isEmpty }
    }
}
