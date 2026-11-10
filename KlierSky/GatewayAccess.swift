import Foundation
import SwiftUI
import UIKit

/// Keychain-backed storage for the access state machine in GatewayAccessCore.
final class KeychainAccessStore: AccessStore {
    private let defaults = UserDefaults.standard
    var ownerToken: String { SecureStore.read() }
    var record: AccessRecord {
        get { Data(SecureStore.read(account: "device-access").utf8).isEmpty ? AccessRecord() : ((try? JSONDecoder().decode(AccessRecord.self, from: Data(SecureStore.read(account: "device-access").utf8))) ?? AccessRecord()) }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            // Read-only device token: usable after first unlock so background refresh can work. Never synced or backed up.
            try? SecureStore.save(String(decoding: data, as: UTF8.self), account: "device-access", afterFirstUnlock: true)
        }
    }
    var retryAfter: Date? {
        get { defaults.object(forKey: "accessRetryAfter") as? Date }
        set { defaults.set(newValue, forKey: "accessRetryAfter") }
    }
    var failures: Int {
        get { defaults.integer(forKey: "accessFailures") }
        set { defaults.set(newValue, forKey: "accessFailures") }
    }
    var lastIssue: AccessIssue? {
        get { defaults.string(forKey: "accessIssue").flatMap(AccessIssue.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: "accessIssue") }
    }
}

struct GatewayTransport: AccessTransport {
    func enroll(installID: String, label: String) async -> EnrollmentResult {
        guard let url = try? Gateway.url("v1/devices") else { return .refused(status: 404, code: "no_gateway") }
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Network.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONEncoder().encode(["installID": installID, "label": label])
        guard let (data, response) = try? await URLSession.shared.data(for: request), let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        if status == 201 || status == 200, let reply = try? JSONDecoder().decode(EnrollmentReply.self, from: data) { return .enrolled(reply) }
        if status == 201 || status == 200 { return .unreachable }
        return .refused(status: status, code: HTTPFailure.code(in: data))
    }
    func status(token: String) async -> DeviceStatusResult {
        struct Reply: Decodable { let status: String }
        guard let url = try? Gateway.url("v1/devices/self") else { return .unreachable }
        do { let reply: Reply = try await Network.get(url, bearer: token, timeout: 15); return .status(reply.status) }
        catch let failure as HTTPFailure { return .refused(status: failure.status, code: failure.code) }
        catch { return .unreachable }
    }
}

/// App-facing view of this install's access to the owner's weather service.
@MainActor @Observable final class GatewayAccess {
    static let shared = GatewayAccess()
    private(set) var state: AccessState
    private let core: GatewayAccessCore
    init() {
        // Generic model name and app version only: no device name, no advertising or vendor identifier.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        core = GatewayAccessCore(store: KeychainAccessStore(), transport: GatewayTransport(), label: "\(UIDevice.current.model) \(version)")
        state = core.current()
    }
    var bearer: String? { core.bearer() }
    var isOwner: Bool { state == .owner }
    @discardableResult func ensure() async -> AccessState {
        let before = state
        state = await core.ensure()
        if state != before { Diagnostics.shared.add("access", Self.log(state)) }
        return state
    }
    func rejected(_ failure: HTTPFailure, token: String) {
        if core.handleRejection(status: failure.status, code: failure.code, token: token) { state = core.current(); Diagnostics.shared.add("access", Self.log(state)) }
    }
    func requestAgain() async { core.requestAgain(); await ensure() }
    func reload() { state = core.current() }

    /// Short, plain status for Settings.
    var title: String {
        switch state {
        case .owner: return "Connected · owner"
        case .active: return "Connected"
        case .pending: return "Waiting for approval"
        case .revoked: return "Access removed"
        case .unavailable(let issue): return issue == .offline ? "Not reachable" : "Not connected"
        }
    }
    var detail: String {
        switch state {
        case .owner: return "This iPhone holds the owner's administrative access. Forecasts come from Foreca through your weather service."
        case .active: return "This iPhone has its own read-only access. Forecasts come from Foreca through the KlierSky weather service. Nothing to set up."
        case .pending(let code): return "This iPhone asked for access automatically. The owner needs to approve it; the code to match is \(code). Until then forecasts come from Open-Meteo."
        case .revoked: return "The owner removed this iPhone's access. Forecasts come from Open-Meteo. You can ask again."
        case .unavailable(.notOffered): return "The weather service does not offer automatic device access yet. Forecasts come from Open-Meteo. The app will check again later."
        case .unavailable(.closed): return "The weather service is not accepting new devices right now. Forecasts come from Open-Meteo. The app will check again later."
        case .unavailable(.full): return "The weather service has reached its device limit. Forecasts come from Open-Meteo. The app will check again later."
        case .unavailable(.busy): return "The weather service asked this iPhone to wait. Forecasts come from Open-Meteo meanwhile."
        case .unavailable(.noGateway): return "No weather service address is set. Forecasts come from Open-Meteo."
        case .unavailable(.offline): return "The weather service could not be reached. Forecasts come from Open-Meteo. The app retries automatically."
        }
    }
    private static func log(_ state: AccessState) -> String {
        switch state {
        case .owner: return "Service access: owner token"
        case .active: return "Service access: device active"
        case .pending: return "Service access: waiting for approval"
        case .revoked: return "Service access: revoked"
        case .unavailable(let issue): return "Service access unavailable: \(issue.rawValue)"
        }
    }
}
