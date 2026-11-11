import SwiftUI

/// Diagnostics and experimental provider options. No credentials live here.
struct WeatherLabView: View {
    @Bindable var model: WeatherModel
    @AppStorage("forecaMapsEnabled") private var maps = false
    @AppStorage("forecaNowcastEnabled") private var nowcast = true
    @AppStorage("refreshMinutes") private var refreshMinutes = 10
    @AppStorage("recordLogs") private var recordLogs = true
    @State private var showLogs = false
    @State private var clearLogs = false
    var body: some View {
        Form {
            Section {
                Picker("Refresh when the app is open", selection: $refreshMinutes) { Text("Every 5 minutes").tag(5); Text("Every 10 minutes").tag(10); Text("Every 30 minutes").tag(30) }
                Toggle("Foreca near-term precipitation", isOn: $nowcast)
                Toggle("Foreca forecast maps", isOn: $maps)
                LabeledContent("Showing now", value: model.providerStatus)
            } header: { Text("Forecast options") } footer: {
                Text("Foreca forecast maps need a separate map licence on the Foreca account. Without it the request is refused and nothing is drawn in its place.")
            }
            if let n = model.nowcast {
                Section(n.isTrueMinute ? "Minute forecast" : "Near-term forecast") {
                    Text("Provider resolution: \(n.resolution) minutes").font(.caption)
                    ForEach(Array(n.points.prefix(12))) { point in
                        HStack { Text(point.time, style: .time); Spacer(); Text(String(format: "%.2f mm/hr", point.rate)).monospacedDigit() }
                    }
                }
            }
            Section {
                LabeledContent("Frames loaded", value: RadarMetrics.shared.summary)
                Text(RadarMetrics.shared.detail).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Radar measurements") } footer: { Text("Measured on this device during the last time the map was open.") }
            Section {
                DisclosureGroup("Custom map manifest") {
                    TextField("HTTPS manifest URL", text: $model.manifestEndpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save") { UserDefaults.standard.set(model.manifestEndpoint, forKey: "manifestEndpoint"); Task { await model.refresh() } }
                    if let error = model.licensedError { Text(error).font(.caption).foregroundStyle(Sky.caution) }
                }
            } footer: { Text("For a licensed map backend that follows Docs/MAP-CONTRACT.md. Leave empty otherwise.") }
            Section {
                Button("It is raining here") { Diagnostics.shared.add("user-report", "User reported rain") }
                Button("It is dry here") { Diagnostics.shared.add("user-report", "User reported dry conditions") }
                Button("Forecast temperature feels wrong") { Diagnostics.shared.add("user-report", "User flagged temperature") }
            } header: { Text("Test report") } footer: { Text("Saved to the local log as feedback. Never used as training truth.") }
            Section {
                Toggle("Keep local diagnostic logs", isOn: $recordLogs)
                Button("View logs (\(Diagnostics.shared.events.count))") { showLogs = true }
                ShareLink(item: Diagnostics.shared.export, subject: Text("KlierSky diagnostic log")) { Label("Export sanitized logs", systemImage: "square.and.arrow.up") }
                Button("Clear diagnostic logs", role: .destructive) { clearLogs = true }
            } header: { Text("Diagnostics") } footer: {
                Text("Up to 500 events on this device: fixed status messages and times only. No coordinates, addresses, tokens or raw responses. Nothing is uploaded.")
            }
        }
        .navigationTitle("Weather Lab").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogs) {
            NavigationStack { List(Diagnostics.shared.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 4) { Text("\(event.category) · \(event.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary); Text(event.message).font(.subheadline) }
            }.navigationTitle("Diagnostic logs").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { showLogs = false } } }
        }
        .confirmationDialog("Clear local diagnostic logs?", isPresented: $clearLogs) { Button("Clear logs", role: .destructive) { Diagnostics.shared.clear() } }
    }
}
