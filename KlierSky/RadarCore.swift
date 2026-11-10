import Foundation

// Real model imagery for the Futurecast tab.
//
// Source: NOAA's HRRR model, simulated radar reflectivity, as rendered into map
// tiles by the Iowa Environmental Mesonet (Iowa State University), which
// documents this tile service and places its products in the public domain.
// Every frame is one actual model time step of one model run. Nothing is
// interpolated, extrapolated from radar, or relabelled.
//
// Checked against the live service on 2026-11-10 (see Docs/CLOUD-REVIEW-2026-11-10.md):
// the run-pinned layer name is IEM's documented "archived HRRR reflectivity"
// template; 15-minute steps exist from minute 0 to 1080; the newest complete run
// was between 1.7 and 3.6 hours old across checks, leaving 14.3 to 16.3 hours of
// it in the future. The model runs 18 hours, but the usable look-ahead is the run
// length minus the run's age: expect roughly 14 to 16 hours, never a full 18. Tiles outside the model domain
// are transparent, exactly like dry areas inside it.
enum HRRRFuturecast {
    static let attribution = "NOAA HRRR model · tiles by Iowa Environmental Mesonet"
    static let stepMinutes = 15
    static let horizonMinutes = 18 * 60     // length of a model run, not the look-ahead from now
    /// Minutes of the frames that still lie ahead of `now`: the honest "how far ahead" figure.
    static func lookAheadMinutes(_ frames: [WeatherFrame], now: Date = Date()) -> Int {
        guard let last = frames.map(\.validTime).max(), last > now else { return 0 }
        return Int(last.timeIntervalSince(now) / 60)
    }
    /// The model domain is the contiguous United States. Kept slightly inside the edge.
    static func covers(latitude: Double, longitude: Double) -> Bool { (24.0...50.0).contains(latitude) && (-125.5...(-66.5)).contains(longitude) }
    struct Step: Decodable { let model_init_utc: String; let forecast_minute: Double; let model_forecast_utc: String }
    static func stepURL(minute: Int) -> URL { URL(string: String(format: "https://mesonet.agron.iastate.edu/data/gis/images/4326/hrrr/refd_%04d.json", minute))! }
    static func runStamp(_ run: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmm"
        return formatter.string(from: run)
    }
    /// Frames of a single, named model run. Valid time is run time plus the forecast minute.
    static func frames(run: Date, now: Date = Date()) -> [WeatherFrame] {
        let stamp = runStamp(run)
        return stride(from: 0, through: horizonMinutes, by: stepMinutes).compactMap { minute in
            let valid = run.addingTimeInterval(Double(minute) * 60)
            guard valid >= now else { return nil }
            // The run is pinned in the tile path, so frames can never mix two model runs.
            return WeatherFrame(id: "hrrr-\(stamp)-\(minute)", validTime: valid, issuedTime: run, kind: .forecast,
                                tileURL: String(format: "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/hrrr::REFD-F%04d-%@/{z}/{x}/{y}.png", minute, stamp),
                                attribution: attribution, maxZoom: 7, minZoom: 2, timeLabel: "Model run")
        }
    }
    /// Chooses the newest run that is published through its full horizon, from the service's own metadata.
    static func completeRun(first: Step, last: Step, now: Date = Date()) -> Date? {
        let formatter = ISO8601DateFormatter()
        guard let newest = formatter.date(from: first.model_init_utc), let complete = formatter.date(from: last.model_init_utc),
              let lastValid = formatter.date(from: last.model_forecast_utc), Int(last.forecast_minute.rounded()) == horizonMinutes,
              abs(lastValid.timeIntervalSince(complete) - Double(horizonMinutes) * 60) < 1 else { return nil }
        // While a new run is still being rendered the last step still belongs to the previous run: use that one.
        let run = min(newest, complete)
        // A run from the future or older than six hours is not shown as a current forecast.
        guard run <= now.addingTimeInterval(300), now.timeIntervalSince(run) <= 6 * 3600 else { return nil }
        return run
    }
    /// The service occasionally drops a connection; one retry, then give up and show nothing.
    private static func step(_ minute: Int) async throws -> Step {
        do { return try await Network.get(stepURL(minute: minute), timeout: 12) }
        catch let refusal as HTTPFailure { throw refusal }      // the service answered: retrying will not help
        catch { return try await Network.get(stepURL(minute: minute), timeout: 12) }
    }
    static func frames() async throws -> [WeatherFrame] {
        async let first = step(0)
        async let last = step(horizonMinutes)
        guard let run = completeRun(first: try await first, last: try await last) else { throw URLError(.cannotParseResponse) }
        return frames(run: run)
    }
}

/// Decides which radar frames load, which one is on screen, and when playback
/// may advance. Pure logic: the map reports tile events, this answers with
/// layer opacities. A frame is shown only once its tiles for the current view
/// have arrived, so playback never flashes half-loaded imagery.
struct RadarBuffer {
    struct Config {
        var maxResident = 14        // frames kept loaded around the playhead
        var maxLoading = 3          // frames fetching at once (bounds request bursts)
        var settle: TimeInterval = 0.9      // no tile activity for this long after warming = nothing to fetch
        var patience: TimeInterval = 2.5    // a frame the user is waiting on is shown as-is after this
        var giveUp: TimeInterval = 10       // stop waiting for missing tiles
    }
    enum State: Equatable { case idle, loading(since: Date), ready, incomplete }
    /// What the map reports per tile, in the order observed from MapLibre:
    /// cache lookup → (cache data) → network request → (network data) → parsed.
    /// A bare cache lookup is not a pending load: the map also probes for optional
    /// placeholder tiles that it never fetches. A tile counts as pending once cached
    /// data arrived or a network request started, and as shown once it is parsed.
    enum TileEvent { case cacheLookup, cacheData, networkRequest, finished, failed }
    static let warmOpacity = 0.004     // just enough for the map to fetch and keep tiles; not visible
    static let shownOpacity = 0.82

