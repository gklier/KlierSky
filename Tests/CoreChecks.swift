import Foundation
@main struct CoreChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let forecast = try decoder.decode(Forecast.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let hours = forecast.hours(relativeTo: Date(timeIntervalSince1970: forecast.hourly.time[0]))
        precondition(hours.count == min(168, forecast.hourly.time.count))
        precondition(hours.allSatisfy { $0.chance >= 0 && $0.chance <= 100 && $0.rain >= 0 })
        let dry = (0..<12).map { index in Hour(time: Date(timeIntervalSince1970: Double(index)*3600), temperature: 60, rain: 0, chance: 0, code: nil, daylight: true, wind: 8) }
        precondition(TrendMetric.choose(dry) == .wind)
        precondition(TrendMetric.choose(Array(dry.prefix(11))) == .rain)
        let chanceOnly = dry.map { Hour(time: $0.time, temperature: 60, rain: 0, chance: 40, code: nil, daylight: true, wind: 8) }
        precondition(TrendMetric.choose(chanceOnly) == .probability)
        let wet = dry.map { Hour(time: $0.time, temperature: 60, rain: 0.1, chance: 40, code: nil, daylight: true, wind: 8) }
        precondition(TrendMetric.choose(wet) == .rain)
        let radar = try decoder.decode(RainViewerProvider.Response.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        precondition(!radar.radar.past.isEmpty)
        precondition(radar.radar.past.allSatisfy { $0.time <= Date().timeIntervalSince1970 })
        let f = WeatherFrame(id: "test", validTime: Date(), issuedTime: Date().addingTimeInterval(-7200), kind: .observed, tileURL: "https://example.com/{z}/{x}/{y}.png", attribution: "test", maxZoom: 7)
        precondition(f.isStale)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let wire = try encoder.encode(f)
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WeatherFrame.self, from: wire)
        precondition(decoded.kind == .observed)
        let now = Date()
        let candidates = (0...288).map { i in WeatherFrame(id: String(i), validTime: now.addingTimeInterval(Double(i) * 300), issuedTime: now, kind: .forecast, tileURL: "https://example.com/{z}/{x}/{y}.png", attribution: "test", maxZoom: 7) }
        let timeline = ForecastTimeline.select(candidates, now: now)
        precondition(timeline.count <= 72)
        precondition(timeline.last!.validTime.timeIntervalSince(now) >= 12 * 3600)
        precondition(timeline[1].validTime.timeIntervalSince(timeline[0].validTime) == 300)
        precondition(ForecastTimeline.select([f], now: now).isEmpty)
        // --- Provider switching: the label always names the source really shown ---
        let both = ["Open-Meteo", "Foreca"]
        precondition(ProviderChoice.pick(available: both, preferred: "Foreca", forecaConnected: true) == .init(source: "Foreca", status: "Foreca", isFallback: false))
        precondition(ProviderChoice.pick(available: both, preferred: "Open-Meteo", forecaConnected: true) == .init(source: "Open-Meteo", status: "Open-Meteo", isFallback: false))
        // Foreca was expected and failed: Open-Meteo is shown and called a fallback.
        precondition(ProviderChoice.pick(available: ["Open-Meteo"], preferred: "Foreca", forecaConnected: true) == .init(source: "Open-Meteo", status: "Open-Meteo · fallback", isFallback: true))
        // Foreca was never reachable for this install: not a failure, but still said plainly.
        precondition(ProviderChoice.pick(available: ["Open-Meteo"], preferred: "Foreca", forecaConnected: false) == .init(source: "Open-Meteo", status: "Open-Meteo · Foreca not connected", isFallback: false))
        // Open-Meteo preferred but down: Foreca is the fallback, and labelled as Foreca.
        precondition(ProviderChoice.pick(available: ["Foreca"], preferred: "Open-Meteo", forecaConnected: true) == .init(source: "Foreca", status: "Foreca · fallback", isFallback: true))
        // Nothing arrived: a saved forecast keeps its own source name; with nothing saved the app says offline.
        precondition(ProviderChoice.pick(available: [], preferred: "Foreca", forecaConnected: true, saved: "Foreca") == .init(source: nil, status: "Foreca · saved", isFallback: false))
        precondition(ProviderChoice.pick(available: [], preferred: "Foreca", forecaConnected: true, saved: "Open-Meteo").status == "Open-Meteo · saved")
        precondition(ProviderChoice.pick(available: [], preferred: "Foreca", forecaConnected: false) == .init(source: nil, status: "Offline", isFallback: false))
        print("PASS: recorded forecast/radar decoding, valid probabilities, past-only observation times, stale detection, frame wire format, provider switching and fallback labels")
    }
}
