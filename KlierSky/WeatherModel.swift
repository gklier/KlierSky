import Foundation
import SwiftUI

@MainActor @Observable final class WeatherModel {
    var place: Place
    var hasSelectedLocation: Bool
    var awaitingLocation = false
    var usingCurrentLocation = false
    var forecast: Forecast?
    var alternatives: [Forecast] = []
    var frames: [WeatherFrame] = []
    var error: String?
    var radarError: String?
    var loading = false
    var licensedFrames: [WeatherFrame] = []
    var licensedError: String?
    var nowcast: Gateway.Nowcast?
    var providerStatus = "Not refreshed yet"
    var manifestEndpoint = UserDefaults.standard.string(forKey: "manifestEndpoint") ?? ""
    var updated: Date?
    var alerts: AlertFeed
    var air: AirQuality?
    var modelFrames: [WeatherFrame] = []
    var modelFramesError: String?
    var modelFramesLoading = false
    private var requestID = UUID()
    let locationService = LocationService()
    init() {
        let saved = UserDefaults.standard.data(forKey: "selectedPlace").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        place = saved ?? Place(name: "Current location", latitude: 0, longitude: 0)
        hasSelectedLocation = saved != nil
        usingCurrentLocation = (UserDefaults.standard.string(forKey: "locationMode") ?? "current") == "current"
        alerts = AlertFeed(placeID: saved?.id ?? "")
        if let cache = CachedForecast.load(place) { forecast = cache.forecast; updated = cache.fetchedAt; providerStatus = (cache.forecast.source ?? "Forecast") + " · saved" }
        if let saved, let cached = AlertCache.load(saved) { alerts = cached }
    }
    var hours: [Hour] {
        guard let forecast else { return [] }
        return AdaptiveStore.shared.selectedHours(base: forecast, alternatives: alternatives, place: place, enabled: UserDefaults.standard.bool(forKey: "adaptiveEnabled"))
    }
    var zone: TimeZone { forecast?.forecastTimeZone ?? .current }
    var isStale: Bool { updated.map { Date().timeIntervalSince($0) > 1800 } ?? false }
    func start() async {
        if (UserDefaults.standard.string(forKey: "locationMode") ?? "current") == "current" { useLocation() }
        else if hasSelectedLocation { await refresh() }
    }
    private func show(_ place: Place) {
        self.place = place; hasSelectedLocation = true; awaitingLocation = false
        if let cache = CachedForecast.load(place) { forecast = cache.forecast; updated = cache.fetchedAt } else { forecast = nil; updated = nil }
        frames = []; air = nil; modelFrames = []; modelFramesError = nil; alternatives = []
        alerts = AlertCache.load(place) ?? AlertFeed(placeID: place.id)
    }
    func select(_ place: Place) {
        UserDefaults.standard.set("fixed", forKey: "locationMode"); usingCurrentLocation = false
        locationService.message = nil      // a chosen city replaces any "location unavailable" notice
        show(place)
        Task { await refresh() }
    }
    func useLocation() {
        UserDefaults.standard.set("current", forKey: "locationMode"); awaitingLocation = true; usingCurrentLocation = true
        locationService.onUnavailable = { [weak self] in
            guard let self else { return }; self.awaitingLocation = false
            if self.hasSelectedLocation { Task { await self.refresh() } }
        }
        locationService.onLocation = { [weak self] place in
            guard let self else { return }
            if place.id != self.place.id || !self.hasSelectedLocation { self.show(place) } else { self.awaitingLocation = false }
            Task { await self.refresh() }
        }
        locationService.locate()
    }
    func refresh() async {
        guard hasSelectedLocation else { return }
        let id = UUID(); requestID = id
        let location = place
        if let data = try? JSONEncoder().encode(location) { UserDefaults.standard.set(data, forKey: "selectedPlace") }
        if forecast == nil, let cache = CachedForecast.load(location) { forecast = cache.forecast; updated = cache.fetchedAt }
        loading = true
        error = nil; radarError = nil; licensedError = nil; nowcast = nil; licensedFrames = []
        Diagnostics.shared.add("refresh", "Weather refresh started")
        // Access is automatic: a new install enrolls itself for read-only service access.
        await GatewayAccess.shared.ensure()
        let token = GatewayAccess.shared.bearer
        async let weatherResult = capture { try await Forecast.load(location) }
        async let radarResult = capture { try await RainViewerProvider().frames() }
        async let forecaResult: Result<Forecast, Error>? = token != nil ? await capture { try await Gateway.forecast(location, token: token!) } : nil
        async let alertResult = AlertService.check(location, previous: alerts)
        async let airResult = AlertService.air(location)
        let (weather, radar, foreca) = await (weatherResult, radarResult, forecaResult)
        guard requestID == id else { return }
        var available: [Forecast] = []
        if case .success(var value) = weather { value.source = "Open-Meteo"; available.append(value); Diagnostics.shared.add("provider", "Open-Meteo forecast received") }
        else { Diagnostics.shared.add("provider", "Open-Meteo request failed") }
        var forecaProblem: String?
        switch foreca {
        case .success(var value)?: value.source = "Foreca"; available.append(value); Diagnostics.shared.add("provider", "Foreca forecast received")
        case .failure(let failure)?:
            Diagnostics.shared.add("provider", "Foreca request failed; checking fallback")
            if let http = failure as? HTTPFailure, let token { GatewayAccess.shared.rejected(http, token: token) }
            forecaProblem = Self.explain(failure)
        case nil: break
        }
        let preferred = UserDefaults.standard.string(forKey: "preferredProvider") ?? "Foreca"
        let choice = ProviderChoice.pick(available: available.compactMap(\.source), preferred: preferred, forecaConnected: token != nil, saved: forecast?.source)
        providerStatus = choice.status
        if var chosen = available.first(where: { $0.source == choice.source }) {
            if chosen.source == "Foreca", chosen.timezone == nil, let metadata = available.first(where: { $0.source == "Open-Meteo" }) { chosen.timezone = metadata.timezone; chosen.utc_offset_seconds = metadata.utc_offset_seconds }
            forecast = chosen; updated = Date(); alternatives = available.filter { $0.source != chosen.source }
            CachedForecast(place: location, forecast: chosen, fetchedAt: updated!).save()
            available.forEach { AdaptiveStore.shared.capture($0, at: location) }
            // Explain a missing Foreca forecast only to someone who asked for Foreca.
            if let forecaProblem, choice.isFallback, preferred == "Foreca" { error = forecaProblem + " Showing \(chosen.source ?? "the fallback source")." }
        } else {
            error = forecast == nil ? "Could not load a forecast. Check the connection and try again." : "Refresh failed. Showing the saved forecast."
        }
        switch radar {
        case .success(let value): frames = value; Diagnostics.shared.add("radar", "Observed radar manifest received")
        case .failure: radarError = "Radar refresh failed."; Diagnostics.shared.add("radar", "Observed radar request failed")
        }
        let (alertFeed, airValue) = await (alertResult, airResult)
        guard requestID == id else { return }
        alerts = alertFeed; AlertCache.save(alertFeed)
        if let airValue { air = airValue }
        if let token, UserDefaults.standard.bool(forKey: "forecaMapsEnabled") {
            do {
                let value = try await Gateway.frames(location, token: token)
                guard requestID == id else { return }; licensedFrames = value
                Diagnostics.shared.add("maps", "Licensed map manifest received")
            } catch { licensedError = "Foreca maps are not available. Map access is licensed separately from point forecasts."; Diagnostics.shared.add("maps", "Licensed map request failed") }
        } else if !manifestEndpoint.isEmpty {
            do {
                guard let url = URL(string: manifestEndpoint), url.scheme == "https" else { throw URLError(.badURL) }
                let value = try await LicensedRadarProvider(endpoint: url).frames()
                guard requestID == id else { return }; licensedFrames = value
            } catch { licensedError = "Custom map connection failed." }
        }
        if let token, forecast?.source == "Foreca", UserDefaults.standard.object(forKey: "forecaNowcastEnabled") as? Bool ?? true {
            do {
                let value = try await Gateway.nowcast(location, token: token)
                guard requestID == id else { return }; nowcast = value
                Diagnostics.shared.add("nowcast", value.isTrueMinute ? "Minute-resolution forecast received" : "Coarser-resolution forecast received")
            } catch { Diagnostics.shared.add("nowcast", "Nowcast not available for this account or location") }
        }
        guard requestID == id else { return }
        loading = false
        Diagnostics.shared.add("refresh", "Weather refresh finished")
        if UserDefaults.standard.bool(forKey: "verifyStations") { await AdaptiveStore.shared.collectIfDue(location) }
    }
    /// Real HRRR model frames, loaded only when the Futurecast tab is opened.
    func loadModelFrames() async {
        guard !modelFramesLoading else { return }
        if let last = modelFrames.first, Date().timeIntervalSince(last.issuedTime) < 2 * 3600, !ForecastTimeline.select(modelFrames).isEmpty { return }
        modelFramesLoading = true; modelFramesError = nil
        defer { modelFramesLoading = false }
        guard HRRRFuturecast.covers(latitude: place.latitude, longitude: place.longitude) else {
            modelFrames = []; modelFramesError = "Model futurecast covers the contiguous United States only. No forecast imagery is available for this location."; return
        }
        do { modelFrames = try await HRRRFuturecast.frames(); Diagnostics.shared.add("maps", "HRRR model frames listed") }
        catch { modelFrames = []; modelFramesError = "The model futurecast source could not be reached. Nothing is shown rather than old or invented frames."; Diagnostics.shared.add("maps", "HRRR model listing failed") }
    }
    private static func explain(_ failure: Error) -> String {
        guard let http = failure as? HTTPFailure else { return "The Foreca service could not be reached." }
        switch (http.status, http.code) {
        case (401, "device_revoked"): return "This iPhone's access to the Foreca service was removed."
        case (403, "device_pending"): return "This iPhone is waiting for owner approval."
        case (429, "device_quota_exceeded"): return "This iPhone reached today's Foreca request limit."
        case (429, _): return "The Foreca service is limiting requests right now."
        case (401, _): return "The Foreca service did not accept this iPhone's access."
        case (503, _): return "The Foreca service is not configured yet."
        default: return "The Foreca service returned an error."
        }
    }
}
func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}

