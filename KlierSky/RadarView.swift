import SwiftUI
import MapLibre

struct RadarMap: UIViewRepresentable {
    let place: Place
    let frames: [WeatherFrame]
    let selected: Int
    @Binding var status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var baseStyle: URL { URL(string: "https://tiles.openfreemap.org/styles/" + (colorScheme == .dark ? "dark" : "positron"))! }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: baseStyle)
        map.delegate = context.coordinator
        map.setCenter(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), zoomLevel: 5, animated: false)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.logoView.isHidden = true
        // Built-in attribution remains available; source credits are also shown below.
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if map.styleURL != baseStyle { map.styleURL = baseStyle; return }
        context.coordinator.install(on: map)
    }
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: RadarMap
        var installed: [WeatherFrame] = []
        init(_ parent: RadarMap) { self.parent = parent }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) { installed = []; install(on: mapView) }
        func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
            let message = fullyRendered ? "Coverage varies · Empty areas may have missing radar data" : "Loading map tiles…"
            if parent.status != message { DispatchQueue.main.async { self.parent.status = message } }
        }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async { self.parent.status = "Map delivery failed. Check connection." }
        }
        func install(on map: MLNMapView) {
            guard let style = map.style else { return }
            let ids = parent.frames
            if installed != ids {
                for i in installed.indices {
                    if let l = style.layer(withIdentifier: "rain-\(i)") { style.removeLayer(l) }
                    if let s = style.source(withIdentifier: "rain-\(i)") { style.removeSource(s) }
                }
                installed = ids
                // Keep the bounded timeline resident, allowing MapLibre's tile cache to
                // reuse decoded textures rather than rebuilding the map on every tick.
                for (i, frame) in parent.frames.enumerated() {
                    let source = MLNRasterTileSource(identifier: "rain-\(i)", tileURLTemplates: [frame.tileURL], options: [.tileSize: 256, .minimumZoomLevel: frame.minZoom ?? 0, .maximumZoomLevel: frame.maxZoom])
                    style.addSource(source)
                    let layer = MLNRasterStyleLayer(identifier: "rain-\(i)", source: source)
                    layer.rasterOpacity = NSExpression(forConstantValue: 0)
                    layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
                    layer.rasterOpacityTransition = MLNTransition(duration: parent.reduceMotion ? 0 : 0.16, delay: 0)
                    if let labels = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) { style.insertLayer(layer, below: labels) } else { style.addLayer(layer) }
                }
            }
            for i in installed.indices {
                (style.layer(withIdentifier: "rain-\(i)") as? MLNRasterStyleLayer)?.rasterOpacity = NSExpression(forConstantValue: i == parent.selected ? 0.78 : 0)
            }
        }
    }
}
struct RadarScreen: View {
    let model: WeatherModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected = 0
    @State private var playing = false
    @State private var status = "Tiles load on demand · gaps may mean missing coverage"
    @State private var future = false
    private var frames: [WeatherFrame] {
        if future { return ForecastTimeline.select(model.licensedFrames) }
        return Array(model.frames.suffix(24))
    }
    private var frame: WeatherFrame? { frames.indices.contains(selected) ? frames[selected] : nil }
    var body: some View {
        ZStack {
            RadarMap(place: model.place, frames: frames, selected: selected, status: $status).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").padding(14).background(.regularMaterial, in: Circle()) }.accessibilityLabel("Close radar")
                    Spacer()
                    Text(model.place.name).font(.headline).padding(12).background(.regularMaterial, in: Capsule())
                }
                Spacer()
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Map mode", selection: $future) { Text("Observed").tag(false); Text("Futurecast").tag(true) }.pickerStyle(.segmented).onChange(of: future) { playing = false; selected = 0 }
                    if future && frames.isEmpty {
                        Text("12+ hour futurecast").font(.title2.weight(.semibold))
                        Text(model.licensedError ?? "A licensed precipitation map connection is required. Your 24-hour point forecast is available on the weather screen.").font(.subheadline)
                        Text("Enable licensed maps and configure your gateway in Weather Lab when your Foreca account has map access.").font(.caption).foregroundStyle(.secondary)
                    } else if let frame {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(frame.validTime, format: .dateTime.hour().minute()).font(.title.weight(.light)).monospacedDigit()
                                Text(frame.kind.rawValue.uppercased() + (frame.isStale ? " · CHECK ISSUE TIME" : "")).font(.caption.weight(.semibold)).foregroundStyle(frame.isStale ? .orange : .cyan)
                            }
                            Spacer()
                            Button { playing.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2).padding(16) }.accessibilityLabel(playing ? "Pause radar" : "Play radar")
                        }
                        Slider(value: Binding(get: { Double(selected) }, set: { selected = Int($0.rounded()); playing = false }), in: 0...Double(max(1, frames.count - 1)), step: 1).disabled(frames.count < 2).accessibilityLabel("Radar frame time")
                        HStack { Text(frames.first?.validTime ?? Date(), format: .dateTime.hour().minute()); Spacer(); Text(future ? "Forecast horizon" : "Latest available") }.font(.caption).foregroundStyle(.secondary)
                        Text("Precipitation · Rain, snow & mixed").font(.caption).foregroundStyle(.cyan)
                    } else { Text(model.radarError ?? "No radar frames available. Pull to refresh on the weather screen.") }
                    if let frame {
                        Text("Device time · Source: \(frame.attribution) · \(frame.timeLabel ?? "Issued") \(frame.issuedTime.formatted(date: .abbreviated, time: .shortened))").font(.caption2)
                        if future { Text("Model placement and timing become less certain farther ahead. Frame spacing is not a measure of forecast skill.").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Link("RainViewer", destination: URL(string: "https://www.rainviewer.com/")!)
                        Text("·")
                        Link("OpenFreeMap", destination: URL(string: "https://openfreemap.org/")!)
                        Link("© OSM", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        Link("OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
                    }.font(.caption2)
                }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }.padding(16)
        }.tint(.cyan)
        .onAppear { selected = max(0, frames.count - 1) }
        .onChange(of: phase) { if phase != .active { playing = false } }
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 1400 : 700)) } catch { return }
                guard !frames.isEmpty else { playing = false; return }
                selected = (selected + 1) % frames.count
            }
        }
    }
}
