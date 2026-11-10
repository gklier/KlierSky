import SwiftUI
struct LocationSearch: View {
    let select: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var renaming: Place?
    @State private var newName = ""
    @State private var message = "Search for a city, or choose a saved location."
    struct Response: Decodable {
        struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double; let country: String?; let admin1: String? }
        let results: [Result]?
    }
    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty && !FavoriteLocations.shared.places.isEmpty {
                    Section("Favorites") {
                        ForEach(FavoriteLocations.shared.places) { place in
                            Button(place.name) { select(place); dismiss() }
                                .contextMenu { Button("Rename") { newName = place.name; renaming = place } }
                        }.onDelete { FavoriteLocations.shared.remove($0) }
                    }
                }
                Section(query.isEmpty ? "Suggested cities" : "Search results") {
                    ForEach(query.isEmpty ? Place.presets : results) { place in
                        HStack {
                            Button(place.name) { select(place); dismiss() }.frame(maxWidth: .infinity, alignment: .leading)
                            Button { FavoriteLocations.shared.toggle(place) } label: { Image(systemName: FavoriteLocations.shared.contains(place) ? "star.fill" : "star").frame(width: 44, height: 36) }.buttonStyle(.borderless).accessibilityLabel(FavoriteLocations.shared.contains(place) ? "Remove favorite" : "Save favorite")
                        }
                    }
                }
                Text(message).font(.caption).foregroundStyle(.secondary)
                Link("Location search by Open-Meteo / GeoNames", destination: URL(string: "https://open-meteo.com/en/docs/geocoding-api")!).font(.caption)
            }.navigationTitle("Your weather")
                .searchable(text: $query, prompt: "City name")
                .toolbar { Button("Done") { dismiss() } }
                .alert("Rename favorite", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("Name", text: $newName)
                    Button("Save") { if let place = renaming { FavoriteLocations.shared.rename(place, name: newName) }; renaming = nil }
                    Button("Cancel", role: .cancel) { renaming = nil }
                }
                .task(id: query) {
                    guard query.count > 1 else { results = []; return }
                    do {
                        try await Task.sleep(for: .milliseconds(400))
                        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                        c.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "10"), URLQueryItem(name: "language", value: "en")]
                        let response: Response = try await Network.get(c.url!)
                        try Task.checkCancellation()
                        results = (response.results ?? []).map { Place(name: [$0.name, $0.admin1, $0.country].compactMap { $0 }.joined(separator: ", "), latitude: $0.latitude, longitude: $0.longitude) }
                        message = results.isEmpty ? "No matching cities." : "Select a city to load its forecast."
                    } catch is CancellationError { } catch { if !Task.isCancelled { message = "Search unavailable. Try again." } }
                }
        }
    }
}
