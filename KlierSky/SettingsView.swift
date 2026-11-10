import SwiftUI

struct SettingsView: View {
    @Bindable var model: WeatherModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("celsius") private var celsius = false
    @AppStorage("rainInches") private var rainInches = false
    @AppStorage("clock24") private var clock24 = false
    @AppStorage("showWind") private var showWind = true
    @AppStorage("locationMode") private var locationMode = "current"
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showDaily") private var showDaily = true
    @AppStorage("showDetails") private var showDetails = true
    @AppStorage("showComparison") private var showComparison = false
    @AppStorage("showHumidity") private var showHumidity = true
    @AppStorage("showPressure") private var showPressure = true
    @AppStorage("showVisibility") private var showVisibility = true
    @AppStorage("showSun") private var showSun = true
    @AppStorage("preferredProvider") private var preferred = "Foreca"
    @AppStorage("modelFuturecast") private var modelFuturecast = true
    @State private var checking = false
    private var access: GatewayAccess { GatewayAccess.shared }
    private var version: String { "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance & units") {
                    Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    Picker("Units", selection: $celsius) { Text("°F, mph, inHg, mi").tag(false); Text("°C, km/h, hPa, km").tag(true) }
                    Picker("Precipitation", selection: $rainInches) { Text("Millimeters").tag(false); Text("Inches").tag(true) }
                    Toggle("24-hour clock", isOn: $clock24)
                }
                Section("Location") {
                    LabeledContent("Showing", value: model.hasSelectedLocation ? model.place.name : "Not set")
                    Picker("When the app opens", selection: $locationMode) { Text("Current location").tag("current"); Text("Last chosen city").tag("fixed") }
                        .onChange(of: locationMode) { if locationMode == "current" { model.useLocation() } }
                    if model.hasSelectedLocation { Button(FavoriteLocations.shared.contains(model.place) ? "Remove from favorites" : "Add to favorites") { FavoriteLocations.shared.toggle(model.place) } }
                    if let message = model.locationService.message { Text(message).font(.footnote).foregroundStyle(Sky.caution) }
                }
                Section {
                    LabeledContent("Foreca service", value: access.title)
                    Text(access.detail).font(.footnote).foregroundStyle(.secondary)
                    if access.state == .revoked { Button(checking ? "Asking…" : "Ask for access again") { check(again: true) }.disabled(checking) }
                    else if !access.state.canFetch { Button(checking ? "Checking…" : "Check now") { check(again: false) }.disabled(checking) }
                    Picker("Preferred forecast", selection: $preferred) { Text("Foreca").tag("Foreca"); Text("Open-Meteo").tag("Open-Meteo") }
                        .onChange(of: preferred) { Task { await model.refresh() } }
                    LabeledContent("Showing now", value: model.providerStatus)
                } header: { Text("Forecast source") } footer: {
                    Text("KlierSky connects to its weather service by itself. There is nothing to enter: each iPhone gets its own read-only access that the owner can remove.")
                }
                Section("On the main screen") {
                    Toggle("Daily forecast", isOn: $showDaily)
                    Toggle("Current details", isOn: $showDetails)
                    Toggle("Compare forecast sources", isOn: $showComparison)
                    Toggle("Wind under the temperature", isOn: $showWind)
                    Toggle("Humidity & dew point", isOn: $showHumidity)
                    Toggle("Pressure", isOn: $showPressure)
                    Toggle("Visibility", isOn: $showVisibility)
                    Toggle("Sunrise & sunset", isOn: $showSun)
                }
                Section {
                    Toggle("Model futurecast (HRRR)", isOn: $modelFuturecast)
                } header: { Text("Map") } footer: {
                    Text("Radar shows RainViewer observations. Futurecast shows NOAA's HRRR model for the contiguous US, loaded only when you open that tab. Each model run covers 18 hours and is a few hours old when published, so expect roughly 14 to 16 hours ahead. It is a model forecast, not radar.")
                }
                Section {
                    Text("Add KlierSky from the Home Screen or Lock Screen widget gallery, then edit the widget to use your location or a city.").font(.footnote)
                } header: { Text("Widgets") } footer: {
                    Text("Widgets fetch Open-Meteo by themselves and say so. iOS decides how often they update, so check the time shown on the widget.")
                }
                Section("More") {
                    NavigationLink("Adaptive weather") { AccuracyPanel(model: model) }
                    NavigationLink("Weather Lab · diagnostics") { WeatherLabView(model: model) }
                    NavigationLink("Owner administration") { OwnerAdminView(model: model) }
                }
                Section {
                    LabeledContent("Version", value: version)
                    Link("Foreca", destination: URL(string: "https://www.foreca.com/")!)
                    Link("Open-Meteo terms & attribution", destination: URL(string: "https://open-meteo.com/en/terms")!)
                    Link("RainViewer terms & attribution", destination: URL(string: "https://www.rainviewer.com/api.html")!)
                    Link("Iowa Environmental Mesonet (HRRR tiles)", destination: URL(string: "https://mesonet.agron.iastate.edu/ogc/")!)
                    Link("National Weather Service", destination: URL(string: "https://www.weather.gov/")!)
                } header: { Text("About KlierSky") } footer: {
                    Text("Personal testing build. Forecasts are model estimates. Official alerts are listed in the app but are not pushed to you.")
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func check(again: Bool) {
        checking = true
        Task {
            if again { await access.requestAgain() } else { UserDefaults.standard.removeObject(forKey: "accessRetryAfter"); await access.ensure() }
            if access.state.canFetch { await model.refresh() }
            checking = false
        }
    }
}

/// Owner-only: the administrative token, device approvals and the vendor key.
/// Family members never need this screen, and nothing here ships with a secret.
struct OwnerAdminView: View {
    let model: WeatherModel
    @AppStorage("gatewayURL") private var gatewayURL = ""
    @State private var pairCode = ""
    @State private var token = ""
    @State private var forecaKey = ""
    @State private var busy = false
    @State private var message = ""
    @State private var list: Gateway.DeviceList?
    @State private var listNote = ""
    @State private var hasOwnerToken = !SecureStore.read().isEmpty
    @State private var confirmRemove = false
    private var defaultURL: String { let value = Bundle.main.object(forInfoDictionaryKey: "KlierSkyGatewayURL") as? String ?? ""; return GatewayAddress.isUsable(value) ? value : "" }

