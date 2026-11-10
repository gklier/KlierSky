import SwiftUI

struct TestingPanel: View {
    @Bindable var model: WeatherModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gatewayURL") private var gatewayURL = ""
    @AppStorage("preferredProvider") private var preferred = "Foreca"
    @AppStorage("forecaMapsEnabled") private var maps = false
    @AppStorage("forecaNowcastEnabled") private var nowcast = true
    @AppStorage("refreshMinutes") private var refreshMinutes = 10
    @AppStorage("recordLogs") private var recordLogs = true
    @State private var token = ""
    @State private var forecaKey = ""
    @State private var pairCode = ""
    @State private var pairing = false
    @State private var provisioning = false
    @State private var connectionMessage = ""
    @State private var showLogs = false
    @State private var clearLogs = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("HTTPS gateway address", text: $gatewayURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("One-time pairing code", text: $pairCode).keyboardType(.numberPad)
                    Button(pairing ? "Pairing…" : "Pair this iPhone") {
                        let code = pairCode; pairCode = ""; pairing = true
                        Task { do { try await Gateway.pair(code); connectionMessage = "Paired. Use Save and test connection to check the server."; Diagnostics.shared.add("settings", "Gateway paired") } catch { connectionMessage = "Pairing failed. Check your internet connection, the server address and the unexpired one-time code." }; pairing = false }
                    }.disabled(pairing || pairCode.count != 8)
                    SecureField("Gateway access token (advanced)", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(SecureStore.read().isEmpty ? "No access token saved" : "Access token is saved in Keychain").font(.caption).foregroundStyle(.secondary)
                    Button(model.loading ? "Refreshing…" : "Save & test connection") {
                        do {
                            if !token.isEmpty { try SecureStore.save(token); token = "" }
                            _ = try Gateway.url("forecast", place: model.place)
                            connectionMessage = "Saved. Refreshing forecasts…"
                            Diagnostics.shared.add("settings", "Gateway configuration saved")
                            Task { do { let status = try await Gateway.health(); if status.configured { await model.refresh(); connectionMessage = model.providerStatus } else { connectionMessage = "Gateway connected. Enter your Foreca API key below." } } catch { connectionMessage = "Gateway check failed. Verify your internet connection, server address and pairing." } }
                        } catch { connectionMessage = "Use an HTTPS gateway address without query parameters. Token storage must succeed." }
                    }.disabled(model.loading)
                    if !connectionMessage.isEmpty { Text(connectionMessage).font(.caption) }
                    Text("Foreca's key stays on your gateway server. Enter the gateway token here, never your Foreca account password. A blank token field leaves an existing token unchanged.").font(.caption).foregroundStyle(.secondary)
                    Button("Remove saved gateway token", role: .destructive) { do { try SecureStore.save(""); connectionMessage = "Saved gateway token removed." } catch { connectionMessage = "Could not remove the token." } }
                }
                Section("Foreca API access") {
                    SecureField("Foreca API key", text: $forecaKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(provisioning ? "Connecting…" : "Send key securely to my gateway") {
                        let key = forecaKey; forecaKey = ""; provisioning = true
                        Task {
                            do { try await Gateway.provisionForeca(key); connectionMessage = "Foreca key sent to your gateway. Refreshing…"; await model.refresh() }
                            catch { connectionMessage = "Could not configure Foreca. Save and test the gateway address and access token first." }
                            provisioning = false
                        }
                    }.disabled(forecaKey.isEmpty || provisioning)
                    Text("Sent over HTTPS to your own gateway, then cleared from this field. Your server stores it in an owner-only credential file when configured for persistent storage. It never enters the app bundle. It is never written into app logs or source code.").font(.caption).foregroundStyle(.secondary)
                    Link("Foreca My API", destination: URL(string: "https://developer.foreca.com/")!)
                }
                Section("Forecast preferences") {
                    Picker("Preferred provider", selection: $preferred) { Text("Foreca").tag("Foreca"); Text("Open-Meteo").tag("Open-Meteo") }
                    Toggle("Request near-term Foreca forecast", isOn: $nowcast)
                    Toggle("Request licensed Foreca maps", isOn: $maps)
                    Text("Map access needs a separate Foreca entitlement. Failure falls back to observed radar; forecasts never become observations.").font(.caption).foregroundStyle(.secondary)
                    Picker("Refresh on returning to app", selection: $refreshMinutes) { Text("After 5 minutes").tag(5); Text("After 10 minutes").tag(10); Text("After 30 minutes").tag(30) }
                    LabeledContent("Current source", value: model.providerStatus)
                    Text("Foreground refresh only. No continuous background tracking.").font(.caption).foregroundStyle(.secondary)
                }
                if let n = model.nowcast {
                    Section(n.isTrueMinute ? "Minute forecast" : "Near-term forecast") {
                        Text("Provider resolution: \(n.resolution) minutes").font(.caption)
                        ForEach(Array(n.points.prefix(12))) { point in
                            HStack { Text(point.time, style: .time); Spacer(); Text(String(format: "%.2f mm/hr", point.rate)).monospacedDigit() }
                        }
                    }
                }
                Section("Test report") {
                    Text("These reports are personal feedback, never automatic training truth.").font(.caption).foregroundStyle(.secondary)
                    Button("It is raining here") { Diagnostics.shared.add("user-report", "User reported rain") }
                    Button("It is dry here") { Diagnostics.shared.add("user-report", "User reported dry conditions") }
                    Button("Forecast temperature feels wrong") { Diagnostics.shared.add("user-report", "User flagged temperature") }
                }
                Section("Diagnostics") {
                    Toggle("Keep local diagnostic logs", isOn: $recordLogs)
                    Button("View logs (\(Diagnostics.shared.events.count))") { showLogs = true }
                    ShareLink(item: Diagnostics.shared.export, subject: Text("KlierSky diagnostic log")) { Label("Export sanitized logs", systemImage: "square.and.arrow.up") }
                    Button("Clear diagnostic logs", role: .destructive) { clearLogs = true }
                    Text("Up to 500 events on this device. Logs contain fixed status messages and timestamps, without coordinates, addresses, tokens or raw API responses. Nothing is uploaded automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Weather Lab").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .sheet(isPresented: $showLogs) {
                    NavigationStack { List(Diagnostics.shared.events.reversed()) { event in
                        VStack(alignment: .leading, spacing: 4) { Text("\(event.category) · \(event.time.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary); Text(event.message).font(.subheadline) }
                    }.navigationTitle("Diagnostic logs").toolbar { Button("Done") { showLogs = false } } }
                }
                .confirmationDialog("Clear local diagnostic logs?", isPresented: $clearLogs) { Button("Clear logs", role: .destructive) { Diagnostics.shared.clear() } }
        }
    }
}
struct AccuracyPanel: View {
    let model: WeatherModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("adaptiveEnabled") private var enabled = false
    @AppStorage("verifyStations") private var stations = false
    @State private var verifying = false
    @State private var clear = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Adaptive temperature") {
                    Toggle("Use verified temperature selection", isOn: $enabled)
                    Toggle("Check nearby US station on refresh", isOn: $stations)
                    Text("Learns from earlier forecasts compared with independent station temperatures. Needs at least 20 matching hours for both providers in a lead-time group and a meaningful error difference. Until then your preferred provider stays in use.").font(.caption)
                    Text("Only temperature can adapt. Rain probability, precipitation amounts, symbols and current conditions stay with the baseline source. No claims of improved rain accuracy are made.").font(.caption).foregroundStyle(.secondary)
                    Text("Station measurements may differ from conditions at your address. Verification is limited to stations within 15 km and observations within 15 minutes of the forecast target.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Local evidence") {
                    Text(AdaptiveStore.shared.status).font(.subheadline)
                    LabeledContent("Saved forecast points", value: String(AdaptiveStore.shared.archive.captures.count))
                    LabeledContent("Verified temperature errors", value: String(AdaptiveStore.shared.archive.samples.filter { $0.placeID == model.place.id }.count))
                    Button(verifying ? "Checking…" : "Verify against nearby US station") {
                        verifying = true
                        Task { await AdaptiveStore.shared.verify(model.place); verifying = false }
                    }.disabled(verifying)
                    Text("Uses your selected location with the US National Weather Service. No current-model estimates or personal reports are accepted as verification truth.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Provider comparison") {
                    if let forecast = model.forecast {
                        ForEach([forecast] + model.alternatives, id: \.source) { f in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(f.source ?? "Open-Meteo").font(.headline)
                                Text("Next hour: \(Int(f.hours.first?.temperature.rounded() ?? 0))°F · \(Int(f.hours.first?.chance ?? 0))% precipitation").font(.caption)
                                ForEach(0..<4) { bucket in
                                    if let score = AdaptiveEngine.score(AdaptiveStore.shared.archive.samples, provider: f.source ?? "Open-Meteo", placeID: model.place.id, bucket: bucket) {
                                        Text("\(["0–6h", "6–24h", "1–3 days", "3+ days"][bucket]): \(score.count) checks · mean temperature error \(score.mae, specifier: "%.1f")°F").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if model.alternatives.isEmpty { Text("Connect Foreca to compare two live providers. One source cannot establish a ranking.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Selected hourly sources") {
                    ForEach(Array(model.hours.prefix(12))) { hour in HStack { Text(hour.time, style: .time); Spacer(); Text(hour.source ?? "Forecast").font(.caption).foregroundStyle(.secondary) } }
                }
                Section { Button("Clear local accuracy history", role: .destructive) { clear = true }; Text("History stays on this device, excluded from backups, and is capped to a rolling 30 days. Clearing it resets selection to your preferred source.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Adaptive weather").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog("Clear local accuracy evidence?", isPresented: $clear) { Button("Clear history", role: .destructive) { AdaptiveStore.shared.clear() } }
        }
    }
}
