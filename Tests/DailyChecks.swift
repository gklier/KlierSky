import Foundation
@main struct DailyChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let forecast = try decoder.decode(Forecast.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        _ = try forecast.validated()
        precondition(forecast.days.count == 14)
        precondition(forecast.days.allSatisfy { $0.date != nil && $0.low != nil && $0.high != nil && $0.low! <= $0.high! })
        precondition(forecast.current.relative_humidity_2m != nil)
        precondition(forecast.hours.first?.humidity != nil)
        precondition(forecast.hours.first?.dewPoint != nil)
        precondition(forecast.days.first?.probabilityLabel == (forecast.source == "Foreca" ? "Provider daily probability" : "Peak hourly rain probability"))
        let keys = Set(forecast.days.map(\.dateKey))
        precondition(keys.count == 14)
        for day in forecast.days.prefix(3) { precondition(!forecast.hours(on: day).isEmpty) }
        let wire = try JSONEncoder().encode(forecast)
        let decoded = try decoder.decode(Forecast.self, from: wire)
        precondition(decoded.days.count == 14)
        precondition(DayForecast(dateKey: "not-a-date").date == nil)
        print("PASS: live daily/statistics decoding, daily timezone grouping, missing-date handling and cache round trip")
    }
}
