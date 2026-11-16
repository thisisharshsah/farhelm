import Foundation

/// A Mac running Companion that this device has paired with.
public struct PairedMac: Codable, Hashable, Identifiable, Sendable {
    /// The Mac's lasting id (it does not change with its name or address).
    public var id: String
    public var name: String
    public var port: Int
    /// Where it may be reached, best first: its .local name, its Wi-Fi
    /// address, its Tailscale address. Kept up to date from the Mac.
    public var hosts: [String]
    /// The pairing code. Kept in the Keychain, never in the plain store.
    public var token: String
    /// The address that worked last, tried first next time.
    public var lastHost: String?
    /// The relay the Mac is reached through away from its network, when it
    /// has one turned on ("wss://…").
    public var relay: String?
    /// The pairing's key for the relay: what seals everything that goes
    /// through it. Kept in the Keychain, never in the plain store.
    public var key: String?

    public init(id: String, name: String, port: Int, hosts: [String], token: String, lastHost: String? = nil,
                relay: String? = nil, key: String? = nil) {
        self.id = id
        self.name = name
        self.port = port
        self.hosts = hosts
        self.token = token
        self.lastHost = lastHost
        self.relay = relay
        self.key = key
    }

    /// Whether it can be reached through a relay when not directly.
    public var reachableAway: Bool {
        guard let relay, let key else { return false }
        return !relay.isEmpty && !key.isEmpty
    }

    /// Addresses in the order to try them: the one that worked last first.
    public var hostsToTry: [String] {
        guard let lastHost else { return hosts }
        return [lastHost] + hosts.filter { $0 != lastHost }
    }
}

/// One chat in the Mac's list.
public struct ChatSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var date: Date
    public var turns: Int
    /// A task is running in it on the Mac, and whether it waits on you.
    public var running: Bool?
    public var waiting: Bool?
}

/// One project in the Mac's sidebar, with its newest chat (none when the
/// project has no chats yet).
public struct ProjectSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The project's folder on the Mac, nil when none is set (or an older Mac).
    public var folder: String?
    public var chatID: String?
    public var chatTitle: String?
    public var chats: Int?
    /// The newest chat's last activity, or when the project was added.
    public var updatedAt: Date
}

/// The Mac's projects (`/projects`).
public struct ProjectList: Codable, Sendable {
    public var projects: [ProjectSummary]
}

/// One project's chats, newest first (`/project/chats`).
public struct ProjectChats: Codable, Sendable {
    public var id: String
    public var name: String
    /// The project's folder on the Mac, nil when none is set.
    public var folder: String?
    public var chats: [ChatSummary]
}

/// One thing the agent did.
public struct WorkStep: Codable, Hashable, Sendable {
    public var kind: String
    public var title: String
    public var failed: Bool
    /// What it was for, and the end of what it printed ("" when none).
    public var why: String?
    public var output: String?
}

/// One item of the agent's plan.
public struct PlanItem: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case todo, doing, done }
    public var text: String
    public var state: State

    public init(text: String, state: State) {
        self.text = text
        self.state = state
    }
}

/// One exchange: what was asked and the answer, with the work it took.
public struct Turn: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var me: String
    public var reply: String
    public var model: String
    public var error: String
    public var image: Bool
    public var streaming: Bool
    public var working: Bool
    public var date: Date?
    public var steps: [WorkStep]
    public var plan: [PlanItem]
    /// What the user may want next, offered once the task is done.
    public var suggestions: [String]
    /// Files changed since this message: editing it offers to fork the
    /// chat, put the files back, or both.
    public var canRewind: Bool

    enum CodingKeys: String, CodingKey {
        case id, me, reply, model, error, image, streaming, working, date, steps, plan, suggestions, canRewind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        me = try c.decodeIfPresent(String.self, forKey: .me) ?? ""
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        image = try c.decodeIfPresent(Bool.self, forKey: .image) ?? false
        streaming = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
        working = try c.decodeIfPresent(Bool.self, forKey: .working) ?? false
        date = try c.decodeIfPresent(Double.self, forKey: .date).map { Date(timeIntervalSince1970: $0) }
        steps = try c.decodeIfPresent([WorkStep].self, forKey: .steps) ?? []
        plan = try c.decodeIfPresent([PlanItem].self, forKey: .plan) ?? []
        suggestions = try c.decodeIfPresent([String].self, forKey: .suggestions) ?? []
        canRewind = try c.decodeIfPresent(Bool.self, forKey: .canRewind) ?? false
    }
}

