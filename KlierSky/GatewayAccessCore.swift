import Foundation

// Automatic, least-privilege access to the owner's weather service.
//
// A new install asks the service for its own read-only device credential. No
// shared owner token, vendor key or other static secret ships in the app, and
// nobody types anything. The owner can revoke any device on the server.
// This file is UI-free so the same logic runs in the portable checks.

struct DeviceCredential: Codable, Equatable {
    var deviceID: String
    var token: String
    var status: String      // "active" or "pending"
    var code: String        // short code the owner can match when approving
}
struct AccessRecord: Codable, Equatable {
    var installID: String? = nil        // random per install; lets a lost reply be retried without using a second slot
    var device: DeviceCredential? = nil
    var revoked = false                 // owner removed this device; never re-enrolls by itself
}
enum AccessIssue: String, Codable, Equatable {
    case notOffered     // service has no device enrollment yet (older server version)
    case closed         // owner is not accepting new devices
    case full           // device limit reached
    case busy           // rate limited or temporarily refused
    case offline        // could not reach the service
    case noGateway      // no usable service address
}
enum AccessState: Equatable {
    case owner                      // administrative token saved on the owner's own phone
    case active                     // read-only device access
    case pending(code: String)      // enrolled; waiting for the owner to approve
    case revoked
    case unavailable(AccessIssue)
    var canFetch: Bool { self == .owner || self == .active }
}
struct EnrollmentReply: Decodable { let deviceID: String; let accessToken: String; let status: String; let code: String }
enum EnrollmentResult { case enrolled(EnrollmentReply); case refused(status: Int, code: String); case unreachable }
enum DeviceStatusResult { case status(String); case refused(status: Int, code: String); case unreachable }

protocol AccessTransport {
    func enroll(installID: String, label: String) async -> EnrollmentResult
    func status(token: String) async -> DeviceStatusResult
}
protocol AccessStore: AnyObject {
    var ownerToken: String { get }
    var record: AccessRecord { get set }         // Keychain in the app
    var retryAfter: Date? { get set }            // not secret
    var failures: Int { get set }
    var lastIssue: AccessIssue? { get set }
}

/// Where the weather service lives. The address comes from the build
/// configuration (never a credential); the owner may override it while testing.
enum GatewayAddress {
    /// Accepts only a plain HTTPS origin or path: no credentials, query or fragment.
    static func isUsable(_ text: String) -> Bool {
        guard let c = URLComponents(string: text), c.scheme == "https", let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return false }
        return true
    }
    /// Decides the address to store at launch.
    /// - `stored`: the address in use so far. `builtIn`: this build's configured address.
    /// - `lastBuiltIn`: the built-in address the previous launch saw.
    /// A stored address that merely copied an older built-in one follows the new build;
    /// an address the owner typed by hand is kept.
    static func resolve(stored: String, builtIn: String, lastBuiltIn: String) -> String {
        let builtIn = isUsable(builtIn) ? builtIn : ""
        if stored.isEmpty || stored == lastBuiltIn { return builtIn.isEmpty ? stored : builtIn }
        return stored
    }
}

struct GatewayAccessCore {
    let store: AccessStore
    let transport: AccessTransport
    var label = "iPhone"
    var newInstallID: () -> String = GatewayAccessCore.randomInstallID

    static func randomInstallID() -> String {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<43).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }

    /// State from saved data only. Never touches the network.
    func current(now: Date = Date()) -> AccessState {
        if !store.ownerToken.isEmpty { return .owner }
        let record = store.record
        if record.revoked { return .revoked }
        if let device = record.device { return device.status == "active" ? .active : .pending(code: device.code) }
        return .unavailable(store.lastIssue ?? .offline)
    }

    /// Bearer for weather requests, or nil when this install has no usable access.
    func bearer() -> String? {
        if !store.ownerToken.isEmpty { return store.ownerToken }
        guard let device = store.record.device, device.status == "active", !store.record.revoked else { return nil }
        return device.token
    }

    /// Make sure this install has access, enrolling when needed. Bounded: one
    /// network attempt per call, with backoff persisted between calls.
    func ensure(now: Date = Date()) async -> AccessState {
        if !store.ownerToken.isEmpty { return .owner }
        var record = store.record
        if record.revoked { return .revoked }
        if var device = record.device {
            if device.status == "active" { return .active }
            if let retry = store.retryAfter, retry > now { return .pending(code: device.code) }
            switch await transport.status(token: device.token) {
            case .status(let value) where value == "active":
                device.status = "active"; record.device = device; store.record = record; store.retryAfter = nil
                return .active
            case .refused(401, "device_revoked"):
                store.record = AccessRecord(installID: record.installID, device: nil, revoked: true)
                return .revoked
            case .refused(401, _):
                // The service no longer knows this device (removed or expired). Start over below.
                record = AccessRecord(); store.record = record
            default:
                store.retryAfter = now.addingTimeInterval(60)
                return .pending(code: device.code)
            }
        }
        if let retry = store.retryAfter, retry > now { return .unavailable(store.lastIssue ?? .offline) }
        if record.installID == nil { record.installID = newInstallID(); store.record = record }
        func backOff(_ issue: AccessIssue, _ seconds: TimeInterval) -> AccessState {
            store.lastIssue = issue; store.retryAfter = now.addingTimeInterval(seconds); return .unavailable(issue)
        }
        switch await transport.enroll(installID: record.installID!, label: label) {
        case .enrolled(let reply):
            record.device = DeviceCredential(deviceID: reply.deviceID, token: reply.accessToken, status: reply.status == "active" ? "active" : "pending", code: reply.code)
            store.record = record; store.failures = 0; store.retryAfter = nil; store.lastIssue = nil
            return reply.status == "active" ? .active : .pending(code: reply.code)
        case .refused(403, "device_revoked"):
            store.record = AccessRecord(installID: record.installID, device: nil, revoked: true)
            return .revoked
        case .refused(403, "enrollment_closed"): return backOff(.closed, 6 * 3600)
        case .refused(403, "device_limit_reached"): return backOff(.full, 6 * 3600)
        case .refused(_, "no_gateway"):
            // This build has no service address. Nothing was contacted, so there is nothing to back off from.
            store.lastIssue = .noGateway; return .unavailable(.noGateway)
        case .refused(404, _), .refused(405, _), .refused(501, _): return backOff(.notOffered, 6 * 3600)
        case .refused: return backOff(.busy, 3600)
        case .unreachable:
            store.failures = min(store.failures + 1, 10)
            return backOff(.offline, min(3600, 60 * pow(2, Double(store.failures - 1))))
        }
    }

    /// A weather request made with `token` was refused. Returns true when access changed.
    @discardableResult func handleRejection(status: Int, code: String, token: String, now: Date = Date()) -> Bool {
        var record = store.record
        guard let device = record.device, device.token == token, token != store.ownerToken else { return false }
        if status == 401, code == "device_revoked" {
            store.record = AccessRecord(installID: record.installID, device: nil, revoked: true); return true
        }
        if status == 401 {
            // Unknown to the service: forget it and allow one fresh enrollment later, not a tight loop.
            store.record = AccessRecord(); store.lastIssue = .busy; store.retryAfter = now.addingTimeInterval(900); return true
        }
        if status == 403, code == "device_pending" {
            record.device?.status = "pending"; store.record = record; return true
        }
        return false
    }

    /// Deliberate user action after revocation or disconnect: ask again as a new install.
    func requestAgain() {
        store.record = AccessRecord(); store.retryAfter = nil; store.failures = 0; store.lastIssue = nil
    }
}
