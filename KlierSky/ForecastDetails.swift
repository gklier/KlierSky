import SwiftUI
import Charts

// MARK: Daily forecast

struct DailyForecastSection: View {
    let forecast: Forecast
    @Environment(\.units) private var units
    @State private var expanded: String?
    @State private var showAll = false
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 38
    @ScaledMetric(relativeTo: .subheadline) private var dayWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .subheadline) private var temperatureWidth: CGFloat = 36

    var body: some View {
        let all = forecast.days
        let days = showAll ? all : Array(all.prefix(7))
        let minimum = days.compactMap(\.low).min() ?? 0
        let maximum = days.compactMap(\.high).max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Daily") {
                if all.count > 7 { Button(showAll ? "Show 7 days" : "Show \(all.count) days") { withAnimation(.snappy) { showAll.toggle() } }.font(.subheadline) }
            }
            if days.isEmpty { Text("This source sent no daily forecast. Pull to refresh.").font(.footnote).foregroundStyle(.secondary) }
            VStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    Button { withAnimation(.snappy(duration: 0.28)) { expanded = expanded == day.id ? nil : day.id } } label: { row(day, index: index, minimum: minimum, maximum: maximum) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(Self.name(day, index: index, zone: forecast.forecastTimeZone, full: true)), \(day.summary ?? WeatherCode.text(day.code)), low \(units.temperature(day.low)), high \(units.temperature(day.high))" + (day.chance.map { ", precipitation chance \(Int($0.rounded())) percent" } ?? ""))
                        .accessibilityHint(expanded == day.id ? "Collapses details" : "Shows details")
                    if expanded == day.id { DayDetail(day: day, forecast: forecast).transition(.opacity.combined(with: .move(edge: .top))) }
                    if index < days.count - 1 { Divider().opacity(0.5) }
                }
            }
            SourceNote(text: "Tap a day for details · \(forecast.dailySourceLine)")
        }
    }
    static func name(_ day: DayForecast, index: Int, zone: TimeZone, full: Bool = false) -> String {
        guard let date = day.date else { return day.dateKey }
        let key = DateFormatter(); key.locale = Locale(identifier: "en_US_POSIX"); key.timeZone = zone; key.dateFormat = "yyyy-MM-dd"
        if !full, key.string(from: Date()) == day.dateKey { return "Today" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = full ? "EEEE, MMMM d" : "EEE"
        return formatter.string(from: date)
    }
    private func row(_ day: DayForecast, index: Int, minimum: Double, maximum: Double) -> some View {
        HStack(spacing: 8) {
            Text(Self.name(day, index: index, zone: forecast.forecastTimeZone)).font(.subheadline.weight(.semibold)).frame(width: dayWidth, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
            WeatherSymbol(code: day.code).font(.body).frame(width: 30)
            Text(day.chance.map { $0 >= 5 ? "\(Int($0.rounded()))%" : "" } ?? "").font(.caption.weight(.medium)).foregroundStyle(Sky.rain).monospacedDigit().frame(width: 36, alignment: .leading)
            Text(units.temperature(day.low)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().frame(width: temperatureWidth, alignment: .trailing)
            GeometryReader { geometry in
                let span = max(1, maximum - minimum)
                let low = max(0, min(1, ((day.low ?? minimum) - minimum) / span))
                let high = max(low, min(1, ((day.high ?? maximum) - minimum) / span))
                ZStack(alignment: .leading) {
                    Capsule().fill(Sky.track).frame(height: 5)
                    if day.low != nil, day.high != nil {
                        // One gradient across the whole period, revealed only over this day's range.
                        LinearGradient(colors: [Sky.rain, Sky.wind, Sky.warm], startPoint: .leading, endPoint: .trailing)
                            .frame(height: 5)
                            .mask(alignment: .leading) { Capsule().frame(width: max(6, geometry.size.width * (high - low)), height: 5).offset(x: geometry.size.width * low) }
                    }
                }.frame(height: geometry.size.height)
            }
            Text(units.temperature(day.high)).font(.subheadline.weight(.semibold)).monospacedDigit().frame(width: temperatureWidth, alignment: .trailing)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded == day.id ? 180 : 0))
        }
        .frame(minHeight: rowHeight).contentShape(Rectangle())
    }
}

