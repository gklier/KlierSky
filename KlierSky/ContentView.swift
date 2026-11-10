import SwiftUI
import Charts

@MainActor @Observable final class WeatherModel {
    var place: Place
    var hasSelectedLocation: Bool
    var awaitingLocation = false
    var forecast: Forecast?
    var alternatives: [Forecast] = []
    var frames: [WeatherFrame] = []
    var error: String?
    var radarError: String?
    var loading = false
    var licensedFrames: [WeatherFrame] = []
    var licensedError: String?
    var nowcast: Gateway.Nowcast?
    var providerStatus = "Not refreshed yet"
    var manifestEndpoint = UserDefaults.standard.string(forKey: "manifestEndpoint") ?? ""
    var updated: Date?
    private var requestID = UUID()
    let locationService = LocationService()
    init() {
        let saved = UserDefaults.standard.data(forKey: "selectedPlace").flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
        place = saved ?? Place(name: "Current location", latitude: 0, longitude: 0)
        hasSelectedLocation = saved != nil
        if let cache = CachedForecast.load(place) { forecast = cache.forecast; updated = cache.fetchedAt; providerStatus = "Saved forecast · Refreshing when connected" }
    }
    var hours: [Hour] {
        guard let forecast else { return [] }
        return AdaptiveStore.shared.selectedHours(base: forecast, alternatives: alternatives, place: place, enabled: UserDefaults.standard.bool(forKey: "adaptiveEnabled"))
    }
    func start() async {
        if (UserDefaults.standard.string(forKey: "locationMode") ?? "current") == "current" { useLocation() }
        else if hasSelectedLocation { await refresh() }
    }
    func select(_ place: Place) {
        UserDefaults.standard.set("fixed", forKey: "locationMode")
        self.place = place; hasSelectedLocation = true; awaitingLocation = false; forecast = nil; updated = nil; frames = []
        Task { await refresh() }
    }
    func useLocation() {
        UserDefaults.standard.set("current", forKey: "locationMode"); awaitingLocation = true
        locationService.onUnavailable = { [weak self] in
            guard let self else { return }; self.awaitingLocation = false
            if self.hasSelectedLocation { Task { await self.refresh() } }
        }
        locationService.onLocation = { [weak self] place in
            guard let self else { return }; self.place = place; self.hasSelectedLocation = true; self.awaitingLocation = false; self.forecast = nil; self.updated = nil; self.frames = []
            Task { await self.refresh() }
        }
        locationService.locate()
    }
    func refresh() async {
        guard hasSelectedLocation else { return }
        let id = UUID(); requestID = id
        let location = place
        if let data = try? JSONEncoder().encode(location) { UserDefaults.standard.set(data, forKey: "selectedPlace") }
        if forecast == nil, let cache = CachedForecast.load(location) { forecast = cache.forecast; updated = cache.fetchedAt }
        loading = true
        error = nil; radarError = nil; licensedError = nil; nowcast = nil; licensedFrames = []; alternatives = []
        Diagnostics.shared.add("refresh", "Weather refresh started")
        let configured = !(UserDefaults.standard.string(forKey: "gatewayURL") ?? "").isEmpty && !SecureStore.read().isEmpty
        async let weatherResult = capture { try await Forecast.load(location) }
        async let radarResult = capture { try await RainViewerProvider().frames() }
        async let forecaResult: Result<Forecast, Error>? = configured ? await capture { try await Gateway.forecast(location) } : nil
        let (weather, radar, foreca) = await (weatherResult, radarResult, forecaResult)
        guard requestID == id else { return }
        var available: [Forecast] = []
        if case .success(var value) = weather { value.source = "Open-Meteo"; available.append(value); Diagnostics.shared.add("provider", "Open-Meteo forecast received") }
        else { Diagnostics.shared.add("provider", "Open-Meteo request failed") }
        if case .success(var value) = foreca { value.source = "Foreca"; available.append(value); Diagnostics.shared.add("provider", "Foreca forecast received") }
        else if configured { Diagnostics.shared.add("provider", "Foreca request failed; checking fallback") }
        let preferred = UserDefaults.standard.string(forKey: "preferredProvider") ?? "Foreca"
        if var chosen = available.first(where: { $0.source == preferred }) ?? available.first {
            if chosen.source == "Foreca", chosen.timezone == nil, let metadata = available.first(where: { $0.source == "Open-Meteo" }) { chosen.timezone = metadata.timezone; chosen.utc_offset_seconds = metadata.utc_offset_seconds }
            forecast = chosen; updated = Date(); alternatives = available.filter { $0.source != chosen.source }
            providerStatus = "\(chosen.source ?? "Forecast")" + (chosen.source != preferred ? " · fallback" : "")
            CachedForecast(place: location, forecast: chosen, fetchedAt: updated!).save()
            available.forEach { AdaptiveStore.shared.capture($0, at: location) }
        } else { error = "Refresh failed. Showing the last saved forecast, if available. Check its update time."; providerStatus = "Offline / unavailable" }
        if configured && !available.contains(where: { $0.source == "Foreca" }) { error = "Foreca unavailable. Check the gateway connection and account access in Settings. Using any available fallback." }
        switch radar {
        case .success(let value): frames = value; Diagnostics.shared.add("radar", "Observed radar manifest received")
        case .failure: radarError = "Radar refresh failed. Check timestamps on retained frames."; Diagnostics.shared.add("radar", "Observed radar request failed")
        }
        if configured && UserDefaults.standard.bool(forKey: "forecaMapsEnabled") {
            do {
                let value = try await Gateway.frames(location)
                guard requestID == id else { return }; licensedFrames = value
                Diagnostics.shared.add("maps", "Licensed map manifest received")
            } catch { licensedError = "Foreca maps unavailable. Map entitlement is separate from point forecasts."; Diagnostics.shared.add("maps", "Licensed map request failed") }
        } else if !manifestEndpoint.isEmpty {
            do {
                guard let url = URL(string: manifestEndpoint), url.scheme == "https" else { throw URLError(.badURL) }
                let value = try await LicensedRadarProvider(endpoint: url).frames()
                guard requestID == id else { return }; licensedFrames = value
            } catch { licensedError = "Custom map connection failed." }
        }
        if configured && UserDefaults.standard.bool(forKey: "forecaNowcastEnabled") {
            do {
                let value = try await Gateway.nowcast(location)
                guard requestID == id else { return }; nowcast = value
                Diagnostics.shared.add("nowcast", value.isTrueMinute ? "Minute-resolution forecast received" : "Coarser-resolution forecast received")
            } catch { Diagnostics.shared.add("nowcast", "Nowcast not available for this account or location") }
        }
        guard requestID == id else { return }
        loading = false
        Diagnostics.shared.add("refresh", "Weather refresh finished")
        if UserDefaults.standard.bool(forKey: "verifyStations") { await AdaptiveStore.shared.verify(location) }
    }
}
func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}
struct ContentView: View {
    @State private var model = WeatherModel()
    @State private var radar = false
    @State private var settings = false
    @State private var search = false
    @State private var engineering = false
    @State private var accuracy = false
    @State private var showAllHours = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var mapStatus = "Loading radar…"
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
    private var blue: Color { colorScheme == .dark ? Color(red: 0.34, green: 0.68, blue: 0.93) : Color(red: 0.05, green: 0.42, blue: 0.68) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if let forecast = model.forecast { conditions(forecast) }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center) }
                    if let updated = model.updated, Date().timeIntervalSince(updated) > 1800 {
                        Text("Saved forecast · updated \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.orange)
                    }
                    if model.hasSelectedLocation { mapPreview }
                    else {
                        VStack(spacing: 10) {
                            Image(systemName: "location.circle").font(.largeTitle).foregroundStyle(blue)
                            Text(model.awaitingLocation ? "Finding your local weather…" : "Weather where you are").font(.headline)
                            Text("Allow location access or choose a city to get started.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Choose a city") { search = true }
                        }.padding(.vertical, 26)
                    }
                    if let forecast = model.forecast {
                        precipitation(forecast)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Hourly forecast").font(.headline)
                                Spacer()
                                Button(showAllHours ? "Show 6 hours" : "Show 24 hours") { showAllHours.toggle() }.font(.caption)
                            }
                            hourly(forecast)
                        }
                        if showDaily { DailyForecastSection(forecast: forecast) }
                        if showDetails { WeatherStatistics(forecast: forecast) }
                        if showComparison { ProviderComparison(forecasts: [forecast] + model.alternatives) }
                    } else if model.loading { ProgressView("Loading forecast…").padding() }
                    if let message = model.locationService.message { Text(message).font(.caption).foregroundStyle(.orange) }
                    footer
                }.padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20)
            }
            .background(Color(.systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refresh() }
            .task {
                await model.start()
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--radar") { radar = true }
#endif
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    let configured = UserDefaults.standard.integer(forKey: "refreshMinutes")
                    let interval = Double([5, 10, 30].contains(configured) ? configured : 10) * 60
                    if scenePhase == .active, !model.loading, Date().timeIntervalSince(model.updated ?? .distantPast) >= interval { await model.refresh() }
                }
            }
            .onChange(of: scenePhase) { if scenePhase == .active, !model.loading, Date().timeIntervalSince(model.updated ?? .distantPast) > Double(UserDefaults.standard.integer(forKey: "refreshMinutes") == 0 ? 10 : UserDefaults.standard.integer(forKey: "refreshMinutes")) * 60 { Task { await model.refresh() } } }
            .fullScreenCover(isPresented: $radar) { RadarScreen(model: model) }
            .sheet(isPresented: $search) {
                LocationSearch { place in model.select(place) }
            }
            .onOpenURL { url in
                guard url.scheme == "kliersky", url.host == "weather", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                let values = Dictionary(c.queryItems?.compactMap { item in item.value.map { (item.name,$0) } } ?? [], uniquingKeysWith: { _, newer in newer })
                if values["current"] == "1" { model.useLocation() }
                else if let lat = values["lat"].flatMap(Double.init), let lon = values["lon"].flatMap(Double.init), lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) { model.select(Place(name: String((values["name"] ?? "Widget location").prefix(120)), latitude: lat, longitude: lon)) }
            }
            .sheet(isPresented: $settings) { settingsView }
            .sheet(isPresented: $engineering) { TestingPanel(model: model) }
            .sheet(isPresented: $accuracy) { AccuracyPanel(model: model) }
        }.tint(blue)
    }
    private var header: some View {
        HStack {
            Button { search = true } label: { Image(systemName: "magnifyingglass").frame(width: 40, height: 40) }.accessibilityLabel("Search locations")
            Spacer(minLength: 4)
            Button { search = true } label: { Text(model.place.name).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.primary) }
            Spacer(minLength: 4)
            Button { settings = true } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 40, height: 40).background(.thinMaterial, in: Circle())
            }.accessibilityLabel("Settings")
        }
    }
    private func conditions(_ f: Forecast) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                Image(systemName: symbol(f.current.weather_code, daylight: f.current.is_day != 0))
                    .symbolRenderingMode(.palette).foregroundStyle(Color.primary, blue).font(.system(size: 32))
                Text(temp(f.current.temperature_2m)).font(.system(size: 54, weight: .semibold)).tracking(-2).monospacedDigit()
            }
            Text("Feels \(temp(f.current.apparent_temperature))" + (showWind ? " · Wind \(Int(f.current.wind_speed_10m.rounded())) mph" : ""))
                .font(.caption).foregroundStyle(.secondary)
            Text(f.current.summary ?? condition(f.current.weather_code)).font(.caption).foregroundStyle(.secondary)
            Text("\(f.source ?? "Open-Meteo") · current estimate").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.top, -4).padding(.bottom, 2)
    }
    private var mapPreview: some View {
        ZStack(alignment: .bottomLeading) {
            RadarMap(place: model.place, frames: Array(model.frames.suffix(1)), selected: 0, status: $mapStatus)
                .id(model.place.id).allowsHitTesting(false)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RADAR").font(.system(size: 9, weight: .bold)).tracking(1.2)
                    if let frame = model.frames.last {
                        Text("Observed · \(frame.validTime.formatted(date: .omitted, time: .shortened))").font(.caption2)
                    } else { Text(model.radarError == nil ? "Loading observations…" : "Radar unavailable").font(.caption2) }
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8).background(.ultraThinMaterial, in: Circle())
            }.foregroundStyle(.white).padding(10)
        }
        .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { Button { radar = true } label: { Color.clear.contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Open interactive radar map") }
        .overlay(alignment: .topLeading) {
            if model.frames.isEmpty && !model.loading { Text("Coverage unavailable").font(.caption2).padding(7).background(.black.opacity(0.8)) }
        }
    }
    private func precipitation(_ f: Forecast) -> some View {
        let candidates = Array(model.hours.prefix(12))
        let hours = candidates.filter { $0.time.timeIntervalSince(candidates.first?.time ?? Date()) < 12 * 3600 }
        let complete = TrendMetric.isComplete(hours)
        let metric = TrendMetric.choose(hours)
        let peak = hours.compactMap { metric.value($0, celsius: celsius) }.max()
        let headline = metric == .wind ? "Low rain chance · Wind outlook" : metric == .temperature ? "Low rain chance · Temperature outlook" : metric == .probability ? "Rain chances in the next 12 hours" : hours.isEmpty ? "Precipitation forecast unavailable" : "Precipitation in the next 12 hours"
        let value = metric == .rain ? amount(peak ?? 0) + " / hr" : metric == .wind ? WeatherStyle.scalar(peak, suffix: " mph") : metric == .probability ? WeatherStyle.scalar(peak, suffix: "%") : WeatherStyle.scalar(peak, suffix: "°")
        return VStack(spacing: 9) {
            Text(headline).font(.subheadline).multilineTextAlignment(.center)
            HStack {
                Text("12-HOUR " + metric.rawValue.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6)
                Spacer()
                Text(peak == nil ? "Data unavailable" : "Peak \(value)").font(.system(size: 9))
            }.foregroundStyle(.secondary)
            PrecipitationGraph(hours: hours, color: metric == .wind ? .indigo : blue, metric: metric, celsius: celsius).frame(height: 76)
            HStack { Text("Now"); Spacer(); Text("+3h"); Spacer(); Text("+6h"); Spacer(); Text("+9h"); Spacer(); Text("+12h") }.font(.system(size: 9)).foregroundStyle(.secondary)
            Text("Hourly model · \(model.providerStatus)" + (complete ? "" : " · Rain data incomplete")).font(.system(size: 9)).foregroundStyle(.secondary)
            if let nowcast = model.nowcast { Text(nowcast.isTrueMinute ? "Minute forecast connected · See Weather Lab" : "Near-term data is \(nowcast.resolution)-minute resolution").font(.caption2).foregroundStyle(blue) }
        }
    }
    private func hourly(_ f: Forecast) -> some View {
        let hours = Array(model.hours.prefix(showAllHours ? 24 : 6))
        let low = hours.map(\.temperature).min() ?? 0
        let high = hours.map(\.temperature).max() ?? 1
        return VStack(spacing: 0) {
            ForEach(Array(hours.enumerated()), id: \.element.id) { index, h in
                HStack(spacing: 10) {
                    Rectangle().fill(blue.opacity(0.18 + h.chance / 100 * 0.82)).frame(width: 14)
                        .accessibilityLabel("Precipitation probability \(Int(h.chance)) percent")
                    Text(index == 0 ? "NOW" : time(h.time)).font(.system(size: 11, weight: .semibold)).frame(width: 48, alignment: .leading)
                    Image(systemName: symbol(h.code ?? -1, daylight: h.daylight)).font(.system(size: 13)).foregroundStyle(blue).frame(width: 20)
                    Text(h.chance > 0 ? "\(Int(h.chance))%" : "").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 29, alignment: .leading)
                    GeometryReader { geometry in
                        let position = (h.temperature - low) / max(1, high - low)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                            Text(temp(h.temperature)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .padding(.horizontal, 7).padding(.vertical, 2).background(Color(.secondarySystemBackground), in: Capsule())
                                .offset(x: max(0, geometry.size.width - 48) * position)
                        }.frame(height: geometry.size.height)
                    }
                }.frame(height: 32)
            }
            HStack { Text("Rain probability"); Spacer(); Text("Hourly temperature") }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 7)
        }.padding(.top, 4)
    }
    private var footer: some View {
        VStack(spacing: 5) {
            if let date = model.updated { Text("Updated \(time(date)) · Times on this device").font(.caption2).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                if model.forecast?.source == "Foreca" { Link("Forecast by Foreca", destination: URL(string: "https://www.foreca.com/")!) }
                else { Link("Forecast by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!) }
                Text("·")
                Link("Radar: RainViewer", destination: URL(string: "https://www.rainviewer.com/")!)
            }.font(.system(size: 10))
            if model.alternatives.contains(where: { $0.source == "Open-Meteo" }) { Link("Comparison data: Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!).font(.system(size: 10)) }
            HStack(spacing: 10) {
                Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Link("OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
            }.font(.system(size: 10))
        }.padding(.top, 8)
    }
    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    Toggle("Daily forecast", isOn: $showDaily)
                    Toggle("Weather details", isOn: $showDetails)
                    Toggle("Compare forecast sources", isOn: $showComparison)
                    Picker("Temperature", selection: $celsius) { Text("Fahrenheit (°F)").tag(false); Text("Celsius (°C)").tag(true) }
                    Picker("Precipitation", selection: $rainInches) { Text("Millimeters").tag(false); Text("Inches").tag(true) }
                    Toggle("24-hour clock", isOn: $clock24)
                    Toggle("Show wind in header", isOn: $showWind)
                }
                Section("Weather detail choices") {
                    Toggle("Humidity & dew point", isOn: $showHumidity)
                    Toggle("Pressure", isOn: $showPressure)
                    Toggle("Visibility", isOn: $showVisibility)
                    Toggle("Sunrise & sunset", isOn: $showSun)
                }
                Section("Location") {
                    Text(model.place.name)
                    Picker("Start with", selection: $locationMode) { Text("Current location").tag("current"); Text("Last selected city").tag("fixed") }
                        .onChange(of: locationMode) { if locationMode == "current" { model.useLocation() } }
                    if model.hasSelectedLocation { Button(FavoriteLocations.shared.contains(model.place) ? "Remove from favorites" : "Add to favorites") { FavoriteLocations.shared.toggle(model.place) } }
                    Button("Use my current location") { model.useLocation() }
                    if let message = model.locationService.message { Text(message).font(.caption).foregroundStyle(.orange) }
                }
                Section("Widgets") {
                    Text("Add KlierSky from the Home Screen or Lock Screen widget gallery. Edit a widget to use current location or search for a city.").font(.caption)
                    Text("Standalone widget forecasts use Open-Meteo. iOS controls update timing, so check the displayed update time.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Testing & providers") {
                    Button("Weather Lab · Providers & logs") { settings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { engineering = true } }
                    Button("Adaptive weather · Accuracy") { settings = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { accuracy = true } }
                }
                Section("Weather data") {
                    LabeledContent("Forecast", value: model.providerStatus)
                    LabeledContent("Observed radar", value: "RainViewer")
                    Text("The precipitation graph is an hourly model forecast. It does not predict the next hour minute by minute. Radar shows observations; missing coverage can appear empty.").font(.caption).foregroundStyle(.secondary)
                    Text("12+ hour futurecast maps need licensed forecast imagery. No future storm motion is manufactured from observed radar.").font(.caption).foregroundStyle(.secondary)
                    Button("Refresh weather") { Task { await model.refresh() } }
                }
                Section {
                    DisclosureGroup("Advanced map connection") {
                        TextField("HTTPS manifest URL", text: $model.manifestEndpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Save connection") { UserDefaults.standard.set(model.manifestEndpoint, forKey: "manifestEndpoint"); Task { await model.refresh() } }
                        Text("Use a licensed backend; keep vendor API keys on the server.").font(.caption).foregroundStyle(.secondary)
                        if let error = model.licensedError { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }
                Section("About KlierSky") {
                    Text("Personal testing build 0.3 · No severe-weather alerts").font(.caption)
                    Link("Open-Meteo terms & attribution", destination: URL(string: "https://open-meteo.com/en/terms")!)
                    Link("RainViewer terms & attribution", destination: URL(string: "https://www.rainviewer.com/api.html")!)
                    Text("Forecast: \(model.forecast?.source ?? "Unavailable"). Radar: RainViewer. Comparison data: Open-Meteo (CC BY 4.0) when connected.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } }
        }.tint(blue)
    }
    private func temp(_ fahrenheit: Double) -> String { "\(Int((celsius ? (fahrenheit - 32) * 5 / 9 : fahrenheit).rounded()))°" }
    private func amount(_ mm: Double) -> String { String(format: rainInches ? "%.2f in" : "%.1f mm", rainInches ? mm / 25.4 : mm) }
    private func time(_ date: Date) -> String { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = clock24 ? "HH:mm" : "h a"; return formatter.string(from: date) }
    private func symbol(_ code: Int, daylight: Bool = true) -> String { code < 0 ? "questionmark" : code == 0 ? (daylight ? "sun.max.fill" : "moon.fill") : code < 4 ? (daylight ? "cloud.sun.fill" : "cloud.moon.fill") : code < 50 ? "cloud.fog.fill" : code < 70 ? "cloud.rain.fill" : code < 80 ? "cloud.snow.fill" : code < 95 ? "cloud.heavyrain.fill" : "cloud.bolt.rain.fill" }
    private func condition(_ code: Int) -> String { code < 0 ? "Conditions unavailable" : code == 0 ? "Clear skies" : code < 4 ? "Partly cloudy" : code < 50 ? "Foggy" : code < 70 ? "Rain" : code < 80 ? "Snow" : code < 95 ? "Showers" : "Thunderstorms" }
}

struct PrecipitationGraph: View {
    let hours: [Hour]
    let color: Color
    var metric: TrendMetric = .rain
    var celsius = false
    var body: some View {
        Canvas { context, size in
            let values = hours.compactMap { metric.value($0,celsius:celsius) }
            let bottom = metric == .temperature ? (values.min() ?? 0)-2 : 0
            let top = metric == .temperature ? (values.max() ?? 0)+2 : metric == .probability ? 100 : max(1,values.max() ?? 1)
            for fraction in [0.0,0.45,0.85] {
                let y = 10+(size.height-14)*fraction
                var grid=Path(); grid.move(to:CGPoint(x:0,y:y)); grid.addLine(to:CGPoint(x:size.width,y:y))
                context.stroke(grid,with:.color(.primary.opacity(0.13)),style:StrokeStyle(lineWidth:0.5,dash:[3,4]))
            }
            guard let start=hours.first?.time else { return }
            var line=Path(); var segmentOpen=false; var previous:Date?
            for hour in hours {
                guard let value=metric.value(hour,celsius:celsius),value.isFinite else { segmentOpen=false; continue }
                if let previous, hour.time.timeIntervalSince(previous)>4500 { segmentOpen=false }
                let x=size.width*hour.time.timeIntervalSince(start)/(12*3600)
                let y=size.height-1-(size.height-15)*(value-bottom)/max(1,top-bottom)
                let point=CGPoint(x:x,y:y)
                if !segmentOpen { line.move(to:point); segmentOpen=true } else { line.addLine(to:point) }
                previous=hour.time
            }
            context.stroke(line,with:.color(color),lineWidth:2.5)
        }.accessibilityLabel("Twelve-hour \(metric.rawValue) forecast. Gaps mean unavailable data.")
    }
}
