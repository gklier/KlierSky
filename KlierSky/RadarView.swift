import SwiftUI
import MapLibre

/// Measurements taken while the map is open. Reported as measured, never assumed.
@MainActor @Observable final class RadarMetrics {
    static let shared = RadarMetrics()
    struct Snapshot: Codable {
        var recordedAt = Date()
        var mode = ""
        var frameCount = 0, framesReady = 0, framesIncomplete = 0
        var loadSeconds: [Double] = []
        var firstFrameSeconds: Double? = nil, allFramesSeconds: Double? = nil
        var tilesRequested = 0, tilesFromNetwork = 0, tilesFromCache = 0, tileErrors = 0
        var playbackSamples = 0
        var averageFPS: Double? = nil, worstFrameMS: Double? = nil, slowFrames = 0
        var bufferingPauses = 0
    }
    var snapshot = Snapshot()
    private let file = AppFiles.url("radar-metrics.json")
    init() { snapshot = (try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))) ?? Snapshot() }
    func save() { if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) } }
    var summary: String { snapshot.frameCount == 0 ? "Not measured yet" : "\(snapshot.framesReady) of \(snapshot.frameCount)" }
    var detail: String {
        let s = snapshot
        guard s.frameCount > 0 else { return "Open the map and play the loop to record load times and frame pacing." }
        let sorted = s.loadSeconds.sorted()
        var parts = ["\(s.mode) · \(s.recordedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let first = s.firstFrameSeconds { parts.append(String(format: "first frame %.2f s", first)) }
        if let all = s.allFramesSeconds { parts.append(String(format: "all frames %.2f s", all)) }
        if !sorted.isEmpty { parts.append(String(format: "per frame median %.2f s, slowest %.2f s", sorted[sorted.count / 2], sorted.last!)) }
        parts.append("tiles: \(s.tilesFromNetwork) network, \(s.tilesFromCache) cache, \(s.tileErrors) failed")
        if s.framesIncomplete > 0 { parts.append("\(s.framesIncomplete) frames shown with missing tiles") }
        if let fps = s.averageFPS, let worst = s.worstFrameMS { parts.append(String(format: "playback %.0f fps average, worst frame %.0f ms, %d slow of %d", fps, worst, s.slowFrames, s.playbackSamples)) }
        if s.bufferingPauses > 0 { parts.append("\(s.bufferingPauses) buffering pauses") }
        return parts.joined(separator: " · ")
    }
}

/// Owns the frame timeline for the interactive map and applies RadarBuffer's decisions.
@MainActor @Observable final class RadarEngine {
    private(set) var frames: [WeatherFrame] = []
    private(set) var buffer = RadarBuffer(count: 0)
    private(set) var moving = false
    var mode = "Radar"
    @ObservationIgnored var apply: (() -> Void)?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var opened = Date()
    @ObservationIgnored private var movedAt = Date.distantPast
    @ObservationIgnored private var counted = Set<String>()
    private var metrics: RadarMetrics { RadarMetrics.shared }

    var displayed: Int? { buffer.displayed }
    var target: Int { buffer.target }
    var displayedFrame: WeatherFrame? { buffer.displayed.flatMap { frames.indices.contains($0) ? frames[$0] : nil } }

