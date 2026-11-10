import SwiftUI
@main struct KlierSkyApp: App {
    @AppStorage("appearance") private var appearance = "system"
    init() {
        // The service address is discovered from the build configuration (KLIERSKY_GATEWAY_URL), never typed by family
        // members and never a credential. A newer build's address replaces an older built-in one automatically.
        let defaults = UserDefaults.standard
        let builtIn = (Bundle.main.object(forInfoDictionaryKey: "KlierSkyGatewayURL") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = defaults.string(forKey: "gatewayURL") ?? ""
        let resolved = GatewayAddress.resolve(stored: stored, builtIn: builtIn, lastBuiltIn: defaults.string(forKey: "gatewayBuiltIn") ?? "")
        if resolved != stored {
            defaults.set(resolved, forKey: "gatewayURL")
            defaults.removeObject(forKey: "accessRetryAfter")   // a new address is worth trying straight away
        }
        if GatewayAddress.isUsable(builtIn) { defaults.set(builtIn, forKey: "gatewayBuiltIn") }
    }
    var body: some Scene {
        WindowGroup { ContentView().preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil) }
            .backgroundTask(.appRefresh(BackgroundCollection.identifier)) { await BackgroundCollection.run() }
    }
}
