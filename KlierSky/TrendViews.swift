import SwiftUI
import Charts

// MARK: 12-hour outlook

extension TrendMetric {
    var title: String { self == .rain ? "Precipitation" : self == .probability ? "Chance of precipitation" : self == .wind ? "Wind" : "Temperature" }
    var tint: Color { self == .wind ? Sky.wind : self == .temperature ? Sky.warm : Sky.rain }
}

struct TrendSection: View {
    let model: WeatherModel
    @State private var chosen: TrendMetric?
    @State private var selection: Date?
    @Environment(\.units) private var units
    private struct Point: Identifiable { let id: Date; let time: Date; let value: Double; let segment: Int }

    var body: some View {
        let candidates = Array(model.hours.prefix(12))
        let hours = candidates.filter { $0.time.timeIntervalSince(candidates.first?.time ?? Date()) < 12 * 3600 }
        let automatic = TrendMetric.choose(hours)
        let metric = chosen ?? automatic
        let points = points(hours, metric)
        let zone = model.zone
        VStack(alignment: .leading, spacing: 8) {
            if let sentence = Outlook.sentence(hours, label: { units.hour($0, zone: zone) }) {
                Text(sentence).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            }
            HStack(alignment: .firstTextBaseline) {
                Menu {
                    Button("Automatic (\(automatic.title))") { chosen = nil }
                    ForEach([TrendMetric.rain, .probability, .wind, .temperature], id: \.self) { item in Button(item.title) { chosen = item } }
                } label: {
                    HStack(spacing: 4) { Text("Next 12 hours · \(metric.title)"); Image(systemName: "chevron.down").font(.caption2) }
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(readout(points, metric, zone)).font(.footnote).monospacedDigit().foregroundStyle(selection == nil ? .secondary : .primary)
            }
            if points.isEmpty {
                Text("The provider has no \(metric.title.lowercased()) values for these hours.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                chart(points, metric, hours, zone).frame(height: 118)
            }
            SourceNote(text: "Hourly model values · \(model.providerStatus)" + (TrendMetric.isComplete(hours) ? "" : " · Some hours are missing; a gap is not dry weather"))
            if let nowcast = model.nowcast { NearTermStrip(nowcast: nowcast, zone: zone) }
        }
    }
    private func display(_ value: Double, _ metric: TrendMetric) -> Double {
        switch metric {
        case .rain: return units.inches ? value / 25.4 : value
        case .wind: return units.windValue(value)
        case .temperature, .probability: return value
        }
    }
    private func points(_ hours: [Hour], _ metric: TrendMetric) -> [Point] {
        var segment = 0; var previous: Date?
        return hours.compactMap { hour in
            guard let raw = metric.value(hour, celsius: units.celsius), raw.isFinite else { previous = nil; segment += 1; return nil }
            if let previous, hour.time.timeIntervalSince(previous) > 4500 { segment += 1 }
            previous = hour.time
            return Point(id: hour.time, time: hour.time, value: display(raw, metric), segment: segment)
        }
    }
    private func format(_ value: Double, _ metric: TrendMetric) -> String {
        switch metric {
        case .rain: return String(format: units.inches ? "%.2f in" : "%.1f mm", value)
        case .probability: return "\(Int(value.rounded()))%"
        case .wind: return "\(Int(value.rounded())) \(units.windUnit)"
        case .temperature: return "\(Int(value.rounded()))°"
        }
    }
    private func nearest(_ points: [Point]) -> Point? {
        guard let selection else { return nil }
        return points.min { abs($0.time.timeIntervalSince(selection)) < abs($1.time.timeIntervalSince(selection)) }
    }
    private func readout(_ points: [Point], _ metric: TrendMetric, _ zone: TimeZone) -> String {
        if let point = nearest(points) { return "\(units.hour(point.time, zone: zone)) · \(format(point.value, metric))" }
        guard let peak = points.max(by: { $0.value < $1.value }) else { return "No data" }
        if metric == .rain && peak.value <= 0 { return "None expected" }
        return "\(metric == .temperature ? "High" : "Peak") \(format(peak.value, metric)) · \(units.hour(peak.time, zone: zone))"
    }
    private func domain(_ points: [Point], _ metric: TrendMetric) -> ClosedRange<Double> {
        let high = points.map(\.value).max() ?? 1, low = points.map(\.value).min() ?? 0
        switch metric {
        case .rain: return 0...max(units.inches ? 0.04 : 1, high * 1.2)
        case .probability: return 0...100
        case .wind: return 0...max(units.celsius ? 16 : 10, high * 1.25)
        case .temperature: return (low - 3)...(high + 3)
        }
    }
    private func chart(_ points: [Point], _ metric: TrendMetric, _ hours: [Hour], _ zone: TimeZone) -> some View {
        let range = domain(points, metric)
        return Chart {
            ForEach(points) { point in
                if metric == .rain {
                    BarMark(x: .value("Hour", point.time, unit: .hour), y: .value(metric.title, point.value), width: .ratio(0.78))
                        .foregroundStyle(metric.tint).cornerRadius(3)
                } else {
                    AreaMark(x: .value("Hour", point.time), yStart: .value("Base", range.lowerBound), yEnd: .value(metric.title, point.value), series: .value("Run", point.segment))
                        .foregroundStyle(LinearGradient(colors: [metric.tint.opacity(0.32), metric.tint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Hour", point.time), y: .value(metric.title, point.value), series: .value("Run", point.segment))
                        .foregroundStyle(metric.tint).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let point = nearest(points) {
                RuleMark(x: .value("Selected", point.time, unit: metric == .rain ? .hour : .second)).foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
                if metric != .rain { PointMark(x: .value("Hour", point.time), y: .value(metric.title, point.value)).foregroundStyle(metric.tint).symbolSize(70) }
            }
        }
        .chartYScale(domain: range)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Sky.hairline)
                AxisValueLabel { if let date = value.as(Date.self) { Text(units.hour(date, zone: zone)).font(.caption2) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Sky.hairline)
                AxisValueLabel { if let number = value.as(Double.self) { Text(axis(number, metric)).font(.caption2) } }
            }
        }
        .chartXSelection(value: $selection)
        .accessibilityLabel("\(metric.title) for the next 12 hours. \(readout(points, metric, zone)). Gaps mean the provider sent no value.")
    }
    private func axis(_ value: Double, _ metric: TrendMetric) -> String {
        switch metric {
        case .rain: return String(format: units.inches ? "%.2f" : "%.1f", value)
        case .probability: return "\(Int(value))%"
        case .wind: return "\(Int(value))"
        case .temperature: return "\(Int(value))°"
        }
    }
}

/// Foreca's near-term precipitation series, shown at exactly the resolution the provider reports.
struct NearTermStrip: View {
    let nowcast: Gateway.Nowcast
    let zone: TimeZone
    @Environment(\.units) private var units
    var body: some View {
        let points = nowcast.points.filter { $0.time > Date().addingTimeInterval(-Double(nowcast.resolution) * 60) && $0.time < Date().addingTimeInterval(2 * 3600) }
        if points.count >= 3 {
            let peak = points.map(\.rate).max() ?? 0
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Near term · \(nowcast.resolution)-minute steps").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(peak > 0 ? "Peak \(units.rain(peak))/h" : "No precipitation").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                }
                if peak > 0 {
                    Chart(points) { point in BarMark(x: .value("Time", point.time), y: .value("Rate", point.rate)).foregroundStyle(Sky.rain) }
                        .chartYAxis(.hidden)
                        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in AxisValueLabel { if let date = value.as(Date.self) { Text(units.clock(date, zone: zone)).font(.caption2) } } } }
                        .frame(height: 54)
                }
                SourceNote(text: "Foreca near-term forecast until \(points.last.map { units.clock($0.time, zone: zone) } ?? "—"). A forecast, not a radar measurement.")
            }.padding(.top, 6)
        }
    }
}

// MARK: Hourly timeline

enum HourlyMetric: String, CaseIterable, Identifiable {
    case temperature, feels, chance, rain, wind, gust, humidity, dewPoint, uv, clouds, pressure
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperature: return "Temp"
        case .feels: return "Feels like"
        case .chance: return "Chance"
        case .rain: return "Precip"
        case .wind: return "Wind"
        case .gust: return "Gusts"
        case .humidity: return "Humidity"
        case .dewPoint: return "Dew point"
        case .uv: return "UV"
        case .clouds: return "Cloud"
        case .pressure: return "Pressure"
        }
    }
    var tint: Color {
        switch self {
        case .temperature, .feels, .uv: return Sky.warm
        case .chance, .rain, .humidity, .dewPoint: return Sky.rain
        case .wind, .gust: return Sky.wind
        case .clouds, .pressure: return Color.secondary
        }
    }
    func value(_ hour: Hour) -> Double? {
        let raw: Double?
        switch self {
        case .temperature: raw = hour.temperature
        case .feels: raw = hour.feels
        case .chance: raw = hour.chance
        case .rain: raw = hour.rain
        case .wind: raw = hour.wind
        case .gust: raw = hour.gust
        case .humidity: raw = hour.humidity
        case .dewPoint: raw = hour.dewPoint
        case .uv: raw = hour.uv
        case .clouds: raw = hour.clouds
        case .pressure: raw = hour.pressure
        }
        return raw.flatMap { $0.isFinite ? $0 : nil }
    }
    func text(_ hour: Hour, _ units: Units) -> String {
        guard let value = value(hour) else { return "—" }
        switch self {
        case .temperature, .feels, .dewPoint: return units.temperature(value)
        case .chance, .humidity, .clouds: return units.percent(value)
        case .rain: return value == 0 ? "0" : units.rain(value)
        case .wind, .gust: return units.wind(value)
        case .uv: return String(format: "%.0f", value)
        case .pressure: return units.pressure(value)
        }
    }
}