/// Inline detail for one day: what the provider sent, nothing inferred.
struct DayDetail: View {
    let day: DayForecast
    let forecast: Forecast
    @Environment(\.units) private var units
    private var hours: [Hour] { forecast.hours(on: day) }
    var body: some View {
        let zone = forecast.forecastTimeZone
        VStack(alignment: .leading, spacing: 12) {
            if let summary = day.summary { Text(summary.prefix(1).uppercased() + summary.dropFirst()).font(.subheadline.weight(.medium)) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3), alignment: .leading, spacing: 12) {
                Stat(name: "Precipitation", value: units.rain(day.rain))
                Stat(name: "Chance", value: units.percent(day.chance))
                Stat(name: "Feels like", value: "\(units.temperature(day.feelsLow)) / \(units.temperature(day.feelsHigh))")
                Stat(name: "Wind", value: units.wind(day.wind))
                Stat(name: "Gusts", value: units.wind(day.gust))
                Stat(name: "UV index", value: day.uv.map { String(format: "%.0f", $0) } ?? "—")
                Stat(name: "Sunrise", value: sun(day.sunrise, day.sunriseLocal, zone))
                Stat(name: "Sunset", value: sun(day.sunset, day.sunsetLocal, zone))
                Stat(name: "Daylight", value: daylight)
            }
            if let lower = day.highP25, let upper = day.highP75 {
                Text("High likely between \(units.temperature(lower)) and \(units.temperature(upper)) (Foreca ensemble, middle half of model runs). Model spread, not a measured accuracy.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if hours.count >= 3 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(hours) { hour in
                            VStack(spacing: 5) {
                                Text(units.hour(hour.time, zone: zone)).font(.caption2).foregroundStyle(.secondary)
                                WeatherSymbol(code: hour.code, day: hour.daylight).font(.footnote).frame(height: 18)
                                Text(units.temperature(hour.temperature)).font(.footnote.weight(.semibold)).monospacedDigit()
                                Text(hour.chance >= 5 ? "\(Int(hour.chance.rounded()))%" : " ").font(.caption2).foregroundStyle(Sky.rain).monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(units.hour(hour.time, zone: zone)), \(WeatherCode.text(hour.code)), \(units.temperature(hour.temperature)), \(Int(hour.chance.rounded())) percent")
                        }
                    }.padding(.horizontal, 20)
                }.padding(.horizontal, -20)
            } else {
                Text("Hourly values are not available this far ahead from \(forecast.source ?? "this source").").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(day.probabilityLabel) · \(day.source ?? forecast.source ?? "Open-Meteo"). — means the provider sent no value.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 4).padding(.bottom, 14)
    }
    private var daylight: String {
        if let seconds = day.daylightSeconds { return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "—"
    }
    private func sun(_ epoch: Double?, _ local: String?, _ zone: TimeZone) -> String {
        if let epoch { return units.clock(Date(timeIntervalSince1970: epoch), zone: zone) }
        if let local, !local.isEmpty { return SunTime.display(local, clock24: units.clock24) }
        return "—"
    }
}
enum SunTime {
    /// Foreca sends local wall-clock sun times as "HH:mm" or "HH:mm:ss"; reformat without shifting zones.
    static func display(_ local: String, clock24: Bool) -> String {
        let parts = local.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return local }
        if clock24 { return String(format: "%02d:%02d", parts[0], parts[1]) }
        return String(format: "%d:%02d %@", parts[0] % 12 == 0 ? 12 : parts[0] % 12, parts[1], parts[0] < 12 ? "AM" : "PM")
    }
}
struct Stat: View {
    let name: String
    let value: String
    var symbol: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.caption2).accessibilityHidden(true) }
                Text(name).font(.caption)
            }.foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(name): \(value == "—" ? "unavailable" : value)")
    }
}

// MARK: Current statistics