enum AlertService {
    /// Checks official alerts for a place. On failure the previous list is kept and marked unverified.
    static func check(_ place: Place, previous: AlertFeed) async -> AlertFeed {
        var feed = previous.placeID == place.id ? previous : AlertFeed(placeID: place.id)
        guard NWSAlerts.mayCover(latitude: place.latitude, longitude: place.longitude) else {
            return AlertFeed(placeID: place.id, coverage: .outside, alerts: [], fetchedAt: Date(), failed: false)
        }
        var request = URLRequest(url: NWSAlerts.activeURL(latitude: place.latitude, longitude: place.longitude), timeoutInterval: 15)
        request.setValue(Network.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else { feed.failed = true; return feed }
        if status == 400 || status == 404 { return AlertFeed(placeID: place.id, coverage: .outside, alerts: [], fetchedAt: Date(), failed: false) }  // NWS: point out of bounds
        guard status == 200, let alerts = try? NWSAlerts.decode(data) else { feed.failed = true; return feed }
        await Diagnostics.shared.add("alerts", alerts.isEmpty ? "No active official alerts" : "Official alerts received")
        return AlertFeed(placeID: place.id, coverage: .covered, alerts: alerts, fetchedAt: Date(), failed: false)
    }
    static func air(_ place: Place) async -> AirQuality? {
        var request = URLRequest(url: AirQuality.url(latitude: place.latitude, longitude: place.longitude), timeoutInterval: 12)
        request.setValue(Network.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return AirQuality.decode(data)
    }
}
enum AlertCache {
    static func load(_ place: Place) -> AlertFeed? {
        guard let feed = try? JSONDecoder().decode(AlertFeed.self, from: Data(contentsOf: AppFiles.url("last-alerts.json"))), feed.placeID == place.id else { return nil }
        var saved = feed; saved.failed = true   // from disk: not yet re-checked this session
        return saved
    }
    static func save(_ feed: AlertFeed) {
        if let data = try? JSONEncoder().encode(feed) { try? data.write(to: AppFiles.url("last-alerts.json"), options: [.atomic, .completeFileProtectionUnlessOpen]) }
    }
}
