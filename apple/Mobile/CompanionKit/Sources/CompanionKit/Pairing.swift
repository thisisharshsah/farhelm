import Foundation

/// The link Companion on the Mac shows as a QR code in Settings > Remote:
/// `companion://pair?v=1&id=…&name=…&port=…&hosts=a,b,c&token=…`.
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
        guard !hosts.isEmpty else { return nil }
        return PairedMac(id: id, name: values["name"] ?? "Mac", port: port, hosts: hosts, token: token)
    }
}
