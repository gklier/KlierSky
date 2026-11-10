import SwiftUI
import UIKit

// KlierSky's visual system: system typography, one accent, semantic weather
// colors that keep contrast in both appearances, and Liquid Glass reserved for
// floating controls rather than content.
enum Sky {
    private static func dynamic(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    static let accent = dynamic(dark: (0.38, 0.72, 0.98), light: (0.03, 0.39, 0.68))
    static let rain = dynamic(dark: (0.30, 0.66, 1.00), light: (0.05, 0.42, 0.80))
    static let warm = dynamic(dark: (1.00, 0.76, 0.28), light: (0.84, 0.45, 0.00))
    static let wind = dynamic(dark: (0.45, 0.84, 0.76), light: (0.00, 0.46, 0.42))
    static let snow = dynamic(dark: (0.72, 0.90, 1.00), light: (0.20, 0.52, 0.70))
    static let bolt = dynamic(dark: (1.00, 0.86, 0.30), light: (0.70, 0.48, 0.00))
    static let moon = dynamic(dark: (0.80, 0.82, 0.98), light: (0.36, 0.38, 0.66))
    /// Cloud body: near-white on dark, dark slate on light, so cloud symbols never wash out.
    static let cloud = dynamic(dark: (0.90, 0.92, 0.95), light: (0.28, 0.32, 0.38))
    static let caution = dynamic(dark: (1.00, 0.66, 0.24), light: (0.72, 0.36, 0.00))
    static let danger = dynamic(dark: (1.00, 0.42, 0.40), light: (0.76, 0.10, 0.12))
    static let hairline = Color.primary.opacity(0.10)
    static let track = Color.primary.opacity(0.07)
    static let surface = Color(.secondarySystemBackground)
}

struct Units: Equatable {
    var celsius = false
    var inches = false
    var clock24 = false
    func temperatureValue(_ f: Double) -> Double { celsius ? (f - 32) * 5 / 9 : f }
    func temperature(_ f: Double?) -> String { guard let f, f.isFinite else { return "—" }; return "\(Int(temperatureValue(f).rounded()))°" }
    func rain(_ mm: Double?) -> String { guard let mm, mm.isFinite else { return "—" }; return String(format: inches ? "%.2f in" : "%.1f mm", inches ? mm / 25.4 : mm) }
    func windValue(_ mph: Double) -> Double { celsius ? mph * 1.609344 : mph }
    var windUnit: String { celsius ? "km/h" : "mph" }
    func wind(_ mph: Double?) -> String { guard let mph, mph.isFinite else { return "—" }; return "\(Int(windValue(mph).rounded())) \(windUnit)" }
    func pressure(_ hPa: Double?) -> String { guard let hPa, hPa.isFinite else { return "—" }; return celsius ? "\(Int(hPa.rounded())) hPa" : String(format: "%.2f inHg", hPa * 0.0295299830714) }
    func distance(_ meters: Double?) -> String { guard let meters, meters.isFinite else { return "—" }; return celsius ? String(format: "%.0f km", meters / 1000) : String(format: "%.0f mi", meters / 1609.344) }
    func percent(_ value: Double?) -> String { guard let value, value.isFinite else { return "—" }; return "\(Int(value.rounded()))%" }
    func hour(_ date: Date, zone: TimeZone) -> String { Self.format(date, zone, clock24 ? "HH:mm" : "h a") }
    func clock(_ date: Date, zone: TimeZone) -> String { Self.format(date, zone, clock24 ? "HH:mm" : "h:mm a") }
    private static func format(_ date: Date, _ zone: TimeZone, _ pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func compass(_ degrees: Double?) -> String {
        guard let degrees, degrees.isFinite else { return "—" }
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return names[Int((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5 + 0.5) % 16]
    }
}
private struct UnitsKey: EnvironmentKey { static let defaultValue = Units() }
extension EnvironmentValues { var units: Units { get { self[UnitsKey.self] } set { self[UnitsKey.self] = newValue } } }

/// Condition symbol with explicit layer colors, so clouds stay legible on white and suns stay warm on black.
struct WeatherSymbol: View {
    let code: Int?
    var day = true
    var body: some View {
        let name = WeatherCode.symbol(code, day: day)
        let image = Image(systemName: name).symbolRenderingMode(.palette)
        switch WeatherCode.kind(code) {
        case .clear: image.foregroundStyle(day ? Sky.warm : Sky.moon, Sky.moon)
        case .mostlyClear, .partlyCloudy: image.foregroundStyle(Sky.cloud, day ? Sky.warm : Sky.moon)
        case .overcast, .fog: image.foregroundStyle(Sky.cloud, Sky.cloud.opacity(0.55))
        case .drizzle, .rain, .heavyRain, .showers: image.foregroundStyle(Sky.cloud, Sky.rain)
        case .sleet, .snow, .snowShowers: image.foregroundStyle(Sky.cloud, Sky.snow)
        case .thunder: image.foregroundStyle(Sky.cloud, Sky.bolt, Sky.rain)
        case .unknown: image.foregroundStyle(Color.secondary, Color.secondary)
        }
    }
}

extension View {
    /// Liquid Glass on systems that have it; a system material elsewhere. For floating controls only.
    @ViewBuilder func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape).overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
    func glass(interactive: Bool = false) -> some View { glass(in: Capsule(), interactive: interactive) }
}

/// Round floating control used in the header and on the map.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.primary).glass(in: Circle(), interactive: true).accessibilityLabel(label)
    }
}

/// Section title with an optional trailing control. Compact; no card chrome.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}
extension SectionHeader where Trailing == EmptyView { init(_ title: String) { self.init(title: title) { EmptyView() } } }

/// Small provenance line under a section.
struct SourceNote: View {
    let text: String
    var body: some View { Text(text).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
}

/// Inline notice for stale data, fallbacks and failures. Tinted, never modal.
struct NoticeRow: View {
    let symbol: String
    let text: String
    var tint: Color = Sky.caution
    var action: (title: String, run: () -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.footnote).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action { Button(action.title, action: action.run).font(.footnote.weight(.semibold)) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
