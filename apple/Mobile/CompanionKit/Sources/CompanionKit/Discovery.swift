import Foundation
import Network
import Observation

/// Macs running Companion on this network, found by Bonjour. Each comes
/// with its id (to match a paired Mac) and, once looked up, its address.
@MainActor
@Observable
public final class Discovery {
    public struct Found: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var host: String?
    }

    public private(set) var found: [Found] = []
    /// Called with each address looked up, by Mac id.
    public var onAddress: ((String, String) -> Void)?

    private var browser: NWBrowser?
    private var lookups: [String: NWConnection] = [:]

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_companion._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for connection in lookups.values { connection.cancel() }
        lookups = [:]
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var list: [Found] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var id = name
            if case let .bonjour(txt) = result.metadata, let value = txt["id"] { id = value }
            let known = found.first { $0.id == id }?.host
            list.append(Found(id: id, name: name, host: known))
            if known == nil { lookUp(result.endpoint, id: id) }
        }
        found = list.sorted { $0.name < $1.name }
    }

    /// Bonjour gives a name; a short connection gives the address.
    private func lookUp(_ endpoint: NWEndpoint, id: String) {
        guard lookups[id] == nil else { return }
        // IPv4, so the address goes into a link as it is.
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        lookups[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint,
                       let address = Self.text(host) {
                        if let index = self.found.firstIndex(where: { $0.id == id }) {
                            self.found[index].host = address
                        }
                        self.onAddress?(id, address)
                    }
                    connection.cancel()
                    self.lookups[id] = nil
                case .failed, .cancelled:
                    self.lookups[id] = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private static func text(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first
        case .name(let name, _):
            return name
        default:
            return nil
        }
    }
}