    func setFrames(_ new: [WeatherFrame], target: Int) {
        guard new != frames else { return }
        frames = new; buffer = RadarBuffer(count: new.count, target: target); opened = Date(); counted = []
        metrics.snapshot = RadarMetrics.Snapshot(mode: mode, frameCount: new.count)
        tick()
    }
    func select(_ index: Int) { buffer.setTarget(index); tick() }
    func styleReloaded() { buffer.reset(); tick() }
    func setMoving(_ value: Bool) { moving = value; if !value { movedAt = Date() } }
    /// Playback holds while the map is being moved and briefly after, so new tiles can arrive first.
    var settled: Bool { !moving && Date().timeIntervalSince(movedAt) > 0.5 }
    func tile(frame: Int, key: String, event: RadarBuffer.TileEvent) {
        buffer.tile(frame: frame, key: key, event: event)
        if event == .cacheData || event == .networkRequest, counted.insert("\(frame)/\(key)").inserted { metrics.snapshot.tilesRequested += 1 }
        if event == .failed { metrics.snapshot.tileErrors += 1 }
    }
    nonisolated func count(network: Bool) {
        DispatchQueue.main.async { if network { self.metrics.snapshot.tilesFromNetwork += 1 } else { self.metrics.snapshot.tilesFromCache += 1 } }
    }
    func start() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
        }
    }
    func stop() { ticker?.cancel(); ticker = nil; metrics.save() }
    private func tick() {
        let before = (buffer.displayed, buffer.states)
        buffer.tick()
        if before.0 != buffer.displayed || before.1 != buffer.states { apply?(); record() }
    }
    private func record() {
        var s = metrics.snapshot
        s.framesReady = buffer.readyCount; s.framesIncomplete = buffer.incompleteCount
        s.loadSeconds = buffer.loadSeconds.values.sorted()
        if s.firstFrameSeconds == nil, buffer.readyCount >= 1 { s.firstFrameSeconds = Date().timeIntervalSince(opened) }
        if s.allFramesSeconds == nil, buffer.readyCount == min(buffer.count, buffer.config.maxResident), buffer.count > 0 { s.allFramesSeconds = Date().timeIntervalSince(opened) }
        metrics.snapshot = s; metrics.save()
    }
}

struct RadarMap: UIViewRepresentable {
    let place: Place
    let frames: [WeatherFrame]
    /// nil for the static preview on the main screen.
    let engine: RadarEngine?
    @Binding var status: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var baseStyle: URL { URL(string: "https://tiles.openfreemap.org/styles/" + (colorScheme == .dark ? "dark" : "positron"))! }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: baseStyle)
        map.delegate = context.coordinator
        map.setCenter(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), zoomLevel: engine == nil ? 5 : 5.6, animated: false)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.logoView.isHidden = true
        map.allowsRotating = false; map.allowsTilting = false
        // Radar imagery tops out near zoom 7; allow modest overzoom only, and never request finer tiles.
        map.minimumZoomLevel = 2; map.maximumZoomLevel = 9.5
        map.compassView.isHidden = true
        if engine != nil {
            map.attributionButtonPosition = .topRight; map.attributionButtonMargins = CGPoint(x: 12, y: 64)
            // No extra low-zoom tile for every frame: keeps requests to the tiles actually shown.
            map.prefetchesTiles = false
        }
        context.coordinator.map = map
        engine?.apply = { [weak coordinator = context.coordinator] in coordinator?.applyOpacities() }
        return map
    }
    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if map.styleURL != baseStyle { map.styleURL = baseStyle; return }
        context.coordinator.install(on: map)
    }
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: RadarMap
        weak var map: MLNMapView?
        var installed: [WeatherFrame] = []
        var opacities: [Double] = []
        init(_ parent: RadarMap) { self.parent = parent }
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Style callbacks are delivered on the main thread.
            MainActor.assumeIsolated { installed = []; opacities = []; install(on: mapView) }
            if let engine = parent.engine { DispatchQueue.main.async { engine.styleReloaded() } }
        }
        func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) { set(fullyRendered ? "" : "Loading map…") }
        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) { set("The base map could not be loaded. Check the connection.") }
        func mapView(_ mapView: MLNMapView, regionWillChangeAnimated animated: Bool) { if let engine = parent.engine { DispatchQueue.main.async { engine.setMoving(true) } } }
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) { if let engine = parent.engine { DispatchQueue.main.async { engine.setMoving(false) } } }
        private func set(_ message: String) { DispatchQueue.main.async { if self.parent.status != message { self.parent.status = message } } }

        func mapView(_ mapView: MLNMapView, tileDidTriggerAction operation: MLNTileOperation, x: Int, y: Int, z: Int, wrap: Int, overscaledZ: Int, sourceID: String) {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--tile-log") { TileLog.add("\(String(format: "%.3f", CACurrentMediaTime())) \(sourceID) op=\(operation.rawValue) \(overscaledZ)/\(z)/\(x)/\(y) main=\(Thread.isMainThread)") }
#endif
            guard let engine = parent.engine, sourceID.hasPrefix("rain-"), let frame = Int(sourceID.dropFirst(5)) else { return }
            let event: RadarBuffer.TileEvent
            switch operation {
            // Observed order: requestedFromCache, loadFromCache, startParse, requestedFromNetwork, endParse.
            // A tile is on screen only after endParse.
            case .requestedFromCache: event = .cacheLookup
            case .requestedFromNetwork: event = .networkRequest
            case .loadFromNetwork: engine.count(network: true); return
            case .loadFromCache: engine.count(network: false); event = .cacheData
            case .endParse, .cancelled: event = .finished
            case .error: event = .failed
            default: return
            }
            let key = "\(overscaledZ)/\(wrap)/\(z)/\(x)/\(y)"
            // The callback may arrive off the main thread; the engine is main-actor state.
            DispatchQueue.main.async { engine.tile(frame: frame, key: key, event: event) }
        }

        @MainActor func install(on map: MLNMapView) {
            guard let style = map.style else { return }
            let frames = parent.frames
            if installed != frames {
                for i in installed.indices {
                    if let layer = style.layer(withIdentifier: "rain-\(i)") { style.removeLayer(layer) }
                    if let source = style.source(withIdentifier: "rain-\(i)") { style.removeSource(source) }
                }
                installed = frames; opacities = Array(repeating: -1, count: frames.count)
                let labels = style.layers.first(where: { $0 is MLNSymbolStyleLayer })
                for (i, frame) in frames.enumerated() {
                    let source = MLNRasterTileSource(identifier: "rain-\(i)", tileURLTemplates: [frame.tileURL], options: [.tileSize: frame.tileSize ?? 256, .minimumZoomLevel: frame.minZoom ?? 0, .maximumZoomLevel: frame.maxZoom])
                    style.addSource(source)
                    let layer = MLNRasterStyleLayer(identifier: "rain-\(i)", source: source)
                    layer.rasterOpacity = NSExpression(forConstantValue: 0)
                    // Hidden layers fetch nothing. The buffer decides which frames may load.
                    layer.isVisible = false
                    layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
                    layer.rasterOpacityTransition = MLNTransition(duration: parent.reduceMotion ? 0 : 0.12, delay: 0)
                    if let labels { style.insertLayer(layer, below: labels) } else { style.addLayer(layer) }
                }
            }
            applyOpacities()
        }
        @MainActor func applyOpacities() {
            guard let style = map?.style, opacities.count == installed.count else { return }
            for i in installed.indices {
                let wanted: Double
                if let engine = parent.engine { wanted = engine.frames == installed ? engine.buffer.opacity(i) : 0 }
                else { wanted = i == installed.count - 1 ? RadarBuffer.shownOpacity : 0 }
                guard opacities[i] != wanted else { continue }
                opacities[i] = wanted
                guard let layer = style.layer(withIdentifier: "rain-\(i)") as? MLNRasterStyleLayer else { continue }
                layer.rasterOpacity = NSExpression(forConstantValue: wanted)
                layer.isVisible = wanted > 0
            }
        }
    }
}

