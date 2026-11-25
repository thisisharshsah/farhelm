import Foundation

/// How a role and model pair has done: built from the board's runs,
/// over the pair's latest 20 judged runs. Replaces TrackRecord with
/// a per-role, per-model record.
public struct Scorecard: Equatable, Sendable {
    public var role: String
    public var modelKey: String
    public var judgedRuns: Int
    public var firstReviewApproved: Int
    public var firstReviewTotal: Int
    public var changesAskedCount: Int
    public var totalReviews: Int
    public var checksPassing: Int
    public var checksTotal: Int
    public var tokenRatios: [Double]
    public var failedOverrun: Int

    public static let enough = 3
    public static let full = 10
    public static let window = 20

    public init(role: String = "", modelKey: String = "",
                judgedRuns: Int = 0,
                firstReviewApproved: Int = 0, firstReviewTotal: Int = 0,
                changesAskedCount: Int = 0, totalReviews: Int = 0,
                checksPassing: Int = 0, checksTotal: Int = 0,
                tokenRatios: [Double] = [], failedOverrun: Int = 0) {
        self.role = role
        self.modelKey = modelKey
        self.judgedRuns = judgedRuns
        self.firstReviewApproved = firstReviewApproved
        self.firstReviewTotal = firstReviewTotal
        self.changesAskedCount = changesAskedCount
        self.totalReviews = totalReviews
        self.checksPassing = checksPassing
        self.checksTotal = checksTotal
        self.tokenRatios = tokenRatios
        self.failedOverrun = failedOverrun
    }

    // MARK: - Rates

    public var firstReviewRate: Double {
        firstReviewTotal > 0 ? Double(firstReviewApproved) / Double(firstReviewTotal) : 0.5
    }

    public var changesAskedRate: Double {
        totalReviews > 0 ? Double(changesAskedCount) / Double(totalReviews) : 0.5
    }

    public var checkPassRate: Double {
        checksTotal > 0 ? Double(checksPassing) / Double(checksTotal) : 0.75
    }

    public var medianTokenRatio: Double {
        guard !tokenRatios.isEmpty else { return 1.0 }
        let sorted = tokenRatios.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// 1 when the ratio is 1.2 or less, falling evenly to 0 at 3.0.
    public var tokenFit: Double {
        let ratio = medianTokenRatio
        if ratio <= 1.2 { return 1.0 }
        if ratio >= 3.0 { return 0.0 }
        return 1.0 - (ratio - 1.2) / (3.0 - 1.2)
    }

    public var rawScore: Double {
        0.40 * firstReviewRate
            + 0.20 * (1 - changesAskedRate)
            + 0.25 * checkPassRate
            + 0.15 * tokenFit
    }

    public static let neutral = Scorecard(
        role: "", modelKey: "",
        firstReviewApproved: 1, firstReviewTotal: 2,
        changesAskedCount: 1, totalReviews: 2,
        checksPassing: 3, checksTotal: 4,
        tokenRatios: [1.0]
    )

    public static let neutralScore: Double = 0.60

    /// The blended score, mixing this pair's data with a prior.
    /// Between `enough` and `full` judged runs, it blends in proportion.
    public func blended(with prior: Scorecard) -> Double {
        guard judgedRuns >= Self.enough else { return prior.rawScore }
        if judgedRuns >= Self.full { return rawScore }
        let own = Double(judgedRuns - Self.enough) / Double(Self.full - Self.enough)
        return rawScore * own + prior.rawScore * (1 - own)
    }

    public var isPoor: Bool {
        judgedRuns >= 5 && rawScore < 0.35
    }

    // MARK: - Key

    public struct Key: Hashable, Sendable {
        public var role: String
        public var modelKey: String

        public init(role: String, modelKey: String) {
            self.role = role
            self.modelKey = modelKey
        }
    }

    // MARK: - Building from runs

    /// Build scorecards from the board's items, per role-model pair.
    public static func of(items: [WorkItem]) -> [Key: Scorecard] {
        struct JudgedRun {
            var taskNumber: Int
            var isFirstOfTask: Bool
            var approved: Bool
            var changesAsked: Bool
            var checksPassed: Bool?
            var tokenRatio: Double?
            var overrun: Bool
            var date: Date
        }

        var allRunsByPair: [Key: [JudgedRun]] = [:]
        var seenTasksPerPair: [Key: Set<Int>] = [:]

        for item in items {
            for run in item.runs where !run.isRunning {
                if run.ending == .person || run.ending == .supervisor || Board.modelFailed(run) {
                    continue
                }
                let roleKey = item.role ?? ""
                let key = Key(role: roleKey, modelKey: run.model.key)

                let isFirst = !(seenTasksPerPair[key]?.contains(item.number) ?? false)
                seenTasksPerPair[key, default: []].insert(item.number)

                let approved = run.review?.verdict == .approved
                let changes = run.review?.verdict == .changesRequested

                let checksPassed: Bool?
                if let checks = run.checks, !checks.isEmpty {
                    checksPassed = checks.allSatisfy(\.passed)
                } else {
                    checksPassed = nil
                }

                let tokenRatio: Double?
                if let tokens = run.tokens, tokens > 0,
                   let estimate = item.estimateTokens, estimate > 0 {
                    tokenRatio = Double(tokens) / Double(estimate)
                } else {
                    tokenRatio = nil
                }

                let judged = JudgedRun(
                    taskNumber: item.number,
                    isFirstOfTask: isFirst,
                    approved: approved,
                    changesAsked: changes,
                    checksPassed: checksPassed,
                    tokenRatio: tokenRatio,
                    overrun: run.ending == .overrun,
                    date: run.endedAt ?? run.startedAt
                )

                allRunsByPair[key, default: []].append(judged)
            }
        }

        var result: [Key: Scorecard] = [:]
        for (key, allRuns) in allRunsByPair {
            let runs = Array(allRuns.sorted { $0.date > $1.date }.prefix(window))

            var card = Scorecard(role: key.role, modelKey: key.modelKey)
            card.judgedRuns = runs.count

            for run in runs {
                if run.isFirstOfTask {
                    card.firstReviewTotal += 1
                    if run.approved { card.firstReviewApproved += 1 }
                }
                if run.approved || run.changesAsked {
                    card.totalReviews += 1
                    if run.changesAsked { card.changesAskedCount += 1 }
                }
                if let passed = run.checksPassed {
                    card.checksTotal += 1
                    if passed { card.checksPassing += 1 }
                }
                if let ratio = run.tokenRatio {
                    card.tokenRatios.append(ratio)
                }
                if run.overrun { card.failedOverrun += 1 }
            }

            result[key] = card
        }

        return result
    }

    /// A line for the supervisor.
    public var line: String {
        let s = String(format: "%.2f", rawScore)
        return "\(judgedRuns) run\(judgedRuns == 1 ? "" : "s"), "
            + "\(pct(firstReviewRate)) first-review approved, "
            + "\(pct(1 - changesAskedRate)) no changes, "
            + "\(pct(checkPassRate)) checks passing, "
            + "score \(s)"
    }

    private func pct(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}