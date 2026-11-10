import SwiftUI
@main struct KlierSkyApp: App {
    @AppStorage("appearance") private var appearance = "system"
    init() {
        let storedAddress = UserDefaults.standard.string(forKey: "gatewayURL") ?? ""
        if storedAddress.isEmpty,
           let address = Bundle.main.object(forInfoDictionaryKey: "KlierSkyGatewayURL") as? String { UserDefaults.standard.set(address, forKey: "gatewayURL") }
    }
    var body: some Scene { WindowGroup { ContentView().preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil) } }
}
