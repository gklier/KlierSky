import Foundation

// Set KlierSkyAppGroup in BOTH Info.plists only after the signing team has
// provisioned the matching App Group entitlement. Standalone widgets can fetch
// Open-Meteo independently without sharing private gateway credentials.
enum WidgetStorage {
    struct Snapshot: Codable { let place: Place; let forecast: Forecast; let fetchedAt: Date }
    static var sharedGroup: String? { Bundle.main.object(forInfoDictionaryKey: "KlierSkyAppGroup") as? String }
    private static var directory: URL {
        let base = sharedGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) } ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("KlierSkyWidgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private static func cacheURL(_ place: Place) -> URL { directory.appendingPathComponent(String(format: "%.2f_%.2f.json", place.latitude, place.longitude)) }
    static func load(_ place: Place) -> Snapshot? {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: cacheURL(place))), snapshot.place.id == place.id else { return nil }
        return snapshot
    }
    static func save(place: Place, forecast: Forecast, fetchedAt: Date) {
        let snapshot = Snapshot(place: place, forecast: forecast, fetchedAt: fetchedAt)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: cacheURL(place), options: [.atomic, .completeFileProtectionUnlessOpen]) }
    }
    static func favorites() -> [Place] { (try? JSONDecoder().decode([Place].self, from: Data(contentsOf: directory.appendingPathComponent("favorites.json")))) ?? [] }
    static func saveFavorites(_ places: [Place]) { guard sharedGroup != nil else { return }; if let data = try? JSONEncoder().encode(places) { try? data.write(to: directory.appendingPathComponent("favorites.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) } }
}
