import SwiftUI

struct HistoricalDay: Identifiable, Codable {
    let date: String
    let high: Double?
    let low: Double?
    let mean: Double?
    var id: String { date }
}
struct HistoryComparison {
    let lastYear: HistoricalDay?
    let averageHigh: Double?
    let averageLow: Double?
    let sampleCount: Int
}

enum WeatherArchive {
    struct Reply: Decodable {
        struct Daily: Decodable {
            let time: [String]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let temperature_2m_mean: [Double?]
        }
        let daily: Daily
    }
    static func fetch(_ place: Place, from: String, through: String, zone: TimeZone) async throws -> [HistoricalDay] {
        var url = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
        url.queryItems = ["latitude": String(place.latitude), "longitude": String(place.longitude), "start_date": from, "end_date": through, "daily": "temperature_2m_max,temperature_2m_min,temperature_2m_mean", "temperature_unit": "fahrenheit", "timezone": zone.identifier, "models": "era5"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let reply: Reply = try await Network.get(url.url!, timeout: 45)
        return reply.daily.time.enumerated().map { i, date in
            HistoricalDay(date: date, high: reply.daily.temperature_2m_max.indices.contains(i) ? reply.daily.temperature_2m_max[i] : nil, low: reply.daily.temperature_2m_min.indices.contains(i) ? reply.daily.temperature_2m_min[i] : nil, mean: reply.daily.temperature_2m_mean.indices.contains(i) ? reply.daily.temperature_2m_mean[i] : nil)
        }
    }
    static func key(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func average(_ days: [HistoricalDay], monthDay: String) -> (high: Double?, low: Double?, count: Int) {
        let matching = days.filter { $0.date.suffix(5) == monthDay }
        let complete = matching.filter { $0.high?.isFinite == true && $0.low?.isFinite == true }
        guard complete.count >= 20 else { return (nil, nil, complete.count) }
        return (complete.compactMap(\.high).reduce(0, +) / Double(complete.count), complete.compactMap(\.low).reduce(0, +) / Double(complete.count), complete.count)
    }
    static func comparison(_ place: Place, date: Date, zone: TimeZone) async throws -> HistoryComparison {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = key(date, zone: zone)
        // Feb 29 has fewer than twenty samples in a 30-year baseline. Keep it missing.
        let lastDate = calendar.date(byAdding: .year, value: -1, to: date)!
        let lastKey = key(lastDate, zone: zone)
        async let last = fetch(place, from: lastKey, through: lastKey, zone: zone)
        let file = AppFiles.url("history-baseline-" + place.id.replacingOccurrences(of: "/", with: "_") + ".json")
        let baseline: [HistoricalDay]
        if let saved = try? JSONDecoder().decode([HistoricalDay].self, from: Data(contentsOf: file)) {
            baseline = saved
        } else {
            baseline = try await fetch(place, from: "1991-01-01", through: "2020-12-31", zone: zone)
            try Task.checkCancellation()
            if let data = try? JSONEncoder().encode(baseline) { try? data.write(to: file, options: .atomic) }
        }
        let average = average(baseline, monthDay: String(day.suffix(5)))
        return HistoryComparison(lastYear: try await last.first, averageHigh: average.high, averageLow: average.low, sampleCount: average.count)
    }
}

struct WeatherHistoryView: View {
    let place: Place
    let forecast: Forecast
    @Environment(\.units) private var units
    @State private var comparison: HistoryComparison?
    @State private var selectedDate = Date().addingTimeInterval(-7 * 86400)
    @State private var selectedDay: HistoricalDay?
    @State private var loading = false
    @State private var historyError: String?
    @State private var comparisonError: String?
    @State private var retry = 0
    var body: some View {
        List {
            Section {
                Text(place.name).font(.headline)
                if let today = forecast.days.first {
                    LabeledContent("Today's forecast high / low", value: "\(units.temperature(today.high)) / \(units.temperature(today.low))")
                }
                if let comparison {
                    if let last = comparison.lastYear {
                        LabeledContent(last.date + " high / low", value: "\(units.temperature(last.high)) / \(units.temperature(last.low))")
                    }
                    LabeledContent("1991–2020 average high / low", value: "\(units.temperature(comparison.averageHigh)) / \(units.temperature(comparison.averageLow))")
                    if let high = forecast.days.first?.high, let average = comparison.averageHigh {
                        let difference = units.temperatureValue(high) - units.temperatureValue(average)
                        Text(String(format: "Today's forecast high is %.1f° %@ the historical average.", abs(difference), difference >= 0 ? "above" : "below"))
                    }
                    Text("Average of \(comparison.sampleCount) matching calendar days. At least 20 complete years are required.").font(.caption).foregroundStyle(.secondary)
                } else if let comparisonError {
                    Text(comparisonError).foregroundStyle(Sky.caution)
                    Button("Retry comparison") { retry += 1 }
                } else { ProgressView("Loading comparison…") }
            } header: { Text("Today in context") }
            Section {
                DatePicker("Past date", selection: $selectedDate, in: earliest...Date().addingTimeInterval(-7 * 86400), displayedComponents: .date)
                if loading { ProgressView("Loading history…") }
                if let selectedDay {
                    LabeledContent("High", value: units.temperature(selectedDay.high))
                    LabeledContent("Low", value: units.temperature(selectedDay.low))
                    LabeledContent("Daily mean", value: units.temperature(selectedDay.mean))
                }
                if let historyError { Text(historyError).foregroundStyle(Sky.caution) }
            } header: { Text("Explore a past day") }
            Section {
                Text("Open-Meteo · ECMWF ERA5 reanalysis. Historical values are gridded estimates combining models and observations. Today's values are the displayed forecast. Differences include the effects of the data sources and grid resolution.")
                Text("The baseline is the 1991–2020 average for this calendar date and location. It is a reanalysis reference, rather than an official station climate normal. On February 29 the average is unavailable if fewer than 20 years match.")
                Link("Historical data & attribution", destination: URL(string: "https://open-meteo.com/en/docs/historical-weather-api")!)
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .environment(\.timeZone, forecast.forecastTimeZone)
        .navigationTitle("Weather history").navigationBarTitleDisplayMode(.inline)
        .task(id: retry) {
            comparisonError = nil
            do { comparison = try await WeatherArchive.comparison(place, date: Date(), zone: forecast.forecastTimeZone) }
            catch is CancellationError { }
            catch { if !Task.isCancelled { comparisonError = "Historical comparison is unavailable. Try again later." } }
        }
        .task(id: selectedDate) {
            loading = true; historyError = nil; selectedDay = nil
            do {
                let day = WeatherArchive.key(selectedDate, zone: forecast.forecastTimeZone)
                let result = try await WeatherArchive.fetch(place, from: day, through: day, zone: forecast.forecastTimeZone)
                try Task.checkCancellation()
                selectedDay = result.first
                loading = false
            } catch { if !Task.isCancelled { historyError = "Historical data is unavailable for this date."; loading = false } }
        }
    }
    private var earliest: Date { Calendar(identifier: .gregorian).date(from: DateComponents(year: 1940, month: 1, day: 1))! }
}
