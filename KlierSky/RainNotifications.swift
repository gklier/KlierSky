import SwiftUI
import UserNotifications

@MainActor @Observable final class RainNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RainNotifications()
    static let identifier = "kliersky.rain"
    var status = ""
    var pending = ""
    var busy = false
    private var generation = 0
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    var enabled: Bool { defaults.bool(forKey: "rainNotifications") }
    override init() {
        super.init()
        center.delegate = self
    }
    func enable() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            defaults.set(granted, forKey: "rainNotifications")
            if !granted { status = "Allow notifications in iPhone Settings to turn on rain alerts." }
            return granted
        } catch { status = "Notification permission could not be requested."; return false }
    }
    func clear() {
        generation += 1
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier, defaults.string(forKey: "rainRequestID") ?? Self.identifier])
        defaults.removeObject(forKey: "rainPlannedFire")
        defaults.removeObject(forKey: "rainPlannedPlace")
        pending = ""
    }
    func update(forecast: Forecast, hours: [Hour], place: Place, fetchedAt: Date) async {
        generation += 1
        let requestGeneration = generation
        guard enabled else { clear(); return }
        guard Date().timeIntervalSince(fetchedAt) < 1800 else { return }
        let settings = await center.notificationSettings()
        guard requestGeneration == generation else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            clear()
            status = "Rain alerts are blocked in iPhone Settings."
            return
        }
        let now = Date()
        let lead = defaults.object(forKey: "rainAlertLead") as? Int ?? 15
        let chance = defaults.object(forKey: "rainAlertChance") as? Double ?? 50
        let plan = RainNotificationPlan.next(hours: hours, now: now, leadMinutes: [15, 30, 60].contains(lead) ? lead : 15, minimumChance: min(90, max(20, chance)))
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier, defaults.string(forKey: "rainRequestID") ?? Self.identifier])
        // Keep a recently fired warning from being repeated on each refresh.
        let lastFire = defaults.double(forKey: "rainPlannedFire")
        let samePlace = defaults.string(forKey: "rainPlannedPlace") == place.id
        if samePlace, lastFire > 0, lastFire <= now.timeIntervalSince1970, now.timeIntervalSince1970 - lastFire < 3 * 3600 {
            pending = "A rain warning was scheduled recently."
            return
        }
        guard let plan else {
            defaults.removeObject(forKey: "rainPlannedFire")
            pending = "No new precipitation onset above your threshold in the next 12 hours."
            return
        }
        let formatter = DateFormatter()
        formatter.timeZone = forecast.forecastTimeZone
        formatter.timeStyle = .short
        let content = UNMutableNotificationContent()
        content.title = "\(plan.precipitation) possible around \(formatter.string(from: plan.start))"
        content.subtitle = place.name
        content.body = "\(Int(plan.chance.rounded()))% chance in the hourly forecast. \(plan.source). Forecast updated \(formatter.string(from: fetchedAt))."
        content.sound = .default
        content.threadIdentifier = "kliersky-weather"
        content.userInfo = ["latitude": place.latitude, "longitude": place.longitude, "placeName": place.name]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, plan.fire.timeIntervalSinceNow), repeats: false)
        do {
            let identifier = Self.identifier + "." + UUID().uuidString
            defaults.set(identifier, forKey: "rainRequestID")
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            guard requestGeneration == generation else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                return
            }
            defaults.set(plan.fire.timeIntervalSince1970, forKey: "rainPlannedFire")
            defaults.set(place.id, forKey: "rainPlannedPlace")
            pending = "Next warning scheduled for \(formatter.string(from: plan.fire))."
            status = ""
        } catch { status = "The rain alert could not be scheduled." }
    }
    func test() async {
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
                status = "Allow notifications in iPhone Settings to receive the test."
                return
            }
        } catch { status = "Notification permission could not be requested."; return }
        let content = UNMutableNotificationContent()
        content.title = "KlierSky test notification"
        content.body = "Notifications are enabled. This is a test, separate from the weather forecast."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "kliersky.notification-test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
            status = "Test scheduled for five seconds from now."
        } catch { status = "The test notification could not be scheduled." }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let lat = info["latitude"] as? Double, let lon = info["longitude"] as? Double, let name = info["placeName"] as? String {
            Task { @MainActor in
                var url = URLComponents(string: "kliersky://weather")!
                url.queryItems = [URLQueryItem(name: "lat", value: String(lat)), URLQueryItem(name: "lon", value: String(lon)), URLQueryItem(name: "name", value: name)]
                if let address = url.url { await UIApplication.shared.open(address) }
            }
        }
        completionHandler()
    }
}

struct NotificationSettingsView: View {
    let model: WeatherModel
    @AppStorage("rainNotifications") private var enabled = false
    @AppStorage("rainAlertLead") private var lead = 15
    @AppStorage("rainAlertChance") private var chance = 50.0
    @State private var busy = false
    private var service: RainNotifications { .shared }
    var body: some View {
        Form {
            Section {
                Toggle("Rain approaching", isOn: Binding(get: { enabled }, set: { value in
                    if value { Task { busy = true; enabled = await service.enable(); if enabled { await update() }; busy = false } }
                    else { enabled = false; service.clear(); BackgroundCollection.schedule() }
                })).disabled(busy)
                if enabled {
                    Picker("Notify before", selection: $lead) {
                        Text("15 minutes").tag(15); Text("30 minutes").tag(30); Text("1 hour").tag(60)
                    }
                    Picker("Minimum rain chance", selection: $chance) {
                        Text("30%").tag(30.0); Text("50%").tag(50.0); Text("70%").tag(70.0)
                    }
                    LabeledContent("Location", value: model.place.name)
                    if !service.pending.isEmpty { Text(service.pending).font(.footnote) }
                }
            } footer: {
                Text("Warnings use the latest hourly forecast for the location you are viewing. Start times are approximate. Scheduled warnings can arrive while KlierSky is closed. Open the app regularly to keep them current; iOS decides when background forecast updates run.")
            }
            Section {
                Button("Send a test notification") { Task { await service.test() } }
                Button("iPhone notification settings") { if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) } }
                if !service.status.isEmpty { Text(service.status).font(.footnote) }
            }
            Section {
                Text("Official severe-weather alerts remain available in the app. Rain reminders depend on forecasts and iPhone notification settings; use official emergency-alert channels for urgent warnings.").font(.footnote)
            }
        }
        .navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
        .onChange(of: lead) { Task { await update() } }
        .onChange(of: chance) { Task { await update() } }
        .task { if enabled { await update() } }
    }
    private func update() async {
        if let forecast = model.forecast, let updated = model.updated { await service.update(forecast: forecast, hours: model.hours, place: model.place, fetchedAt: updated) }
        BackgroundCollection.schedule()
    }
}
