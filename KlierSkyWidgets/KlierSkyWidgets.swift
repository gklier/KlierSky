import SwiftUI
import WidgetKit
import AppIntents
import CoreLocation

struct WidgetCity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "City"
    static var defaultQuery = WidgetCityQuery()
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    var place: Place { Place(name: name, latitude: latitude, longitude: longitude) }
    init(_ place: Place) {
        self.name = place.name; self.latitude = place.latitude; self.longitude = place.longitude
        id = (try? JSONEncoder().encode(place).base64EncodedString()) ?? place.id
    }
}
struct WidgetCityQuery: EntityStringQuery {
    struct Search: Decodable { struct City: Decodable { let name: String; let latitude: Double; let longitude: Double; let admin1: String?; let country: String? }; let results: [City]? }
    func entities(for identifiers: [String]) async throws -> [WidgetCity] { identifiers.compactMap { id in guard let data = Data(base64Encoded: id), let place = try? JSONDecoder().decode(Place.self, from: data) else { return nil }; return WidgetCity(place) } }
    func suggestedEntities() async throws -> [WidgetCity] { (WidgetStorage.favorites().isEmpty ? Place.presets : WidgetStorage.favorites()).map(WidgetCity.init) }
    func entities(matching string: String) async throws -> [WidgetCity] {
        guard string.count > 1 else { return try await suggestedEntities() }
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: string), URLQueryItem(name: "count", value: "8")]
        let result: Search = try await Network.get(c.url!)
        return (result.results ?? []).map { WidgetCity(Place(name: [$0.name,$0.admin1,$0.country].compactMap { $0 }.joined(separator: ", "), latitude: $0.latitude, longitude: $0.longitude)) }
    }
}
struct SkyConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "KlierSky weather"
    static var description = IntentDescription("Show current-location weather or search for a city. Standalone widgets use Open-Meteo; iOS controls refresh timing.")
    @Parameter(title: "Use current location", default: true) var currentLocation: Bool
    @Parameter(title: "City") var city: WidgetCity?
    @Parameter(title: "Celsius", default: false) var celsius: Bool
}
struct SkyEntry: TimelineEntry {
    let date: Date
    let place: Place?
    let forecast: Forecast?
    let fetchedAt: Date?
    let configuration: SkyConfiguration
    let message: String?
    /// True for the follow-up entry that takes over if iOS has not refreshed the widget in time.
    var aged = false
}
@MainActor final class WidgetLocator: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Place?, Never>?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }
    func locate() async -> Place? {
        guard manager.isAuthorizedForWidgetUpdates else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
            Task { [weak self] in try? await Task.sleep(for: .seconds(8)); self?.finish(nil) }
        }
    }
    private func finish(_ value: Place?) { let pending = continuation; continuation = nil; pending?.resume(returning: value) }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, abs(value.timestamp.timeIntervalSinceNow) < 1800, value.horizontalAccuracy >= 0 else { finish(nil); return }
        finish(Place(name: "Current location", latitude: (value.coordinate.latitude*100).rounded()/100, longitude: (value.coordinate.longitude*100).rounded()/100))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
}
struct SkyTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SkyEntry { SkyEntry(date: Date(), place: nil, forecast: nil, fetchedAt: nil, configuration: SkyConfiguration(), message: "Weather") }
    func snapshot(for configuration: SkyConfiguration, in context: Context) async -> SkyEntry { await entry(configuration) }
    func timeline(for configuration: SkyConfiguration, in context: Context) async -> Timeline<SkyEntry> {
        let value = await entry(configuration)
        var entries = [value]
        // iOS may not refresh on schedule. A second entry marks the data as old by itself, 90 minutes after it was fetched.
        if let fetched = value.fetchedAt, value.forecast != nil {
            var old = value; old.aged = true
            entries.append(SkyEntry(date: max(Date().addingTimeInterval(60), fetched.addingTimeInterval(90 * 60)), place: old.place, forecast: old.forecast, fetchedAt: old.fetchedAt, configuration: old.configuration, message: old.message, aged: true))
        }
        return Timeline(entries: entries, policy: .after(Date().addingTimeInterval(value.forecast == nil ? 10 * 60 : 25 * 60)))
    }
    private func entry(_ configuration: SkyConfiguration) async -> SkyEntry {
        var place = configuration.city?.place
        if configuration.currentLocation { let locator = await WidgetLocator(); place = await locator.locate() }
        guard let place else { return SkyEntry(date: Date(), place: nil, forecast: nil, fetchedAt: nil, configuration: configuration, message: configuration.currentLocation ? "Allow widget location in iPhone Settings, or choose a city" : "Edit widget to choose a city") }
        if WidgetStorage.sharedGroup != nil, let cache = WidgetStorage.load(place), Date().timeIntervalSince(cache.fetchedAt) < 1800 { return SkyEntry(date: Date(), place: place, forecast: cache.forecast, fetchedAt: cache.fetchedAt, configuration: configuration, message: nil) }
        do {
            var forecast = try await Forecast.load(place, days: 2, detailed: false, timeout: 8); forecast.source = "Open-Meteo"
            let now = Date(); WidgetStorage.save(place: place, forecast: forecast, fetchedAt: now)
            return SkyEntry(date: now, place: place, forecast: forecast, fetchedAt: now, configuration: configuration, message: nil)
        } catch {
            // Offline: show the last fetch for up to three hours, always with its time. After that, say so instead of showing old weather.
            let saved = WidgetStorage.load(place)
            let cache = saved.flatMap { Date().timeIntervalSince($0.fetchedAt) < 3 * 3600 ? $0 : nil }
            return SkyEntry(date: Date(), place: place, forecast: cache?.forecast, fetchedAt: cache?.fetchedAt, configuration: configuration, message: cache == nil ? "Weather unavailable" : nil, aged: cache != nil)
        }
    }
}
struct SkyWidgetView: View {
    let entry: SkyEntry
    @Environment(\.widgetFamily) private var family
    private var celsius: Bool { entry.configuration.celsius }
    private func degrees(_ f: Double?) -> String { guard let f, f.isFinite else { return "—" }; return "\(Int((celsius ? (f - 32) * 5 / 9 : f).rounded()))°" }
    private var current: Forecast.Current? { entry.forecast?.current }
    private var temperature: String { degrees(current?.temperature_2m) }
    private var symbol: String { current.map { WeatherCode.symbol($0.weather_code, day: $0.is_day != 0) } ?? "cloud" }
    private var condition: String { current.map { WeatherCode.text($0.weather_code) } ?? "No data" }
    private var zone: TimeZone { entry.forecast?.forecastTimeZone ?? .current }
    /// Hours from the entry's own time onward, so an old entry never presents a past hour as "now".
    private var hours: [Hour] { entry.forecast?.hours(relativeTo: entry.date) ?? [] }
    private var today: DayForecast? { entry.forecast?.days.first }
    private func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "ha"
        return formatter.string(from: date).lowercased()
    }
    /// Short precipitation line from hourly values: the first hour with measurable precipitation or a 30%+ chance.
    private var rainLine: String {
        guard let first = hours.first else { return "No data" }
        if first.rain >= 0.1 { return "\(WeatherCode.precipitationWord(first.code)) now" }
        if let next = hours.dropFirst().prefix(11).first(where: { $0.rain >= 0.1 || $0.chance >= 30 }) { return "\(WeatherCode.precipitationWord(next.code)) \(Int(next.chance.rounded()))% at \(hourLabel(next.time))" }
        return hours.count >= 6 ? "Dry next \(min(12, hours.count)) h" : "\(Int(first.chance.rounded()))% rain"
    }
    private var stamp: String {
        guard let fetched = entry.fetchedAt else { return "" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "h:mm a"
        return (entry.aged ? "Old · " : "") + formatter.string(from: fetched)
    }
    private var deepLink: URL? {
        var c = URLComponents(); c.scheme = "kliersky"; c.host = "weather"
        if entry.configuration.currentLocation { c.queryItems = [URLQueryItem(name: "current", value: "1")] }
        else if let place = entry.place { c.queryItems = [URLQueryItem(name: "lat", value: String(place.latitude)), URLQueryItem(name: "lon", value: String(place.longitude)), URLQueryItem(name: "name", value: place.name)] }
        return c.url
    }
    private var placeName: String { entry.place?.name.components(separatedBy: ",").first ?? "KlierSky" }

    var body: some View {
        Group {
            if entry.forecast == nil { unavailable } else {
                switch family {
                case .accessoryInline: Label("\(temperature) \(rainLine)", systemImage: symbol)
                case .accessoryCircular: circular
                case .accessoryRectangular: rectangular
                case .systemMedium: medium
                default: small
                }
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(deepLink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.forecast == nil ? "KlierSky. \(entry.message ?? "Weather unavailable")" : "KlierSky, \(placeName), \(temperature), \(condition). \(rainLine). Open-Meteo forecast\(entry.aged ? ", old data" : "") from \(stamp)")
    }
    @ViewBuilder private var unavailable: some View {
        switch family {
        case .accessoryInline: Label(entry.message ?? "Weather unavailable", systemImage: "exclamationmark.icloud")
        case .accessoryCircular: Image(systemName: "exclamationmark.icloud").font(.title3)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("KlierSky", systemImage: "exclamationmark.icloud").font(.caption.weight(.semibold))
                Text(entry.message ?? "Weather unavailable").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private var circular: some View {
        Group {
            if let low = today?.low, let high = today?.high, let now = current?.temperature_2m, high > low {
                Gauge(value: min(max(now, low), high), in: low...high) { Image(systemName: symbol) } currentValueLabel: { Text(temperature) } minimumValueLabel: { Text(degrees(low)) } maximumValueLabel: { Text(degrees(high)) }
                    .gaugeStyle(.accessoryCircular)
            } else {
                VStack(spacing: 1) { Image(systemName: symbol).font(.caption); Text(temperature).font(.headline).minimumScaleFactor(0.7) }
            }
        }.opacity(entry.aged ? 0.6 : 1)
    }
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text("\(temperature) \(condition)").lineLimit(1)
            }.font(.headline)
            Text([today.flatMap { day in day.high.flatMap { high in day.low.map { "H \(degrees(high)) L \(degrees($0))" } } }, rainLine].compactMap { $0 }.joined(separator: " · ")).font(.caption).lineLimit(1).minimumScaleFactor(0.75)
            // The Lock Screen widget names its own source: it fetches Open-Meteo, never the app's Foreca forecast.
            Text(["Open-Meteo", stamp.isEmpty ? nil : stamp].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var header: some View {
        HStack(spacing: 4) {
            if entry.configuration.currentLocation { Image(systemName: "location.fill").font(.system(size: 8)) }
            Text(placeName).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 2)
        }
    }
    private var footer: some View {
        HStack { Text("Open-Meteo"); Spacer(minLength: 2); Text(stamp).foregroundStyle(entry.aged ? Color.orange : Color.secondary) }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
    }
    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            HStack(alignment: .center, spacing: 6) {
                Text(temperature).font(.system(size: 40, weight: .semibold)).minimumScaleFactor(0.6).lineLimit(1)
                Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.title3)
            }
            Text(condition).font(.caption.weight(.medium)).lineLimit(1)
            if let day = today, let low = day.low, let high = day.high { Text("H \(degrees(high))  L \(degrees(low))").font(.caption2).foregroundStyle(.secondary) }
            Text(rainLine).font(.caption2).lineLimit(1)
            Spacer(minLength: 0)
            footer
        }
    }
    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    header
                    HStack(spacing: 6) {
                        Text(temperature).font(.system(size: 36, weight: .semibold)).minimumScaleFactor(0.6).lineLimit(1)
                        Image(systemName: symbol).symbolRenderingMode(.multicolor).font(.title3)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(condition).font(.caption.weight(.medium))
                    if let day = today, let low = day.low, let high = day.high { Text("H \(degrees(high))  L \(degrees(low))").font(.caption2).foregroundStyle(.secondary) }
                    Text(rainLine).font(.caption2)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(hours.dropFirst().prefix(6))) { hour in
                    VStack(spacing: 2) {
                        Text(hourLabel(hour.time)).font(.system(size: 9)).foregroundStyle(.secondary)
                        Image(systemName: WeatherCode.symbol(hour.code, day: hour.daylight)).symbolRenderingMode(.multicolor).font(.caption).frame(height: 14)
                        Text(degrees(hour.temperature)).font(.caption2.weight(.semibold))
                        Text(hour.chance >= 10 ? "\(Int(hour.chance.rounded()))%" : " ").font(.system(size: 8)).foregroundStyle(.blue)
                    }.frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
            footer
        }
    }
}
struct KlierSkyForecastWidget: Widget {
    let kind = "KlierSkyForecast"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SkyConfiguration.self, provider: SkyTimeline()) { SkyWidgetView(entry: $0) }
            .configurationDisplayName("KlierSky weather")
            .description("Current conditions, high and low, next precipitation and the coming hours. Open-Meteo forecast for your location or a chosen city.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
@main struct KlierSkyWidgets: WidgetBundle { var body: some Widget { KlierSkyForecastWidget() } }
