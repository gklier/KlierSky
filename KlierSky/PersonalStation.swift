import SwiftUI
import CoreLocation

struct StationReply: Decodable {
    let configured: Bool
    let observation: StationObservation?
}
struct StationObservation: Decodable {
    let provider: String
    let stationID: String
    let name: String
    let timestamp: Double
    let temperature: Double?
    let humidity: Double?
    let wind: Double?
    let uv: Double?
    let pressure: Double?
    let latitude: Double?
    let longitude: Double?
    var date: Date { Date(timeIntervalSince1970: timestamp) }
    var stale: Bool { Date().timeIntervalSince(date) > 1200 }
    func distance(from place: Place) -> Double? {
        guard let latitude, let longitude else { return nil }
        return CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
    }
}

@MainActor @Observable final class PersonalStation {
    static let shared = PersonalStation()
    var observation: StationObservation?
    var configured = false
    var message = ""
    var busy = false
    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { apply(try await request(method: "GET")) }
        catch { message = "Could not update your station. Check your weather-service access and try again." }
    }
    func connect(provider: String, station: String, key: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            apply(try await request(method: "PUT", body: ["provider": provider, "stationID": station.trimmingCharacters(in: .whitespacesAndNewlines), "key": key.trimmingCharacters(in: .whitespacesAndNewlines)]))
            message = "Connected. Your station credentials are saved on your server."
        } catch let error as HTTPFailure {
            message = error.status == 404 ? "This server needs the station connector update." : error.status == 401 || error.status == 403 ? "Check your service access, station ID and personal API credential." : "The station could not be reached. Your previous connection is still available."
        } catch { message = "Could not connect. Check your connection and try again." }
    }
    func disconnect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { apply(try await request(method: "DELETE")); message = "Station disconnected." }
        catch { message = "Could not disconnect. Try again when your server is reachable." }
    }
    private func apply(_ reply: StationReply) {
        configured = reply.configured
        observation = reply.observation
        message = ""
    }
    private func request(method: String, body: [String: String]? = nil) async throws -> StationReply {
        await GatewayAccess.shared.ensure()
        guard let token = GatewayAccess.shared.bearer else { throw URLError(.userAuthenticationRequired) }
        var request = URLRequest(url: try Gateway.url("v1/station"), timeoutInterval: 25)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(Network.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw HTTPFailure(status: http.statusCode, code: HTTPFailure.code(in: data)) }
        return try JSONDecoder().decode(StationReply.self, from: data)
    }
}

struct StationSettingsView: View {
    @State private var provider = "tempest"
    @State private var stationID = ""
    @State private var key = ""
    @State private var confirmDisconnect = false
    private var station: PersonalStation { .shared }
    var body: some View {
        Form {
            if let observation = station.observation {
                Section("Connected station") {
                    LabeledContent(observation.provider, value: observation.name)
                    Text(observation.date, style: .relative).font(.caption)
                    Button("Disconnect station", role: .destructive) { confirmDisconnect = true }
                }
            }
            Section {
                Picker("Station service", selection: $provider) {
                    Text("Tempest").tag("tempest")
                    Text("Weather Underground").tag("wunderground")
                }
                TextField("Station ID", text: $stationID).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(provider == "tempest" ? "Personal access token" : "PWS API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(station.busy ? "Connecting…" : "Connect station") {
                    let credential = key
                    key = ""
                    Task { await station.connect(provider: provider, station: stationID, key: credential) }
                }.disabled(station.busy || stationID.isEmpty || key.isEmpty)
            } header: { Text(station.configured ? "Change connection" : "Connect your station") } footer: {
                Text("Use a station you own or have permission to access. Credentials are sent over HTTPS and stored privately on your weather server for this device's account. Station readings appear separately from the forecast with their time and location.")
            }
            Section {
                if provider == "tempest" {
                    Link("Get a Tempest personal token", destination: URL(string: "https://tempestwx.com/settings/tokens")!)
                    Text("Find the numeric station ID in your Tempest station page URL. A personal token authorizes the stations available to your account.")
                } else {
                    Link("Weather Underground API keys", destination: URL(string: "https://www.wunderground.com/member/api-keys")!)
                    Text("Use the PWS data API key from your contributor account, together with your station ID. The station upload key is a different credential.")
                }
            }.font(.footnote)
            if !station.message.isEmpty { Section { Text(station.message).font(.footnote) } }
            if !GatewayAccess.shared.state.canFetch {
                Section { Text(GatewayAccess.shared.detail).font(.footnote) }
            }
        }
        .navigationTitle("My weather station").navigationBarTitleDisplayMode(.inline)
        .task { await station.load() }
        .confirmationDialog("Disconnect this station and delete its saved credentials from your server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await station.disconnect() } }
        }
    }
}

struct PersonalStationCard: View {
    let model: WeatherModel
    @Environment(\.units) private var units
    private var station: PersonalStation { .shared }
    var body: some View {
        Group {
            if let value = station.observation {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("My weather station")
                    HStack {
                        Text(value.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(units.temperature(value.temperature)).font(.title2.weight(.semibold))
                    }
                    HStack {
                        Label(units.percent(value.humidity), systemImage: "humidity")
                        Spacer()
                        Label(units.wind(value.wind), systemImage: "wind")
                        Spacer()
                        Label(value.uv.map { String(format: "%.1f UV", $0) } ?? "— UV", systemImage: "sun.max")
                    }.font(.footnote)
                    Text("\(value.provider) · observed \(units.clock(value.date, zone: model.zone))" + (value.stale ? " · Out of date" : "") + (value.distance(from: model.place).map { " · \(units.distance($0)) from forecast location" } ?? ""))
                        .font(.caption).foregroundStyle(value.stale ? Sky.caution : .secondary)
                    if !station.message.isEmpty { Text(station.message).font(.caption).foregroundStyle(Sky.caution) }
                }
            }
        }.task(id: model.updated) { await station.load() }
    }
}
