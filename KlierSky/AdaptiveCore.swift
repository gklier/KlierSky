import Foundation

struct ForecastCapture: Codable, Identifiable {
    let id: UUID
    let placeID: String
    let provider: String
    let capturedAt: Date
    let hour: Hour
    var bucket: Int { AdaptiveEngine.bucket(hour.time.timeIntervalSince(capturedAt)) }
    var evidenceKey: String { "\(provider)|\(placeID)|\(hour.time.timeIntervalSince1970)|\(bucket)" }
}
struct VerifiedTemperature: Codable, Identifiable {
    let id: UUID
    let captureID: UUID
    let placeID: String
    let provider: String
    let targetTime: Date
    let observedTime: Date
    let station: String
    let stationDistanceKM: Double
    let bucket: Int
    let errorF: Double
}
enum AdaptiveEngine {
    static func bucket(_ lead: TimeInterval) -> Int { lead < 6 * 3600 ? 0 : lead < 24 * 3600 ? 1 : lead < 72 * 3600 ? 2 : 3 }
    static func score(_ samples: [VerifiedTemperature], provider: String, placeID: String, bucket: Int, now: Date = Date()) -> (count: Int, mae: Double)? {
        let matches = samples.filter { $0.provider == provider && $0.placeID == placeID && $0.bucket == bucket && $0.targetTime <= now && now.timeIntervalSince($0.observedTime) < 30 * 86400 }
        guard !matches.isEmpty else { return nil }
        return (matches.count, matches.map { abs($0.errorF) }.reduce(0, +) / Double(matches.count))
    }
    static func temperatureWinner(providers: [String], placeID: String, bucket: Int, samples: [VerifiedTemperature], minimum: Int = 20) -> String? {
        // Require equal target hours between providers to avoid comparing easy weather
        // for one source against difficult weather for another. No retrospective fitting.
        guard providers.count >= 2 else { return nil }
        let sets = providers.map { provider in Set(samples.filter { $0.provider == provider && $0.placeID == placeID && $0.bucket == bucket && $0.targetTime <= Date() && Date().timeIntervalSince($0.observedTime) < 30 * 86400 }.map(\.targetTime)) }
        let common = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
        guard common.count >= minimum else { return nil }
        let paired = samples.filter { common.contains($0.targetTime) }
        let ranking = providers.compactMap { provider -> (String, Double)? in
            guard let s = score(paired, provider: provider, placeID: placeID, bucket: bucket) else { return nil }; return (provider, s.mae)
        }.sorted { $0.1 < $1.1 }
        guard ranking.count >= 2, ranking[1].1 - ranking[0].1 >= 0.5 else { return nil }
        return ranking[0].0
    }
    static func verify(captures: [ForecastCapture], existing: [VerifiedTemperature], placeID: String, observedAt: Date, temperatureF: Double, station: String, distanceKM: Double) -> [VerifiedTemperature] {
        guard distanceKM <= 15, distanceKM >= 0, temperatureF.isFinite, observedAt <= Date().addingTimeInterval(60), Date().timeIntervalSince(observedAt) < 7200 else { return [] }
        var keys = Set(existing.map { "\($0.provider)|\($0.placeID)|\($0.targetTime.timeIntervalSince1970)|\($0.bucket)" })
        var result: [VerifiedTemperature] = []
        for capture in captures.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            guard capture.placeID == placeID, capture.capturedAt <= capture.hour.time.addingTimeInterval(-1800), abs(capture.hour.time.timeIntervalSince(observedAt)) <= 900 else { continue }
            let key = "\(capture.provider)|\(capture.placeID)|\(capture.hour.time.timeIntervalSince1970)|\(capture.bucket)"
            guard keys.insert(key).inserted else { continue }
            result.append(VerifiedTemperature(id: UUID(), captureID: capture.id, placeID: placeID, provider: capture.provider, targetTime: capture.hour.time, observedTime: observedAt, station: station, stationDistanceKM: distanceKM, bucket: capture.bucket, errorF: capture.hour.temperature - temperatureF))
        }
        return result
    }
}
