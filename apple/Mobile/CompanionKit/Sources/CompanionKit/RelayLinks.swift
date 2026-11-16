import CompanionLink
import Foundation

/// The relay connections this device keeps: at most one per paired Mac,
/// opened only when the Mac cannot be reached directly, and closed when
/// the app stops following it.
actor RelayLinks {
    static let shared = RelayLinks()

    private var endpoints: [String: LinkEndpoint] = [:]

    /// The connection for `mac`, started; nil when its pairing has no relay.
    func endpoint(for mac: PairedMac) async -> LinkEndpoint? {
        guard let relay = mac.relay.flatMap({ RelayAddress.url(from: $0) }),
              let key = mac.key.flatMap({ LinkKey(text: $0) }) else { return nil }
        let name = mac.id + "|" + key.channel + "|" + relay.absoluteString
        if let kept = endpoints[name] {
            await kept.start()
            return kept
        }
        // The same Mac with an older pairing or relay: that connection goes.
        for old in endpoints.keys where old.hasPrefix(mac.id + "|") {
            await endpoints.removeValue(forKey: old)?.stop()
        }
        let endpoint = LinkEndpoint(relay: relay, key: key, role: .device(DeviceIdentity.id))
        endpoints[name] = endpoint
        await endpoint.start()
        return endpoint
    }

    /// Closes every connection (the app is going to the background, or a
    /// Mac answered directly).
    func stopAll() async {
        let all = Array(endpoints.values)
        endpoints = [:]
        for endpoint in all { await endpoint.stop() }
    }
}

/// This install's lasting id on the relay link, so the Mac can tell its
/// devices apart (answers go to the device that asked). Not a secret.
enum DeviceIdentity {
    static var id: String {
        let key = "companionDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
