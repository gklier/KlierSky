import SwiftUI

extension WeatherAlert {
    var tint: Color { rank <= 1 ? Sky.danger : Sky.caution }
    var symbol: String { rank <= 1 ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill" }
    static func stamp(_ date: Date?, zone: TimeZone, clock24: Bool) -> String {
        guard let date else { return "not stated" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone
        formatter.dateFormat = clock24 ? "EEE MMM d, HH:mm" : "EEE MMM d, h:mm a"
        return formatter.string(from: date)
    }
}

struct AlertBanner: View {
    let alert: WeatherAlert
    let zone: TimeZone
    let unverified: Bool
    let open: () -> Void
    @Environment(\.units) private var units
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: alert.symbol).foregroundStyle(alert.tint).font(.body).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.event).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text([alert.endTime.map { "Until \(WeatherAlert.stamp($0, zone: zone, clock24: units.clock24))" }, alert.sender].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    if unverified { Text("Not re-checked this session. It may have changed.").font(.caption2).foregroundStyle(Sky.caution) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(alert.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(alert.tint.opacity(0.35), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Official alert: \(alert.event). \(alert.severity) severity." + (alert.endTime.map { " Until \(WeatherAlert.stamp($0, zone: zone, clock24: units.clock24))." } ?? ""))
        .accessibilityHint("Shows the full alert")
    }
}

struct AlertListView: View {
    let feed: AlertFeed
    let placeName: String
    let zone: TimeZone
    @Environment(\.dismiss) private var dismiss
    @Environment(\.units) private var units
    var body: some View {
        let alerts = feed.current()
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(status, systemImage: feed.coverage == .outside ? "minus.circle" : feed.isStale() ? "questionmark.circle" : alerts.isEmpty ? "checkmark.shield" : "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let checked = feed.fetchedAt, feed.coverage != .outside { Text("Last successful check: \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ForEach(alerts) { alert in
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(alert.event, systemImage: alert.symbol).font(.headline).foregroundStyle(alert.tint)
                            Text([alert.severity == "Unknown" ? nil : "\(alert.severity) severity", alert.urgency.map { "\($0) urgency" }, alert.certainty.map { "\($0) certainty" }].compactMap { $0 }.joined(separator: " · ")).font(.caption.weight(.medium))
                            if let headline = alert.headline { Text(headline).font(.subheadline) }
                        }
                        LabeledContent("Issued by", value: alert.sender ?? "not stated")
                        LabeledContent("Issued", value: WeatherAlert.stamp(alert.sent, zone: zone, clock24: units.clock24))
                        if let onset = alert.onset { LabeledContent("Begins", value: WeatherAlert.stamp(onset, zone: zone, clock24: units.clock24)) }
                        if let ends = alert.ends { LabeledContent("Event ends", value: WeatherAlert.stamp(ends, zone: zone, clock24: units.clock24)) }
                        LabeledContent("Message expires", value: WeatherAlert.stamp(alert.expires, zone: zone, clock24: units.clock24))
                        if let area = alert.area { VStack(alignment: .leading, spacing: 3) { Text("Area").font(.caption).foregroundStyle(.secondary); Text(area).font(.subheadline) } }
                        if let instruction = alert.instruction {
                            VStack(alignment: .leading, spacing: 3) { Text("What to do").font(.caption.weight(.semibold)).foregroundStyle(alert.tint); Text(instruction).font(.subheadline) }
                        }
                        if let description = alert.description {
                            DisclosureGroup("Full text") { Text(description).font(.footnote).textSelection(.enabled) }
                        }
                    }
                }
                Section {
                    Text("Alerts come from the US National Weather Service and are checked when KlierSky refreshes while it is open. KlierSky does not send push warnings. Keep Wireless Emergency Alerts on and use another warning source for severe weather.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("National Weather Service alerts", destination: URL(string: "https://www.weather.gov/alerts")!).font(.footnote)
                }
            }
            .navigationTitle("Alerts · \(placeName)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private var status: String {
        if feed.coverage == .outside { return "Official alerts are not available here. Coverage is the United States only." }
        if feed.fetchedAt == nil { return "Alerts have not been checked yet." }
        if feed.failed { return "The latest check failed. This list may be out of date." }
        if feed.isStale() { return "This list is more than 30 minutes old." }
        let count = feed.current().count
        return count == 0 ? "No active alerts for this location." : "\(count) active alert\(count == 1 ? "" : "s") for this location."
    }
}
