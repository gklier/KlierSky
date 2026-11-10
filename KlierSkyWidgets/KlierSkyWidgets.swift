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
        return Timeline(entries: [value], policy: .after(Date().addingTimeInterval(20*60)))
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
            let saved = WidgetStorage.load(place)
            let cache = saved.flatMap { Date().timeIntervalSince($0.fetchedAt) < 3 * 3600 ? $0 : nil }
            return SkyEntry(date: Date(), place: place, forecast: cache?.forecast, fetchedAt: cache?.fetchedAt, configuration: configuration, message: cache == nil ? "Weather unavailable" : "Saved forecast")
        }
    }
}
struct SkyWidgetView: View {
    let entry: SkyEntry
    @Environment(\.widgetFamily) private var family
    private var temperature: String { guard let value = entry.forecast?.current.temperature_2m else { return "—" }; return "\(Int((entry.configuration.celsius ? (value-32)*5/9 : value).rounded()))°" }
    private var symbol: String { guard let code = entry.forecast?.current.weather_code, code >= 0 else { return "cloud" }; return code == 0 ? (entry.forecast?.current.is_day == 0 ? "moon.fill" : "sun.max.fill") : code < 4 ? "cloud.sun.fill" : code < 50 ? "cloud.fog.fill" : code < 70 ? "cloud.rain.fill" : code < 80 ? "cloud.snow.fill" : code < 95 ? "cloud.heavyrain.fill" : "cloud.bolt.rain.fill" }
    private var rain: String { entry.forecast?.hours.first.map { "\(Int($0.chance))% rain" } ?? "No data" }
    private var deepLink: URL? {
        var c = URLComponents(); c.scheme = "kliersky"; c.host = "weather"
        if entry.configuration.currentLocation { c.queryItems = [URLQueryItem(name: "current", value: "1")] }
        else if let place = entry.place { c.queryItems = [URLQueryItem(name: "lat", value: String(place.latitude)), URLQueryItem(name: "lon", value: String(place.longitude)), URLQueryItem(name: "name", value: place.name)] }
        return c.url
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("\(temperature) · \(entry.message ?? rain)", systemImage: symbol)
            case .accessoryCircular:
                VStack(spacing: 1) { Image(systemName: symbol).font(.caption); Text(temperature).font(.headline).minimumScaleFactor(0.7) }
            case .accessoryRectangular:
                HStack(spacing: 8) { Image(systemName: symbol).font(.title2); VStack(alignment: .leading) { Text("\(temperature)  \(entry.place?.name ?? "KlierSky")").font(.headline).lineLimit(1); Text(entry.message ?? rain).font(.caption); if let time = entry.fetchedAt { Text(time, style: .time).font(.caption2) } } }
            default:
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text(entry.place?.name ?? "KlierSky").font(.caption.weight(.semibold)).lineLimit(1); Spacer(); Image(systemName: symbol).symbolRenderingMode(.palette).foregroundStyle(Color.primary, Color.orange, Color.blue) }
                    Text(temperature).font(.system(size: 42, weight: .semibold)).minimumScaleFactor(0.7)
                    if let day = entry.forecast?.days.first, let low = day.low, let high = day.high { Text("H \(converted(high))° · L \(converted(low))°").font(.caption) }
                    Text(entry.message ?? rain).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                    HStack { Text(entry.forecast?.source ?? "KlierSky"); Spacer(); if let date = entry.fetchedAt { Text(date, style: .time) } }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(deepLink)
        .accessibilityLabel("KlierSky, \(entry.place?.name ?? "location unavailable"), \(temperature), \(entry.message ?? rain), source \(entry.forecast?.source ?? "unavailable")")
    }
    private func converted(_ f: Double) -> Int { Int((entry.configuration.celsius ? (f-32)*5/9 : f).rounded()) }
}
struct KlierSkyForecastWidget: Widget {
    let kind = "KlierSkyForecast"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SkyConfiguration.self, provider: SkyTimeline()) { SkyWidgetView(entry: $0) }
            .configurationDisplayName("KlierSky weather")
            .description("Current conditions, daily high/low and rain probability. Location and city forecasts, powered by Open-Meteo.")
            .supportedFamilies([.systemSmall,.systemMedium,.accessoryInline,.accessoryCircular,.accessoryRectangular])
    }
}
@main struct KlierSkyWidgets: WidgetBundle { var body: some Widget { KlierSkyForecastWidget() } }
