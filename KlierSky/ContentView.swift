import SwiftUI

struct ContentView: View {
    @State private var model = WeatherModel()
    @State private var sheet: Sheet?
    @State private var radar = false
    @State private var mapStatus = ""
    @State private var scrollTarget: String?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("celsius") private var celsius = false
    @AppStorage("rainInches") private var rainInches = false
    @AppStorage("clock24") private var clock24 = false
    @AppStorage("showWind") private var showWind = true
    @AppStorage("showDaily") private var showDaily = true
    @AppStorage("showDetails") private var showDetails = true
    @AppStorage("showComparison") private var showComparison = false
    @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize: CGFloat = 72
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 42
    enum Sheet: String, Identifiable { case search, settings, alerts, adaptive, owner, lab; var id: String { rawValue } }
    private var units: Units { Units(celsius: celsius, inches: rainInches, clock24: clock24) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    if let forecast = model.forecast {
                        conditions(forecast)
                        notices
                        if model.hasSelectedLocation { mapPreview }
                        TrendSection(model: model).id("trend")
                        HourlySection(model: model).id("hourly")
                        if showDaily { DailyForecastSection(forecast: forecast).id("daily") }
                        if showDetails { WeatherStatistics(forecast: forecast, air: model.air, alerts: model.alerts) { sheet = .alerts }.id("details") }
                        if showComparison { ProviderComparison(forecasts: [forecast] + model.alternatives) }
                    } else if !model.hasSelectedLocation {
                        welcome
                    } else {
                        notices
                        if model.loading { LoadingPlaceholder() } else { mapPreview }
                    }
                    footer
                }
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 28)
            }
            .onChange(of: scrollTarget) { if let scrollTarget { withAnimation { proxy.scrollTo(scrollTarget, anchor: .top) } } }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 20)
                // Content fades out beneath the floating controls instead of colliding with them.
                .background {
                    LinearGradient(stops: [.init(color: Color(.systemBackground), location: 0), .init(color: Color(.systemBackground), location: 0.74), .init(color: Color(.systemBackground).opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top).allowsHitTesting(false)
                }
        }
        .background(Color(.systemBackground))
        .refreshable { await model.refresh() }
        .environment(\.units, units)
        .tint(Sky.accent)
        .task {
            debugLaunch()
            await model.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if scenePhase == .active, !model.loading, Date().timeIntervalSince(model.updated ?? .distantPast) >= refreshInterval { await model.refresh() }
            }
        }
        .onChange(of: scenePhase) { if scenePhase == .background { BackgroundCollection.schedule() } }
        .onChange(of: scenePhase) { if scenePhase == .active, !model.loading, Date().timeIntervalSince(model.updated ?? .distantPast) > refreshInterval { Task { await model.refresh() } } }
        .fullScreenCover(isPresented: $radar) { RadarScreen(model: model).environment(\.units, units) }
        .sheet(item: $sheet) { item in
            Group {
                switch item {
                case .search: LocationSearch(usingCurrent: model.usingCurrentLocation, useCurrent: { model.useLocation() }) { model.select($0) }
                case .settings: SettingsView(model: model)
                case .alerts: AlertListView(feed: model.alerts, placeName: model.place.name, zone: model.zone)
                // Reached from Settings in normal use; direct entry exists for development screenshots.
                case .adaptive: NavigationStack { AccuracyPanel(model: model) }
                case .owner: NavigationStack { OwnerAdminView(model: model) }
                case .lab: NavigationStack { WeatherLabView(model: model) }
                }
            }.environment(\.units, units).tint(Sky.accent)
        }
        .onOpenURL { url in
            guard url.scheme == "kliersky", url.host == "weather", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            let values = Dictionary(c.queryItems?.compactMap { item in item.value.map { (item.name, $0) } } ?? [], uniquingKeysWith: { _, newer in newer })
            if values["current"] == "1" { model.useLocation() }
            else if let lat = values["lat"].flatMap(Double.init), let lon = values["lon"].flatMap(Double.init), lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) { model.select(Place(name: String((values["name"] ?? "Widget location").prefix(120)), latitude: lat, longitude: lon)) }
        }
    }
    private var refreshInterval: TimeInterval {
        let configured = UserDefaults.standard.integer(forKey: "refreshMinutes")
        return Double([5, 10, 30].contains(configured) ? configured : 10) * 60
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            GlassIconButton(symbol: "magnifyingglass", label: "Search locations") { sheet = .search }
            Spacer(minLength: 0)
            Button { sheet = .search } label: {
                HStack(spacing: 6) {
                    if model.usingCurrentLocation { Image(systemName: "location.fill").font(.caption2).foregroundStyle(Sky.accent).accessibilityLabel("Current location") }
                    Text(model.hasSelectedLocation ? model.place.name : "KlierSky").font(.subheadline.weight(.semibold)).lineLimit(1)
                    if model.loading { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 16).frame(minHeight: 44).contentShape(Capsule())
            }
            .buttonStyle(.plain).glass(interactive: true)
            .accessibilityHint("Choose a location")
            Spacer(minLength: 0)
            GlassIconButton(symbol: "slider.horizontal.3", label: "Settings") { sheet = .settings }
        }
    }

    // MARK: Current conditions

    private func conditions(_ f: Forecast) -> some View {
        let today = f.days.first
        let hour = model.hours.first
        return VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 12) {
                WeatherSymbol(code: f.current.weather_code, day: f.current.is_day != 0).font(.system(size: symbolSize)).accessibilityHidden(true)
                Text(units.temperature(f.current.temperature_2m)).font(.system(size: temperatureSize, weight: .medium)).monospacedDigit().tracking(-2).minimumScaleFactor(0.6).lineLimit(1)
            }
            Text(f.current.summary.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? WeatherCode.text(f.current.weather_code)).font(.title3.weight(.semibold))
            Text(["Feels \(units.temperature(f.current.apparent_temperature))", today?.high.map { "High \(units.temperature($0))" }, today?.low.map { "Low \(units.temperature($0))" }].compactMap { $0 }.joined(separator: "  ·  "))
                .font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { facts(f, hour) }
                VStack(spacing: 6) { facts(f, hour) }
            }.padding(.top, 10)
            Text("\(f.source ?? "Open-Meteo") model estimate" + (model.updated.map { " · updated \(units.clock($0, zone: .current))" } ?? ""))
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func facts(_ f: Forecast, _ hour: Hour?) -> some View {
        if showWind { fact("wind", "\(units.wind(f.current.wind_speed_10m)) \((f.current.wind_direction_10m ?? hour?.windDirection).map { Units.compass($0) } ?? "")", "Wind") }
        if let humidity = f.current.relative_humidity_2m ?? hour?.humidity { fact("humidity.fill", units.percent(humidity), "Humidity") }
        if let dew = f.current.dew_point_2m ?? hour?.dewPoint { fact("drop.degreesign", units.temperature(dew), "Dew point") }
        if let uv = hour?.uv { fact("sun.max", "UV \(Int(uv.rounded()))", "UV index") }
    }
    private func fact(_ symbol: String, _ value: String, _ name: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(value).monospacedDigit()
        }.font(.footnote.weight(.medium)).accessibilityElement(children: .ignore).accessibilityLabel("\(name) \(value)")
    }

    // MARK: Notices and alerts

    @ViewBuilder private var notices: some View {
        let current = model.alerts.current()
        if !current.isEmpty || model.error != nil || model.isStale || model.locationService.message != nil {
            VStack(spacing: 8) {
                ForEach(current.prefix(2)) { alert in AlertBanner(alert: alert, zone: model.zone, unverified: model.alerts.isStale()) { sheet = .alerts } }
                if current.count > 2 { Button("\(current.count - 2) more official alert\(current.count - 2 == 1 ? "" : "s")") { sheet = .alerts }.font(.footnote.weight(.semibold)) }
                if model.isStale, let updated = model.updated {
                    NoticeRow(symbol: "clock.arrow.circlepath", text: "Saved forecast from \(updated.formatted(date: .abbreviated, time: .shortened)). It may be out of date.", action: ("Refresh", { Task { await model.refresh() } }))
                }
                if let error = model.error { NoticeRow(symbol: "exclamationmark.triangle.fill", text: error) }
                if let message = model.locationService.message { NoticeRow(symbol: "location.slash.fill", text: message, action: ("Choose city", { sheet = .search })) }
            }
        }
    }

    // MARK: Map

    private var mapPreview: some View {
        ZStack(alignment: .bottom) {
            RadarMap(place: model.place, frames: Array(model.frames.suffix(1)), engine: nil, status: $mapStatus)
                .id(model.place.id).allowsHitTesting(false).accessibilityHidden(true)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Radar").font(.caption.weight(.semibold))
                    Group {
                        if let frame = model.frames.last { Text("Observed \(units.clock(frame.validTime, zone: model.zone))") }
                        else { Text(model.radarError == nil ? (model.loading ? "Loading observations…" : "No radar frames") : "Radar unavailable") }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 7).glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.footnote.weight(.semibold)).frame(width: 36, height: 36).glass(in: Circle())
            }.padding(10)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Sky.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { radar = true }
        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
        .accessibilityLabel("Radar map. " + (model.frames.last.map { "Latest observation \(units.clock($0.validTime, zone: model.zone))." } ?? "No radar frames.") + " Opens the interactive map.")
    }

    // MARK: Empty and footer

    private var welcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.circle").font(.system(size: 44)).foregroundStyle(Sky.accent)
            Text(model.awaitingLocation ? "Finding your local weather…" : "Weather where you are").font(.title3.weight(.semibold))
            Text("Allow location access for local forecasts, or choose a city. Your location is rounded to about a kilometre before any request.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Use my location") { model.useLocation() }.buttonStyle(.borderedProminent)
                Button("Choose a city") { sheet = .search }.buttonStyle(.bordered)
            }.padding(.top, 4)
            if let message = model.locationService.message { Text(message).font(.footnote).foregroundStyle(Sky.caution).multilineTextAlignment(.center) }
        }.padding(.vertical, 40).frame(maxWidth: .infinity)
    }
    private var footer: some View {
        VStack(spacing: 6) {
            if model.forecast != nil, model.zone.secondsFromGMT() != TimeZone.current.secondsFromGMT() {
                Text("Forecast times are local to \(model.place.name) (\(model.zone.abbreviation() ?? model.zone.identifier)).").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if model.forecast?.source == "Foreca" { Link("Forecast by Foreca", destination: URL(string: "https://www.foreca.com/")!) }
                else { Link("Forecast by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!) }
                Text("·").foregroundStyle(.secondary)
                Link("Radar by RainViewer", destination: URL(string: "https://www.rainviewer.com/")!)
            }
            if model.alternatives.contains(where: { $0.source == "Open-Meteo" }) { Link("Comparison data: Open-Meteo · CC BY 4.0", destination: URL(string: "https://open-meteo.com/")!) }
            HStack(spacing: 10) {
                Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Link("OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
                Link("OpenFreeMap", destination: URL(string: "https://openfreemap.org/")!)
            }
        }.font(.caption2).frame(maxWidth: .infinity).padding(.top, 4)
    }

    /// Launch arguments used only to capture real screens during development.
    private func debugLaunch() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? { arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        if let text = value("--place") {
            let parts = text.split(separator: ",", maxSplits: 2).map(String.init)
            if parts.count == 3, let lat = Double(parts[0]), let lon = Double(parts[1]) { model.select(Place(name: parts[2], latitude: lat, longitude: lon)) }
        }
        if arguments.contains("--radar") { radar = true }
        if let name = value("--sheet"), let item = Sheet(rawValue: name) { sheet = item }
        if let target = value("--scroll") { Task { try? await Task.sleep(for: .seconds(4)); scrollTarget = target } }
#endif
    }
}

struct LoadingPlaceholder: View {
    var body: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 12).fill(Sky.track).frame(width: 190, height: 84)
            RoundedRectangle(cornerRadius: 6).fill(Sky.track).frame(width: 220, height: 16)
            RoundedRectangle(cornerRadius: 18).fill(Sky.track).frame(height: 190)
            ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(Sky.track).frame(height: 26) }
        }
        .frame(maxWidth: .infinity).padding(.top, 8)
        .accessibilityElement(children: .ignore).accessibilityLabel("Loading forecast")
    }
}
