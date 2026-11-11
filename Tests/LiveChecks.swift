import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Optional live smoke test (Tests/live.sh). Uses the app's own request and decoding code against
// the real public services. It needs network access, contacts third parties with a preset city
// (never a personal location) and can fail for reasons outside the app (rate limits, outages),
// so it is not part of Tests/run.sh. It never touches the Foreca gateway and needs no credential.
@main struct LiveChecks {
    static func main() async {
        let place = Place.presets[1]
        var failures = 0
        func report(_ name: String, _ work: () async throws -> String) async {
            do { print("OK    \(name): \(try await work())") } catch { failures += 1; print("FAIL  \(name): \(error)") }
        }
        await report("Open-Meteo forecast") {
            let forecast = try await Forecast.load(place)
            if CommandLine.arguments.count > 1 { try JSONEncoder().encode(forecast).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
            return "\(forecast.hours.count) hours, \(forecast.days.count) days, time zone \(forecast.timezone ?? "missing")"
        }
        await report("RainViewer observed radar") {
            let frames = try await RainViewerProvider().frames()
            guard let newest = frames.last, frames.allSatisfy({ $0.kind == .observed && $0.validTime <= Date().addingTimeInterval(60) }) else { throw URLError(.cannotParseResponse) }
            return "\(frames.count) frames, newest \(Int(Date().timeIntervalSince(newest.validTime) / 60)) min old, none in the future"
        }
        await report("HRRR model futurecast (IEM)") {
            let frames = try await HRRRFuturecast.frames()
            guard let first = frames.first, Set(frames.map(\.issuedTime)).count == 1 else { throw URLError(.cannotParseResponse) }
            return "one run, \(Int(Date().timeIntervalSince(first.issuedTime) / 60)) min old, \(frames.count) future 15-minute frames, look-ahead \(HRRRFuturecast.lookAheadMinutes(frames)) min, \(ForecastTimeline.select(frames).count) frames after thinning"
        }
        var series: [SourceSeries] = []
        await report("MET Norway forecast") {
            let norway = try METNorway.decode(try await Network.data(METNorway.url(place), timeout: 15))
            guard norway.hours.count >= 24, norway.current != nil else { throw URLError(.cannotParseResponse) }
            series.append(norway)
            return "\(norway.hours.count) hourly values, current conditions present"
        }
        await report("NWS hourly forecast") {
            let nws = try await NWSHourly.load(place, timeout: 15)
            guard nws.hours.count >= 24 else { throw URLError(.cannotParseResponse) }
            series.append(nws)
            return "\(nws.hours.count) hourly values"
        }
        await report("Global models via Open-Meteo") {
            let models = try OpenMeteoModels.decode(try await Network.data(OpenMeteoModels.url(place), timeout: 15))
            guard !models.isEmpty else { throw URLError(.cannotParseResponse) }
            series += models
            return models.map { "\($0.source) \($0.hours.count) h" }.joined(separator: ", ")
        }
        await report("Blend of the free sources") {
            let weights = Blend.startingWeights(series.map(\.source))
            guard let blended = Blend.combine(series, weights: { _ in weights }), let info = blended.blend else { throw URLError(.cannotParseResponse) }
            _ = try blended.validated()
            return "\(info.shares); now \(Int(blended.current.temperature_2m.rounded()))°F, \(blended.hours.count) hours"
        }
        await report("NWS active alerts") {
            var request = URLRequest(url: NWSAlerts.activeURL(latitude: place.latitude, longitude: place.longitude), timeoutInterval: 15)
            request.setValue(Network.userAgent, forHTTPHeaderField: "User-Agent"); request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            return "\(try NWSAlerts.decode(data).count) active for \(place.name)"
        }
        await report("Open-Meteo air quality") {
            let (data, response) = try await URLSession.shared.data(from: AirQuality.url(latitude: place.latitude, longitude: place.longitude))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw HTTPFailure(status: status, code: HTTPFailure.code(in: data)) }
            guard let air = AirQuality.decode(data) else { throw URLError(.cannotParseResponse) }
            return "US AQI \(Int(air.usAQI.rounded())) (\(air.category))"
        }
        print(failures == 0 ? "LIVE: all services answered and decoded" : "LIVE: \(failures) service(s) failed; see above")
        exit(failures == 0 ? 0 : 1)
    }
}