    var config = Config()
    private(set) var states: [State]
    private(set) var pending: [Set<String>]
    private var done: [Set<String>]
    private(set) var requested: [Int]
    private(set) var failures: [Int]
    private(set) var lastActivity: [Date?]
    private(set) var displayed: Int?
    private(set) var target: Int
    private var targetSince: Date
    /// Seconds each frame took from first warm-up to ready, for the measured report.
    private(set) var loadSeconds: [Int: TimeInterval] = [:]

    init(count: Int, target: Int = 0, now: Date = Date()) {
        states = Array(repeating: .idle, count: count); pending = Array(repeating: [], count: count); done = Array(repeating: [], count: count)
        requested = Array(repeating: 0, count: count); failures = Array(repeating: 0, count: count); lastActivity = Array(repeating: nil, count: count)
        self.target = count == 0 ? 0 : min(max(0, target), count - 1); targetSince = now
    }
    var count: Int { states.count }
    func isUsable(_ frame: Int) -> Bool { states.indices.contains(frame) && (states[frame] == .ready || states[frame] == .incomplete) }
    var isBuffering: Bool { count > 0 && displayed != target }
    var readyCount: Int { states.filter { $0 == .ready || $0 == .incomplete }.count }
    var incompleteCount: Int { states.filter { $0 == .incomplete }.count }

    mutating func setTarget(_ frame: Int, now: Date = Date()) {
        guard states.indices.contains(frame), frame != target else { return }
        target = frame; targetSince = now
    }
    /// The view moved or the map style reloaded: every frame needs its tiles for the new view.
    mutating func reset(now: Date = Date()) {
        for i in states.indices { clear(i) }
        targetSince = now
    }
    mutating func tile(frame: Int, key: String, event: TileEvent, now: Date = Date()) {
        guard states.indices.contains(frame) else { return }
        lastActivity[frame] = now
        switch event {
        case .cacheLookup:
            done[frame].remove(key)     // a new load cycle for this tile begins
        case .cacheData, .networkRequest:
            // A cached tile is drawn first and then re-checked online; that re-check is not a new wait.
            if event == .networkRequest, done[frame].contains(key) { return }
            if pending[frame].insert(key).inserted { requested[frame] += 1 }
            // New tiles for a frame we thought was complete (the view grew): it is loading again.
            if states[frame] == .ready || states[frame] == .incomplete { states[frame] = .loading(since: now) }
        case .finished: pending[frame].remove(key); done[frame].insert(key)
        case .failed: if pending[frame].remove(key) != nil { failures[frame] += 1 }
        }
    }
    /// Frames that should be resident, nearest playback order first.
    var residents: [Int] {
        guard count > 0 else { return [] }
        if count <= config.maxResident { return (0..<count).map { (target + $0) % count } }
        let behind = 2
        return (0..<config.maxResident).map { (target - behind + $0 + count * 2) % count }.sorted { order($0) < order($1) }
    }
    private func order(_ frame: Int) -> Int { (frame - target + count) % count }

    /// Advance the state machine. Call on tile events and on a short timer.
    mutating func tick(now: Date = Date()) {
        guard count > 0 else { displayed = nil; return }
        let resident = residents
        let keep = Set(resident)
        for i in states.indices where !keep.contains(i) && states[i] != .idle { clear(i) }
        for i in resident {
            guard case .loading(let since) = states[i] else { continue }
            let quiet = now.timeIntervalSince(lastActivity[i] ?? since)
            if requested[i] > 0, pending[i].isEmpty, quiet >= 0.15 { finish(i, failures[i] == 0 ? .ready : .incomplete, since: since, now: now) }
            else if requested[i] == 0, now.timeIntervalSince(since) >= config.settle { finish(i, .ready, since: since, now: now) }
            else if now.timeIntervalSince(since) >= config.giveUp { finish(i, .incomplete, since: since, now: now) }
        }
        var loading = resident.filter { if case .loading = states[$0] { return true }; return false }.count
        for i in resident where states[i] == .idle && loading < config.maxLoading { states[i] = .loading(since: now); loading += 1 }
        if isUsable(target) || displayed == nil || now.timeIntervalSince(targetSince) >= config.patience { displayed = target }
        else if let shown = displayed, !keep.contains(shown) { displayed = target }
    }
    private mutating func clear(_ i: Int) { states[i] = .idle; pending[i] = []; done[i] = []; requested[i] = 0; failures[i] = 0; lastActivity[i] = nil }
    private mutating func finish(_ frame: Int, _ state: State, since: Date, now: Date) {
        states[frame] = state
        if loadSeconds[frame] == nil { loadSeconds[frame] = now.timeIntervalSince(since) }
    }
    func opacity(_ frame: Int) -> Double {
        if frame == displayed { return Self.shownOpacity }
        return states.indices.contains(frame) && states[frame] != .idle ? Self.warmOpacity : 0
    }
    /// Next frame for playback, or nil while it is still buffering.
    func nextForPlayback() -> Int? {
        guard count > 1 else { return nil }
        let next = (target + 1) % count
        return isUsable(next) ? next : nil
    }
}
