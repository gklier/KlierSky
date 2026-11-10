import SwiftUI
import Charts

enum WeatherStyle {
    static func symbol(_ code: Int?, day: Bool = true) -> String {
        guard let code, code >= 0 else { return "questionmark" }
        return code == 0 ? (day ? "sun.max.fill" : "moon.fill") : code < 4 ? (day ? "cloud.sun.fill" : "cloud.moon.fill") : code < 50 ? "cloud.fog.fill" : code < 70 ? "cloud.rain.fill" : code < 80 ? "cloud.snow.fill" : code < 95 ? "cloud.heavyrain.fill" : "cloud.bolt.rain.fill"
    }
    static func temperature(_ f: Double?, celsius: Bool) -> String { guard let f, f.isFinite else { return "—" }; return "\(Int((celsius ? (f - 32) * 5 / 9 : f).rounded()))°" }
    static func dayName(_ day: DayForecast, full: Bool = false) -> String {
        guard let date = day.date else { return day.dateKey }
        let f = DateFormatter(); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = full ? "EEEE, MMM d" : "EEE"; return f.string(from: date)
    }
    static func amount(_ mm: Double?, inches: Bool) -> String { guard let mm, mm.isFinite else { return "—" }; return String(format: inches ? "%.2f in" : "%.1f mm", inches ? mm / 25.4 : mm) }
    static func scalar(_ value: Double?, suffix: String, digits: Int = 0) -> String { guard let value, value.isFinite else { return "—" }; return String(format: "%.*f%@", digits, value, suffix) }
}
struct DailyForecastSection: View {
    let forecast: Forecast
    @AppStorage("celsius") private var celsius = false
    @AppStorage("rainInches") private var inches = false
    @State private var selected: DayForecast?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Daily forecast").font(.headline); Spacer(); Text("\(forecast.days.count) days").font(.caption).foregroundStyle(.secondary) }
            if forecast.days.isEmpty { Text("Daily data is unavailable from this source. Refresh or choose another source in Weather Lab.").font(.caption).foregroundStyle(.secondary) }
            let minimum = forecast.days.compactMap(\.low).min() ?? 0
            let maximum = forecast.days.compactMap(\.high).max() ?? 1
            ForEach(forecast.days) { day in
                Button { selected = day } label: {
                    HStack(spacing: 9) {
                        Text(WeatherStyle.dayName(day)).font(.system(size: 12, weight: .semibold)).frame(width: 35, alignment: .leading)
                        Image(systemName: WeatherStyle.symbol(day.code)).symbolRenderingMode(.palette).foregroundStyle(Color.primary, Color.orange, Color.blue).frame(width: 24)
                        Text(WeatherStyle.scalar(day.chance, suffix: "%")).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 32)
                        Text(WeatherStyle.temperature(day.low, celsius: celsius)).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                        GeometryReader { g in
                            let low = max(0, min(1, ((day.low ?? minimum) - minimum) / max(1, maximum - minimum)))
                            let high = max(low, min(1, ((day.high ?? maximum) - minimum) / max(1, maximum - minimum)))
                            Capsule().fill(.primary.opacity(0.06)).frame(height: 4).overlay(alignment: .leading) {
                                if day.low != nil && day.high != nil { Capsule().fill(LinearGradient(colors: [.blue, .cyan, .yellow], startPoint: .leading, endPoint: .trailing)).frame(width: max(4, g.size.width * (high - low)), height: 4).offset(x: g.size.width * low) }
                            }.frame(height: g.size.height)
                        }.frame(height: 28)
                        Text(WeatherStyle.temperature(day.high, celsius: celsius)).font(.system(size: 12, weight: .semibold)).frame(width: 30, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }.foregroundStyle(.primary).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(WeatherStyle.dayName(day, full: true)), low \(WeatherStyle.temperature(day.low, celsius: celsius)), high \(WeatherStyle.temperature(day.high, celsius: celsius)). Open day details.")
            }
            Text("Tap a day for precipitation, sun times and hourly detail. \(forecast.source ?? "Open-Meteo")").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
        .sheet(item: $selected) { DailyDetailView(day: $0, forecast: forecast) }
    }
}
struct DailyDetailView: View {
    let day: DayForecast
    let forecast: Forecast
    @Environment(\.dismiss) private var dismiss
    @AppStorage("celsius") private var celsius = false
    @AppStorage("rainInches") private var inches = false
    @AppStorage("clock24") private var clock24 = false
    private var hours: [Hour] { forecast.hours(on: day) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: WeatherStyle.symbol(day.code)).symbolRenderingMode(.palette).foregroundStyle(Color.primary, Color.orange, Color.blue).font(.largeTitle)
                        Spacer()
                        Text("\(WeatherStyle.temperature(day.low, celsius: celsius)) / \(WeatherStyle.temperature(day.high, celsius: celsius))").font(.title.weight(.semibold))
                    }
                    if let summary = day.summary { Text(summary) }
                    LabeledContent("Source", value: day.source ?? forecast.source ?? "Open-Meteo")
                    Text("Forecast detail decreases farther ahead. Missing values are shown as —.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Precipitation & conditions") {
                    LabeledContent("Daily precipitation", value: WeatherStyle.amount(day.rain, inches: inches))
                    LabeledContent(day.probabilityLabel, value: WeatherStyle.scalar(day.chance, suffix: "%"))
                    LabeledContent("Max wind", value: WeatherStyle.scalar(day.wind, suffix: " mph"))
                    LabeledContent("Max gust", value: WeatherStyle.scalar(day.gust, suffix: " mph"))
                    LabeledContent("Max UV index", value: WeatherStyle.scalar(day.uv, suffix: "", digits: 1))
                    LabeledContent("Feels-like range", value: "\(WeatherStyle.temperature(day.feelsLow, celsius: celsius)) / \(WeatherStyle.temperature(day.feelsHigh, celsius: celsius))")
                }
                Section("Sun · local forecast time") {
                    LabeledContent("Sunrise", value: sunTime(day.sunrise, local: day.sunriseLocal))
                    LabeledContent("Sunset", value: sunTime(day.sunset, local: day.sunsetLocal))
                    LabeledContent("Daylight", value: day.daylightSeconds.map { "\(Int($0 / 3600))h \(Int($0.truncatingRemainder(dividingBy: 3600) / 60))m" } ?? "—")
                }
                if let lower = day.highP25, let upper = day.highP75 {
                    Section("Provider ensemble · daytime high") {
                        Text("\(WeatherStyle.temperature(lower, celsius: celsius)) – \(WeatherStyle.temperature(upper, celsius: celsius))")
                        Text("Foreca 25th–75th percentile range. This is model spread, not a guarantee or a measured accuracy score.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Hourly outlook") {
                    if hours.isEmpty { Text("Hourly data is not available this far ahead from this source.").font(.caption).foregroundStyle(.secondary) }
                    if !hours.isEmpty {
                        Chart(hours) { h in LineMark(x: .value("Time", h.time), y: .value("Temperature", celsius ? (h.temperature - 32) * 5 / 9 : h.temperature)).foregroundStyle(.blue) }.frame(height: 140)
                        ForEach(hours) { h in HStack { Text(hourTime(h.time)); Spacer(); Image(systemName: WeatherStyle.symbol(h.code, day: h.daylight)).foregroundStyle(.blue); Text(WeatherStyle.scalar(h.chance, suffix: "%")).foregroundStyle(.secondary); Text(WeatherStyle.temperature(h.temperature, celsius: celsius)).monospacedDigit() }.font(.subheadline) }
                    }
                }
            }.navigationTitle(WeatherStyle.dayName(day, full: true)).navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
        }
    }
    private func hourTime(_ time: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = forecast.forecastTimeZone; f.dateFormat = clock24 ? "HH:mm" : "h a"; return f.string(from: time) }
    private func sunTime(_ epoch: Double?, local: String?) -> String {
        if let epoch { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = forecast.forecastTimeZone; f.dateFormat = clock24 ? "HH:mm" : "h:mm a"; return f.string(from: Date(timeIntervalSince1970: epoch)) }
        if let local, !local.isEmpty { return local }
        return "—"
    }
}
struct WeatherStatistics: View {
    let forecast: Forecast
    @AppStorage("celsius") private var celsius = false
    @AppStorage("showHumidity") private var humidity = true
    @AppStorage("showPressure") private var pressure = true
    @AppStorage("showVisibility") private var visibility = true
    @AppStorage("showSun") private var sun = true
    var body: some View {
        let hour = forecast.hours.first
        VStack(alignment: .leading, spacing: 12) {
            Text("Weather details").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 16) {
                if humidity {
                    metric("Humidity", value: WeatherStyle.scalar(forecast.current.relative_humidity_2m ?? hour?.humidity, suffix: "%"), symbol: "humidity")
                    metric("Dew point", value: WeatherStyle.temperature(forecast.current.dew_point_2m ?? hour?.dewPoint, celsius: celsius), symbol: "drop.degreesign")
                }
                metric("Wind / gust", value: "\(WeatherStyle.scalar(forecast.current.wind_speed_10m, suffix: "")) / \(WeatherStyle.scalar(forecast.current.wind_gusts_10m ?? hour?.gust, suffix: " mph"))", symbol: "wind")
                metric("Cloud cover", value: WeatherStyle.scalar(forecast.current.cloud_cover ?? hour?.clouds, suffix: "%"), symbol: "cloud")
                if pressure { metric("Sea-level pressure", value: WeatherStyle.scalar(forecast.current.pressure_msl ?? hour?.pressure, suffix: " hPa"), symbol: "barometer") }
                if visibility { metric("Visibility", value: (forecast.current.visibility ?? hour?.visibility).map { String(format: "%.1f km", $0 / 1000) } ?? "—", symbol: "eye") }
                metric("Hourly UV index", value: WeatherStyle.scalar(hour?.uv, suffix: "", digits: 1), symbol: "sun.max")
                metric("Wind direction", value: WeatherStyle.scalar(forecast.current.wind_direction_10m ?? hour?.windDirection, suffix: "°"), symbol: "location.north")
            }
            if sun, let day = forecast.days.first { HStack { Label("Sunrise", systemImage: "sunrise"); Spacer(); Text(sunTime(day.sunrise, local: day.sunriseLocal)) }.font(.caption); HStack { Label("Sunset", systemImage: "sunset"); Spacer(); Text(sunTime(day.sunset, local: day.sunsetLocal)) }.font(.caption) }
            Text("Model estimates · \(forecast.source ?? "Open-Meteo"). Hourly values supplement missing current fields. — means unavailable.").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }
    private func metric(_ name: String, value: String, symbol: String) -> some View { VStack(alignment: .leading, spacing: 5) { Label(name, systemImage: symbol).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit() } }
    private func sunTime(_ epoch: Double?, local: String?) -> String { guard let epoch else { return local ?? "—" }; let f = DateFormatter(); f.timeZone = forecast.forecastTimeZone; f.timeStyle = .short; return f.string(from: Date(timeIntervalSince1970: epoch)) }
}
struct ProviderComparison: View {
    let forecasts: [Forecast]
    @AppStorage("celsius") private var celsius = false
    struct Point: Identifiable { let id: String; let time: Date; let temperature: Double; let source: String }
    private var points: [Point] { forecasts.flatMap { f in f.hours.prefix(24).map { h in Point(id: "\(f.source ?? "Forecast")-\(h.time.timeIntervalSince1970)", time: h.time, temperature: celsius ? (h.temperature - 32) * 5 / 9 : h.temperature, source: f.source ?? "Forecast") } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare forecasts").font(.headline)
            if forecasts.count >= 2 {
                Chart(points) { p in LineMark(x: .value("Time", p.time), y: .value("Temperature", p.temperature)).foregroundStyle(by: .value("Source", p.source)) }.frame(height: 160)
                Text("Independent provider predictions. Their separation is disagreement, not a calibrated confidence band.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Connect Foreca in Weather Lab to compare it with Open-Meteo. No alternate lines are invented.").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 12)
    }
}