/// Samples display frame intervals during playback so smoothness is measured, not asserted.
final class FramePacer: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var intervals: [Double] = []
    func start() {
        stop(); intervals = []; last = 0
        link = CADisplayLink(target: self, selector: #selector(step(_:))); link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func step(_ link: CADisplayLink) {
        if last > 0, intervals.count < 20000 { intervals.append(link.timestamp - last) }
        last = link.timestamp
    }
    /// Average rate, worst interval, and frames that took over 1.5× the median.
    var summary: (fps: Double, worstMS: Double, slow: Int, count: Int)? {
        guard intervals.count >= 30 else { return nil }
        let sorted = intervals.sorted(); let median = sorted[sorted.count / 2]
        return (Double(intervals.count) / intervals.reduce(0, +), sorted.last! * 1000, intervals.filter { $0 > median * 1.5 }.count, intervals.count)
    }
}

struct RadarScreen: View {
    let model: WeatherModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.units) private var units
    @AppStorage("modelFuturecast") private var modelFuturecast = true
    @State private var engine = RadarEngine()
    @State private var playing = false
    @State private var status = ""
    /// "timeline": past radar followed by the model forecast on one scrubber. "radar": past only. "model": forecast only.
    @AppStorage("mapMode") private var mode = "timeline"
    @State private var buffering = false
    @State private var pacer = FramePacer()

    private var futureFrames: [WeatherFrame] {
        let licensed = ForecastTimeline.select(model.licensedFrames)
        if !licensed.isEmpty { return licensed }
        return modelFuturecast ? ForecastTimeline.select(model.modelFrames) : []
    }
    private var observed: [WeatherFrame] { Array(model.frames.suffix(24)) }
    private var showsFuture: Bool { mode != "radar" }
    private var frames: [WeatherFrame] {
        switch mode {
        case "radar": return observed
        case "model": return futureFrames
        // Observed frames end at the present and model frames start there, so the order is already chronological.
        default: return observed + futureFrames
        }
    }
    /// Position of the newest observed frame when both kinds are on one timeline: where "now" sits.
    private var nowIndex: Int? { mode == "timeline" && !observed.isEmpty && !futureFrames.isEmpty ? observed.count - 1 : nil }
    private var zone: TimeZone { model.zone }

    var body: some View {
        ZStack {
            RadarMap(place: model.place, frames: frames, engine: engine, status: $status).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    GlassIconButton(symbol: "xmark", label: "Close map") { dismiss() }
                    Spacer()
                    Text(model.place.name).font(.subheadline.weight(.semibold)).lineLimit(1).padding(.horizontal, 16).frame(minHeight: 44).glass()
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                Spacer()
                panel
            }.padding(.horizontal, 14).padding(.bottom, 6)
        }
        .tint(Sky.accent)
        .onAppear { reload(); engine.start(); launchOptions(); if showsFuture { Task { await model.loadModelFrames() } } }
        .onDisappear { finishPlayback(); engine.stop() }
        .onChange(of: frames) { reload() }
        .onChange(of: mode) { playing = false; reload(); if showsFuture { Task { await model.loadModelFrames() } } }
        .onChange(of: phase) { if phase != .active { playing = false } }
        .onChange(of: playing) { if playing { pacer.start() } else { finishPlayback() } }
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled {
                let last = engine.target == engine.frames.count - 1
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 1400 : last ? 1300 : 480)) } catch { return }
                guard engine.frames.count > 1 else { playing = false; return }
                if engine.settled, let next = engine.buffer.nextForPlayback() { buffering = false; engine.select(next) }
                else if !buffering { buffering = true; RadarMetrics.shared.snapshot.bufferingPauses += 1 }
                if engine.target % 8 == 0 { recordPacing() }     // periodically, so a measurement survives the app closing
            }
        }
    }
    private func reload() {
        engine.mode = mode == "model" ? "Futurecast" : mode == "radar" ? "Radar" : "Radar + futurecast"
        // Open on the present: the newest observation, or the first model frame when only the model is shown.
        let start = mode == "model" ? 0 : min(max(0, observed.count - 1), max(0, frames.count - 1))
        engine.setFrames(frames, target: start)
    }
    private func finishPlayback() {
        pacer.stop(); buffering = false
        recordPacing()
    }
    private func recordPacing() {
        if let result = pacer.summary {
            RadarMetrics.shared.snapshot.averageFPS = result.fps; RadarMetrics.shared.snapshot.worstFrameMS = result.worstMS
            RadarMetrics.shared.snapshot.slowFrames = result.slow; RadarMetrics.shared.snapshot.playbackSamples = result.count
            RadarMetrics.shared.save()
        }
    }
    private func launchOptions() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--futurecast") { mode = "model" }
        if arguments.contains("--play") { Task { try? await Task.sleep(for: .seconds(arguments.contains("--futurecast") ? 6 : 3)); playing = true } }
