import Foundation

/// The wire types, mirroring `crates/forge-runner/src/api.rs` and the TypeScript
/// in `packages/client-core/src/api.ts`.
///
/// Only the subset a wrist needs is decoded. `SessionView` skips the output tail
/// and the plan's checkpoint SHAs because nothing on a watch can use them, and
/// decoding fields nobody reads is just a bigger surface to get wrong. Unknown
/// JSON keys are ignored by `Codable`, so the runner can add fields freely.

public struct BudgetView: Codable, Equatable, Sendable {
    public let capUSD: Double?
    public let spentUSD: Double
    public let pct: Double?
    public let state: BudgetState

    enum CodingKeys: String, CodingKey {
        case capUSD = "cap_usd"
        case spentUSD = "spent_usd"
        case pct
        case state
    }
}

public enum BudgetState: String, Codable, Sendable {
    case ok, warn, stop
}

public enum SessionStatus: String, Codable, Sendable {
    case running
    case awaitingApproval = "awaiting_approval"
    case paused
    case done
    case dead

    /// What a human calls it. The wrist has no room for a legend.
    public var label: String {
        switch self {
        case .running: return "Running"
        case .awaitingApproval: return "Needs you"
        case .paused: return "Paused"
        case .done: return "Done"
        case .dead: return "Stopped"
        }
    }
}

public enum Risk: String, Codable, Sendable {
    case low, medium, destructive
}

public enum Decision: String, Codable, Sendable {
    case approved, denied, timeout
}

public struct PlanProgress: Codable, Equatable, Sendable {
    public let total: Int
    public let settled: Int
    public let currentOrdinal: Int?
    public let currentTitle: String?

    enum CodingKeys: String, CodingKey {
        case total
        case settled
        case currentOrdinal = "current_ordinal"
        case currentTitle = "current_title"
    }
}

public struct SessionView: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let repoName: String
    public let machineName: String
    public let status: SessionStatus
    public let isLive: Bool
    public let plan: PlanProgress?
    public let budget: BudgetView

    enum CodingKeys: String, CodingKey {
        case id
        case repoName = "repo_name"
        case machineName = "machine_name"
        case status
        case isLive = "is_live"
        case plan
        case budget
    }
}

public struct ApprovalView: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public let tool: String
    public let payload: String
    public let risk: Risk
    public let requestedAt: Int64
    public let repoName: String
    /// The runner's own answer to "may a watch clear this?".
    ///
    /// The watch obeys it for the UI, but does not rely on it: the same rule is
    /// enforced server-side against this device's registered kind, so a modified
    /// watch app gains nothing by ignoring the flag.
    public let allowsWatchDecision: Bool
    public let budget: BudgetView

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case tool
        case payload
        case risk
        case requestedAt = "requested_at"
        case repoName = "repo_name"
        case allowsWatchDecision = "allows_watch_decision"
        case budget
    }
}

public struct FleetView: Codable, Equatable, Sendable {
    public let sessions: [SessionView]
    public let pendingApprovals: [ApprovalView]
    public let todayUSD: Double
    public let cacheHitRatio: Double

    enum CodingKeys: String, CodingKey {
        case sessions
        case pendingApprovals = "pending_approvals"
        case todayUSD = "today_usd"
        case cacheHitRatio = "cache_hit_ratio"
    }
}

/// What the runner pushes. Mirrors `forge_runner::state::ServerEvent`, plus the
/// `command_error` the relay path adds.
public enum ServerEvent: Sendable, Equatable {
    case sessionUpsert(sessionID: String)
    case approvalRequest
    case approvalDecision(approvalID: String, decision: Decision)
    case budgetAlert(sessionID: String, pct: Double, hardStop: Bool)
    case commandError(message: String)
    /// Anything the runner added that this build predates. Ignored, not fatal.
    case unknown(String)
}

extension ServerEvent: Decodable {
    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case approvalID = "approval_id"
        case decision
        case pct
        case hardStop = "hard_stop"
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "session_upsert":
            self = .sessionUpsert(sessionID: try container.decode(String.self, forKey: .sessionID))
        case "approval_request":
            self = .approvalRequest
        case "approval_decision":
            self = .approvalDecision(
                approvalID: try container.decode(String.self, forKey: .approvalID),
                decision: try container.decode(Decision.self, forKey: .decision)
            )
        case "budget_alert":
            self = .budgetAlert(
                sessionID: try container.decode(String.self, forKey: .sessionID),
                pct: try container.decode(Double.self, forKey: .pct),
                hardStop: try container.decode(Bool.self, forKey: .hardStop)
            )
        case "command_error":
            self = .commandError(message: try container.decode(String.self, forKey: .message))
        default:
            self = .unknown(type)
        }
    }
}

/// What a device sends. Mirrors `forge_runner::commands::Command`.
///
/// The watch sends only three of these. It cannot start a session, control a
/// plan, or read the cost dashboard — not because of a missing case here, but
/// because none of those are things to do from a wrist.
public enum Command: Encodable, Sendable {
    case snapshot
    case decide(approvalID: String, decision: Decision)
    case instruct(sessionID: String, text: String)

    enum CodingKeys: String, CodingKey {
        case type
        case approvalID = "approval_id"
        case decision
        case sessionID = "session_id"
        case text
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot:
            try container.encode("snapshot", forKey: .type)
        case .decide(let approvalID, let decision):
            try container.encode("decide", forKey: .type)
            try container.encode(approvalID, forKey: .approvalID)
            try container.encode(decision, forKey: .decision)
        case .instruct(let sessionID, let text):
            try container.encode("instruct", forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(text, forKey: .text)
        }
    }
}

/// What this watch remembers after pairing. Mirrors the TypeScript `Pairing`.
public struct Pairing: Codable, Equatable, Sendable {
    public let relayURL: String
    public let channel: String
    public let runnerPublicKey: String
    public let deviceID: String
    public let secret: String

    public init(
        relayURL: String,
        channel: String,
        runnerPublicKey: String,
        deviceID: String,
        secret: String
    ) {
        self.relayURL = relayURL
        self.channel = channel
        self.runnerPublicKey = runnerPublicKey
        self.deviceID = deviceID
        self.secret = secret
    }

    enum CodingKeys: String, CodingKey {
        case relayURL = "relayUrl"
        case channel
        case runnerPublicKey
        case deviceID = "deviceId"
        case secret
    }
}
