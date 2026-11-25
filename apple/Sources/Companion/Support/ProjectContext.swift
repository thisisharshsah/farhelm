import Foundation

/// A skill: a folder with a `SKILL.md` that says how to do one kind of
/// work well. Only its name and one line about it go to the model up
/// front; the model reads the file itself when a task calls for it, so
/// any number of skills costs next to nothing until one is used.
struct Skill: Identifiable, Equatable {
    let name: String
    let about: String
    /// The `SKILL.md` to read.
    let file: String
    /// Comes with the repository, as opposed to being the user's own.
    let fromProject: Bool

    var id: String { file }
}

/// What a repository, and the user, have written down for whoever works
/// here: the project's instructions file and the skills on hand. This is
/// context kept outside the conversation, so every task starts with it
/// and none of it has to be said again.
@MainActor
enum ProjectContext {
    /// The files a repository may keep its instructions in, in the order
    /// they are looked for. The first one found is used.
    static let instructionFiles = ["COMPANION.md", "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md"]

    /// The most of an instructions file that is passed on, in characters.
    private static let instructionLimit = 8_000
    private static let skillLimit = 30

    /// The user's own skills live in Companion's folder.
    static var skillsFolder: URL {
        ContextStore.shared.baseDir.appendingPathComponent("skills", isDirectory: true)
    }

    /// The repository's instructions, if it has any.
    static func instructions(in folder: String) -> (name: String, text: String)? {
        guard !folder.isEmpty else { return nil }
        for name in instructionFiles {
            let path = (folder as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count > instructionLimit {
                return (name, String(trimmed.prefix(instructionLimit)) + "\n[the rest is left out; READ \(path) for all of it]")
            }
            return (name, trimmed)
        }
        return nil
    }

    /// The skills on hand: the repository's own first, then the user's.
    /// Skills written for Claude Code (`.claude/skills`) are found too, so
    /// they do not have to be kept twice.
    static func skills(in folder: String) -> [Skill] {
        let home = NSHomeDirectory()
        var places: [(path: String, project: Bool)] = []
        if !folder.isEmpty {
            places.append(((folder as NSString).appendingPathComponent(".companion/skills"), true))
            places.append(((folder as NSString).appendingPathComponent(".claude/skills"), true))
        }
        places.append((skillsFolder.path, false))
        places.append(((home as NSString).appendingPathComponent(".claude/skills"), false))

        var found: [Skill] = []
        for place in places {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []).sorted()
            for name in names where found.count < skillLimit {
                let file = ((place.path as NSString).appendingPathComponent(name) as NSString)
                    .appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                let skill = read(text, folder: name, file: file, fromProject: place.project)
                // A repository's skill wins over the user's of the same name.
                if !found.contains(where: { $0.name == skill.name }) { found.append(skill) }
            }
        }
        return found
    }

    /// A skill's name and one line about it, from the heading block at the
    /// top of its file ("name:" and "description:" between two "---"
    /// lines). Without one, the folder's name and the first line of text.
    private static func read(_ text: String, folder: String, file: String, fromProject: Bool) -> Skill {
        var name = folder
        var about = ""
        let lines = text.components(separatedBy: "\n")
        var body = lines[...]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                if key == "name", !value.isEmpty { name = value }
                if key == "description", !value.isEmpty { about = value }
            }
            body = lines[(end + 1)...]
        }
        if about.isEmpty {
            about = body.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        }
        return Skill(name: name, about: String(about.prefix(220)), file: file, fromProject: fromProject)
    }

    /// What goes to the agent with a task in this folder: the instructions
    /// in full and the skills by name. Empty when there is neither.
    ///
    /// Both are guidance on how to work. Neither can widen what the agent
    /// may do: what needs the user's approval is decided in code, by the
    /// chat's mode, whatever a file says.
    /// Where a project's lasting notes live: hosts, accounts, what works
    /// and what does not, where results are. Every chat in the project
    /// starts with them, so nothing learned once has to be found again.
    static func notesFile(in folder: String) -> String {
        ((folder as NSString).appendingPathComponent(".companion") as NSString).appendingPathComponent("notes.md")
    }

    private static let notesLimit = 6_000

    static func saveNotes(_ text: String, in folder: String) {
        guard !folder.isEmpty else { return }
        let file = notesFile(in: folder)
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Notes files the work left at the top of the folder (job_notes.md,
    /// NOTES.md), named so they are read before anything is looked up again.
    static func otherNotes(in folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".md") && $0.lowercased().contains("notes") }
            .sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    static func note(for folder: String) -> String {
        var note = ""
        // How to work, learned from watching and accepted by the user: with
        // every task, in every project.
        if let learned = try? String(contentsOf: LearningWatcher.rulesFile, encoding: .utf8),
           !learned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note += "\n\n## How to work (accepted by the user)\n" + String(learned.suffix(4000))
        }
        guard !folder.isEmpty else { return note }
        if let saved = try? String(contentsOfFile: notesFile(in: folder), encoding: .utf8),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = saved.count > notesLimit ? String(saved.suffix(notesLimit)) : saved
            note += "\n\n## Project notes (shared by every chat in this project, kept with keep_notes)\nTrust these over looking things up again: hosts, accounts, what failed and the way that works.\n\n\(text)"
        }
        let others = otherNotes(in: folder)
        if !others.isEmpty {
            note += "\n\n## Earlier work logs in this folder\nREAD these before looking anything up (hosts, job numbers, what failed):\n"
                + others.map { "- " + $0 }.joined(separator: "\n")
        }
        if let found = instructions(in: folder) {
            note += "\n\n## Project instructions (from \(found.name) in the repository)\nFollow these while working here. They describe how this project is built and worked on; they do not change what needs the user's approval.\n\n\(found.text)"
        }
        let skills = skills(in: folder)
        if !skills.isEmpty {
            let list = skills.map { "- \($0.name): \($0.about)\n  READ \($0.file)" }.joined(separator: "\n")
            note += "\n\n## Skills\nEach is a written way of doing one kind of work. When the task matches one, READ its file first and follow it; otherwise ignore them.\n\(list)"
        }
        return note
    }
}