#endif
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Map mode", selection: $mode) { Text("Past + future").tag("timeline"); Text("Radar").tag("radar"); Text("Model").tag("model") }.pickerStyle(.segmented)
            if let frame = engine.displayedFrame, engine.frames == frames {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(units.clock(frame.validTime, zone: zone)).font(.title.weight(.semibold)).monospacedDigit()
                            Text(relative(frame.validTime)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(kindLabel(frame)).font(.caption.weight(.bold)).tracking(0.4).foregroundStyle(frame.kind == .observed ? Sky.accent : Sky.warm)
                    }
                    Spacer()
                    if engine.buffer.isBuffering || buffering { ProgressView().controlSize(.small).padding(.trailing, 6).accessibilityLabel("Loading frame") }
                    Button { playing.toggle() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 48, height: 48).contentShape(Circle())
                    }.buttonStyle(.plain).glass(in: Circle(), interactive: true).disabled(frames.count < 2).accessibilityLabel(playing ? "Pause" : "Play")
                }
                VStack(spacing: 3) {
                    Slider(value: Binding(get: { Double(engine.target) }, set: { engine.select(Int($0.rounded())); playing = false }), in: 0...Double(max(1, frames.count - 1)), step: 1)
                        .disabled(frames.count < 2).accessibilityLabel("Frame time").accessibilityValue(units.clock(frame.validTime, zone: zone))
                    ReadinessBar(states: engine.buffer.states, target: engine.target, now: nowIndex)
                    HStack {
                        Text(frames.first.map { units.clock($0.validTime, zone: zone) } ?? "")
                        Spacer()
                        Text(loadLine).foregroundStyle(engine.buffer.incompleteCount > 0 ? Sky.caution : .secondary)
                        Spacer()
                        Text(frames.last.map { units.clock($0.validTime, zone: zone) } ?? "")
                    }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                MapLegend(observed: frame.kind == .observed)
                Text(provenance(frame)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if mode == "timeline", futureFrames.isEmpty {
                    // Only the past is on the timeline: say why, so a missing forecast is never mistaken for a dry one.
                    Text(model.modelFramesLoading ? "Finding the latest model run…" : !modelFuturecast ? "Model futurecast is turned off in Settings, so only past radar is shown." : (model.modelFramesError ?? "No model forecast frames are available right now, so only past radar is shown."))
                        .font(.caption2).foregroundStyle(Sky.caution).fixedSize(horizontal: false, vertical: true)
                }
            } else if mode == "model" {
                futureEmpty
            } else {
                Text(model.radarError ?? (model.loading ? "Loading radar frames…" : "No radar frames are available right now. Pull down on the weather screen to refresh.")).font(.subheadline)
            }
            if !status.isEmpty { Text(status).font(.caption2).foregroundStyle(Sky.caution) }
            HStack(spacing: 8) {
                if mode != "model" { Link("RainViewer", destination: URL(string: "https://www.rainviewer.com/")!) }
                if showsFuture && model.licensedFrames.isEmpty { Link("NOAA HRRR", destination: URL(string: "https://rapidrefresh.noaa.gov/hrrr/")!); Link("IEM", destination: URL(string: "https://mesonet.agron.iastate.edu/ogc/")!) }
            }.font(.caption2).lineLimit(1)
            HStack(spacing: 8) {
                Link("OpenFreeMap", destination: URL(string: "https://openfreemap.org/")!)
                Link("© OSM", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Link("OpenMapTiles", destination: URL(string: "https://openmaptiles.org/")!)
            }.font(.caption2).lineLimit(1)
        }
        .padding(16)
        .glass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
    @ViewBuilder private var futureEmpty: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.modelFramesLoading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Finding the latest model run…").font(.subheadline) } }
            else if !modelFuturecast { Text("Model futurecast is turned off in Settings.").font(.subheadline) }
            else if let error = model.modelFramesError ?? model.licensedError { Text(error).font(.subheadline) }
            else { Text("No forecast frames are available right now.").font(.subheadline) }
            Text("Futurecast only ever shows real model imagery. Past radar is never moved forward or relabelled as a forecast.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var loadLine: String {
        let buffer = engine.buffer
        let resident = min(buffer.count, buffer.config.maxResident)
        if buffer.incompleteCount > 0 { return "\(buffer.incompleteCount) frame\(buffer.incompleteCount == 1 ? "" : "s") missing tiles" }
        if buffer.count > resident { return buffer.isBuffering || buffering ? "Buffering…" : "\(buffer.count) frames" }
        return buffer.readyCount >= resident ? "\(buffer.count) frames" : "Loading \(buffer.readyCount)/\(resident)"
    }
    private func relative(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSinceNow / 60).rounded())
        let size = abs(minutes)
        let text = size < 60 ? "\(size) min" : size % 60 == 0 ? "\(size / 60) h" : "\(size / 60) h \(size % 60) min"
        return minutes == 0 ? "now" : minutes < 0 ? "\(text) ago" : "in \(text)"
    }
    private func kindLabel(_ frame: WeatherFrame) -> String {
        switch frame.kind {
        case .observed: return "OBSERVED RADAR"
        case .nowcast: return "SHORT-RANGE FORECAST"
        case .forecast: return frame.attribution.contains("HRRR") ? "HRRR MODEL FORECAST · NOT RADAR" : "MODEL FORECAST · NOT RADAR"
        }
    }
    private func provenance(_ frame: WeatherFrame) -> String {
        let age = Int(Date().timeIntervalSince(frame.issuedTime) / 60)
        let ageText = age < 60 ? "\(max(0, age)) min" : "\(age / 60) h \(age % 60) min"
        switch frame.kind {
        case .observed:
            return "RainViewer radar composite, generated \(units.clock(frame.issuedTime, zone: zone)). Light to dark blue is light to heavy precipitation. Empty areas can mean no radar coverage, not dry weather."
        default:
            let coverage = frame.attribution.contains("HRRR") ? " Covers the contiguous US only: blank areas beyond it are outside the model, not a dry forecast." : ""
            return "\(frame.attribution). \(frame.timeLabel ?? "Issued") \(units.clock(frame.issuedTime, zone: zone)), \(ageText) old. Simulated reflectivity: where the model expects precipitation (gray-blue faint, green light, yellow moderate, red heavy). Timing and placement errors grow with lead time.\(coverage)"
        }
    }
}

