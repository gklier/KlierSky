import Foundation

@main struct NotificationChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func hour(_ offset: Double, rain: Double = 0, chance: Double = 0) -> Hour {
            Hour(time: now.addingTimeInterval(offset * 3600), temperature: 60, rain: rain, chance: chance, code: rain > 0 ? 61 : 0, daylight: true, source: "Test fixture only")
        }
        let future = [hour(-0.5), hour(0.5), hour(1.5, rain: 2, chance: 70), hour(2.5, rain: 3, chance: 80)]
        let plan = RainNotificationPlan.next(hours: future, now: now, leadMinutes: 15, minimumChance: 50)
        precondition(plan?.start == future[2].time)
        precondition(plan?.fire == future[2].time.addingTimeInterval(-900))
        precondition(plan?.source == "Test fixture only")
        precondition(RainNotificationPlan.next(hours: [hour(-0.1, rain: 2, chance: 80), hour(0.9, rain: 2, chance: 80)], now: now, leadMinutes: 15, minimumChance: 50) == nil, "ongoing rain must not be described as approaching")
        precondition(RainNotificationPlan.next(hours: [hour(1, rain: 2, chance: 20)], now: now, leadMinutes: 15, minimumChance: 50) == nil)
        precondition(RainNotificationPlan.next(hours: [hour(1, rain: .nan, chance: 90)], now: now, leadMinutes: 15, minimumChance: 50) == nil)
        precondition(RainNotificationPlan.next(hours: [hour(13, rain: 2, chance: 90)], now: now, leadMinutes: 15, minimumChance: 50) == nil)
        let soon = RainNotificationPlan.next(hours: [hour(0.1, rain: 2, chance: 80)], now: now, leadMinutes: 15, minimumChance: 50)
        precondition(soon?.fire == now.addingTimeInterval(5))
        print("PASS: rain notification onset, source, lead time, ongoing rain, threshold, invalid data and horizon")
    }
}