struct WeatherStatistics: View {
    let forecast: Forecast
    let air: AirQuality?
    let alerts: AlertFeed
    let showAlerts: () -> Void
    @Environment(\.units) private var units
    @AppStorage("showHumidity") private var humidity = true
    @AppStorage("showPressure") private var pressure = true
    @AppStorage("showVisibility") private var visibility = true
    @AppStorage("showSun") private var sun = true
    var body: some View {
        let hour = forecast.hours.first
        let today = forecast.days.first
        let zone = forecast.forecastTimeZone
        let direction = forecast.current.wind_direction_10m ?? hour?.windDirection
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Right now")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3), alignment: .leading, spacing: 16) {
                Stat(name: "Wind", value: units.wind(forecast.current.wind_speed_10m), symbol: "wind")
                Stat(name: "Gusts", value: units.wind(forecast.current.wind_gusts_10m ?? hour?.gust), symbol: "wind")
                Stat(name: "Direction", value: direction.map { "\(Units.compass($0)) \(Int($0.rounded()))°" } ?? "—", symbol: "location.north")
                if humidity {
                    Stat(name: "Humidity", value: units.percent(forecast.current.relative_humidity_2m ?? hour?.humidity), symbol: "humidity")
                    Stat(name: "Dew point", value: units.temperature(forecast.current.dew_point_2m ?? hour?.dewPoint), symbol: "drop.degreesign")
                }
                Stat(name: "Cloud cover", value: units.percent(forecast.current.cloud_cover ?? hour?.clouds), symbol: "cloud")
                if pressure { Stat(name: "Pressure", value: units.pressure(forecast.current.pressure_msl ?? hour?.pressure), symbol: "barometer") }
                if visibility { Stat(name: "Visibility", value: units.distance(forecast.current.visibility ?? hour?.visibility), symbol: "eye") }
                Stat(name: "UV index", value: hour?.uv.map { String(format: "%.0f", $0) } ?? "—", symbol: "sun.max")
                if sun, let today {
                    Stat(name: "Sunrise", value: sunTime(today.sunrise, today.sunriseLocal, zone), symbol: "sunrise")
                    Stat(name: "Sunset", value: sunTime(today.sunset, today.sunsetLocal, zone), symbol: "sunset")
                }
                Stat(name: "Air quality", value: air.map { "\(Int($0.usAQI.rounded())) AQI" } ?? "—", symbol: "aqi.medium")
            }
            if let air { Text("Air quality: \(air.category). US AQI from the Open-Meteo / CAMS regional model, not a nearby sensor.").font(.caption2).foregroundStyle(.secondary) }
            Button(action: showAlerts) {
                HStack(spacing: 8) {
                    Image(systemName: alertSymbol).foregroundStyle(alertTint)
                    Text(alertLine).font(.footnote).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain)
            SourceNote(text: "Model estimates · \(forecast.sourceLine). Hourly values fill in where the provider sends no current value. — means unavailable.")
        }
    }
    private var alertSymbol: String { alerts.coverage == .outside ? "minus.circle" : alerts.isStale() ? "questionmark.circle" : alerts.current().isEmpty ? "checkmark.shield" : "exclamationmark.triangle.fill" }
    private var alertTint: Color { alerts.coverage == .outside || alerts.isStale() ? .secondary : alerts.current().isEmpty ? Sky.wind : Sky.caution }
    private var alertLine: String {
        let checked = alerts.fetchedAt.map { units.clock($0, zone: .current) }
        if alerts.coverage == .outside { return "Official alerts are not available for this location (US National Weather Service only)." }
        if alerts.isStale() { return checked.map { "Alert status not confirmed. Last checked \($0)." } ?? "Alert status not confirmed yet." }
        let count = alerts.current().count
        return count == 0 ? "No active National Weather Service alerts · checked \(checked ?? "now")" : "\(count) active National Weather Service alert\(count == 1 ? "" : "s") · checked \(checked ?? "now")"
    }
    private func sunTime(_ epoch: Double?, _ local: String?, _ zone: TimeZone) -> String {
        if let epoch { return units.clock(Date(timeIntervalSince1970: epoch), zone: zone) }
        if let local, !local.isEmpty { return SunTime.display(local, clock24: units.clock24) }
        return "—"
    }
}

// MARK: Provider comparison

struct ProviderComparison: View {
    let forecasts: [Forecast]
    @Environment(\.units) private var units
    struct Point: Identifiable { let id: String; let time: Date; let temperature: Double; let source: String }
    private var points: [Point] { forecasts.flatMap { f in f.hours.prefix(24).map { h in Point(id: "\(f.source ?? "Forecast")-\(h.time.timeIntervalSince1970)", time: h.time, temperature: units.temperatureValue(h.temperature), source: f.source ?? "Forecast") } } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Compare sources")
            if forecasts.count >= 2 {
                Chart(points) { p in LineMark(x: .value("Time", p.time), y: .value("Temperature", p.temperature)).foregroundStyle(by: .value("Source", p.source)).interpolationMethod(.monotone) }
                    .chartForegroundStyleScale(["Foreca": Sky.accent, "Open-Meteo": Sky.warm, Blend.name: Color.primary])
                    .chartYScale(domain: .automatic(includesZero: false)).frame(height: 150)
                SourceNote(text: "One line per forecast for the next 24 hours" + (forecasts.contains { $0.blend != nil } ? "; the blend is their weighted average with the other sources" : "") + ". The gap between lines is disagreement, not a confidence band.")
            } else { Text("Only one forecast source is connected right now, so there is nothing to compare.").font(.footnote).foregroundStyle(.secondary) }
        }
    }
}
