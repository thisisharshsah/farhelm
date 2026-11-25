import Foundation

// MARK: - Types

/// A kind of work the project needs: Mac engineer, designer, writer.
public struct TeamRole: Codable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var brief: String
    public var kinds: [WorkKind]
    public var paths: [String]
    public var model: ModelChoice?
    public var isActive: Bool
    public var createdAt: Date
    public var createdBy: BoardActor
    public var retiredAt: Date?

    public init(key: String, title: String, brief: String = "",
                kinds: [WorkKind] = [.feature], paths: [String] = [],
                model: ModelChoice? = nil, isActive: Bool = true,
                createdAt: Date, createdBy: BoardActor = .supervisor,
                retiredAt: Date? = nil) {
        self.key = TeamRules.key(key)
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(TeamRules.titleLength))
        self.brief = String(brief.prefix(TeamRules.briefLength))
        self.kinds = kinds.isEmpty ? [.feature] : kinds
        self.paths = Leases.list(paths)
        self.model = model
        self.isActive = isActive
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.retiredAt = retiredAt
    }
}

/// One member of the team holding a role. A specialist is a seat, not
/// a process: it has an id, its role, and whether it is active. It
/// holds at most one run at a time.
public struct Specialist: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var role: String
    public var isActive: Bool
    public var createdAt: Date
    public var createdBy: BoardActor
    public var reason: String
    public var retiredAt: Date?

    public init(id: UUID = UUID(), role: String, isActive: Bool = true,
                createdAt: Date, createdBy: BoardActor = .supervisor,
                reason: String = "", retiredAt: Date? = nil) {
        self.id = id
        self.role = role
        self.isActive = isActive
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.reason = reason
        self.retiredAt = retiredAt
    }
}

// MARK: - Rules

public enum TeamRules {
    public static let roleLimit = 8
    public static let queueToGrow = 3
    public static let reviewQueue = 3
    public static let idleInterval: TimeInterval = 24 * 3600
    public static let defaultTeamLimit = 3
    public static let keyLength = 32
    public static let titleLength = 40
    public static let briefLength = 1_200

    public static func key(_ text: String) -> String {
        let cleaned = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return String(cleaned.prefix(keyLength))
    }
}

// MARK: - Routing

/// Choosing which role takes a task by rule.
public enum TeamRouting {
    /// The role for a task: best path coverage, then kind match, then
    /// fewest open tasks, then oldest role. nil when no role scores
    /// (the task is marked "needs a role").
    public static func role(for item: WorkItem, among roles: [TeamRole],
                            items: [WorkItem]) -> String? {
        let active = roles.filter { $0.isActive }
        guard !active.isEmpty else { return nil }

        struct Candidate {
            var key: String
            var pathScore: Int
            var kindMatch: Bool
            var openTasks: Int
            var createdAt: Date
        }

        var candidates: [Candidate] = active.map { role in
            let pathScore: Int
            if item.paths.isEmpty || role.paths.isEmpty {
                pathScore = 0
            } else {
                pathScore = item.paths.filter { taskPath in
                    role.paths.contains { Leases.overlap($0, taskPath) }
                }.count
            }
            let kindMatch = role.kinds.contains(item.kind)
            let openTasks = items.filter {
                $0.role == role.key && $0.status != .done && $0.status != .backlog
            }.count
            return Candidate(key: role.key, pathScore: pathScore, kindMatch: kindMatch,
                             openTasks: openTasks, createdAt: role.createdAt)
        }

        let maxPaths = candidates.map(\.pathScore).max() ?? 0
        if maxPaths > 0 {
            candidates = candidates.filter { $0.pathScore == maxPaths }
            if candidates.count == 1 { return candidates[0].key }
        }

        let kindMatches = candidates.filter { $0.kindMatch }
        if !kindMatches.isEmpty {
            candidates = kindMatches
            if candidates.count == 1 { return candidates[0].key }
        } else if maxPaths == 0 {
            return nil
        }

        candidates.sort { ($0.openTasks, $0.createdAt) < ($1.openTasks, $1.createdAt) }
        return candidates.first?.key
    }
}

