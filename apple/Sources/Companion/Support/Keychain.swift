import Foundation
import Security

enum Keychain {
    private static let service = "com.harshsah.companion"

    // Asking the keychain is a round trip to another process, and the
    // interface asks on every redraw (is a model set up?). What was read is
    // kept, so only the first ask of each key pays for it.
    private static let lock = NSLock()
    private static var known: [String: String?] = [:]

    static func read(_ account: String) -> String? {
        lock.lock()
        if let hit = known[account] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let value = fetch(account)
        lock.lock()
        known[account] = .some(value)
        lock.unlock()
        return value
    }

    private static func fetch(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        lock.lock()
        known[account] = .some(value.isEmpty ? nil : value)
        lock.unlock()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        if SecItemCopyMatching(base as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
