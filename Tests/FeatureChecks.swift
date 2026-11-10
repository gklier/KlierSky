import Foundation

// Checks for behavior added in 0.4: radar buffering, model futurecast timing,
// official alert decoding (from a real saved NWS reply), outlook wording.
@main struct FeatureChecks {
    static func hour(_ index: Int, rain: Double = 0, chance: Double = 0, code: Int? = 0, base: Date) -> Hour {
        Hour(time: base.addingTimeInterval(Double(index) * 3600), temperature: 50, rain: rain, chance: chance, code: code, daylight: true, wind: 5)
    }
    static func main() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // --- Radar buffer: bounded loading, no half-loaded frame during playback ---
        var buffer = RadarBuffer(count: 13, target: 12, now: t0)
        buffer.tick(now: t0)
        func loading(_ b: RadarBuffer) -> [Int] { b.states.indices.filter { if case .loading = b.states[$0] { return true }; return false } }
        precondition(loading(buffer) == [0, 1, 12], "at most three frames load at once, playhead first then forward: \(loading(buffer))")
        precondition(buffer.displayed == 12, "the first frame is shown immediately so the map is never blank by choice")
        precondition(buffer.opacity(12) == RadarBuffer.shownOpacity && buffer.opacity(0) == RadarBuffer.warmOpacity && buffer.opacity(5) == 0)
        precondition(buffer.nextForPlayback() == nil, "playback must wait while the next frame has no tiles")
        // A cache probe for an optional placeholder tile is not a pending load.
        buffer.tile(frame: 0, key: "parent", event: .cacheLookup, now: t0)
        // Frame 0: one tile from cache (then re-checked online), one from the network.
        buffer.tile(frame: 0, key: "a", event: .cacheLookup, now: t0)
        buffer.tile(frame: 0, key: "a", event: .cacheData, now: t0)
        buffer.tile(frame: 0, key: "a", event: .networkRequest, now: t0)
        buffer.tile(frame: 0, key: "b", event: .cacheLookup, now: t0)
        buffer.tile(frame: 0, key: "b", event: .networkRequest, now: t0)
        buffer.tile(frame: 0, key: "a", event: .finished, now: t0.addingTimeInterval(0.1))
        buffer.tick(now: t0.addingTimeInterval(0.4))
        precondition(!buffer.isUsable(0), "one tile still outstanding")
        buffer.tile(frame: 0, key: "b", event: .finished, now: t0.addingTimeInterval(0.5))
        buffer.tile(frame: 0, key: "a", event: .networkRequest, now: t0.addingTimeInterval(0.55))   // late re-check of an already drawn tile
        buffer.tick(now: t0.addingTimeInterval(0.8))
        precondition(buffer.isUsable(0) && buffer.states[0] == .ready, "frame is ready once every needed tile is parsed: \(buffer.states[0])")
        precondition(buffer.nextForPlayback() == 0)
        precondition(loading(buffer).count == 3, "a finished frame frees a slot for the next one: \(loading(buffer))")
        // Scrubbing to a frame that is not ready keeps the current picture until it arrives or patience runs out.
        buffer.setTarget(6, now: t0.addingTimeInterval(1)); buffer.tick(now: t0.addingTimeInterval(1))
        precondition(buffer.displayed == 12 && buffer.isBuffering)
        buffer.tick(now: t0.addingTimeInterval(1 + 2.6))
        precondition(buffer.displayed == 6, "after the patience window the requested frame is shown as it loads")
        // A failed tile marks the frame incomplete rather than silently complete.
        var failing = RadarBuffer(count: 2, target: 0, now: t0); failing.tick(now: t0)
        failing.tile(frame: 0, key: "x", event: .networkRequest, now: t0); failing.tile(frame: 0, key: "x", event: .failed, now: t0.addingTimeInterval(0.2))
        failing.tick(now: t0.addingTimeInterval(0.5))
        precondition(failing.states[0] == .incomplete && failing.incompleteCount == 1)
        // Tiles that never arrive stop blocking after the give-up time, and are flagged.
        var stalled = RadarBuffer(count: 2, target: 0, now: t0); stalled.tick(now: t0)
        stalled.tile(frame: 1, key: "y", event: .networkRequest, now: t0)
        stalled.tick(now: t0.addingTimeInterval(5)); precondition(!stalled.isUsable(1))
        stalled.tick(now: t0.addingTimeInterval(10.1)); precondition(stalled.states[1] == .incomplete)
        // Long timelines keep a bounded window resident.
        var long = RadarBuffer(count: 40, target: 0, now: t0)
        for step in 0..<400 { long.tick(now: t0.addingTimeInterval(Double(step) * 0.5)) }
        let resident = long.states.filter { $0 != .idle }.count
        precondition(resident == long.config.maxResident, "window is bounded: \(resident)")
        precondition(long.opacity(25) == 0, "frames outside the window fetch nothing")
        long.setTarget(20, now: t0.addingTimeInterval(300)); long.tick(now: t0.addingTimeInterval(300))
        precondition(long.states[20] != .idle && long.states[2] == .idle, "the window follows the playhead")
        precondition(RadarBuffer(count: 0).nextForPlayback() == nil && RadarBuffer(count: 1).nextForPlayback() == nil)