/// A message sent while the agent works, waiting for it.
public struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var text: String
    /// Cancelled: it stays in the chat struck through, and is not sent.
    public var void: Bool
}

/// The open chat's state on the Mac.
public struct ChatMeta: Codable, Hashable, Sendable {
    public var chat: String
    public var title: String
    public var status: String
    public var agentRunning: Bool
    public var agentStatus: String
    public var replying: Bool
    public var mac: String
    /// The agent's question, waiting for an answer, with its choices.
    public var question: String?
    public var options: [String]?
    /// The agent waits for an approval, which is given on the Mac.
    public var awaitingApproval: Bool
    /// The chat box's controls: the engine, the effort and the levels it
    /// takes, and how much runs without asking (manual, autoEdit, full).
    public var model: String = ""
    public var effort: String = ""
    public var efforts: [String] = []
    public var access: String = "manual"
    public var queued: [QueuedMessage] = []

    public static let empty = ChatMeta(chat: "", title: "", status: "", agentRunning: false, agentStatus: "",
                                       replying: false, mac: "", question: nil, options: nil, awaitingApproval: false)

    public init(chat: String, title: String, status: String, agentRunning: Bool, agentStatus: String,
                replying: Bool, mac: String, question: String?, options: [String]?, awaitingApproval: Bool) {
        self.chat = chat
        self.title = title
        self.status = status
        self.agentRunning = agentRunning
        self.agentStatus = agentStatus
        self.replying = replying
        self.mac = mac
        self.question = question
        self.options = options
        self.awaitingApproval = awaitingApproval
    }

    enum CodingKeys: String, CodingKey {
        case chat, title, status, agentRunning, agentStatus, replying, mac, question, options, awaitingApproval
        case model, effort, efforts, access, queued
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = try c.decodeIfPresent(String.self, forKey: .chat) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
        agentRunning = try c.decodeIfPresent(Bool.self, forKey: .agentRunning) ?? false
        agentStatus = try c.decodeIfPresent(String.self, forKey: .agentStatus) ?? ""
        replying = try c.decodeIfPresent(Bool.self, forKey: .replying) ?? false
        mac = try c.decodeIfPresent(String.self, forKey: .mac) ?? ""
        question = try c.decodeIfPresent(String.self, forKey: .question)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        awaitingApproval = try c.decodeIfPresent(Bool.self, forKey: .awaitingApproval) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? ""
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
        access = try c.decodeIfPresent(String.self, forKey: .access) ?? "manual"
        queued = try c.decodeIfPresent([QueuedMessage].self, forKey: .queued) ?? []
    }

    /// Something is going on: the agent works or a reply is written.
    public var busy: Bool { agentRunning || replying }
}

/// One message from the Mac's live feed: the chat's state, the order of
/// its turns, and the turns that changed (all of them when `full`).
public struct FeedUpdate: Codable, Sendable {
    public var full: Bool
    public var meta: ChatMeta
    public var order: [String]
    public var changed: [Turn]
}

/// What the Mac says about itself (`/info`).
public struct MacInfo: Codable, Sendable {
    public var id: String
    public var name: String
    public var port: Int
    public var hosts: [String]
    /// Its relay now: "" when it has none turned on; missing from a Mac
    /// that predates the relay.
    public var relay: String?
}

/// An engine Companion on the Mac can answer with, and its models, as the
/// Mac's model picker lists them.
public struct Engine: Codable, Hashable, Identifiable, Sendable {
    public struct Model: Codable, Hashable, Identifiable, Sendable {
        /// The model's identifier ("" is the engine's own default).
        public var id: String
        public var title: String
        /// Who picks the default, or what it is good at.
        public var note: String
    }
    public var id: String
    public var name: String
    /// "local", "account" or "api".
    public var place: String
    public var inUse: Bool
    /// The model it would use.
    public var current: String
    public var models: [Model]
}

public struct EngineList: Codable, Sendable {
    public var engines: [Engine]
}
