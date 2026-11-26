import Foundation

/// How a run is watched for loops, and the thresholds that turn signals
/// into a flag. The supervisor is told about flagged runs in its next
/// board update, and the board only lets the supervisor stop a run that
/// is flagged (`Board.loopFlag`), so a healthy run is never cut off by a
/// model misreading the state.
public enum LoopDetection {
    /// How far past a task's own estimate a run must go before the board
    /// flags it as runaway. By three times the plan is clearly wrong, so
    /// the task is to re-plan (split, sharpen or route to another model),
    /// not to keep spending on.
    public static let tokenMultiple = 3

    /// How many reads of the same file without a successful edit between
    /// them count as a read loop. One is a first look, two can be re-reading
    /// a long file, three in a row is going round.
    public static let repeatedReadsLimit = 3

    /// How many failing edits in a row with the same error mean the
    /// approach itself does not work. One fail is learning, two is
    /// retrying, three is the same wall each time.
    public static let repeatedEditsLimit = 3
}

/// The signals kept on a run while it goes, so the board can tell a
/// healthy run from one that is looping. The app records these; the board
/// reads them in `loopFlag`.
public struct RunSignals: Codable, Equatable, Sendable {
    /// Each file read, with how many reads of that file have piled up
    /// since the last successful edit. A successful edit clears this.
    public var reads: [String: Int]
    /// The signature of the last failing edit, or nil when the last edit
    /// did not fail (or none has run yet). Matching a signature in a row
    /// is what counts; a new error restarts the count.
    public var lastFailingEditKey: String?
    /// How many failing edits in a row share `lastFailingEditKey`.
    public var repeatedFailingEdits: Int
    /// The run's model was swapped to a weaker one after its own could
    /// not answer (a subscription limit, overload). On its own that is
    /// not a loop, so the flag only fires once reads or edits go round
    /// as well; it is kept here so the flag can say why.
    public var fellBack: Bool

    public init(reads: [String: Int] = [:], lastFailingEditKey: String? = nil,
                repeatedFailingEdits: Int = 0, fellBack: Bool = false) {
        self.reads = reads
        self.lastFailingEditKey = lastFailingEditKey
        self.repeatedFailingEdits = repeatedFailingEdits
        self.fellBack = fellBack
    }

    /// Records a file the run read. The counter for that file goes up;
    /// reads of other files leave it alone until an edit clears them.
    public mutating func recordRead(_ file: String) {
        let path = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        reads[path, default: 0] += 1
    }

    /// Records an edit attempt. A successful edit clears every read
    /// count (a change was made, so further reads are checking that
    /// change, not looping) and the failing-edit count. A failing edit
    /// whose error matches the one before raises the count; a new error
    /// starts it over at one.
    public mutating func recordEdit(_ file: String, succeeded: Bool, errorKey: String? = nil) {
        if succeeded {
            reads.removeAll()
            lastFailingEditKey = nil
            repeatedFailingEdits = 0
            return
        }
        let key = (errorKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = file.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let signature = key.isEmpty ? path : key
        guard !signature.isEmpty else { return }
        if signature == lastFailingEditKey {
            repeatedFailingEdits += 1
        } else {
            lastFailingEditKey = signature
            repeatedFailingEdits = 1
        }
    }

    private enum CodingKeys: String, CodingKey {
        case reads, lastFailingEditKey, repeatedFailingEdits, fellBack
    }

    /// Read field by field so a run saved before signals existed still
    /// loads with empty signals (nothing is lost; nothing is flagged).
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reads = try values.decodeIfPresent([String: Int].self, forKey: .reads) ?? [:]
        lastFailingEditKey = try values.decodeIfPresent(String.self, forKey: .lastFailingEditKey)
        repeatedFailingEdits = try values.decodeIfPresent(Int.self, forKey: .repeatedFailingEdits) ?? 0
        fellBack = try values.decodeIfPresent(Bool.self, forKey: .fellBack) ?? false
    }
}

/// Why a run is flagged as looping, as a kind the UI can switch on and a
/// line of plain words for the supervisor's board update and the card's note.
public struct LoopFlag: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, Codable {
        /// Tokens past `LoopDetection.tokenMultiple` of the task's estimate.
        case overrun
        /// A file read `LoopDetection.repeatedReadsLimit` times without
        /// a successful edit between the reads.
        case repeatedReads
        /// Failing edits in a row, `LoopDetection.repeatedEditsLimit`
        /// of them, with the same error and no successful edit between.
        case repeatedEdits
        /// A read or edit loop after the run's model fell back to a
        /// weaker one. The fallback on its own is not a loop; the loop is.
        case fallbackLooping
    }

    public var kind: Kind
    /// The reason in plain words, meant to read naturally after a task
    /// key: "T-3 has used 60k tokens, over 3x its 20k-token estimate".
    public var reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

extension LoopDetection {
    /// Whether a task's run going on is looping, and why. nil for a task
    /// with no run, or a run whose signals and token use are within reach.
    /// The board consults this before it allows the supervisor to stop a
    /// run, and the item line sent to the supervisor names the reason, so
    /// the model can stop it and re-plan the task in its next reply.
    public static func flag(for item: WorkItem) -> LoopFlag? {
        guard let run = item.activeRun else { return nil }
        // Tokens over the multiple of the estimate: the plan is clearly
        // wrong, so the task is to re-plan, not to keep spending on.
        if let estimate = item.estimateTokens, estimate > 0, let used = run.tokens,
           used > estimate * tokenMultiple {
            return LoopFlag(kind: .overrun,
                            reason: "\(item.key) has used \(tokens(used)), "
                                + "over \(tokenMultiple)x its \(tokens(estimate))-token estimate.")
        }
        // The same file read again and again without an edit between.
        // Ties between files are settled by name so the reason is stable.
        let worstRead = run.signals.reads
            .filter { $0.value >= repeatedReadsLimit }
            .max { ($0.value, $1.key) < ($1.value, $0.key) }
        if let worst = worstRead {
            let base = "has read \(worst.key) \(worst.value) times in a row without a successful edit between"
            if run.signals.fellBack {
                return LoopFlag(kind: .fallbackLooping,
                                reason: "\(item.key) fell back to a weaker model and \(base).")
            }
            return LoopFlag(kind: .repeatedReads, reason: "\(item.key) \(base).")
        }
        // Failing edits in a row that share an error signature.
        if run.signals.repeatedFailingEdits >= repeatedEditsLimit {
            let base = "has \(run.signals.repeatedFailingEdits) failing edits in a row with the same error"
            if run.signals.fellBack {
                return LoopFlag(kind: .fallbackLooping,
                                reason: "\(item.key) fell back to a weaker model and \(base).")
            }
            return LoopFlag(kind: .repeatedEdits, reason: "\(item.key) \(base).")
        }
        return nil
    }

    /// A short token count as it reads in the reason: 60000 becomes "60k",
    /// 1500000 becomes "1.5M". Kept here so a flag's wording matches the
    /// numbers the supervisor sees elsewhere on the board.
    static func tokens(_ count: Int) -> String {
        if count < 1_000 { return String(count) }
        if count < 1_000_000 { return "\(count / 1_000)k" }
        let millions = Double(count) / 1_000_000
        return String(format: "%.1fM", millions)
    }

    /// The "looping: ..." fact the supervisor sees on a task's item line in
    /// its board update, so the stop and the re-plan go in the same reply.
    /// nil for a task whose run is healthy. Kept here so the item line and
    /// the tests of it share one wording.
    public static func fact(for item: WorkItem) -> String? {
        flag(for: item).map { "looping: " + $0.reason }
    }
}