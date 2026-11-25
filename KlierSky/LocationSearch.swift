import SwiftUI
import MapKit
struct LocationSearch: View {
    var usingCurrent = false
    var useCurrent: () -> Void = {}
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
                if query.isEmpty {
                    Section {
                        Button { useCurrent(); dismiss() } label: {
                            HStack { Label("Current location", systemImage: "location.fill"); Spacer(); if usingCurrent { Image(systemName: "checkmark").foregroundStyle(Sky.accent) } }
                        }
                    }
                    Section {
                        NavigationLink("Saved locations map") { SavedLocationsMap(usingCurrent: usingCurrent, useCurrent: { useCurrent(); dismiss() }) { select($0); dismiss() } }
                    }
                    if !FavoriteLocations.shared.places.isEmpty {
                        Section("Favorites") {
                            ForEach(FavoriteLocations.shared.places) { place in
                                Button { select(place); dismiss() } label: { Label(place.name, systemImage: "star.fill").foregroundStyle(.primary) }
                                    .contextMenu { Button("Rename") { newName = place.name; renaming = place } }
                            }.onDelete { FavoriteLocations.shared.remove($0) }
                        }
                    }
                }
                Section(query.isEmpty ? "Suggested cities" : "Search results") {
                    ForEach(query.isEmpty ? Place.presets : results) { place in
                        HStack {
                            Button(place.name) { select(place); dismiss() }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                            Button { FavoriteLocations.shared.toggle(place) } label: { Image(systemName: FavoriteLocations.shared.contains(place) ? "star.fill" : "star").frame(width: 44, height: 36) }.buttonStyle(.borderless).accessibilityLabel(FavoriteLocations.shared.contains(place) ? "Remove \(place.name) from favorites" : "Save \(place.name) as favorite")
                        }
                    }
                }
                Section {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Link("Location search by Open-Meteo / GeoNames", destination: URL(string: "https://open-meteo.com/en/docs/geocoding-api")!).font(.caption)
                }
            }.navigationTitle("Locations").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City name")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
                    } catch is CancellationError { } catch { if !Task.isCancelled { message = "Search is unavailable right now. Check the connection and try again." } }
                }
        }
    }
}


struct SavedLocationsMap: View {
    var usingCurrent = false
    var useCurrent: () -> Void = {}
    let select: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var position = MapCameraPosition.automatic
    @State private var selectedID: String?
    private var places: [Place] { FavoriteLocations.shared.places }
    var body: some View {
        Map(position: $position, selection: $selectedID) {
            ForEach(places) { place in
                Marker(place.name, systemImage: "star.fill", coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
                    .tint(Sky.accent).tag(place.id)
            }
        }
        .mapControls { MapCompass(); MapScaleView() }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if let place = places.first(where: { $0.id == selectedID }) {
                    Text(place.name).font(.headline)
                    Button("Show forecast") { select(place); dismiss() }.buttonStyle(.borderedProminent)
                } else {
                    Text(places.isEmpty ? "Save a city with the star in Locations to put it on this map." : "Tap a saved location to see its forecast.")
                        .font(.subheadline)
                }
                Button { useCurrent(); dismiss() } label: {
                    Label("Use current location", systemImage: "location.fill")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.regularMaterial)
        }
        .navigationTitle("Saved locations").navigationBarTitleDisplayMode(.inline)
        .accessibilityLabel("Map of saved weather locations")
    }
}
