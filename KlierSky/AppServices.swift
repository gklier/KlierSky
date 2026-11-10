import Foundation
import SwiftUI
import Security
import CoreLocation
import WidgetKit

@MainActor @Observable final class Diagnostics {
    static let shared = Diagnostics()
    struct Event: Codable, Identifiable { let id: UUID; let time: Date; let category: String; let message: String }
    var events: [Event] = []
    var recording: Bool { UserDefaults.standard.object(forKey: "recordLogs") as? Bool ?? true }
    private let file = AppFiles.url("diagnostics.json")
    init() { events = (try? JSONDecoder().decode([Event].self, from: Data(contentsOf: file))) ?? [] }
    // Call sites supply fixed messages only. Never pass URL, body, error.description or credentials.
    func add(_ category: String, _ message: String) {
        guard recording else { return }
        events.append(Event(id: UUID(), time: Date(), category: category, message: message))
        events = Array(events.suffix(500)); persist()
    }
    func clear() { events = []; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(events) { try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen]) } }
    var export: String { events.map { "\($0.time.ISO8601Format()) [\($0.category)] \($0.message)" }.joined(separator: "\n") }
}
enum AppFiles {
    static func url(_ name: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KlierSky", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? excluded.setResourceValues(values)
        return directory.appendingPathComponent(name)
    }
}
enum SecureStore {
    private static let service = "com.klier.KlierSky.gateway"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "access", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "access"]
        if token.isEmpty { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw URLError(.cannotWriteToFile) }; return }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw URLError(.cannotWriteToFile) }
    }
}
struct CachedForecast: Codable {
    let place: Place
    let forecast: Forecast
    let fetchedAt: Date
    static func load(_ place: Place) -> CachedForecast? {
        guard let cache = try? JSONDecoder().decode(CachedForecast.self, from: Data(contentsOf: AppFiles.url("last-forecast.json"))), cache.place == place else { return nil }
        return cache
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: AppFiles.url("last-forecast.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) }
        if WidgetStorage.sharedGroup != nil { WidgetStorage.save(place: place, forecast: forecast, fetchedAt: fetchedAt) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
enum Gateway {
    static func url(_ path: String, place: Place? = nil) throws -> URL {
        let raw = UserDefaults.standard.string(forKey: "gatewayURL") ?? ""
        guard var c = URLComponents(string: raw), c.scheme == "https", c.host != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw URLError(.badURL) }
        c.path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.path = "/" + (c.path.isEmpty ? "" : c.path + "/") + path
        if let place { c.queryItems = [URLQueryItem(name: "latitude", value: String(place.latitude)), URLQueryItem(name: "longitude", value: String(place.longitude))] }
        guard let url = c.url else { throw URLError(.badURL) }; return url
    }
    struct PairReply: Decodable { let accessToken: String }
    struct Health: Decodable { let configured: Bool; let mapsEnabled: Bool }
    static func health() async throws -> Health { try await Network.get(url("health"), bearer: SecureStore.read()) }
    static func pair(_ code: String) async throws {
        var request = URLRequest(url: try url("pair")); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(["code":code])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let reply = try JSONDecoder().decode(PairReply.self, from: data); try SecureStore.save(reply.accessToken)
    }
    static func provisionForeca(_ key: String) async throws {
        var request = URLRequest(url: try url("credentials")); request.httpMethod = "PUT"; request.timeoutInterval = 20
        request.setValue("Bearer " + SecureStore.read(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["forecaKey": key])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
    }
    static func forecast(_ place: Place) async throws -> Forecast { let result: Forecast = try await Network.get(url("forecast", place: place), bearer: SecureStore.read()); return try result.validated() }
    static func frames(_ place: Place) async throws -> [WeatherFrame] { try await Network.get(url("maps", place: place), bearer: SecureStore.read()) }
    struct Minute: Codable, Identifiable { var id: Date { time }; let time: Date; let rate: Double }
    struct Nowcast: Codable { let resolution: Int; let points: [Minute]; var isTrueMinute: Bool { resolution == 1 } }
    static func nowcast(_ place: Place) async throws -> Nowcast { try await Network.get(url("nowcast", place: place), bearer: SecureStore.read()) }
}
@MainActor @Observable final class LocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var message: String?
    var onLocation: ((Place) -> Void)?
    var onUnavailable: (() -> Void)?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }
    func locate() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
        else { message = "Location access is off. Enable it in iPhone Settings, or search for a city."; onUnavailable?() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { message = "Choose a city, or allow location access in iPhone Settings."; onUnavailable?() } }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, abs(location.timestamp.timeIntervalSinceNow) < 120, location.horizontalAccuracy >= 0 else { return }
        message = nil
        onLocation?(Place(name: "Current location", latitude: (location.coordinate.latitude * 100).rounded() / 100, longitude: (location.coordinate.longitude * 100).rounded() / 100))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "Location unavailable. Try city search."; onUnavailable?() }
}

@MainActor @Observable final class FavoriteLocations {
    static let shared = FavoriteLocations()
    private(set) var places: [Place]
    init() { places = UserDefaults.standard.data(forKey: "favoritePlaces").flatMap { try? JSONDecoder().decode([Place].self, from: $0) } ?? [] }
    func contains(_ place: Place) -> Bool { places.contains { $0.id == place.id } }
    func toggle(_ place: Place) {
        if contains(place) { places.removeAll { $0.id == place.id } }
        else if places.count < 30 { places.append(Place(name: place.name == "Current location" ? "Saved location" : place.name, latitude: place.latitude, longitude: place.longitude)) }
        persist()
    }
    func rename(_ place: Place, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[index] = Place(name: String(name.prefix(80)), latitude: place.latitude, longitude: place.longitude); persist()
    }
    func remove(_ offsets: IndexSet) { places.remove(atOffsets: offsets); persist() }
    private func persist() { if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: "favoritePlaces"); WidgetStorage.saveFavorites(places) } }
}
