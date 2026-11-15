import Foundation

/// What the Watch and the phone say to each other. The Watch reaches the
/// Mac through the phone, which wakes for it even in the background.
public enum WatchRelay {
    /// Watch to phone: what it asks for. Values are in `Key`.
    public enum Ask: String, Sendable {
        case state, say, stop
    }

    public enum Key {
        public static let ask = "ask"
        public static let text = "text"
        /// Phone to Watch, in each reply: the summary, as JSON.
        public static let summary = "summary"
        public static let error = "error"
        /// Phone to Watch, in the application context: the paired Macs.
        public static let macs = "macs"
    }

    /// All the Watch shows: small enough for one message.
    public struct Summary: Codable, Sendable, Equatable {
        public var mac: String
        public var title: String
        public var busy: Bool
        public var status: String
        public var plan: [PlanItem]
        public var lastAsk: String
        public var lastReply: String
        public var question: String?
        public var options: [String]
        public var awaitingApproval: Bool

        public init(meta: ChatMeta, turns: [Turn]) {
            mac = meta.mac
            title = meta.title
            busy = meta.busy
            status = meta.agentRunning ? (meta.agentStatus.isEmpty ? "Working" : meta.agentStatus)
                : (meta.replying ? "Writing a reply" : "Ready")
            let last = turns.last
            plan = last?.plan ?? []
            lastAsk = String((last?.me ?? "").prefix(200))
            lastReply = String((last?.reply ?? "").suffix(600))
            question = meta.question
            options = meta.options ?? []
            awaitingApproval = meta.awaitingApproval
        }
    }
}
