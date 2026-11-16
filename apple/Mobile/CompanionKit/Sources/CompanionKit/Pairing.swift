import CompanionLink
import Foundation

/// The link Companion on the Mac shows as a QR code in Settings > Remote:
/// `companion://pair?v=1&id=…&name=…&port=…&hosts=a,b,c&token=…`, and, when
/// the Mac can be reached away from its network, `&relay=…&key=…`.
public enum PairingLink {
    /// The Mac it describes, or nil when it is not a Companion pairing link.
    public static func parse(_ text: String) -> PairedMac? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "companion", parts.host == "pair" else { return nil }
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] { values[item.name] = item.value }
        guard let id = values["id"], !id.isEmpty,
              let token = values["token"], !token.isEmpty,
              let port = values["port"].flatMap(Int.init), (1...65_535).contains(port) else { return nil }
        let hosts = (values["hosts"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // A relay counts only with a key that is one, and the other way round.
        let relay = values["relay"].flatMap { RelayAddress.url(from: $0) }?.absoluteString
        let key = values["key"].flatMap { LinkKey(text: $0) }?.text
        let away = relay != nil && key != nil
        // Somewhere to reach it: on the network, or through the relay.
        guard !hosts.isEmpty || away else { return nil }
        return PairedMac(id: id, name: values["name"] ?? "Mac", port: port, hosts: hosts, token: token,
                         relay: away ? relay : nil, key: away ? key : nil)
    }
}
