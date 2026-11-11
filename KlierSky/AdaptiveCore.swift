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
    /// When the scored forecast was saved. Lets the held-out check use only evidence that existed before it.
    var capturedAt: Date? = nil
}
/// One station temperature reading used as independent truth.
struct StationReading: Equatable { let time: Date; let temperatureF: Double }
enum AdaptiveEngine {
    static func bucket(_ lead: TimeInterval) -> Int { lead < 6 * 3600 ? 0 : lead < 24 * 3600 ? 1 : lead < 72 * 3600 ? 2 : 3 }
    static func score(_ samples: [VerifiedTemperature], provider: String, placeID: String, bucket: Int, now: Date = Date()) -> (count: Int, mae: Double)? {
        let matches = samples.filter { $0.provider == provider && $0.placeID == placeID && $0.bucket == bucket && $0.targetTime <= now && now.timeIntervalSince($0.observedTime) < 30 * 86400 }
        guard !matches.isEmpty else { return nil }
        return (matches.count, matches.map { abs($0.errorF) }.reduce(0, +) / Double(matches.count))
    }
    /// In-sample ranking only. Kept for the portable checks; the app decides through `decide`, which adds the held-out and day gates.
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
            result.append(VerifiedTemperature(id: UUID(), captureID: capture.id, placeID: placeID, provider: capture.provider, targetTime: capture.hour.time, observedTime: observedAt, station: station, stationDistanceKM: distanceKM, bucket: capture.bucket, errorF: capture.hour.temperature - temperatureF, capturedAt: capture.capturedAt))
        }
        return result
    }

    static let bucketNames = ["0–6 h", "6–24 h", "1–3 days", "3+ days"]

    /// Scores saved forecasts against a station's observation history, so verification
    /// no longer depends on the app being open at the forecast hour. Same safeguards as
    /// `verify`: forecast saved at least 30 minutes before its hour, reading within 15
    /// minutes of the hour, station within 15 km, one score per provider/hour/lead group.
    static func verifyHistory(captures: [ForecastCapture], existing: [VerifiedTemperature], placeID: String, readings: [StationReading], station: String, distanceKM: Double, now: Date = Date()) -> [VerifiedTemperature] {
        guard distanceKM <= 15, distanceKM >= 0 else { return [] }
        let usable = readings.filter { $0.temperatureF.isFinite && (-130...150).contains($0.temperatureF) && $0.time <= now.addingTimeInterval(60) && now.timeIntervalSince($0.time) < 8 * 86400 }.sorted { $0.time < $1.time }
        guard !usable.isEmpty else { return [] }
        let times = usable.map { $0.time.timeIntervalSince1970 }
        func nearest(_ target: Date) -> StationReading? {
            let t = target.timeIntervalSince1970
            var low = 0, high = times.count
            while low < high { let mid = (low + high) / 2; if times[mid] < t { low = mid + 1 } else { high = mid } }
            let candidates = [low - 1, low].filter { times.indices.contains($0) }
            guard let best = candidates.min(by: { abs(times[$0] - t) < abs(times[$1] - t) }), abs(times[best] - t) <= 900 else { return nil }
            return usable[best]
        }
        var keys = Set(existing.map { "\($0.provider)|\($0.placeID)|\($0.targetTime.timeIntervalSince1970)|\($0.bucket)" })
        var result: [VerifiedTemperature] = []
        for capture in captures.sorted(by: { $0.capturedAt < $1.capturedAt }) {
            guard capture.placeID == placeID, capture.hour.time <= now, capture.capturedAt <= capture.hour.time.addingTimeInterval(-1800), let reading = nearest(capture.hour.time) else { continue }
            let key = "\(capture.provider)|\(capture.placeID)|\(capture.hour.time.timeIntervalSince1970)|\(capture.bucket)"
            guard keys.insert(key).inserted else { continue }
            result.append(VerifiedTemperature(id: UUID(), captureID: capture.id, placeID: placeID, provider: capture.provider, targetTime: capture.hour.time, observedTime: reading.time, station: station, stationDistanceKM: distanceKM, bucket: capture.bucket, errorF: capture.hour.temperature - reading.temperatureF, capturedAt: capture.capturedAt))
        }
        return result
    }

    /// Forecasts compared for the same hour must have been saved within this long of each other.
    /// Otherwise a one-hour-old forecast from one source could be ranked against a five-hour-old one from another.
    static let maximumIssueGap: TimeInterval = 3600
    /// Calendar day (UTC) of a target hour. Hours of one day share the same weather and mostly the same
    /// forecast run, so they are not independent evidence; gates below also count distinct days.
    static func day(_ time: Date) -> Int { Int((time.timeIntervalSince1970 / 86400).rounded(.down)) }

    /// Hours where every provider was scored from forecasts saved at about the same time, oldest first.
    private static func paired(_ samples: [VerifiedTemperature], providers: [String], placeID: String, bucket: Int, now: Date) -> [(target: Date, issued: Date, errors: [String: Double])] {
        var byTarget: [Date: [String: VerifiedTemperature]] = [:]
        for sample in samples where sample.placeID == placeID && sample.bucket == bucket && providers.contains(sample.provider) && sample.targetTime <= now && now.timeIntervalSince(sample.observedTime) < 30 * 86400 {
            byTarget[sample.targetTime, default: [:]][sample.provider] = sample
        }
        return byTarget.compactMap { target, row in
            guard row.count == providers.count else { return nil }
            // Scores from before issue times were recorded cannot be shown to be a like-for-like comparison: left out.
            let saved = row.values.compactMap(\.capturedAt)
            guard saved.count == row.count, let issued = saved.max(), let earliest = saved.min(), issued.timeIntervalSince(earliest) <= maximumIssueGap,
                  issued <= target.addingTimeInterval(-1800) else { return nil }
            return (target, issued, row.mapValues { abs($0.errorF) })
        }.sorted { $0.target < $1.target }
    }
    private static func winner(_ rows: [(target: Date, issued: Date, errors: [String: Double])], providers: [String], minimum: Int) -> String? {
        guard rows.count >= minimum else { return nil }
        let ranking = providers.map { provider in (provider, rows.map { $0.errors[provider]! }.reduce(0, +) / Double(rows.count)) }.sorted { $0.1 < $1.1 }
        guard ranking.count >= 2, ranking[1].1 - ranking[0].1 >= 0.5 else { return nil }
        return ranking[0].0
    }

    /// Out-of-sample result of the selection rule. For every paired hour, the rule
    /// is applied using only evidence observed before that hour's forecasts were
    /// saved, then compared with always using the baseline provider.
    struct HeldOut: Equatable {
        let evaluated: Int          // hours where a decision could be made from earlier evidence
        let switched: Int           // of those, hours where the rule picked a non-baseline provider
        let switchedDays: Int       // distinct days those switched hours fall on
        let baselineMAE: Double
        let adaptiveMAE: Double
        var improvement: Double { baselineMAE - adaptiveMAE }
    }
    static func heldOut(providers: [String], baseline: String, placeID: String, bucket: Int, samples: [VerifiedTemperature], minimum: Int = 20, now: Date = Date()) -> HeldOut? {
        guard providers.count >= 2, providers.contains(baseline) else { return nil }
        let rows = paired(samples, providers: providers, placeID: placeID, bucket: bucket, now: now)
        var evaluated = 0, switched = 0, baselineSum = 0.0, adaptiveSum = 0.0
        var switchedDays = Set<Int>()
        for (index, row) in rows.enumerated() {
            // Evidence available when this hour's forecasts were issued: earlier hours whose observation had already happened.
            let prior = rows[..<index].filter { $0.target.addingTimeInterval(900) <= row.issued }
            guard prior.count >= minimum else { continue }
            let choice = winner(Array(prior), providers: providers, minimum: minimum) ?? baseline
            evaluated += 1; if choice != baseline { switched += 1; switchedDays.insert(day(row.target)) }
            baselineSum += row.errors[baseline]!; adaptiveSum += row.errors[choice]!
        }
        guard evaluated > 0 else { return nil }
        return HeldOut(evaluated: evaluated, switched: switched, switchedDays: switchedDays.count, baselineMAE: baselineSum / Double(evaluated), adaptiveMAE: adaptiveSum / Double(evaluated))
    }

    enum Decision: Equatable {
        case collecting(paired: Int, needed: Int)       // not enough paired hours yet
        case collectingDays(days: Int, needed: Int)     // enough hours, but from too few different days
        case noClearDifference                          // enough hours, providers within 0.5°F
        case baselineBest                               // the preferred provider is already the better one
        case awaitingHeldOut(candidate: String)         // in-sample winner exists; held-out check not yet passed
        case use(String)                                // in-sample winner confirmed out of sample
    }
    /// The only path by which adaptation can change a displayed temperature.
    ///
    /// Gates, all required: `minimum` paired hours spread over `minimumDays` different days; a 0.5°F in-sample
    /// advantage; and a held-out check in which the rule switched on at least `minimumSwitched` hours across
    /// `minimumSwitchedDays` days and beat the baseline by at least `minimumGain`. These are sanity gates on a
    /// small sample, not a statistical significance test: hourly errors within a day are correlated.
    static func decide(providers: [String], baseline: String, placeID: String, bucket: Int, samples: [VerifiedTemperature], minimum: Int = 20, minimumSwitched: Int = 10, minimumDays: Int = 5, minimumSwitchedDays: Int = 3, minimumGain: Double = 0.25, now: Date = Date()) -> Decision {
        let rows = paired(samples, providers: providers, placeID: placeID, bucket: bucket, now: now)
        guard providers.count >= 2, rows.count >= minimum else { return .collecting(paired: providers.count >= 2 ? rows.count : 0, needed: minimum) }
        let days = Set(rows.map { day($0.target) }).count
        guard days >= minimumDays else { return .collectingDays(days: days, needed: minimumDays) }
        guard let candidate = winner(rows, providers: providers, minimum: minimum) else { return .noClearDifference }
        if candidate == baseline { return .baselineBest }
        guard let check = heldOut(providers: providers, baseline: baseline, placeID: placeID, bucket: bucket, samples: samples, minimum: minimum, now: now),
              check.switched >= minimumSwitched, check.switchedDays >= minimumSwitchedDays, check.improvement >= minimumGain else { return .awaitingHeldOut(candidate: candidate) }
        return .use(candidate)
    }

    /// Weights for the multi-source blend in one lead-time group.
    ///
    /// Every source starts from the stated ranking in `Blend.priors`. Sources with enough scored forecasts
    /// (`minimum` of the same hours across `minimumDays` days, so nobody is ranked on easier weather) have that
    /// starting weight scaled by how close they were: (typical miss ÷ own miss)², limited to a factor of 4
    /// either way so a short lucky run cannot take over the blend. Only past scores are used.
    struct BlendWeights: Equatable { let weights: [String: Double]; let measured: Set<String>; let hours: Int }
    static func blendWeights(sources: [String], placeID: String, bucket: Int, samples: [VerifiedTemperature], minimum: Int = 20, minimumDays: Int = 5, now: Date = Date()) -> BlendWeights {
        var weights = Blend.startingWeights(sources)
        let recent = samples.filter { $0.placeID == placeID && $0.bucket == bucket && $0.targetTime <= now && now.timeIntervalSince($0.observedTime) < 30 * 86400 && sources.contains($0.provider) }
        var byProvider: [String: [Date: Double]] = [:]
        for sample in recent { byProvider[sample.provider, default: [:]][sample.targetTime] = abs(sample.errorF) }
        // Sources with enough hours of their own, most-scored first; keep adding while the shared hours stay sufficient.
        let candidates = byProvider.filter { $0.value.count >= minimum }.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        var chosen: [String] = [], common: Set<Date> = []
        for (provider, scores) in candidates {
            let shared = chosen.isEmpty ? Set(scores.keys) : common.intersection(scores.keys)
            guard shared.count >= minimum, Set(shared.map(day)).count >= minimumDays else { continue }
            chosen.append(provider); common = shared
        }
        guard chosen.count >= 2 else { return BlendWeights(weights: weights, measured: [], hours: 0) }
        let misses = Dictionary(uniqueKeysWithValues: chosen.map { provider in (provider, common.map { byProvider[provider]![$0]! }.reduce(0, +) / Double(common.count)) })
        let sorted = misses.values.sorted()
        let typical = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        for provider in chosen {
            let ratio = max(typical, 0.25) / max(misses[provider]!, 0.25)       // misses under a quarter degree are treated alike
            weights[provider] = (weights[provider] ?? 1) * min(4, max(0.25, ratio * ratio))
        }
        return BlendWeights(weights: weights, measured: Set(chosen), hours: common.count)
    }

    struct Coverage: Equatable { let provider: String; let bucket: Int; let count: Int; let mae: Double; let bias: Double; let first: Date; let last: Date }
    static func coverage(_ samples: [VerifiedTemperature], placeID: String, now: Date = Date()) -> [Coverage] {
        var groups: [String: [VerifiedTemperature]] = [:]
        for sample in samples where sample.placeID == placeID && now.timeIntervalSince(sample.observedTime) < 30 * 86400 { groups["\(sample.provider)|\(sample.bucket)", default: []].append(sample) }
        return groups.values.map { rows in
            Coverage(provider: rows[0].provider, bucket: rows[0].bucket, count: rows.count, mae: rows.map { abs($0.errorF) }.reduce(0, +) / Double(rows.count), bias: rows.map(\.errorF).reduce(0, +) / Double(rows.count), first: rows.map(\.targetTime).min()!, last: rows.map(\.targetTime).max()!)
        }.sorted { ($0.bucket, $0.provider) < ($1.bucket, $1.provider) }
    }
}

/// Decoder for US National Weather Service station observation history.
enum StationHistory {
    private struct History: Decodable {
        struct Value: Decodable { let value: Double?; let unitCode: String?; let qualityControl: String? }
        struct Properties: Decodable { let timestamp: String; let temperature: Value }
        struct Feature: Decodable { let properties: Properties }
        let features: [Feature]
    }
    /// Quality-controlled temperature readings in °F. Readings the NWS has not passed are dropped.
    static func readings(from data: Data) throws -> [StationReading] {
        let history = try JSONDecoder().decode(History.self, from: data)
        let formatter = ISO8601DateFormatter()
        return history.features.compactMap { feature in
            let t = feature.properties.temperature
            guard t.unitCode == "wmoUnit:degC", let celsius = t.value, celsius.isFinite, ["V", "C", "S", "G"].contains(t.qualityControl ?? ""), let time = formatter.date(from: feature.properties.timestamp) else { return nil }
            return StationReading(time: time, temperatureF: celsius * 9 / 5 + 32)
        }
    }
}
