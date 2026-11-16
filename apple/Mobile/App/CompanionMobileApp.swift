import CompanionKit
import SwiftUI

/// Companion on iPhone and iPad: follow the chats on your Mac, write to
/// them, answer the agent and stop it, on the same Wi-Fi or from anywhere
/// through your relay.
@main
struct CompanionMobileApp: App {
    @State private var store: MacStore
    @State private var session: LiveSession
    @State private var discovery = Discovery()
    @State private var watch: WatchBridge
    @Environment(\.scenePhase) private var phase

    init() {
        let store = MacStore()
        let session = LiveSession(store: store)
        _store = State(initialValue: store)
        _session = State(initialValue: session)
        _watch = State(initialValue: WatchBridge(store: store, session: session))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(session)
                .environment(discovery)
                .onOpenURL(perform: pair)
                .onAppear {
                    watch.activate()
                    // A paired Mac found on this network: its address is
                    // learned, so it is reached even if its name changes.
                    discovery.onAddress = { id, host in store.found(id, host: host) }
                    discovery.start()
                    session.start()
                }
                .onChange(of: phase) { _, phase in
                    switch phase {
                    case .active:
                        discovery.start()
                        session.start()
                    case .background:
                        session.stop()
                        discovery.stop()
                    default:
                        break
                    }
                }
                .onChange(of: store.macs) { _, _ in watch.sendMacs() }
        }
    }

    /// A `companion://pair` link, from the Camera app or the scanner.
    private func pair(_ url: URL) {
        guard let mac = PairingLink.parse(url.absoluteString) else { return }
        store.add(mac)
        session.restart()
    }
}
