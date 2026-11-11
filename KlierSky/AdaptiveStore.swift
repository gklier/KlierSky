import Foundation
import CoreLocation

/// Local, opt-in forecast verification. Everything here stays on the device:
/// saved forecasts, station readings and scores are never sent to the KlierSky
/// server. Checking truth contacts the US National Weather Service with the
/// rounded location, the same service used for alerts.
@MainActor @Observable final class AdaptiveStore {
    static let shared = AdaptiveStore()
    struct Station: Codable, Equatable { let id: String; let distanceKM: Double }
    struct Archive: Codable {
        var captures: [ForecastCapture]
        var samples: [VerifiedTemperature]
        var stations: [String: Station]? = nil      // one fixed station per place, so truth is consistent
        var lastChecked: [String: Date]? = nil
    }
    private(set) var archive: Archive
    var status = "No forecasts have been checked yet."
    @ObservationIgnored private var decisions: [String: AdaptiveEngine.Decision] = [:]
    @ObservationIgnored private var checking = false
    init() { archive = (try? JSONDecoder().decode(Archive.self, from: Data(contentsOf: AppFiles.url("accuracy.json")))) ?? Archive(captures: [], samples: []) }

    /// Saves what each source forecast for the coming hours, so it can be scored later. Only when the
    /// user has turned evidence collection on. Temperature is the only value kept and scored.
    func capture(_ all: [SourceSeries], at place: Place, time: Date = Date()) {
        guard UserDefaults.standard.bool(forKey: "verifyStations") else { return }
        var existing = Set(archive.captures.map(\.evidenceKey))
        var added = false
        for series in all {
            let provider = series.source
            // At most one snapshot per source every half hour.
            guard !archive.captures.contains(where: { $0.placeID == place.id && $0.provider == provider && time.timeIntervalSince($0.capturedAt) < 1800 }) else { continue }
            for (target, hour) in series.hours {
                guard target > time.addingTimeInterval(1800), target <= time.addingTimeInterval(7 * 86400), let temperature = hour.temperature, temperature.isFinite else { continue }
                // Rain and chance are placeholders here: this record is only ever used to score temperature.
                let capture = ForecastCapture(id: UUID(), placeID: place.id, provider: provider, capturedAt: time, hour: Hour(time: target, temperature: temperature, rain: 0, chance: 0, code: nil, daylight: true))
                if existing.insert(capture.evidenceKey).inserted { archive.captures.append(capture); added = true }
            }
        }
        guard added else { return }
        archive.captures = Array(archive.captures.filter { time.timeIntervalSince($0.capturedAt) < 30 * 86400 }.suffix(30000))
        save()
    }
    func capture(_ forecast: Forecast, at place: Place, time: Date = Date()) { capture([SourceSeries(forecast)], at: place, time: time) }
    /// Blend weights for one lead-time group at this place: the starting ranking, scaled by scored forecasts where there are enough.
    func blendWeights(sources: [String], place: Place, bucket: Int) -> AdaptiveEngine.BlendWeights {
        AdaptiveEngine.blendWeights(sources: sources, placeID: place.id, bucket: bucket, samples: archive.samples)
    }
    func clear() { archive = Archive(captures: [], samples: []); decisions = [:]; save(); status = "Local evidence cleared. Your preferred source is in use." }
    private func save() { if let data = try? JSONEncoder().encode(archive) { try? data.write(to: AppFiles.url("accuracy.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) } }

    func station(for place: Place) -> Station? { archive.stations?[place.id] }
    func lastChecked(_ place: Place) -> Date? { archive.lastChecked?[place.id] }
    func captureCount(_ place: Place) -> Int { archive.captures.filter { $0.placeID == place.id }.count }
    /// Saved forecast hours that are already in the past but have no score yet.
    func unscored(_ place: Place, now: Date = Date()) -> Int {
        let scored = Set(archive.samples.filter { $0.placeID == place.id }.map(\.captureID))
        return archive.captures.filter { $0.placeID == place.id && $0.hour.time < now.addingTimeInterval(-900) && !scored.contains($0.id) }.count
    }

    /// Cached decision for one lead-time group. Recomputed only when the evidence changes.
    func decision(providers: [String], baseline: String, place: Place, bucket: Int) -> AdaptiveEngine.Decision {
        let key = "\(place.id)|\(bucket)|\(baseline)|\(providers.joined(separator: ","))"
        if let cached = decisions[key] { return cached }
        let value = AdaptiveEngine.decide(providers: providers, baseline: baseline, placeID: place.id, bucket: bucket, samples: archive.samples)
        decisions[key] = value
        return value
    }
    func selectedHours(base: Forecast, alternatives: [Forecast], place: Place, enabled: Bool) -> [Hour] {
        // A blend already weighs every source; the single-source switch below applies only without one.
        guard enabled, base.blend == nil, !alternatives.isEmpty else { return base.hours }
        let all = [base] + alternatives
        let baseline = base.source ?? "Open-Meteo"
        let providers = Array(Set(all.map { $0.source ?? "Open-Meteo" })).sorted()
        var winners: [Int: String] = [:]
        for bucket in 0...3 { if case .use(let provider) = decision(providers: providers, baseline: baseline, place: place, bucket: bucket) { winners[bucket] = provider } }
        guard !winners.isEmpty else { return base.hours }
        let choices = Dictionary(all.map { ($0.source ?? "Open-Meteo", $0.hours) }, uniquingKeysWith: { first, _ in first })
        return base.hours.map { hour in
            guard let winner = winners[AdaptiveEngine.bucket(hour.time.timeIntervalSinceNow)], let better = choices[winner]?.first(where: { abs($0.time.timeIntervalSince(hour.time)) < 60 }) else { return hour }
            var selected = hour
            selected.temperature = better.temperature
            selected.source = "\(hour.source ?? "Forecast") · temp: \(winner)"
            return selected
        }
    }

    /// Checks saved forecasts against the station's recent observation history (up to seven days back).
    func verify(_ place: Place) async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        do {
            let station: Station
            if let known = archive.stations?[place.id] { station = known } else {
                let found = try await NWSObservation.nearestStation(place)
                station = Station(id: found.id, distanceKM: found.distanceKM)
                archive.stations = (archive.stations ?? [:]).merging([place.id: station]) { _, new in new }
            }
            let now = Date()
            let since = max(now.addingTimeInterval(-7 * 86400), (archive.lastChecked?[place.id] ?? .distantPast).addingTimeInterval(-3 * 3600))
            let readings = try await NWSObservation.history(station.id, since: since)
            let values = AdaptiveEngine.verifyHistory(captures: archive.captures, existing: archive.samples, placeID: place.id, readings: readings, station: station.id, distanceKM: station.distanceKM, now: now)
            archive.samples = Array((archive.samples + values).filter { now.timeIntervalSince($0.observedTime) < 30 * 86400 }.suffix(12000))
            archive.lastChecked = (archive.lastChecked ?? [:]).merging([place.id: now]) { _, new in new }
            if !values.isEmpty { decisions = [:] }
            save()
            status = values.isEmpty ? "Checked station \(station.id): no new forecast hours could be scored." : "Scored \(values.count) saved forecast hours against station \(station.id)."
            Diagnostics.shared.add("accuracy", values.isEmpty ? "No new matching observations" : "Independent temperature samples recorded")
        } catch {
            status = "No station check was possible here (no US station within 15 km, or the service was unreachable). Nothing was scored or estimated."
            Diagnostics.shared.add("accuracy", "Station verification unavailable")
        }
    }
    /// Called after a refresh when collection is on. At most one station check per place per hour.
    func collectIfDue(_ place: Place) async {
        if let last = archive.lastChecked?[place.id], Date().timeIntervalSince(last) < 3300 { return }
        await verify(place)
    }
}

enum NWSObservation {
    struct Point: Decodable { struct Properties: Decodable { let observationStations: URL }; let properties: Properties }
    struct Stations: Decodable {
        struct Feature: Decodable { struct Geometry: Decodable { let coordinates: [Double] }; struct Properties: Decodable { let stationIdentifier: String }; let geometry: Geometry; let properties: Properties }
        let features: [Feature]
    }
    static func nearestStation(_ place: Place) async throws -> (id: String, distanceKM: Double) {
        let point: Point = try await Network.get(URL(string: "https://api.weather.gov/points/\(place.latitude),\(place.longitude)")!)
        guard point.properties.observationStations.scheme == "https", point.properties.observationStations.host == "api.weather.gov" else { throw URLError(.badServerResponse) }
        let stations: Stations = try await Network.get(point.properties.observationStations)
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let candidates = stations.features.compactMap { station -> (String, Double)? in
            guard station.geometry.coordinates.count >= 2, !station.properties.stationIdentifier.isEmpty, station.properties.stationIdentifier.count <= 8, station.properties.stationIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return (station.properties.stationIdentifier, location.distance(from: CLLocation(latitude: station.geometry.coordinates[1], longitude: station.geometry.coordinates[0])) / 1000)
        }.filter { $0.1 <= 15 }.sorted { $0.1 < $1.1 }
        guard let candidate = candidates.first else { throw URLError(.resourceUnavailable) }
        return candidate
    }
    static func history(_ station: String, since: Date) async throws -> [StationReading] {
        struct Page: Decodable { struct Pagination: Decodable { let next: URL? }; let pagination: Pagination? }
        var components = URLComponents(string: "https://api.weather.gov/stations/\(station)/observations")!
        components.queryItems = [URLQueryItem(name: "start", value: ISO8601DateFormatter().string(from: since)), URLQueryItem(name: "limit", value: "500")]
        var next = components.url
        var all: [StationReading] = []
        // Five-minute stations need several pages to reach back a week. Bounded to four requests.
        for _ in 0..<4 {
            guard let url = next, url.scheme == "https", url.host == "api.weather.gov" else { break }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue(Network.userAgent, forHTTPHeaderField: "User-Agent"); request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { if all.isEmpty { throw URLError(.badServerResponse) }; break }
            let page = try StationHistory.readings(from: data)
            all += page
            next = (try? JSONDecoder().decode(Page.self, from: data))?.pagination?.next
            if page.isEmpty || (page.map(\.time).min() ?? since) <= since { break }
        }
        return all
    }
}

import BackgroundTasks
/// Optional background evidence collection. iOS decides if and when this runs;
/// it is best effort and never a guarantee of continuous coverage.
enum BackgroundCollection {
    static let identifier = "KlierSky.collect"
    private static var wanted: Bool { UserDefaults.standard.bool(forKey: "backgroundCollection") && UserDefaults.standard.bool(forKey: "verifyStations") }
    static func schedule() {
        guard wanted else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
    static func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
    /// Saves the current forecasts for the last shown place and scores earlier ones. Uses the saved place only: no location access in the background.
    @MainActor static func run() async {
        schedule()
        guard wanted, let place = UserDefaults.standard.data(forKey: "selectedPlace").flatMap({ try? JSONDecoder().decode(Place.self, from: $0) }) else { return }
        let token = GatewayAccess.shared.bearer     // existing access only; never enrolls from the background
        async let open = capture { try await Forecast.load(place, timeout: 12) }
        async let foreca: Result<Forecast, Error>? = token != nil ? await capture { try await Gateway.forecast(place, token: token!) } : nil
        var series: [SourceSeries] = []
        if case .success(var value) = await open { value.source = "Open-Meteo"; series.append(SourceSeries(value)) }
        if case .success(var value)? = await foreca { value.source = "Foreca"; series.append(SourceSeries(value)) }
        if (UserDefaults.standard.string(forKey: "forecastMode") ?? "blend") == "blend" { series += await FreeSources.load(place) }
        AdaptiveStore.shared.capture(series, at: place)
        await AdaptiveStore.shared.collectIfDue(place)
        Diagnostics.shared.add("accuracy", "Background collection ran")
    }
}
