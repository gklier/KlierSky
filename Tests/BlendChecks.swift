import Foundation

// Checks for the multi-source blend: source adapters against recorded real replies, the
// weighted average itself, and weights from scored forecasts.
@main struct BlendChecks {
    static func close(_ a: Double?, _ b: Double, _ tolerance: Double = 0.01) -> Bool { a.map { abs($0 - b) <= tolerance } ?? false }
    static func main() throws {
        let fixtures = CommandLine.arguments[1]
        func file(_ name: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: fixtures + "/" + name)) }
        let formatter = ISO8601DateFormatter()

        // --- MET Norway: recorded reply, 2026-11-10, Milwaukee ---
        let recorded = formatter.date(from: "2026-11-10T20:10:00Z")!
        let norway = try METNorway.decode(try file("metno-complete.json"), now: recorded)
        precondition(norway.source == "MET Norway" && norway.hours.count == 30, "only one-hour entries are used, coarser steps are skipped: \(norway.hours.count)")
        let first = norway.hours[formatter.date(from: "2026-11-10T20:00:00Z")!]!
        precondition(close(first.temperature, 59.0) && close(first.wind, 3.3 * 2.236936) && close(first.rain, 0) && first.code == 0 && first.daylight == true, "Celsius and m/s are converted: \(first)")
        precondition(close(norway.current?.temperature_2m, 59.0) && norway.current?.is_day == 1, "the present hour doubles as current conditions")
        let stale = try METNorway.decode(try file("metno-complete.json"), now: recorded.addingTimeInterval(3 * 86400))
        precondition(stale.current == nil, "an old reply never supplies current conditions")
        precondition(METNorway.code("heavyrainshowers_night").code == 82 && METNorway.code("lightsnow").code == 71 && METNorway.code("rainandthunder").code == 95 && METNorway.code("sleet").code == 69)
        precondition(METNorway.code("partlycloudy_night").daylight == false && METNorway.code("something_new").code == nil, "unknown symbols stay unknown")

        // --- US National Weather Service hourly: recorded reply ---
        let nws = try NWSHourly.decode(try file("nws-hourly.json"))
        precondition(nws.source == "NWS" && nws.hours.count == 30 && nws.current == nil && nws.days.isEmpty)
        let nwsFirst = nws.hours[formatter.date(from: "2026-11-10T20:00:00Z")!]!
        precondition(nwsFirst.temperature == 65 && nwsFirst.chance == 0 && close(nwsFirst.dewPoint, 36.0) && nwsFirst.wind == 5 && nwsFirst.windDirection == 270 && nwsFirst.code == 0 && nwsFirst.rain == nil, "no precipitation amount is invented for NWS: \(nwsFirst)")
        precondition(NWSHourly.speed("5 to 15 mph") == 10 && NWSHourly.speed("calm") == nil)
        precondition(NWSHourly.code("Chance Rain Showers") == 80 && NWSHourly.code("Slight Chance Thunderstorms") == 95 && NWSHourly.code("Mostly Cloudy") == 3 && NWSHourly.code("Patchy Fog") == 45 && NWSHourly.code("Mostly Sunny") == 1 && NWSHourly.code("Blustery") == nil)

        // --- Open-Meteo models: column naming as documented ("<variable>_<model>"). Shape only; not a recorded reply. ---
        let shaped = Data(#"{"hourly":{"time":[1800000000,1800003600],"temperature_2m_gfs_seamless":[50,51],"precipitation_gfs_seamless":[0,0.4],"weather_code_gfs_seamless":[3,61],"temperature_2m_ecmwf_ifs025":[48,null],"temperature_2m_gem_seamless":[null,null]}}"#.utf8)
        let models = try OpenMeteoModels.decode(shaped)
        precondition(models.map(\.source) == ["ECMWF", "NOAA GFS"], "a model with no data here is left out: \(models.map(\.source))")
        precondition(models[1].hours.count == 2 && models[1].hours[Date(timeIntervalSince1970: 1_800_003_600)]?.code == 61 && models[0].hours.count == 1)
        precondition((try? OpenMeteoModels.decode(Data(#"{"error":true,"reason":"limit"}"#.utf8))) == nil, "an error reply yields no sources")

        // --- The weighted average ---
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func hour(_ index: Int) -> Date { now.addingTimeInterval(Double(index) * 3600) }
        func series(_ name: String, temperature: Double, count: Int = 24, rain: Double? = 0, chance: Double? = 10, direction: Double? = nil, code: Int? = 2, current: Bool = true) -> SourceSeries {
            var s = SourceSeries(source: name)
            for i in 0..<count { s.hours[hour(i)] = SeriesHour(temperature: temperature, chance: chance, rain: rain, wind: 10, windDirection: direction, code: code, daylight: true) }
            if current { s.current = Forecast.Current(temperature_2m: temperature, apparent_temperature: temperature - 2, weather_code: code ?? -1, wind_speed_10m: 10, is_day: 1) }
            s.days = [DayForecast(dateKey: "2027-01-15", low: temperature - 10, high: temperature + 10, code: code, source: name)]
            return s
        }
        let weights: (Int) -> [String: Double] = { _ in ["Foreca": 3, "Open-Meteo": 2, "NWS": 1] }
        let a = series("Foreca", temperature: 60, rain: 1.0, chance: 80, direction: 350, code: 63)
        let b = series("Open-Meteo", temperature: 54, rain: 0, chance: 20, direction: 10, code: 3)
        var c = series("NWS", temperature: 48, count: 12, rain: nil, chance: 50, code: 80, current: false); c.days = []
        let blended = Blend.combine([a, b, c], weights: weights, now: now)!
        let hours = blended.hours(relativeTo: now)
        precondition(blended.source == "Blend" && hours.count == 24)
        // (60×3 + 54×2 + 48×1) ÷ 6 = 56 while all three report; (60×3 + 54×2) ÷ 5 = 57.6 after NWS ends.
        precondition(close(hours[0].temperature, 56) && close(hours[20].temperature, 57.6), "the most trusted source weighs most; weights renormalise when a source ends")
        let expectedChance: Double = 330.0 / 6.0      // (80×3 + 20×2 + 50×1) ÷ 6
        let expectedRain: Double = 3.0 / 5.0          // NWS has no amount: (1.0×3 + 0×2) ÷ 5
        precondition(close(hours[0].chance, expectedChance), "all three report a chance")
        precondition(close(hours[0].rain, expectedRain), "a source with no value for a field is left out of that field, not counted as zero")
        precondition(hours[0].code == 63, "conditions come from the highest-ranked source, never an average of codes")
        precondition(close(hours[0].windDirection, 358, 0.1), "directions average around north, not through south: \(hours[0].windDirection ?? -1)")
        precondition(close(blended.current.temperature_2m, 57.6) && close(blended.current.apparent_temperature, 55.6), "current conditions use only sources that publish them")
        precondition(blended.days.count == 1 && close(blended.days[0].high, 67.6) && blended.days[0].source == "Blend")
        let info = blended.blend!
        precondition(info.members.map(\.source) == ["Foreca", "Open-Meteo", "NWS"] && close(info.members[0].share, 0.5) && !info.isMeasured && info.dailySources == ["Foreca", "Open-Meteo"])
        precondition(blended.sourceLine == "Blend of 3 sources (starting weights)" && blended.dailySourceLine == "Blend of Foreca and Open-Meteo")
        precondition((try? blended.validated(now: now)) != nil, "a blend passes the same validation as any forecast")
        // The blend survives saving and reloading with its provenance.
        let reloaded = try JSONDecoder().decode(Forecast.self, from: JSONEncoder().encode(blended))
        precondition(reloaded.blend == info && reloaded.source == "Blend")
        // A missing value stays missing: nobody reports gusts, so there are none.
        precondition(hours.allSatisfy { $0.gust == nil && $0.uv == nil })
        // One source only: it is shown under its own name, not called a blend.
        let single = Blend.combine([b], weights: weights, now: now)!
        precondition(single.source == "Open-Meteo" && single.blend == nil && single.sourceLine == "Open-Meteo")
        // A source with zero weight or no hours takes no part; duplicates are ignored.
        let trimmed = Blend.combine([a, b, series("Unlisted", temperature: 0), SourceSeries(source: "NWS"), a], weights: weights, now: now)!
        precondition(trimmed.blend!.members.count == 2 && close(trimmed.hours(relativeTo: now)[0].temperature, 57.6))
        // Without any source of current conditions there is no blend, rather than an invented "now".
        precondition(Blend.combine([c], weights: weights, now: now) == nil)
        // Hours that do not line up (a half-hour time zone) are never mixed.
        var offset = SourceSeries(source: "NWS"); for i in 0..<24 { offset.hours[hour(i).addingTimeInterval(1800)] = SeriesHour(temperature: 0) }
        precondition(close(Blend.combine([a, b, offset], weights: weights, now: now)!.hours(relativeTo: now)[0].temperature, 57.6))
        // Different weights per lead time are honoured.
        let byLead = Blend.combine([a, b], weights: { $0 == 0 ? ["Foreca": 1, "Open-Meteo": 1] : ["Foreca": 0, "Open-Meteo": 1] }, now: now)!.hours(relativeTo: now)
        precondition(close(byLead[1].temperature, 57) && close(byLead[10].temperature, 54))
        precondition(Blend.prior("Foreca") > Blend.prior("Open-Meteo") && Blend.prior("Open-Meteo") > Blend.prior("Unknown source"), "the starting ranking puts the preferred source first")

        // --- Weights from scored forecasts ---
        func scores(_ provider: String, miss: Double, count: Int = 60, spacingHours: Double = 3) -> [VerifiedTemperature] {
            (0..<count).map { i in
                let time = now.addingTimeInterval(-Double(count - i) * spacingHours * 3600)
                return VerifiedTemperature(id: UUID(), captureID: UUID(), placeID: "place", provider: provider, targetTime: time, observedTime: time, station: "TEST", stationDistanceKM: 5, bucket: 0, errorF: miss, capturedAt: time.addingTimeInterval(-7200))
            }
        }
        let names = ["Foreca", "Open-Meteo", "NWS"]
        let none = AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 0, samples: [], now: now)
        precondition(none.measured.isEmpty && none.weights == Blend.startingWeights(names), "no evidence: the starting ranking is used and said to be a starting ranking")
        let evidence = scores("Foreca", miss: 1) + scores("Open-Meteo", miss: 2) + scores("NWS", miss: -4)
        let measured = AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 0, samples: evidence, now: now)
        // Typical miss is 2°F. Foreca: 3 × (2/1)² = 12; Open-Meteo: 2 × 1 = 2; NWS: 2 × (2/4)² = 0.5.
        precondition(measured.measured == Set(names) && measured.hours == 60 && close(measured.weights["Foreca"], 12) && close(measured.weights["Open-Meteo"], 2) && close(measured.weights["NWS"], 0.5), "\(measured)")
        // A wildly better score is capped at a factor of four either way.
        let extreme = AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 0, samples: scores("Foreca", miss: 0.3) + scores("Open-Meteo", miss: 3) + scores("NWS", miss: 30), now: now)
        precondition(close(extreme.weights["Foreca"], 12) && close(extreme.weights["NWS"], 0.5))
        // Too few days, too few hours, one scored source, or another lead-time group: starting weights stay.
        precondition(AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 0, samples: scores("Foreca", miss: 1, spacingHours: 1) + scores("Open-Meteo", miss: 2, spacingHours: 1), now: now).measured.isEmpty, "consecutive hours from a few days are not enough")
        precondition(AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 0, samples: scores("Foreca", miss: 1, count: 12) + scores("Open-Meteo", miss: 2, count: 12), now: now).measured.isEmpty)
        precondition(AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 0, samples: scores("Foreca", miss: 1), now: now).measured.isEmpty)
        precondition(AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 1, samples: evidence, now: now).measured.isEmpty)
        precondition(AdaptiveEngine.blendWeights(sources: names, placeID: "elsewhere", bucket: 0, samples: evidence, now: now).measured.isEmpty)
        // A source scored on too few hours keeps its starting weight while the others are measured.
        let partial = AdaptiveEngine.blendWeights(sources: names, placeID: "place", bucket: 0, samples: scores("Foreca", miss: 1) + scores("Open-Meteo", miss: 2) + scores("NWS", miss: 9, count: 5), now: now)
        precondition(partial.measured == ["Foreca", "Open-Meteo"] && partial.weights["NWS"] == Blend.prior("NWS"))
        // End to end: measured weights flow into the blend and its label.
        let final = Blend.combine([a, b], weights: { _ in measured.weights }, measured: measured.measured, now: now)!
        let expectedFinal: Double = 828.0 / 14.0      // (60×12 + 54×2) ÷ 14
        precondition(final.blend!.isMeasured && final.sourceLine == "Blend of 2 sources (weights from scored forecasts)")
        precondition(close(final.hours(relativeTo: now)[0].temperature, expectedFinal))
        print("PASS: MET Norway and NWS decoding from recorded replies, model column naming, weighted average, missing values, wind direction, lead-time weights, measured weights and caps, blend labels")
    }
}
