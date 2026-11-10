import Foundation

// Acceptance checks for automatic device access, client side. The fake service
// below follows the gateway's documented replies; Gateway/test_devices.py
// checks the real server gives those replies.
final class MemoryStore: AccessStore {
    var ownerToken = ""
    var record = AccessRecord()
    var retryAfter: Date?
    var failures = 0
    var lastIssue: AccessIssue?
}
final class FakeService: AccessTransport {
    enum Mode { case open, approval, closed, full, missing, offline, noAddress }
    var mode = Mode.open
    var devices: [String: (install: String, status: String)] = [:]   // token -> record
    var revokedInstalls = Set<String>()
    var enrollCalls = 0, statusCalls = 0
    var dropNextReply = false
    func enroll(installID: String, label: String) async -> EnrollmentResult {
        enrollCalls += 1
        precondition(!label.contains("@"), "label must not carry personal identifiers")
        if mode == .offline { return .unreachable }
        if mode == .noAddress { return .refused(status: 404, code: "no_gateway") }   // what the app's transport reports without an address
        if mode == .missing { return .refused(status: 404, code: "not_found") }
        if revokedInstalls.contains(installID) { return .refused(status: 403, code: "device_revoked") }
        let existing = devices.first { $0.value.install == installID }
        if existing == nil, mode == .closed { return .refused(status: 403, code: "enrollment_closed") }
        if existing == nil, mode == .full { return .refused(status: 403, code: "device_limit_reached") }
        if let existing { devices[existing.key] = nil }
        let token = "ksd_\(enrollCalls)_\(installID.prefix(4))"
        devices[token] = (installID, existing?.value.status ?? (mode == .approval ? "pending" : "active"))
        if dropNextReply { dropNextReply = false; return .unreachable }
        return .enrolled(EnrollmentReply(deviceID: "d\(enrollCalls)", accessToken: token, status: devices[token]!.status, code: "K7Q2"))
    }
    func status(token: String) async -> DeviceStatusResult {
        statusCalls += 1
        if mode == .offline { return .unreachable }
        guard let device = devices[token] else { return .refused(status: 401, code: "gateway_auth_required") }
        if device.status == "revoked" { return .refused(status: 401, code: "device_revoked") }
        return .status(device.status)
    }
    func revoke(_ token: String) { if let device = devices[token] { devices[token] = (device.install, "revoked"); revokedInstalls.insert(device.install) } }
    /// What a weather request with this token would get.
    func weather(_ token: String?) -> (Int, String) {
        guard let token, let device = devices[token] else { return (401, "gateway_auth_required") }
        return device.status == "active" ? (200, "") : device.status == "revoked" ? (401, "device_revoked") : (403, "device_pending")
    }
}