struct HourlySection: View {
    let model: WeatherModel
    @State private var expanded = false
    @AppStorage("hourlyMetric") private var metricName = HourlyMetric.temperature.rawValue
    @Environment(\.units) private var units
    @ScaledMetric(relativeTo: .footnote) private var rowHeight: CGFloat = 34
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 50
    @ScaledMetric(relativeTo: .footnote) private var pillWidth: CGFloat = 62

    var body: some View {
        let day = Array(model.hours.prefix(24))
        let hours = Array(day.prefix(expanded ? 24 : 6))
        let available = HourlyMetric.allCases.filter { metric in day.contains { metric.value($0) != nil } }
        let metric = available.first { $0.rawValue == metricName } ?? .temperature
        let values = hours.compactMap { metric.value($0) }
        let low = values.min() ?? 0, high = values.max() ?? 1
        let zone = model.zone
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Hourly") {
                Button(expanded ? "Show 6 hours" : "Show 24 hours") { withAnimation(.snappy) { expanded.toggle() } }.font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(available) { item in
                        Button { metricName = item.rawValue } label: {
                            Text(item.title).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(item == metric ? Color(.systemBackground) : .primary)
                                .background(item == metric ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Sky.track), in: Capsule())
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(item == metric ? .isSelected : [])
                    }
                }.padding(.horizontal, 20)
            }.padding(.horizontal, -20)
            VStack(spacing: 0) {
                ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
                    row(index: index, hour: hour, previous: index > 0 ? hours[index - 1] : nil, last: index == hours.count - 1, metric: metric, low: low, high: high, zone: zone)
                }
            }
            SourceNote(text: "\(metric.title) by hour · \(sources(hours))")
        }
    }
    private func sources(_ hours: [Hour]) -> String {
        let names = Array(Set(hours.compactMap(\.source))).sorted()
        return names.isEmpty ? (model.forecast?.source ?? "Forecast") : names.joined(separator: "; ")
    }
    private func stripColor(_ hour: Hour) -> Color {
        switch WeatherCode.kind(hour.code) {
        case .clear, .mostlyClear: return hour.daylight ? Sky.warm.opacity(0.55) : Sky.moon.opacity(0.35)
        case .partlyCloudy: return Sky.cloud.opacity(0.30)
        case .overcast, .fog: return Sky.cloud.opacity(0.55)
        case .drizzle, .showers: return Sky.rain.opacity(0.55)
        case .rain: return Sky.rain.opacity(0.8)
        case .heavyRain, .thunder: return Sky.rain
        case .sleet, .snow, .snowShowers: return Sky.snow
        case .unknown: return Sky.track
        }
    }
    private func dayLabel(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
    private func row(index: Int, hour: Hour, previous: Hour?, last: Bool, metric: HourlyMetric, low: Double, high: Double, zone: TimeZone) -> some View {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let newDay = previous.map { !calendar.isDate($0.time, inSameDayAs: hour.time) } ?? false
        let changed = previous.map { WeatherCode.kind($0.code) != WeatherCode.kind(hour.code) } ?? true
        let value = metric.value(hour)
        let fraction = value.map { high > low ? ($0 - low) / (high - low) : 0.5 } ?? 0
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                UnevenRoundedRectangle(topLeadingRadius: index == 0 ? 4 : 0, bottomLeadingRadius: last ? 4 : 0, bottomTrailingRadius: last ? 4 : 0, topTrailingRadius: index == 0 ? 4 : 0)
                    .fill(stripColor(hour)).frame(width: 8)
                Text(index == 0 ? "Now" : units.hour(hour.time, zone: zone)).font(.footnote.weight(.semibold)).monospacedDigit()
                    .frame(width: timeWidth, alignment: .leading).padding(.leading, 10)
                WeatherSymbol(code: hour.code, day: hour.daylight).font(.footnote).frame(width: 26)
                Text(newDay ? dayLabel(hour.time, zone) : changed ? WeatherCode.text(hour.code) : "")
                    .font(.footnote).foregroundStyle(newDay ? Color.primary : Color.secondary).fontWeight(newDay ? .semibold : .regular)
                    .lineLimit(1).minimumScaleFactor(0.8).frame(width: 96, alignment: .leading).padding(.leading, 4)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Sky.hairline).frame(height: 1)
                        Text(metric.text(hour, units)).font(.footnote.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            .frame(width: pillWidth).padding(.vertical, 4)
                            .background(Color(.systemBackground), in: Capsule())
                            .background(metric.tint.opacity(value == nil ? 0 : 0.20), in: Capsule())
                            .overlay(Capsule().stroke(metric.tint.opacity(value == nil ? 0.15 : 0.45), lineWidth: 0.75))
                            .offset(x: max(0, geometry.size.width - pillWidth) * fraction)
                    }.frame(height: geometry.size.height)
                }
            }.frame(height: rowHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index == 0 ? "Now" : units.hour(hour.time, zone: zone)), \(WeatherCode.text(hour.code)), \(metric.title) \(value == nil ? "unavailable" : metric.text(hour, units))")
    }
}
