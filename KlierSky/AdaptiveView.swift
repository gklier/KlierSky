import SwiftUI

struct AccuracyPanel: View {
    let model: WeatherModel
    @AppStorage("adaptiveEnabled") private var enabled = false
    @AppStorage("verifyStations") private var collect = false
    @AppStorage("backgroundCollection") private var background = false
    @State private var verifying = false
    @State private var clear = false
    private var store: AdaptiveStore { AdaptiveStore.shared }
    private var forecasts: [Forecast] { model.forecast.map { [$0] + model.alternatives } ?? [] }
    private var providers: [String] { Array(Set(forecasts.map { $0.source ?? "Open-Meteo" })).sorted() }
    private var baseline: String { model.forecast?.source ?? "Open-Meteo" }

    var body: some View {
        let place = model.place
        let coverage = AdaptiveEngine.coverage(store.archive.samples, placeID: place.id)
        Form {
            Section {
                Toggle("Collect forecast evidence", isOn: $collect)
                    .onChange(of: collect) { if collect { check() } else { background = false; BackgroundCollection.cancel() } }
                Toggle("Also collect in the background", isOn: $background).disabled(!collect)
                    .onChange(of: background) { if background { BackgroundCollection.schedule() } else { BackgroundCollection.cancel() } }
            } header: { Text("Collection") } footer: {
                Text("Off by default. When on, KlierSky saves each forecast it shows for this location and later compares it with quality-controlled temperature readings from the nearest US weather station. Saved forecasts and scores stay on this iPhone, are excluded from backups and are deleted after 30 days. The station check sends the rounded location to the US National Weather Service; nothing is sent to the KlierSky server. Background collection runs only when iOS allows it and is not guaranteed.")
            }
            Section {
                Toggle("Use the better-verified temperature", isOn: $enabled)
            } header: { Text("Adaptive temperature") } footer: {
                Text("Changes hourly temperatures only, and only for a lead-time group where both sources were scored on at least 20 of the same hours across 5 or more days, one was at least 0.5°F closer on average, and that choice also did at least 0.25°F better on later hours it had not seen. These are safeguards on a small sample, not proof of better accuracy. Otherwise your preferred source is shown unchanged. Rain chance, amounts, symbols and current conditions never adapt.")
            }
            Section("Evidence for \(place.name)") {
                LabeledContent("Station", value: store.station(for: place).map { "\($0.id) · \(String(format: "%.1f", $0.distanceKM)) km away" } ?? "Not chosen yet")
                LabeledContent("Last station check", value: store.lastChecked(place).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                LabeledContent("Saved forecast hours", value: "\(store.captureCount(place))")
                LabeledContent("Past hours not scored yet", value: "\(store.unscored(place))")
                Text(store.status).font(.footnote).foregroundStyle(.secondary)
                Button(verifying ? "Checking…" : "Check station history now") { check() }.disabled(verifying || !model.hasSelectedLocation)
            }
            Section {
                ForEach(0..<4, id: \.self) { bucket in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Forecasts \(AdaptiveEngine.bucketNames[bucket]) ahead").font(.subheadline.weight(.semibold))
                        Text(explain(store.decision(providers: providers, baseline: baseline, place: place, bucket: bucket))).font(.footnote)
                        ForEach(coverage.filter { $0.bucket == bucket }, id: \.provider) { row in
                            Text("\(row.provider): \(row.count) hours scored · average miss \(String(format: "%.1f", row.mae))°F · tends \(String(format: "%.1f", abs(row.bias)))°F \(row.bias >= 0 ? "warm" : "cool") · \(row.first.formatted(date: .abbreviated, time: .omitted)) to \(row.last.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let check = AdaptiveEngine.heldOut(providers: providers, baseline: baseline, placeID: place.id, bucket: bucket, samples: store.archive.samples) {
                            Text("Held-out check: \(check.evaluated) later hours, \(check.switched) switched on \(check.switchedDays) day\(check.switchedDays == 1 ? "" : "s") · \(baseline) alone \(String(format: "%.2f", check.baselineMAE))°F vs adaptive \(String(format: "%.2f", check.adaptiveMAE))°F")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 2)
                }
            } header: { Text("By lead time") } footer: {
                Text(providers.count < 2 ? "Only one forecast source is connected, so sources cannot be compared yet. Scores for the single source still accumulate." : "A station reading is not the temperature at your address. Scores describe these sources at this station over the dates shown, nothing more.")
            }
            Section("Temperature source for the next hours") {
                ForEach(Array(model.hours.prefix(8))) { hour in
                    HStack { Text(hour.time, style: .time); Spacer(); Text(hour.source ?? baseline).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                Button("Clear local evidence", role: .destructive) { clear = true }
            } footer: { Text("Removes saved forecasts, station choice and scores from this iPhone.") }
        }
        .navigationTitle("Adaptive weather").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear local accuracy evidence?", isPresented: $clear) { Button("Clear evidence", role: .destructive) { store.clear() } }
    }
    private func check() {
        guard !verifying, model.hasSelectedLocation else { return }
        verifying = true
        Task { await store.verify(model.place); verifying = false }
    }
    private func explain(_ decision: AdaptiveEngine.Decision) -> String {
        switch decision {
        case .collecting(let paired, let needed): return providers.count < 2 ? "Waiting for a second forecast source to compare." : "Collecting: \(paired) of \(needed) hours scored for both sources. No change to the forecast."
        case .collectingDays(let days, let needed): return "Collecting: enough hours, but from only \(days) of the \(needed) different days needed. Hours from one day are too alike to count as separate evidence. No change to the forecast."
        case .noClearDifference: return "Enough hours scored. The sources are within 0.5°F of each other, so nothing changes."
        case .baselineBest: return "\(baseline), your preferred source, is already the closer one here."
        case .awaitingHeldOut(let candidate): return "\(candidate) has been closer so far, but has not yet proved it on later hours. No change until it does."
        case .use(let provider): return enabled ? "Using \(provider) temperatures: closer on scored hours and on later held-out hours." : "\(provider) qualifies. Turn on adaptive temperature to use it."
        }
    }
}
