import Foundation
import CoreLocation

@MainActor @Observable final class AdaptiveStore {
    static let shared = AdaptiveStore()
    struct Archive: Codable { var captures: [ForecastCapture]; var samples: [VerifiedTemperature] }
    private(set) var archive: Archive
    var status = "Collecting forecasts. No accuracy advantage established."
    init() { archive = (try? JSONDecoder().decode(Archive.self, from: Data(contentsOf: AppFiles.url("accuracy.json")))) ?? Archive(captures: [], samples: []) }
    func capture(_ forecast: Forecast, at place: Place, time: Date = Date()) {
        let provider = forecast.source ?? "Open-Meteo"
        let recent = archive.captures.filter { $0.placeID == place.id && $0.provider == provider && time.timeIntervalSince($0.capturedAt) < 1800 }
        guard recent.isEmpty else { return }
        let existing = Set(archive.captures.map(\.evidenceKey))
        archive.captures += forecast.hours.filter { $0.time > time.addingTimeInterval(1800) }.map { ForecastCapture(id: UUID(), placeID: place.id, provider: provider, capturedAt: time, hour: $0) }.filter { !existing.contains($0.evidenceKey) }
        archive.captures = Array(archive.captures.filter { time.timeIntervalSince($0.capturedAt) < 30 * 86400 }.suffix(12000))
        save()
    }
    func clear() { archive = Archive(captures: [], samples: []); save(); status = "Local accuracy history cleared." }
    private func save() { if let data = try? JSONEncoder().encode(archive) { try? data.write(to: AppFiles.url("accuracy.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) } }
    func selectedHours(base: Forecast, alternatives: [Forecast], place: Place, enabled: Bool) -> [Hour] {
        guard enabled else { return base.hours }
        let all = [base] + alternatives
        let providers = Array(Set(all.map { $0.source ?? "Open-Meteo" })).sorted()
        let choices = Dictionary(uniqueKeysWithValues: all.map { ($0.source ?? "Open-Meteo", $0.hours) })
        var winners: [Int: String] = [:]
        for bucket in 0...3 { winners[bucket] = AdaptiveEngine.temperatureWinner(providers: providers, placeID: place.id, bucket: bucket, samples: archive.samples) }
        return base.hours.map { hour in
            guard let winner = winners[AdaptiveEngine.bucket(hour.time.timeIntervalSinceNow)], let better = choices[winner]?.first(where: { abs($0.time.timeIntervalSince(hour.time)) < 60 }) else { return hour }
            var selected = hour
            selected.temperature = better.temperature
            selected.source = "\(hour.source ?? "Forecast") · temp: \(winner)"
            return selected
        }
    }
    func verify(_ place: Place) async {
        do {
            let station = try await NWSObservation.nearest(place)
            let values = AdaptiveEngine.verify(captures: archive.captures, existing: archive.samples, placeID: place.id, observedAt: station.time, temperatureF: station.temperatureF, station: station.id, distanceKM: station.distanceKM)
            archive.samples = Array((archive.samples + values).filter { Date().timeIntervalSince($0.observedTime) < 30 * 86400 }.suffix(12000))
            save()
            status = values.isEmpty ? "Station checked; no new matching forecast hours to score." : "Verified \(values.count) earlier forecasts against \(station.id)."
            Diagnostics.shared.add("accuracy", values.isEmpty ? "No new matching observations" : "Independent temperature samples recorded")
        } catch { status = "Independent station verification unavailable here. No scores were fabricated."; Diagnostics.shared.add("accuracy", "Station verification unavailable") }
    }
}
enum NWSObservation {
    struct Point: Decodable { struct Properties: Decodable { let observationStations: URL }; let properties: Properties }
    struct Stations: Decodable {
        struct Feature: Decodable { struct Geometry: Decodable { let coordinates: [Double] }; struct Properties: Decodable { let stationIdentifier: String }; let geometry: Geometry; let properties: Properties }
        let features: [Feature]
    }
    struct Observation: Decodable {
        struct Value: Decodable { let value: Double?; let unitCode: String? }
        struct Properties: Decodable { let timestamp: String; let temperature: Value }
        let properties: Properties
    }
    struct Result { let id: String; let time: Date; let temperatureF: Double; let distanceKM: Double }
    static func nearest(_ place: Place) async throws -> Result {
        let point: Point = try await Network.get(URL(string: "https://api.weather.gov/points/\(place.latitude),\(place.longitude)")!)
        guard point.properties.observationStations.scheme == "https", point.properties.observationStations.host == "api.weather.gov" else { throw URLError(.badServerResponse) }
        let stations: Stations = try await Network.get(point.properties.observationStations)
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let candidates = stations.features.compactMap { station -> (String, Double)? in
            guard station.geometry.coordinates.count >= 2, station.properties.stationIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return (station.properties.stationIdentifier, location.distance(from: CLLocation(latitude: station.geometry.coordinates[1], longitude: station.geometry.coordinates[0])) / 1000)
        }.filter { $0.1 <= 15 }.sorted { $0.1 < $1.1 }
        guard let candidate = candidates.first else { throw URLError(.resourceUnavailable) }
        let observation: Observation = try await Network.get(URL(string: "https://api.weather.gov/stations/\(candidate.0)/observations/latest?require_qc=true")!)
        guard observation.properties.temperature.unitCode == "wmoUnit:degC", let c = observation.properties.temperature.value, let time = ISO8601DateFormatter().date(from: observation.properties.timestamp) else { throw URLError(.cannotParseResponse) }
        return Result(id: candidate.0, time: time, temperatureF: c * 9 / 5 + 32, distanceKM: candidate.1)
    }
}
