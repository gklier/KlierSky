import Foundation
@main struct AdaptiveChecks {
    static func main() throws {
        let now = Date()
        let target = now.addingTimeInterval(-300)
        let hour = Hour(time: target, temperature: 50, rain: 0, chance: 40, code: 2, daylight: true)
        let capture = ForecastCapture(id: UUID(), placeID: "place", provider: "A", capturedAt: target.addingTimeInterval(-3600), hour: hour)
        let duplicate = ForecastCapture(id: UUID(), placeID: "place", provider: "A", capturedAt: capture.capturedAt.addingTimeInterval(60), hour: hour)
        precondition(duplicate.evidenceKey == capture.evidenceKey)
        let longerLead = ForecastCapture(id: UUID(), placeID: "place", provider: "A", capturedAt: target.addingTimeInterval(-7 * 3600), hour: hour)
        precondition(longerLead.evidenceKey != capture.evidenceKey)
        let result = AdaptiveEngine.verify(captures: [capture], existing: [], placeID: "place", observedAt: target, temperatureF: 47, station: "TEST", distanceKM: 5)
        precondition(result.count == 1 && result[0].errorF == 3)
        precondition(AdaptiveEngine.verify(captures: [capture], existing: result, placeID: "place", observedAt: target, temperatureF: 47, station: "TEST", distanceKM: 5).isEmpty)
        let late = ForecastCapture(id: UUID(), placeID: "place", provider: "A", capturedAt: now, hour: hour)
        precondition(AdaptiveEngine.verify(captures: [late], existing: [], placeID: "place", observedAt: target, temperatureF: 47, station: "TEST", distanceKM: 5).isEmpty)
        precondition(AdaptiveEngine.verify(captures: [capture], existing: [], placeID: "other", observedAt: target, temperatureF: 47, station: "TEST", distanceKM: 5).isEmpty)
        precondition(AdaptiveEngine.verify(captures: [capture], existing: [], placeID: "place", observedAt: target, temperatureF: 47, station: "TEST", distanceKM: 16).isEmpty)
        precondition(AdaptiveEngine.verify(captures: [capture], existing: [], placeID: "place", observedAt: target.addingTimeInterval(-1000), temperatureF: 47, station: "TEST", distanceKM: 5).isEmpty)
        var samples: [VerifiedTemperature] = []
        for provider in ["A", "B"] {
            for i in 0..<20 {
                let time = target.addingTimeInterval(-Double(i) * 3600)
                samples.append(VerifiedTemperature(id: UUID(), captureID: UUID(), placeID: "place", provider: provider, targetTime: time, observedTime: time, station: "TEST", stationDistanceKM: 5, bucket: 0, errorF: provider == "A" ? 1 : 3))
            }
        }
        precondition(AdaptiveEngine.temperatureWinner(providers: ["A","B"], placeID: "place", bucket: 0, samples: samples) == "A")
        precondition(AdaptiveEngine.temperatureWinner(providers: ["A","B"], placeID: "place", bucket: 1, samples: samples) == nil)
        precondition(AdaptiveEngine.temperatureWinner(providers: ["A","B"], placeID: "place", bucket: 0, samples: Array(samples.dropLast())) == nil)
        precondition(AdaptiveEngine.temperatureWinner(providers: ["A"], placeID: "place", bucket: 0, samples: samples) == nil)
        var expired = WeatherFrame(id: "expired", validTime: now.addingTimeInterval(3600), issuedTime: now, kind: .forecast, tileURL: "https://example.com/{z}/{x}/{y}.png", attribution: "test", maxZoom: 7)
        expired.expiresAt = now.addingTimeInterval(-1)
        precondition(ForecastTimeline.select([expired], now: now).isEmpty)
        print("PASS: lookahead prevention, duplicate prevention, location/time/distance matching, paired-hour threshold, horizon-specific ranking, expired signed frame exclusion")
    }
}
