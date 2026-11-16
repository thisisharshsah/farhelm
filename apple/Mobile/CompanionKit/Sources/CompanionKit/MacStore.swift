import Foundation
import Observation
import Security

/// The Macs this device has paired with. Names and addresses are kept in
/// the app's defaults; each pairing code, and each relay key, is kept in
/// the Keychain.
@MainActor
@Observable
public final class MacStore {
    public private(set) var macs: [PairedMac] = []
    /// The Mac in use.
    public var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: Self.selectedKey) }
    }

    private static let listKey = "pairedMacs"
    private static let selectedKey = "selectedMac"
    private static let service = "app.companion.pairing"

    public init() {
        load()
    }

    public var selected: PairedMac? {
        macs.first { $0.id == selectedID } ?? macs.first
    }

    /// Adds a Mac, or brings one already paired up to date (a new code,
    /// new addresses). It becomes the Mac in use.
    public func add(_ mac: PairedMac) {
        if let index = macs.firstIndex(where: { $0.id == mac.id }) {
            var kept = mac
            kept.lastHost = macs[index].lastHost
            macs[index] = kept
        } else {
            macs.append(mac)
        }
        selectedID = mac.id
        save()
    }

    public func remove(_ id: String) {
        macs.removeAll { $0.id == id }
        Self.keychainDelete(account: id)
        Self.keychainDelete(account: Self.keyAccount(id))
        if selectedID == id { selectedID = macs.first?.id }
        save()
    }

    /// The address that worked, and anything new the Mac said about itself.
    public func update(_ id: String, info: MacInfo? = nil, workingHost: String? = nil) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        var mac = macs[index]
        if let info {
            mac.name = info.name
            mac.port = info.port
            // Its own addresses first; one found on the network that it did
            // not list is kept at the end.
            mac.hosts = info.hosts + mac.hosts.filter { !info.hosts.contains($0) }
            // Its relay moved, or was turned off. The key stays: only a new
            // pairing changes it.
            if let relay = info.relay { mac.relay = relay.isEmpty ? nil : relay }
        }
        if let workingHost { mac.lastHost = workingHost }
        guard mac != macs[index] else { return }
        macs[index] = mac
        save()
    }

    /// An address found on the local network for a paired Mac.
    public func found(_ id: String, host: String) {
        guard let index = macs.firstIndex(where: { $0.id == id }), !macs[index].hosts.contains(host) else { return }
        macs[index].hosts.append(host)
        save()
    }

    /// Replaces the whole list (the Watch takes it from the phone).
    public func replace(with macs: [PairedMac], selected: String?) {
        self.macs = macs
        selectedID = selected ?? macs.first?.id
        save()
    }

    // MARK: Storage

    private struct Stored: Codable {
        var id: String
        var name: String
        var port: Int
        var hosts: [String]
        var lastHost: String?
        var relay: String?
    }

    private func load() {
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey)
        guard let data = UserDefaults.standard.data(forKey: Self.listKey),
              let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return }
        macs = stored.compactMap { item in
            guard let token = Self.keychainRead(account: item.id) else { return nil }
            return PairedMac(id: item.id, name: item.name, port: item.port, hosts: item.hosts,
                             token: token, lastHost: item.lastHost,
                             relay: item.relay, key: Self.keychainRead(account: Self.keyAccount(item.id)))
        }
    }

    private func save() {
        let stored = macs.map { Stored(id: $0.id, name: $0.name, port: $0.port, hosts: $0.hosts,
                                       lastHost: $0.lastHost, relay: $0.relay) }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
        for mac in macs {
            Self.keychainWrite(mac.token, account: mac.id)
            if let key = mac.key {
                Self.keychainWrite(key, account: Self.keyAccount(mac.id))
            } else {
                Self.keychainDelete(account: Self.keyAccount(mac.id))
            }
        }
    }

    /// Where a Mac's relay key is kept: beside its pairing code.
    private static func keyAccount(_ id: String) -> String { id + ".link" }

    // MARK: Keychain

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainRead(account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(_ value: String, account: String) {
        let data = Data(value.utf8)
        let q = query(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(q as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = q
            add.merge(attributes) { $1 }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func keychainDelete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
