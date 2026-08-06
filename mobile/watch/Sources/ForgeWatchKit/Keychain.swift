import Foundation
import Security

/// Where the watch keeps its pairing.
///
/// The Keychain, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
///
/// - **AfterFirstUnlock** rather than `WhenUnlocked`, because the whole point of
///   this app is reacting to a notification, and a wrist is often not "unlocked"
///   in the sense the stricter class means.
/// - **ThisDeviceOnly** so the secret is excluded from encrypted backups and
///   never syncs to iCloud. A device key that follows a restore to new hardware
///   would make "unpair that watch" a lie.
public struct PairingStore: Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "dev.relayforge.watch",
        account: String = "forge-device-identity"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> Pairing? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let pairing = try? JSONDecoder().decode(Pairing.self, from: data)
        else { return nil }
        return pairing
    }

    @discardableResult
    public func save(_ pairing: Pairing) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }

        // Replace rather than update-or-add: one pairing per watch, and a stale
        // half-written one is worse than none.
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public func forget() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