    var body: some View {
        Form {
            Section {
                Text("For the person who runs the weather server. Other people using KlierSky can ignore this screen: their access is set up automatically and cannot change anything here.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Owner sign-in") {
                if hasOwnerToken {
                    Label("Owner access is saved on this iPhone", systemImage: "checkmark.seal.fill").foregroundStyle(Sky.wind)
                    Button("Remove owner access from this iPhone", role: .destructive) { confirmRemove = true }
                } else {
                    SecureField("One-time pairing code", text: $pairCode).keyboardType(.numberPad)
                    Button(busy ? "Pairing…" : "Pair as owner") { pair() }.disabled(busy || pairCode.count != 8)
                    SecureField("Owner token (advanced)", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save owner token") { saveToken() }.disabled(token.isEmpty)
                    Text("The owner token is kept in this iPhone's Keychain only. It is never built into the app or shared with other devices.").font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).font(.footnote) }
            }
            if hasOwnerToken {
                Section {
                    if let list {
                        Picker("New devices", selection: Binding(get: { list.enrollment }, set: { mode in run { try await Gateway.admin("PUT", "v1/admin/enrollment", body: ["mode": mode]) } })) {
                            Text("Join automatically").tag("open"); Text("Need my approval").tag("approval"); Text("Not accepted").tag("closed")
                        }
                        LabeledContent("Devices", value: "\(list.devices.filter { $0.status != "revoked" }.count) of \(list.maxDevices)")
                        LabeledContent("Daily limit per device", value: "\(list.dailyRequestsPerDevice) requests")
                        if list.upstreamBudget > 0 { LabeledContent("Foreca calls today", value: "\(list.upstreamUsedToday) of \(list.upstreamBudget)") }
                        ForEach(list.devices) { device in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(device.label.isEmpty ? "Device" : device.label).font(.subheadline.weight(.semibold)); Spacer(); Text(device.status.capitalized).font(.caption.weight(.semibold)).foregroundStyle(device.status == "active" ? Sky.wind : device.status == "pending" ? Sky.caution : Sky.danger) }
                                Text("Code \(device.code) · \(device.requestsToday) requests today · last seen \(device.lastSeen > 0 ? Date(timeIntervalSince1970: device.lastSeen).formatted(date: .abbreviated, time: .shortened) : "never")").font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 16) {
                                    if device.status == "pending" { Button("Approve") { run { try await Gateway.admin("POST", "v1/admin/devices/\(device.deviceID)/approve") } } }
                                    if device.status != "revoked" { Button("Revoke", role: .destructive) { run { try await Gateway.admin("POST", "v1/admin/devices/\(device.deviceID)/revoke") } } }
                                    else { Button("Forget") { run { try await Gateway.admin("DELETE", "v1/admin/devices/\(device.deviceID)") } } }
                                }.buttonStyle(.borderless).font(.footnote.weight(.semibold))
                            }.padding(.vertical, 2)
                        }
                    }
                    if !listNote.isEmpty { Text(listNote).font(.footnote).foregroundStyle(.secondary) }
                    Button(busy ? "Loading…" : "Reload devices") { loadDevices() }.disabled(busy)
                } header: { Text("Devices") } footer: {
                    Text("Revoke blocks a device and it cannot come back by itself. Devices only ever get read-only forecasts.")
                }
                Section {
                    SecureField("Foreca API key", text: $forecaKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(busy ? "Sending…" : "Send key to my server") { sendKey() }.disabled(forecaKey.isEmpty || busy)
                } header: { Text("Foreca key") } footer: {
                    Text("Needed once per server, not per phone. It is sent over HTTPS to your server, stored there in an owner-only file, and cleared from this field. It is never stored in the app.")
                }
            }
            Section {
                TextField("HTTPS address", text: $gatewayURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if gatewayURL != defaultURL, !defaultURL.isEmpty { Button("Use the built-in address") { gatewayURL = defaultURL } }
            } header: { Text("Service address") } footer: { Text(defaultURL.isEmpty ? "This build has no built-in service address, so it uses Open-Meteo until one is entered here. Release builds set it through the KLIERSKY_GATEWAY_URL build setting." : "Set automatically from this build. Change it only when testing another server.") }
        }
        .navigationTitle("Owner administration").navigationBarTitleDisplayMode(.inline)
        .task { if hasOwnerToken { loadDevices() } }
        .confirmationDialog("Remove the owner token from this iPhone? The app will then use ordinary automatic access.", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove owner access", role: .destructive) {
                do { try SecureStore.save(""); hasOwnerToken = false; list = nil; GatewayAccess.shared.reload(); message = "Owner access removed from this iPhone."; Task { await model.refresh() } }
                catch { message = "Could not remove the token." }
            }
        }
    }
    private func pair() {
        let code = pairCode; pairCode = ""; busy = true
        Task {
            do { try await Gateway.pair(code); hasOwnerToken = true; GatewayAccess.shared.reload(); message = "Paired as owner."; Diagnostics.shared.add("settings", "Owner paired"); await model.refresh(); loadDevices() }
            catch { message = "Pairing failed. Check the connection and that the one-time code is unused and unexpired." }
            busy = false
        }
    }
    private func saveToken() {
        do { try SecureStore.save(token); token = ""; hasOwnerToken = true; GatewayAccess.shared.reload(); message = "Owner token saved."; Task { await model.refresh() }; loadDevices() }
        catch { message = "The token could not be saved to the Keychain." }
    }
    private func sendKey() {
        let key = forecaKey; forecaKey = ""; busy = true
        Task {
            do { try await Gateway.provisionForeca(key); message = "Foreca key stored on your server."; await model.refresh() }
            catch { message = "The server did not accept the key. Check owner sign-in first." }
            busy = false
        }
    }
    private func loadDevices() { run { try await Gateway.devices() } }
    private func run(_ action: @escaping () async throws -> Gateway.DeviceList) {
        busy = true
        Task {
            do { list = try await action(); listNote = "" }
            catch let failure as HTTPFailure where failure.status == 404 { list = nil; listNote = "This server does not have device access switched on yet. See Gateway/MIGRATION.md for the one-time setup." }
            catch let failure as HTTPFailure where failure.status == 409 { listNote = "The device limit is reached. Revoke or forget a device before approving another." }
            catch let failure as HTTPFailure where failure.status == 401 || failure.status == 403 { list = nil; listNote = "The server did not accept the saved owner token." }
            catch { listNote = "Could not reach the server." }
            busy = false
        }
    }
}
