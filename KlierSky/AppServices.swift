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
    /// "access" is the owner's administrative token (owner's phone only). "device-access" is this install's own read-only record.
    static func read(account: String = "access") -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String, account: String = "access", afterFirstUnlock: Bool = false) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if token.isEmpty { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw URLError(.cannotWriteToFile) }; return }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: afterFirstUnlock ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
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
        if WidgetStorage.sharedGroup != nil {
            WidgetStorage.save(place: place, forecast: forecast, fetchedAt: fetchedAt)
            if place.name == "Current location" { WidgetStorage.saveLastLocation(place, at: fetchedAt) }
        }
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
    struct Health: Decodable { let configured: Bool; let mapsEnabled: Bool; var role: String? = nil }
    static func health(token: String) async throws -> Health { try await Network.get(url("health"), bearer: token) }
    static func pair(_ code: String) async throws {
        var request = URLRequest(url: try url("pair")); request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(["code":code])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let reply = try JSONDecoder().decode(PairReply.self, from: data); try SecureStore.save(reply.accessToken)
    }
    // Owner administration. These need the owner's token; device tokens are refused by the service.
    struct Device: Decodable, Identifiable { let deviceID: String; let label: String; let code: String; let status: String; let created: Double; let lastSeen: Double; let requestsToday: Int; var id: String { deviceID } }
    struct DeviceList: Decodable { let enrollment: String; let maxDevices: Int; let dailyRequestsPerDevice: Int; let upstreamBudget: Int; let upstreamUsedToday: Int; let devices: [Device] }
    static func devices() async throws -> DeviceList { try await Network.get(url("v1/admin/devices"), bearer: SecureStore.read()) }
    static func admin(_ method: String, _ path: String, body: [String: String]? = nil) async throws -> DeviceList {
        var request = URLRequest(url: try url(path)); request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("Bearer " + SecureStore.read(), forHTTPHeaderField: "Authorization")
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        guard status == 200 else { throw HTTPFailure(status: status, code: HTTPFailure.code(in: data)) }
        return try JSONDecoder().decode(DeviceList.self, from: data)
    }
    static func provisionForeca(_ key: String) async throws {
        var request = URLRequest(url: try url("credentials")); request.httpMethod = "PUT"; request.timeoutInterval = 20
        request.setValue("Bearer " + SecureStore.read(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["forecaKey": key])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
    }
    static func forecast(_ place: Place, token: String) async throws -> Forecast { let result: Forecast = try await Network.get(url("forecast", place: place), bearer: token); return try result.validated() }
    static func frames(_ place: Place, token: String) async throws -> [WeatherFrame] { try await Network.get(url("maps", place: place), bearer: token) }
    struct Minute: Codable, Identifiable { var id: Date { time }; let time: Date; let rate: Double }
    struct Nowcast: Codable { let resolution: Int; let points: [Minute]; var isTrueMinute: Bool { resolution == 1 } }
    static func nowcast(_ place: Place, token: String) async throws -> Nowcast { try await Network.get(url("nowcast", place: place), bearer: token) }
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