/// Qualitative colour key for the layer on screen. The two sources use different palettes, and neither
/// is presented as a calibrated scale: the key only says which end is light and which is heavy.
struct MapLegend: View {
    let observed: Bool
    private var colors: [Color] {
        observed
            ? [Color(red: 0.62, green: 0.84, blue: 0.98), Color(red: 0.33, green: 0.63, blue: 0.95), Color(red: 0.13, green: 0.40, blue: 0.85), Color(red: 0.05, green: 0.20, blue: 0.62)]
            : [Color(red: 0.55, green: 0.62, blue: 0.72), Color(red: 0.20, green: 0.70, blue: 0.25), Color(red: 0.95, green: 0.85, blue: 0.20), Color(red: 0.90, green: 0.20, blue: 0.15)]
    }
    var body: some View {
        HStack(spacing: 6) {
            Text("Light").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 2) { ForEach(colors.indices, id: \.self) { index in RoundedRectangle(cornerRadius: 2).fill(colors[index]).frame(width: 22, height: 6) } }
            Text("Heavy").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(observed ? "Radar colours" : "Model colours").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(observed ? "Radar colours run from light blue for light precipitation to dark blue for heavy." : "Model colours run from gray-blue for faint, through green and yellow, to red for heavy precipitation.")
    }
}