@main struct AccessChecks {
    static func main() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // Fresh install: one enrollment, no user input, read-only device token in use.
        do {
            let store = MemoryStore(), service = FakeService()
            let access = GatewayAccessCore(store: store, transport: service)
            precondition(access.bearer() == nil)
            let fresh = await access.ensure(now: start)
            precondition(fresh == .active && service.enrollCalls == 1)
            precondition(service.weather(access.bearer()).0 == 200)
            let again = await access.ensure(now: start.addingTimeInterval(5))
            precondition(again == .active && service.enrollCalls == 1, "an enrolled device must not enroll again")
            precondition(store.record.installID!.count >= 22 && store.record.installID!.count <= 64)
        }
        // Update from an owner-token build: the saved token keeps working and nothing is enrolled.
        do {
            let store = MemoryStore(), service = FakeService(); store.ownerToken = "legacy-owner-token"
            let access = GatewayAccessCore(store: store, transport: service)
            let state = await access.ensure(now: start)
            precondition(state == .owner)
            precondition(access.bearer() == "legacy-owner-token" && service.enrollCalls == 0 && store.record.device == nil)
        }
        // Reinstall with surviving Keychain: saved credential is reused offline, no new device.
        do {
            let store = MemoryStore(), service = FakeService()
            _ = await GatewayAccessCore(store: store, transport: service).ensure(now: start)
            let token = store.record.device!.token
            store.retryAfter = nil; store.failures = 0; store.lastIssue = nil     // non-secret settings are lost on reinstall
            service.mode = .offline
            let reinstalled = GatewayAccessCore(store: store, transport: service)
            let state = await reinstalled.ensure(now: start.addingTimeInterval(86400))
            precondition(state == .active)
            precondition(reinstalled.bearer() == token && service.enrollCalls == 1)
        }
        // Reinstall without Keychain: enrolls again as a new device, still with no input.
        do {
            let service = FakeService()
            let first = MemoryStore(); _ = await GatewayAccessCore(store: first, transport: service).ensure(now: start)
            let second = MemoryStore(); let access = GatewayAccessCore(store: second, transport: service)
            let state = await access.ensure(now: start.addingTimeInterval(60))
            precondition(state == .active)
            precondition(second.record.installID != first.record.installID && second.record.device!.token != first.record.device!.token)
            precondition(service.devices.count == 2)
        }
        // Lost enrollment reply: the retry reuses the same install ID, so no second slot is consumed.
        do {
            let store = MemoryStore(), service = FakeService(); service.dropNextReply = true
            let access = GatewayAccessCore(store: store, transport: service)
            let lost = await access.ensure(now: start)
            precondition(lost == .unavailable(.offline))
            let firstID = store.record.installID
            let early = await access.ensure(now: start.addingTimeInterval(30))
            precondition(early == .unavailable(.offline) && service.enrollCalls == 1, "must respect backoff")
            let retry = await access.ensure(now: start.addingTimeInterval(61))
            precondition(retry == .active)
            precondition(store.record.installID == firstID && service.devices.count == 1)
        }
        // Revocation: access ends, the fallback is used, and the app does not re-enroll by itself.
        do {
            let store = MemoryStore(), service = FakeService()
            let access = GatewayAccessCore(store: store, transport: service)
            _ = await access.ensure(now: start)
            let token = access.bearer()!
            service.revoke(token)
            let (status, code) = service.weather(token)
            precondition(access.handleRejection(status: status, code: code, token: token))
            precondition(access.bearer() == nil && access.current() == .revoked && store.record.device == nil)
            for hour in 1...48 {
                let state = await access.ensure(now: start.addingTimeInterval(Double(hour) * 3600))
                precondition(state == .revoked)
            }
            precondition(service.enrollCalls == 1, "revoked devices must never auto-enroll")
            // Even if local flags were lost but the install ID survived, the service still refuses it.
            store.record.revoked = false
            let sneaky = await access.ensure(now: start.addingTimeInterval(100 * 3600))
            precondition(sneaky == .revoked && access.bearer() == nil)
            // A deliberate "request access again" is a new install request the owner can see and refuse.
            access.requestAgain()
            precondition(store.record.installID == nil && !store.record.revoked)
        }
        // Rejections for someone else's token, or the owner's token, never change device state.
        do {
            let store = MemoryStore(), service = FakeService()
            let access = GatewayAccessCore(store: store, transport: service)
            _ = await access.ensure(now: start)
            precondition(!access.handleRejection(status: 401, code: "device_revoked", token: "some-other-token"))
            precondition(!access.handleRejection(status: 429, code: "device_quota_exceeded", token: access.bearer()!))
            precondition(access.current() == .active)
        }
        // Device removed (not revoked) on the server: forgets the stale credential, waits, then enrolls once.
        do {
            let store = MemoryStore(), service = FakeService()
            let access = GatewayAccessCore(store: store, transport: service)
            _ = await access.ensure(now: start)
            let token = access.bearer()!
            service.devices[token] = nil
            precondition(access.handleRejection(status: 401, code: "gateway_auth_required", token: token, now: start))
            let soon = await access.ensure(now: start.addingTimeInterval(60))
            precondition(!soon.canFetch && service.enrollCalls == 1, "must not hammer enrollment after a refusal")
            let later = await access.ensure(now: start.addingTimeInterval(901))
            precondition(later == .active && service.enrollCalls == 2)
        }
        // Approval mode: waits without fetching, polls at most once a minute, activates after approval.
        do {
            let store = MemoryStore(), service = FakeService(); service.mode = .approval
            let access = GatewayAccessCore(store: store, transport: service)
            let pending = await access.ensure(now: start)
            precondition(pending == .pending(code: "K7Q2") && access.bearer() == nil)
            _ = await access.ensure(now: start.addingTimeInterval(1))
            _ = await access.ensure(now: start.addingTimeInterval(20))
            precondition(service.statusCalls == 1, "pending status is polled at most once a minute")
            let token = store.record.device!.token
            service.devices[token] = (service.devices[token]!.install, "active")
            let approved = await access.ensure(now: start.addingTimeInterval(62))
            precondition(approved == .active && access.bearer() == token && service.enrollCalls == 1)
        }
        // Current production server (no enrollment endpoint yet), closed and full services: long backoff, clear reason, fallback.
        for (mode, issue) in [(FakeService.Mode.missing, AccessIssue.notOffered), (.closed, .closed), (.full, .full)] {
            let store = MemoryStore(), service = FakeService(); service.mode = mode
            let access = GatewayAccessCore(store: store, transport: service)
            let first = await access.ensure(now: start)
            precondition(first == .unavailable(issue) && access.bearer() == nil)
            for minute in 1...300 { _ = await access.ensure(now: start.addingTimeInterval(Double(minute) * 60)) }
            precondition(service.enrollCalls == 1, "no more than one enrollment attempt per six hours when refused")
            service.mode = .open
            let opened = await access.ensure(now: start.addingTimeInterval(6 * 3600 + 1))
            precondition(opened == .active)
        }
        // Offline: exponential backoff capped at one hour; never a tight loop.
        do {
            let store = MemoryStore(), service = FakeService(); service.mode = .offline
            let access = GatewayAccessCore(store: store, transport: service)
            var now = start
            for _ in 0..<(24 * 60) { _ = await access.ensure(now: now); now = now.addingTimeInterval(60) }
            precondition(service.enrollCalls <= 6 + 24, "offline retries must back off (got \(service.enrollCalls))")
            precondition(service.enrollCalls >= 20, "but keep trying about hourly")
            service.mode = .open
            let back = await access.ensure(now: now.addingTimeInterval(3600))
            precondition(back == .active && store.failures == 0)
        }
        // A build without a service address: says so, never waits six hours, and enrolls as soon as an address exists.
        do {
            let store = MemoryStore(), service = FakeService(); service.mode = .noAddress
            let access = GatewayAccessCore(store: store, transport: service)
            let none = await access.ensure(now: start)
            precondition(none == .unavailable(.noGateway) && access.bearer() == nil && store.retryAfter == nil)
            precondition(access.current() == .unavailable(.noGateway), "the saved reason must be the missing address, not 'offline'")
            service.mode = .open
            let found = await access.ensure(now: start.addingTimeInterval(5))
            precondition(found == .active)
        }
        // Service address discovery from the build configuration. No address is ever a credential.
        do {
            let a = "https://weather.example", b = "https://weather2.example", typed = "https://test.example/base"
            precondition(GatewayAddress.resolve(stored: "", builtIn: a, lastBuiltIn: "") == a, "fresh install uses the built-in address")
            precondition(GatewayAddress.resolve(stored: a, builtIn: b, lastBuiltIn: a) == b, "a newer build's address replaces the older built-in one")
            precondition(GatewayAddress.resolve(stored: typed, builtIn: b, lastBuiltIn: a) == typed, "an address the owner typed is kept")
            precondition(GatewayAddress.resolve(stored: a, builtIn: "", lastBuiltIn: a) == a, "a build without an address does not erase a working one")
            precondition(GatewayAddress.resolve(stored: "", builtIn: "$(KLIERSKY_GATEWAY_URL)", lastBuiltIn: "") == "", "an unexpanded build setting is not an address")
            for bad in ["http://weather.example", "https://user:secret@weather.example", "https://weather.example?token=abc", "https://weather.example#x", "weather.example", ""] {
                precondition(!GatewayAddress.isUsable(bad) && GatewayAddress.resolve(stored: "", builtIn: bad, lastBuiltIn: "") == "", "rejected: \(bad)")
            }
            precondition(GatewayAddress.isUsable(typed))
        }
        print("PASS: fresh install, owner-token update, reinstall with and without saved credential, lost reply, revocation, removal, approval, refused/offline backoff, missing address, address discovery")
    }
}
