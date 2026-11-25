import Foundation
import AppKit
import ScreenCaptureKit

/// Something Companion picked up by watching another assistant work, kept
/// as a proposal until the user accepts or dismisses it.
struct LearnedItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// A way of doing one kind of work: becomes a SKILL.md.
        case skill
        /// A standing rule for how the agent works.
        case rule
        /// How the user likes things.
        case preference
        /// Where Companion fell short next to the other assistant.
        case gap

        var label: String {
            switch self {
            case .skill: return "Skill"
            case .rule: return "Rule"
            case .preference: return "Preference"
            case .gap: return "Gap"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var body: String
    /// What was seen that led to it, in a line.
    var evidence: String
    var date = Date()
}

/// Learns from the Claude desktop app while the user lets it: it reads only
/// that app's window from the screen (text recognized on this Mac), notes
/// what is new, and when the work there pauses, asks the model what is
/// worth keeping. What comes back waits as proposals; nothing changes how
/// Companion works until the user accepts it.
@MainActor
final class LearningWatcher: ObservableObject {
    static let shared = LearningWatcher()

    /// The apps watched: the Claude desktop app.
    nonisolated static let watchedApps: Set<String> = ["com.anthropic.claudefordesktop"]

    @Published private(set) var watching = false
    @Published private(set) var proposals: [LearnedItem] = []
    @Published private(set) var status = "Off"

    /// Rules and preferences the user accepted. Every task starts with them.
    static var rulesFile: URL { ContextStore.shared.baseDir.appendingPathComponent("learned-rules.md") }
    private let file = ContextStore.shared.baseDir.appendingPathComponent("learning.json")

    private var loop: Task<Void, Never>?
    /// Lines already seen, so only what is new is kept.
    private var seenLines: [String] = []
    private var seenSet: Set<String> = []
    /// New text since the last time it was looked over.
    private var pending: [String] = []
    private var lastChange = Date.distantPast
    /// What Companion's own agent did lately, to compare with.
    private var companionWork: [String] = []
    private let engine = SuggestionEngine()
    private var distilling = false

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([LearnedItem].self, from: data) {
            proposals = saved
        }
    }

    func toggle() { watching ? stop() : start() }

    func start() {
        guard !watching else { return }
        watching = true
        status = "Watching the Claude app"
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        watching = false
        status = "Off"
        // What was seen but not yet looked over is not thrown away.
        if pending.joined().count > 400 { Task { await distill() } }
    }

    /// Called when one of Companion's own tasks ends.
    func noteCompanionWork(task: String, steps: [String], answer: String) {
        let entry = "Task: " + String(task.prefix(300))
            + "\nSteps: " + steps.suffix(12).map { String($0.prefix(120)) }.joined(separator: " | ")
            + "\nEnded with: " + String(answer.prefix(500))
        companionWork.append(entry)
        if companionWork.count > 6 { companionWork.removeFirst(companionWork.count - 6) }
    }

    private func tick() async {
        guard let text = await Self.readClaudeWindow() else {
            status = "Waiting for the Claude app to be on screen"
            return
        }
        status = "Watching the Claude app"
        var fresh: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 3, !seenSet.contains(line) else { continue }
            fresh.append(line)
            seenSet.insert(line)
            seenLines.append(line)
        }
        if seenLines.count > 6000 {
            let drop = seenLines.prefix(seenLines.count - 6000)
            drop.forEach { seenSet.remove($0) }
            seenLines.removeFirst(drop.count)
        }
        if !fresh.isEmpty {
            pending.append(contentsOf: fresh)
            lastChange = Date()
        }
        let size = pending.reduce(0) { $0 + $1.count }
        // Looked over when the work there pauses, or when a lot has piled up.
        let paused = Date().timeIntervalSince(lastChange) > 45
        if size > 1500 && paused || size > 14000 { await distill() }
    }

    private func distill() async {
        guard !distilling, !pending.isEmpty else { return }
        distilling = true
        defer { distilling = false }
        let observed = pending.joined(separator: "\n")
        pending.removeAll()
        status = "Looking over what it saw"
        let known = proposals.map { "- \($0.kind.rawValue): \($0.title)" }.joined(separator: "\n")
        let rules = (try? String(contentsOf: Self.rulesFile, encoding: .utf8)) ?? ""
        let skills = ProjectContext.skills(in: "").map { "- " + $0.name }.joined(separator: "\n")
        do {
            let items = try await engine.learn(observed: String(observed.suffix(16000)),
                                               companion: companionWork.joined(separator: "\n\n"),
                                               existing: [known, rules, skills].joined(separator: "\n"))
            if !items.isEmpty {
                proposals.append(contentsOf: items)
                save()
            }
            status = items.isEmpty ? "Watching the Claude app" : "\(proposals.count) to review"
        } catch {
            status = "Could not look it over: \(error.localizedDescription)"
        }
    }

    func accept(_ item: LearnedItem) {
        switch item.kind {
        case .skill:
            let slug = Self.slug(item.title)
            let folder = ProjectContext.skillsFolder.appendingPathComponent(slug, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let about = item.evidence.isEmpty ? item.title : item.evidence
            let text = "---\nname: \(slug)\ndescription: \(about.replacingOccurrences(of: "\n", with: " "))\n---\n\n# \(item.title)\n\n\(item.body)\n"
            try? text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        case .rule, .preference, .gap:
            let line = "- " + item.title + ": " + item.body.replacingOccurrences(of: "\n", with: " ") + "\n"
            let current = (try? String(contentsOf: Self.rulesFile, encoding: .utf8)) ?? "# How to work (learned, approved by the user)\n\n"
            try? (current + line).write(to: Self.rulesFile, atomically: true, encoding: .utf8)
        }
        dismiss(item)
    }

    func dismiss(_ item: LearnedItem) {
        proposals.removeAll { $0.id == item.id }
        save()
        if watching { status = proposals.isEmpty ? "Watching the Claude app" : "\(proposals.count) to review" }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(proposals) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private static func slug(_ title: String) -> String {
        let lower = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(lower).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "learned-skill" : String(joined.prefix(48))
    }

    /// The text of the Claude app's largest window on screen, read on this
    /// Mac, or nil when it is not on screen. Only that window is captured.
    nonisolated static func readClaudeWindow() async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let windows = content.windows.filter {
            watchedApps.contains($0.owningApplication?.bundleIdentifier ?? "") && $0.isOnScreen
                && $0.frame.width >= 320 && $0.frame.height >= 220
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        // The same path as every other screen read: card numbers and
        // password fields are left out of the text.
        let owner = window.owningApplication?.processID
        return try? await Redaction.release(image, area: window.frame, owner: owner).text
    }
}