/// One tick per frame: filled when its tiles are in, hollow while loading, amber when tiles are missing.
/// On a combined timeline a taller mark shows where observation ends and the model forecast begins.
struct ReadinessBar: View {
    let states: [RadarBuffer.State]
    let target: Int
    var now: Int? = nil
    var body: some View {
        Canvas { context, size in
            guard !states.isEmpty else { return }
            let gap: CGFloat = states.count > 30 ? 1 : 2
            let width = (size.width - gap * CGFloat(states.count - 1)) / CGFloat(states.count)
            for (index, state) in states.enumerated() {
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: max(1, width), height: size.height)
                let color: Color = state == .ready ? Sky.accent : state == .incomplete ? Sky.caution : Color.primary.opacity(state == .idle ? 0.10 : 0.25)
                let inset = now == nil ? 0 : (size.height - 4) / 2
                context.fill(Path(roundedRect: rect.insetBy(dx: 0, dy: inset), cornerRadius: 1.5), with: .color(color.opacity(index == target ? 1 : 0.6)))
            }
            if let now, states.indices.contains(now) {
                // The boundary between what was observed and what the model expects.
                let x = CGFloat(now + 1) * (width + gap) - gap / 2
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.primary))
            }
        }
        .frame(height: now == nil ? 4 : 10).accessibilityHidden(true)
    }
}

#if DEBUG
enum TileLog {
    private static let queue = DispatchQueue(label: "tile-log")
    private static var lines: [String] = []
    static func add(_ line: String) {
        queue.async {
            guard lines.count < 1500 else { return }
            lines.append(line)
            if lines.count % 25 == 0 { try? lines.joined(separator: "\n").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("tile-events.log"), atomically: true, encoding: .utf8) }
        }
    }
}
#endif