// MARK: - Board team management

extension Board {
    /// A free specialist of a role: active, and not running any task.
    public func freeSpecialist(for roleKey: String) -> Specialist? {
        let busy = Set(allItems.compactMap { $0.activeRun?.specialist })
        return specialists.first { $0.role == roleKey && $0.isActive && !busy.contains($0.id) }
    }

    /// The specialists that have had no run for `TeamRules.idleInterval`
    /// and whose role has no task in To do or In progress.
    public func idleSpecialists(now: Date) -> [Specialist] {
        specialists.filter { specialist in
            guard specialist.isActive else { return false }
            let lastRun = allItems.flatMap(\.runs)
                .filter { $0.specialist == specialist.id }
                .compactMap(\.endedAt)
                .max() ?? specialist.createdAt
            guard now.timeIntervalSince(lastRun) >= TeamRules.idleInterval else { return false }
            let hasWork = allItems.contains {
                $0.role == specialist.role && ($0.status == .todo || $0.status == .inProgress)
            }
            return !hasWork
        }
    }

    /// The active specialists of a role.
    public func activeSpecialists(of roleKey: String) -> [Specialist] {
        specialists.filter { $0.role == roleKey && $0.isActive }
    }

    @discardableResult
    public mutating func addRole(_ role: TeamRole, by actor: BoardActor, now: Date) -> Bool {
        let activeCount = roles.filter(\.isActive).count
        guard activeCount < TeamRules.roleLimit else { return false }
        guard !roles.contains(where: { $0.isActive && $0.key == role.key }) else { return false }
        var added = role
        added.createdAt = now
        added.createdBy = actor
        roles.append(added)
        log("Added role \(added.title)", by: actor, now: now)
        return true
    }

    /// Retires a role: only when it has no open tasks (not done, not
    /// backlog). Its specialists are retired with it. Retired roles
    /// stay on the board with their scorecards.
    @discardableResult
    public mutating func retireRole(key: String, by actor: BoardActor, now: Date) -> Bool {
        guard let index = roles.firstIndex(where: { $0.key == key && $0.isActive }) else { return false }
        let hasOpen = allItems.contains {
            $0.role == key && $0.status != .done && $0.status != .backlog
        }
        guard !hasOpen else { return false }
        roles[index].isActive = false
        roles[index].retiredAt = now
        for i in specialists.indices where specialists[i].role == key && specialists[i].isActive {
            specialists[i].isActive = false
            specialists[i].retiredAt = now
        }
        log("Retired role \(roles[index].title)", by: actor, now: now)
        return true
    }

    @discardableResult
    public mutating func addSpecialist(role roleKey: String, reason: String = "",
                                       by actor: BoardActor, now: Date) -> Specialist? {
        guard roles.contains(where: { $0.key == roleKey && $0.isActive }) else { return nil }
        let total = specialists.filter(\.isActive).count
        guard total < settings.teamLimit else { return nil }
        let specialist = Specialist(role: roleKey, createdAt: now, createdBy: actor, reason: reason)
        specialists.append(specialist)
        log("Added a specialist for \(roleKey)", by: actor, now: now)
        return specialist
    }

    /// Retires a specialist. Cannot retire one that holds a run.
    @discardableResult
    public mutating func retireSpecialist(id: UUID, by actor: BoardActor, now: Date) -> Bool {
        guard let index = specialists.firstIndex(where: { $0.id == id && $0.isActive }) else { return false }
        let busy = allItems.contains { $0.activeRun?.specialist == id }
        guard !busy else { return false }
        specialists[index].isActive = false
        specialists[index].retiredAt = now
        log("Retired a specialist for \(specialists[index].role)", by: actor, now: now)
        return true
    }
}