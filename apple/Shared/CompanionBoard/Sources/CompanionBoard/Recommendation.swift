import Foundation

/// A supervisor's answer to "which of these would you pick?", read from
/// what it wrote. It is asked to put its pick on the first line (one of
/// the words it was given, or NONE) and a short reason after it. A model
/// wrote it, so it is read forgivingly. Reading it decides nothing: what
/// is done with a pick is up to whoever asked.
public struct Recommendation: Equatable, Sendable {
    /// The place of the option picked among the ones offered, from 0.
    public var option: Int
    /// Why, in a sentence. May be empty.
    public var reason: String

    public init(option: Int, reason: String) {
        self.option = option
        self.reason = reason
    }

    /// The most of a reason that is kept.
    public static let reasonLimit = 260

    /// What a supervisor's answer comes to.
    public enum Reading: Equatable, Sendable {
        /// It picked one of the options.
        case pick(Recommendation)
        /// It left the choice to the person, and may have said why.
        case left(String)
    }

    /// Words that leave the choice to the person.
    private static let leaving: Set<String> = ["NONE", "NEITHER", "ASK"]

    /// Words a model puts before its pick, which say nothing.
    private static let filler: Set<String> = [
        "RECOMMENDATION", "RECOMMENDED", "RECOMMEND", "I", "PICK", "ANSWER", "OPTION", "CHOICE", "VERDICT", "MY",
        "THE", "IS", "WOULD", "GO", "WITH", "NUMBER"
    ]

    /// Reads an answer for its pick. `words` are the options as the
    /// supervisor was told to write them ("ALLOW", "DENY"), in the
    /// options' order; a number picks an option by its place, counted
    /// from 1. nil when it picked none of them, or wrote something else.
    public static func parse(_ answer: String, among words: [String]) -> Recommendation? {
        if case .pick(let found)? = read(answer, among: words) { return found }
        return nil
    }

    /// Reads an answer: the option it picks, or that it leaves the
    /// choice to the person ("NONE", "ASK"), each with the reason it
    /// gave. nil when it wrote something else.
    public static func read(_ answer: String, among words: [String]) -> Reading? {
        let lines = answer.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, !words.isEmpty else { return nil }
        let names = words.map { $0.uppercased() }
        // The first line in pieces: words and numbers, and what is between them.
        var rest = Substring(first)
        var option: Int?
        var leaves = false
        var looked = 0
        while option == nil, !leaves, looked < 6 {
            rest = rest.drop { !$0.isLetter && !$0.isNumber }
            let token = rest.prefix { $0.isLetter || $0.isNumber }
            guard !token.isEmpty else { break }
            rest = rest.dropFirst(token.count)
            looked += 1
            let word = token.uppercased()
            if let place = names.firstIndex(of: word) {
                option = place
            } else if leaving.contains(word) {
                leaves = true
            } else if let number = Int(word), (1...words.count).contains(number) {
                option = number - 1
            } else if !filler.contains(word) {
                return nil
            }
        }
        guard option != nil || leaves else { return nil }
        if option != nil {
            // "ALWAYS ALLOW": a second name right after the pick is part of it.
            let after = rest.drop { !$0.isLetter && !$0.isNumber }
            let next = after.prefix { $0.isLetter || $0.isNumber }
            if names.contains(next.uppercased()) { rest = after.dropFirst(next.count) }
        }
        // What follows the pick on its line, without the marks between them.
        let marks: Set<Character> = [" ", "\t", ":", ".", ",", ";", "*", "_", "-"]
        var reason = String(rest.drop { marks.contains($0) }).trimmingCharacters(in: .whitespaces)
        let more = lines.dropFirst().joined(separator: " ")
        if !more.isEmpty { reason = reason.isEmpty ? more : reason + " " + more }
        reason = reason.replacingOccurrences(of: "**", with: "")
        if reason.count > reasonLimit { reason = String(reason.prefix(reasonLimit - 1)) + "…" }
        if let picked = option { return .pick(Recommendation(option: picked, reason: reason)) }
        return .left(reason)
    }
}