        // --- HRRR futurecast: real model steps only, one run, exact valid times ---
        let iso = ISO8601DateFormatter()
        let run = iso.date(from: "2026-11-10T03:00:00Z")!
        let now = iso.date(from: "2026-11-10T04:40:00Z")!
        let frames = HRRRFuturecast.frames(run: run, now: now)
        precondition(frames.first!.validTime == iso.date(from: "2026-11-10T04:45:00Z")!, "no frame in the past is offered as a forecast")
        precondition(frames.last!.validTime == run.addingTimeInterval(18 * 3600))
        precondition(frames.allSatisfy { $0.kind == .forecast && $0.issuedTime == run && $0.tileURL.contains("-202611100300/") && $0.tileURL.hasPrefix("https://") })
        precondition(zip(frames, frames.dropFirst()).allSatisfy { $1.validTime.timeIntervalSince($0.validTime) == 900 }, "native 15-minute steps, nothing interpolated")
        precondition(frames.first!.tileURL.contains("REFD-F0105-"), "forecast minute matches valid time: \(frames.first!.tileURL)")
        let shown = ForecastTimeline.select(frames, now: now)
        precondition(shown.count <= 72 && shown.allSatisfy { f in frames.contains { $0.id == f.id } })
        func step(_ initTime: String, _ minute: Double, _ valid: String) -> HRRRFuturecast.Step { HRRRFuturecast.Step(model_init_utc: initTime, forecast_minute: minute, model_forecast_utc: valid) }
        precondition(HRRRFuturecast.completeRun(first: step("2026-11-10T03:00:00Z", 0, "2026-11-10T03:00:00Z"), last: step("2026-11-10T03:00:00Z", 1080, "2026-11-10T21:00:00Z"), now: now) == run)
        // New run still rendering: fall back to the previous complete run, never mix the two.
        precondition(HRRRFuturecast.completeRun(first: step("2026-11-10T04:00:00Z", 0, "2026-11-10T04:00:00Z"), last: step("2026-11-10T03:00:00Z", 1080, "2026-11-10T21:00:00Z"), now: now) == run)
        // Stale, future-dated or inconsistent metadata is refused: nothing is shown.
        precondition(HRRRFuturecast.completeRun(first: step("2026-11-09T18:00:00Z", 0, "2026-11-09T18:00:00Z"), last: step("2026-11-09T18:00:00Z", 1080, "2026-11-10T12:00:00Z"), now: now) == nil)
        precondition(HRRRFuturecast.completeRun(first: step("2026-11-10T09:00:00Z", 0, "2026-11-10T09:00:00Z"), last: step("2026-11-10T09:00:00Z", 1080, "2026-11-11T03:00:00Z"), now: now) == nil)
        precondition(HRRRFuturecast.completeRun(first: step("2026-11-10T03:00:00Z", 0, "2026-11-10T03:00:00Z"), last: step("2026-11-10T03:00:00Z", 1080, "2026-11-10T20:00:00Z"), now: now) == nil)
        // Look-ahead is what remains of the run, not the run length: a 3.5-hour-old run leaves 14.5 hours.
        let aged = Date(timeIntervalSince1970: 1_794_000_000)
        let agedFrames = HRRRFuturecast.frames(run: aged.addingTimeInterval(-3.5 * 3600), now: aged)
        precondition(HRRRFuturecast.lookAheadMinutes(agedFrames, now: aged) == 870 && HRRRFuturecast.lookAheadMinutes([], now: aged) == 0)
        precondition(agedFrames.allSatisfy { $0.validTime >= aged && $0.kind == .forecast } && Set(agedFrames.map(\.issuedTime)).count == 1)
        precondition(HRRRFuturecast.covers(latitude: 47.6, longitude: -122.3) && !HRRRFuturecast.covers(latitude: 51.5, longitude: -0.1) && !HRRRFuturecast.covers(latitude: 21.3, longitude: -157.8))

