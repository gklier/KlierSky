import SwiftUI
import MapLibre
@main struct KlierSkyApp: App {
    @AppStorage("appearance") private var appearance = "system"
    init() {
        // The service address is discovered from the build configuration (KLIERSKY_GATEWAY_URL), never typed by family
        // members and never a credential. A newer build's address replaces an older built-in one automatically.
        _ = RainNotifications.shared
        MapCache.configure()
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
        WindowGroup { ContentView().background(AppearanceBridge(appearance: appearance).frame(width: 0, height: 0)) }
            .backgroundTask(.appRefresh(BackgroundCollection.identifier)) { await BackgroundCollection.run() }
    }
}

/// Apply the app preference to the scene window, including already-presented sheets.
/// Keeping one source of truth avoids competing presentation color-scheme preferences.
struct AppearanceBridge: UIViewRepresentable {
    let appearance: String
    final class Host: UIView {
        var style: UIUserInterfaceStyle = .unspecified
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.overrideUserInterfaceStyle = style
        }
    }
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        view.style = appearance == "dark" ? .dark : appearance == "light" ? .light : .unspecified
        if view.window?.overrideUserInterfaceStyle != view.style {
            view.window?.overrideUserInterfaceStyle = view.style
        }
    }
}

enum MapCache {
    static func configure() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024, diskPath: "KlierSkyMapHTTP")
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.httpMaximumConnectionsPerHost = 4
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(256 * 1024 * 1024) { error in
            if error != nil { Task { @MainActor in Diagnostics.shared.add("map", "Map cache size could not be updated") } }
        }
    }
}
