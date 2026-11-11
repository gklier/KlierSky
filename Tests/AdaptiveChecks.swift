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
        // --- Observation history: verification no longer depends on the app being open at the hour ---
        let base = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600).addingTimeInterval(-40 * 3600)
        func made(_ provider: String, _ hourIndex: Int, lead: TimeInterval, temp: Double) -> ForecastCapture {
            let time = base.addingTimeInterval(Double(hourIndex) * 3600)
            return ForecastCapture(id: UUID(), placeID: "place", provider: provider, capturedAt: time.addingTimeInterval(-lead), hour: Hour(time: time, temperature: temp, rain: 0, chance: 0, code: 0, daylight: true))
        }
        let history = (0..<30).flatMap { i -> [StationReading] in
            let hourTime = base.addingTimeInterval(Double(i) * 3600)
            return [StationReading(time: hourTime.addingTimeInterval(-1200), temperatureF: 99), StationReading(time: hourTime.addingTimeInterval(180), temperatureF: 50 + Double(i)), StationReading(time: hourTime.addingTimeInterval(600), temperatureF: -40)]
        }
        let saved = (0..<30).map { made("A", $0, lead: 2 * 3600, temp: 52 + Double($0)) } + [made("A", 35, lead: 3600, temp: 60), made("A", 3, lead: 600, temp: 0), made("A", 60, lead: 3600, temp: 60)]
        let scored = AdaptiveEngine.verifyHistory(captures: saved, existing: [], placeID: "place", readings: history, station: "TEST", distanceKM: 4, now: now)
        precondition(scored.count == 30, "every saved hour with a reading within 15 minutes is scored: \(scored.count)")
        precondition(scored.allSatisfy { $0.errorF == 2 && abs($0.observedTime.timeIntervalSince($0.targetTime)) == 180 }, "the closest reading is used, not an earlier or later one")
        precondition(scored.allSatisfy { $0.capturedAt != nil && $0.capturedAt! <= $0.targetTime.addingTimeInterval(-1800) }, "forecasts saved too close to their hour are never scored")
        precondition(AdaptiveEngine.verifyHistory(captures: saved, existing: scored, placeID: "place", readings: history, station: "TEST", distanceKM: 4, now: now).isEmpty, "a second check adds no duplicates")
        precondition(AdaptiveEngine.verifyHistory(captures: saved, existing: [], placeID: "place", readings: history, station: "TEST", distanceKM: 15.1, now: now).isEmpty)
        precondition(AdaptiveEngine.verifyHistory(captures: saved, existing: [], placeID: "place", readings: [StationReading(time: base, temperatureF: .nan), StationReading(time: now.addingTimeInterval(3600), temperatureF: 50)], station: "TEST", distanceKM: 4, now: now).isEmpty, "invalid and future readings are not truth")
        let fixture = try StationHistory.readings(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(fixture.count >= 30 && fixture.allSatisfy { (-60...130).contains($0.temperatureF) }, "real NWS history decodes to plausible °F: \(fixture.count)")
        let rejected = try StationHistory.readings(from: Data(#"{"features":[{"properties":{"timestamp":"2026-11-10T04:55:00+00:00","temperature":{"unitCode":"wmoUnit:degC","value":10,"qualityControl":"X"}}},{"properties":{"timestamp":"2026-11-10T04:55:00+00:00","temperature":{"unitCode":"wmoUnit:degC","value":null,"qualityControl":"V"}}},{"properties":{"timestamp":"2026-11-10T04:55:00+00:00","temperature":{"unitCode":"wmoUnit:degF","value":50,"qualityControl":"V"}}}]}"#.utf8))
        precondition(rejected.isEmpty, "failed QC, missing values and unexpected units are dropped")

        // --- Held-out gate: an in-sample winner must also win on hours it had not seen ---
        // Scored hours three hours apart by default, so 60 of them cover more than a week of different days.
        func series(_ errors: (Int) -> (a: Double, b: Double), count: Int, spacingHours: Double = 3) -> [VerifiedTemperature] {
            (0..<count).flatMap { i -> [VerifiedTemperature] in
                let time = now.addingTimeInterval(-Double(count - i) * spacingHours * 3600)
                let e = errors(i)
                return [("A", e.a), ("B", e.b)].map { VerifiedTemperature(id: UUID(), captureID: UUID(), placeID: "place", provider: $0.0, targetTime: time, observedTime: time, station: "TEST", stationDistanceKM: 5, bucket: 0, errorF: $0.1, capturedAt: time.addingTimeInterval(-2 * 3600)) }
            }
        }
        // B is consistently closer: the rule switches to B and keeps beating the baseline A out of sample.
        let steady = series({ _ in (3, 1) }, count: 60)
        let steadyCheck = AdaptiveEngine.heldOut(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: steady, now: now)!
        precondition(steadyCheck.evaluated == 40 && steadyCheck.switched == 40 && steadyCheck.switchedDays >= 5, "only hours with 20 earlier scored hours are evaluated: \(steadyCheck)")
        precondition(steadyCheck.baselineMAE == 3 && steadyCheck.adaptiveMAE == 1)
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: steady, now: now) == .use("B"))
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "B", placeID: "place", bucket: 0, samples: steady, now: now) == .baselineBest)
        // B was closer early and worse later. In-sample average still favors B, but switching did not help on unseen hours: no adaptation.
        let reversal = series({ $0 < 34 ? (4, 1) : (1, 3) }, count: 60)
        let reversalCheck = AdaptiveEngine.heldOut(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: reversal, now: now)!
        precondition(reversalCheck.adaptiveMAE > reversalCheck.baselineMAE, "the rule chased a pattern that reversed: \(reversalCheck)")
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: reversal, now: now) == .awaitingHeldOut(candidate: "B"), "an in-sample winner that fails out of sample is not used")
        // Too little history for any held-out decision: nothing adapts yet.
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: series({ _ in (3, 1) }, count: 24, spacingHours: 6), now: now) == .awaitingHeldOut(candidate: "B"))
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: series({ _ in (3, 1) }, count: 12), now: now) == .collecting(paired: 12, needed: 20))
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: series({ _ in (2, 1.8) }, count: 60), now: now) == .noClearDifference)
        precondition(AdaptiveEngine.decide(providers: ["A"], baseline: "A", placeID: "place", bucket: 0, samples: steady, now: now) == .collecting(paired: 0, needed: 20), "one source can never be ranked")
        // Evidence that arrives after a forecast was issued cannot inform that forecast's decision.
        let lookahead = steady.map { sample -> VerifiedTemperature in var copy = sample; copy.capturedAt = sample.targetTime.addingTimeInterval(-200 * 3600); return copy }
        precondition(AdaptiveEngine.heldOut(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: lookahead, now: now) == nil, "with 200-hour-old issue times no hour has 20 earlier observed hours")
        // Independence: 60 consecutive hours are at most four days of weather. Plenty of hours, too few days: nothing adapts.
        if case .collectingDays(let days, let needed) = AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: series({ _ in (3, 1) }, count: 60, spacingHours: 1), now: now) {
            precondition(days <= 4 && needed == 5)
        } else { preconditionFailure("consecutive hours from a few days must not be enough evidence") }
        // The held-out switch must also be spread over several days and be worth at least the minimum gain.
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: steady, minimumSwitchedDays: 99, now: now) == .awaitingHeldOut(candidate: "B"))
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: steady, minimumGain: 2.5, now: now) == .awaitingHeldOut(candidate: "B"))
        // Like for like: forecasts saved hours apart for the same target hour are not a fair pair and are left out.
        let uneven = steady.map { sample -> VerifiedTemperature in var copy = sample; if sample.provider == "B" { copy.capturedAt = sample.targetTime.addingTimeInterval(-3600 * 0.6) }; return copy }
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: uneven, now: now) == .collecting(paired: 0, needed: 20), "a fresher forecast must not be ranked against an older one")
        // Scores without a recorded issue time (older app versions) cannot be shown to be fair pairs.
        let undated = steady.map { sample -> VerifiedTemperature in var copy = sample; copy.capturedAt = nil; return copy }
        precondition(AdaptiveEngine.decide(providers: ["A", "B"], baseline: "A", placeID: "place", bucket: 0, samples: undated, now: now) == .collecting(paired: 0, needed: 20))
        let cover = AdaptiveEngine.coverage(steady, placeID: "place", now: now)
        precondition(cover.count == 2 && cover[0].provider == "A" && cover[0].count == 60 && cover[0].mae == 3 && cover[0].bias == 3)

        var expired = WeatherFrame(id: "expired", validTime: now.addingTimeInterval(3600), issuedTime: now, kind: .forecast, tileURL: "https://example.com/{z}/{x}/{y}.png", attribution: "test", maxZoom: 7)
        expired.expiresAt = now.addingTimeInterval(-1)
        precondition(ForecastTimeline.select([expired], now: now).isEmpty)
        print("PASS: lookahead prevention, duplicate prevention, location/time/distance matching, paired-hour threshold, horizon-specific ranking, station-history scoring, held-out gate, distinct-day and like-for-like gates, expired signed frame exclusion")
    }
}
