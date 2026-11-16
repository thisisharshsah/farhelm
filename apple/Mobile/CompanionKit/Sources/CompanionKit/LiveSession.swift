import Foundation
import Observation

/// The live view of the Mac in use: the chat open on it, kept up to date
/// from its feed, and its list of chats. It reconnects by itself, trying
/// every address the Mac can be reached at, then its relay.
@MainActor
@Observable
public final class LiveSession {
    public enum Link: Equatable {
        case idle
        case connecting
        case live(CompanionClient.Route)
        case failed(String)
    }

    public private(set) var link: Link = .idle
    public private(set) var meta: ChatMeta = .empty
    public private(set) var turns: [Turn] = []
    public private(set) var chats: [ChatSummary] = []
    /// The client for the address that answered, while live.
    public private(set) var client: CompanionClient?

    public let store: MacStore
    private var feed: Task<Void, Never>?
    /// The chat list is looked at again now and then: tasks run in chats
    /// other than the open one.
    private var listTicker: Task<Void, Never>?
    private var lastChat = ""
    /// The relay connection being closed by `stop`. Following starts again
    /// only once it is, so the close cannot catch the new connection.
    private var closing: Task<Void, Never>?

    public init(store: MacStore) {
        self.store = store
    }

    public var isLive: Bool {
        if case .live = link { return true }
        return false
    }

    /// Connects to the Mac in use and follows it until stopped.
    public func start() {
        guard feed == nil else { return }
        feed = Task { [weak self] in await self?.follow() }
        listTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.refreshChats()
            }
        }
    }

    public func stop() {
        feed?.cancel()
        feed = nil
        listTicker?.cancel()
        listTicker = nil
        if case .live = link { link = .idle }
        // A relay connection is not kept open while nothing follows it.
        closing = Task { await RelayLinks.shared.stopAll() }
    }

    /// Starts again, for another Mac or after pairing anew.
    public func restart() {
        stop()
        meta = .empty
        turns = []
        chats = []
        projects = []
        client = nil
        lastChat = ""
        start()
    }

    private func follow() async {
        await closing?.value
        var wait: UInt64 = 1
        while !Task.isCancelled {
            guard let mac = store.selected else {
                link = .idle
                return
            }
            if case .live = link {} else { link = .connecting }
            do {
                let (client, info) = try await CompanionClient.connect(to: mac)
                self.client = client
                store.update(mac.id, info: info, workingHost: client.host)
                link = .live(client.route)
                wait = 1
                await refreshChats()
                for try await update in client.updates() {
                    apply(update)
                }
            } catch CompanionError.unpaired {
                link = .failed(CompanionError.unpaired.localizedDescription)
                client = nil
                return
            } catch {
                if Task.isCancelled { return }
                link = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            wait = min(wait * 2, 15)
        }
    }

    private func apply(_ update: FeedUpdate) {
        meta = update.meta
        if update.full {
            let byID = Dictionary(update.changed.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            turns = update.order.compactMap { byID[$0] }
        } else {
            var byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            for turn in update.changed { byID[turn.id] = turn }
            turns = update.order.compactMap { byID[$0] }
        }
        // Another chat was opened (here or on the Mac): its title and the
        // list's order change with it.
        if update.meta.chat != lastChat {
            lastChat = update.meta.chat
            Task { await refreshChats() }
        }
    }

    // MARK: What the user does

    public func refreshChats() async {
        guard let client else { return }
        if let list = try? await client.chats() { chats = list.chats }
        if let list = try? await client.projects() { projects = list }
    }

    /// The Mac's projects, each with its newest chat.
    public private(set) var projects: [ProjectSummary] = []

    public func send(_ text: String, files: [String] = []) async throws {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        try await required().say(words, files: files)
    }

    public func attach(_ data: Data, name: String) async throws -> String {
        try await required().attach(data, name: name)
    }

    /// The engines and models the Mac offers, as last looked up.
    public private(set) var engines: [Engine] = []

    public func refreshEngines() async throws {
        engines = try await required().engines()
    }

    public func choose(engine: String, model: String) async throws {
        try await required().choose(engine: engine, model: model)
        try? await refreshEngines()
    }

    public func lookAtScreen(_ question: String = "") async throws {
        try await required().lookAtScreen(question)
    }

    public func edit(_ turnID: String, to text: String, choice: String = "") async throws {
        try await required().edit(turnID, to: text, choice: choice)
    }

    public func stopWork() async throws {
        try await required().stop()
    }

    public func open(_ chatID: String) async throws {
        guard chatID != meta.chat else { return }
        try await required().open(chatID)
    }

    /// One project's chats, newest first.
    public func projectChats(_ id: String) async throws -> ProjectChats {
        try await required().projectChats(id)
    }

    public func newChat() async throws {
        try await required().newChat()
    }

    public func setAccess(_ access: String) async throws {
        try await required().setAccess(access)
    }

    public func setEffort(_ level: String) async throws {
        try await required().setEffort(level)
    }

    public func queued(_ action: String, _ id: String) async throws {
        try await required().queued(action, id)
    }

    private func required() throws -> CompanionClient {
        guard let client else { throw CompanionError.unreachable(store.selected?.name ?? "the Mac") }
        return client
    }
}