        // --- Official alerts: real NWS reply saved 2026-11-09 ---
        let alerts = try NWSAlerts.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(alerts.count == 1)
        let alert = alerts[0]
        precondition(alert.event == "Flood Warning" && alert.severity == "Severe" && alert.rank == 1)
        precondition(alert.sender?.hasPrefix("NWS") == true && alert.area?.isEmpty == false && alert.instruction != nil && alert.description != nil)
        precondition(alert.sent == iso.date(from: "2026-11-10T01:13:00Z"), "issue time keeps its offset: \(String(describing: alert.sent))")
        precondition(alert.ends == iso.date(from: "2026-11-14T06:00:00Z") && alert.endTime == alert.ends)
        precondition(alert.isCurrent(iso.date(from: "2026-11-12T00:00:00Z")!) && !alert.isCurrent(iso.date(from: "2026-11-14T06:00:01Z")!))
        precondition(!alert.instruction!.contains("flood\ndeaths"), "hard-wrapped lines are joined")
        var feed = AlertFeed(placeID: "p", coverage: .covered, alerts: alerts, fetchedAt: now, failed: false)
        precondition(feed.current(now).count == 1 && !feed.isStale(now))
        precondition(feed.current(iso.date(from: "2026-11-15T00:00:00Z")!).isEmpty, "expired alerts drop out by themselves")
        precondition(feed.isStale(now.addingTimeInterval(1801)), "an old list is never presented as current")
        feed.failed = true; precondition(feed.isStale(now), "a failed check is never presented as 'no alerts'")
        precondition(AlertFeed(placeID: "p").isStale(now), "unchecked is not the same as clear")
        let cancelled = #"{"features":[{"properties":{"id":"a","event":"Test Message","status":"Test","messageType":"Alert"}},{"properties":{"id":"b","event":"Tornado Warning","status":"Actual","messageType":"Cancel"}},{"properties":{"id":"c","event":"Tornado Warning","status":"Actual","messageType":"Alert","severity":"Extreme"}},{"properties":{"id":"c","event":"Tornado Warning","status":"Actual","messageType":"Alert","severity":"Extreme"}},{"properties":{"id":"d","event":"Wind Advisory","status":"Actual","messageType":"Update","severity":"Minor"}}]}"#
        let filtered = try NWSAlerts.decode(Data(cancelled.utf8))
        precondition(filtered.map(\.id) == ["c", "d"], "tests, cancellations and duplicates are dropped: \(filtered.map(\.id))")
        precondition(AlertFeed(placeID: "p", coverage: .covered, alerts: filtered.reversed(), fetchedAt: now).current(now).first?.id == "c", "most severe first")
        precondition(NWSAlerts.mayCover(latitude: 39.74, longitude: -104.99) && NWSAlerts.mayCover(latitude: 21.3, longitude: -157.8) && NWSAlerts.mayCover(latitude: 61.2, longitude: -149.9))
        precondition(!NWSAlerts.mayCover(latitude: 51.5, longitude: -0.1) && !NWSAlerts.mayCover(latitude: -33.9, longitude: 151.2))
        precondition((try? NWSAlerts.decode(Data("{}".utf8))) == nil, "a malformed reply is an error, not an empty list")

        // --- Air quality: model value or nothing ---
        precondition(AirQuality.decode(Data(#"{"current":{"time":1794283200,"us_aqi":52}}"#.utf8))?.category == "Moderate")
        precondition(AirQuality.decode(Data(#"{"current":{"time":1794283200,"us_aqi":null}}"#.utf8)) == nil, "missing stays missing")

        // --- Outlook sentence: hourly wording only, from provider values ---
        func label(_ date: Date) -> String { "H\(Int(date.timeIntervalSince(t0) / 3600))" }
        let dry = (0..<12).map { hour($0, base: t0) }
        precondition(Outlook.sentence(dry, label: label) == "No precipitation expected in the next 12 hours.")
        precondition(Outlook.sentence(Array(dry.prefix(5)), label: label) == nil, "too few hours: say nothing")
        precondition(Outlook.sentence(Array(dry.prefix(8)), label: label) == "No precipitation expected in the hours shown.", "never claims 12 hours it does not have")
        var later = dry; later[4] = hour(4, rain: 0.6, chance: 70, code: 61, base: t0)
        precondition(Outlook.sentence(later, label: label) == "Rain likely around H4 (70%).")
        later[4] = hour(4, rain: 0.3, chance: 38, code: 61, base: t0)
        precondition(Outlook.sentence(later, label: label) == "Rain possible around H4 (38%).", "38% is not 'likely'")
        var slight = dry; slight[7] = hour(7, rain: 0, chance: 35, code: 71, base: t0)
        precondition(Outlook.sentence(slight, label: label) == "Chance of snow around H7 (35%).")
        var raining = dry; raining[0] = hour(0, rain: 1.2, chance: 90, code: 63, base: t0); raining[1] = hour(1, rain: 0.4, chance: 80, code: 61, base: t0)
        precondition(Outlook.sentence(raining, label: label) == "Rain this hour, easing around H2.")
        precondition(Outlook.sentence((0..<12).map { hour($0, rain: 1, chance: 90, code: 73, base: t0) }, label: label) == "Snow continuing through the next 12 hours.")

        // --- Condition codes: one mapping, unknown is never shown as clear ---
        precondition(WeatherCode.kind(nil) == .unknown && WeatherCode.kind(-1) == .unknown && WeatherCode.symbol(-1) == "questionmark.circle")
        precondition(WeatherCode.kind(0) == .clear && WeatherCode.kind(3) == .overcast && WeatherCode.kind(45) == .fog && WeatherCode.kind(61) == .rain)
        precondition(WeatherCode.kind(69) == .sleet && WeatherCode.kind(73) == .snow && WeatherCode.kind(80) == .showers && WeatherCode.kind(95) == .thunder)
        precondition(WeatherCode.symbol(0, day: false) != WeatherCode.symbol(0, day: true))
        print("PASS: radar buffering and playback gating, model-run frame timing, official alert decoding and staleness, air quality, outlook wording, condition codes")
    }
}
