import AppKit
import Foundation

/// The skills beyond the ones written by hand: which chats used which
/// skill, and skills fetched from GitHub repositories (Anthropic's own
/// anthropics/skills, obra/superpowers, or any repository with SKILL.md
/// folders), installed into Companion's skills folder.
///
/// A skill is guidance the agent reads; installing one runs nothing. Each
/// installed skill keeps a note of where it came from and its license.
@MainActor
final class SkillLibrary: ObservableObject {
    static let shared = SkillLibrary()

    // MARK: Which chats used which skill

    struct Use: Codable, Hashable {
        let skill: String
        let conversation: UUID
        var title: String
        var date: Date
    }

    @Published private(set) var uses: [Use] = []

    private var usesURL: URL { ContextStore.shared.baseDir.appendingPathComponent("skill-uses.json") }

    init() {
        if let data = try? Data(contentsOf: usesURL),
           let saved = try? JSONDecoder().decode([Use].self, from: data) {
            uses = saved
        }
    }

    /// The agent read a skill's file in a chat. Once per skill and chat;
    /// the date is the latest use.
    func record(_ skill: String, conversation: UUID, title: String) {
        if let index = uses.firstIndex(where: { $0.skill == skill && $0.conversation == conversation }) {
            uses[index].date = Date()
            uses[index].title = title
        } else {
            uses.append(Use(skill: skill, conversation: conversation, title: title, date: Date()))
        }
        if let data = try? JSONEncoder().encode(uses) { try? data.write(to: usesURL, options: .atomic) }
    }

    func chats(using skill: String) -> [Use] {
        uses.filter { $0.skill == skill }.sorted { $0.date > $1.date }
    }

    func skills(in conversation: UUID) -> [String] {
        uses.filter { $0.conversation == conversation }.map(\.skill)
    }

    /// The skill a SKILL.md path belongs to, by the name in its heading.
    static func name(ofSkillFile path: String, folder: String) -> String? {
        guard path.hasSuffix("/SKILL.md") || path == "SKILL.md" else { return nil }
        let full = (path as NSString).standardizingPath
        if let known = ProjectContext.skills(in: folder).first(where: { ($0.file as NSString).standardizingPath == full }) {
            return known.name
        }
        return ((full as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    // MARK: Skills on GitHub

    struct Remote: Identifiable, Hashable {
        let name: String
        let about: String
        /// The skill's folder in the repository.
        let path: String
        let repo: String
        let branch: String
        /// The license it comes under: its own file's first line, or the repository's.
        let license: String
        var id: String { repo + "/" + path }
    }

    /// Repositories worth knowing about, offered as one click.
    static let known: [(repo: String, about: String)] = [
        ("anthropics/skills", "Anthropic's skills: documents (Word, PDF, PowerPoint, Excel), design, web app testing, MCP servers, skill creation"),
        ("obra/superpowers", "A way of working for coding agents: brainstorming, planning, test-driven development, debugging, code review")
    ]

    @Published private(set) var remote: [Remote] = []
    @Published private(set) var browsing = ""
    @Published private(set) var loading = false
    @Published private(set) var installing: Set<String> = []
    @Published var note = ""
    /// Skills the model judged a fit for the work in hand.
    @Published var suggested: Set<String> = []

    /// "owner/repo", a GitHub link, or a link to a folder in one.
    static func parse(_ text: String) -> (owner: String, repo: String, path: String)? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        let parts = rest.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var path = ""
        // owner/repo/tree/branch/some/folder
        if parts.count > 4, parts[2] == "tree" { path = parts[4...].joined(separator: "/") }
        return (parts[0], parts[1].replacingOccurrences(of: ".git", with: ""), path)
    }

    private static func get(_ url: String) async throws -> Data {
        guard let link = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: link)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Companion", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 403 || http.statusCode == 429 {
                throw NSError(domain: "GitHub", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "GitHub's limit for looking without signing in was reached; try again within the hour."])
            }
            throw NSError(domain: "GitHub", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub answered \(http.statusCode) for \(link.path)."])
        }
        return data
    }

    /// Every file of a repository, and its default branch and license.
    private struct Tree {
        let branch: String
        let license: String
        let files: [(path: String, size: Int)]
    }

    private var trees: [String: Tree] = [:]

    private func tree(_ owner: String, _ repo: String) async throws -> Tree {
        let key = "\(owner)/\(repo)"
        if let known = trees[key] { return known }
        let info = try JSONSerialization.jsonObject(with: try await Self.get("https://api.github.com/repos/\(key)")) as? [String: Any] ?? [:]
        let branch = info["default_branch"] as? String ?? "main"
        let license = ((info["license"] as? [String: Any])?["spdx_id"] as? String).flatMap { $0 == "NOASSERTION" ? nil : $0 } ?? "see the repository"
        let listing = try JSONSerialization.jsonObject(
            with: try await Self.get("https://api.github.com/repos/\(key)/git/trees/\(branch)?recursive=1")) as? [String: Any] ?? [:]
        let files = (listing["tree"] as? [[String: Any]] ?? []).compactMap { item -> (path: String, size: Int)? in
            guard item["type"] as? String == "blob", let path = item["path"] as? String else { return nil }
            return (path, item["size"] as? Int ?? 0)
        }
        let tree = Tree(branch: branch, license: license, files: files)
        trees[key] = tree
        return tree
    }

    private static func raw(_ repo: String, _ branch: String, _ path: String) -> String {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "https://raw.githubusercontent.com/\(repo)/\(branch)/\(escaped)"
    }

    /// Lists the skills in a repository (or in one folder of it).
    func browse(_ text: String) {
        guard let found = Self.parse(text) else {
            note = "Give a repository as owner/name, such as anthropics/skills."
            return
        }
        let key = "\(found.owner)/\(found.repo)"
        browsing = key
        loading = true
        note = ""
        remote = []
        suggested = []
        Task { @MainActor in
            defer { loading = false }
            do {
                let tree = try await tree(found.owner, found.repo)
                let folders = tree.files
                    .filter { $0.path.hasSuffix("SKILL.md") && (found.path.isEmpty || $0.path.hasPrefix(found.path + "/") || $0.path.hasPrefix(found.path)) }
                    .map { ($0.path as NSString).deletingLastPathComponent }
                    .prefix(80)
                var list: [Remote] = []
                await withTaskGroup(of: Remote?.self) { group in
                    for folder in folders {
                        group.addTask { @MainActor in
                            let skillFile = folder.isEmpty ? "SKILL.md" : folder + "/SKILL.md"
                            guard let data = try? await Self.get(Self.raw(key, tree.branch, skillFile)),
                                  let text = String(data: data, encoding: .utf8) else { return nil }
                            let heading = Self.heading(text, fallback: (folder as NSString).lastPathComponent)
                            // A license file in the skill's own folder outranks the repository's.
                            var license = tree.license
                            if let own = tree.files.first(where: {
                                ($0.path as NSString).deletingLastPathComponent == folder
                                    && ($0.path as NSString).lastPathComponent.uppercased().hasPrefix("LICENSE")
                            }), let data = try? await Self.get(Self.raw(key, tree.branch, own.path)),
                               let first = String(data: data, encoding: .utf8)?
                                .split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                                license = String(first.trimmingCharacters(in: .whitespaces).prefix(80))
                            }
                            return Remote(name: heading.name, about: heading.about, path: folder, repo: key,
                                          branch: tree.branch, license: license)
                        }
                    }
                    for await item in group { if let item { list.append(item) } }
                }
                guard browsing == key else { return }
                remote = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if remote.isEmpty { note = "No SKILL.md folders found in \(key)." }
            } catch {
                note = error.localizedDescription
            }
        }
    }

    /// "name:" and "description:" from a SKILL.md's heading block.
    private static func heading(_ text: String, fallback: String) -> (name: String, about: String) {
        var name = fallback, about = ""
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                if key == "name", !value.isEmpty { name = value }
                if key == "description", !value.isEmpty { about = value }
            }
        }
        return (name, String(about.prefix(300)))
    }

    /// Where an installed skill lives in Companion's folder.
    func folder(for skill: Remote) -> URL {
        let name = (skill.path as NSString).lastPathComponent
        return ProjectContext.skillsFolder.appendingPathComponent(name.isEmpty ? skill.name : name, isDirectory: true)
    }

    func isInstalled(_ skill: Remote) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: skill).appendingPathComponent("SKILL.md").path)
    }

    /// Downloads every file of the skill's folder into Companion's skills folder.
    func install(_ skill: Remote) {
        guard !installing.contains(skill.id), let parts = Self.parse(skill.repo) else { return }
        installing.insert(skill.id)
        Task { @MainActor in
            defer { installing.remove(skill.id) }
            do {
                let tree = try await tree(parts.owner, parts.repo)
                let prefix = skill.path.isEmpty ? "" : skill.path + "/"
                let files = tree.files.filter { prefix.isEmpty ? !$0.path.contains("/") : $0.path.hasPrefix(prefix) }
                guard files.count <= 300, files.reduce(0, { $0 + $1.size }) <= 20_000_000 else {
                    note = "\(skill.name) is too large to install here (over 300 files or 20 MB)."
                    return
                }
                let target = folder(for: skill)
                let fm = FileManager.default
                for file in files {
                    let relative = String(file.path.dropFirst(prefix.count))
                    // Nothing may land outside the skill's folder.
                    guard !relative.contains(".."), !relative.hasPrefix("/") else { continue }
                    let data = try await Self.get(Self.raw(skill.repo, tree.branch, file.path))
                    let destination = target.appendingPathComponent(relative)
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: destination, options: .atomic)
                }
                let source: [String: Any] = ["repository": skill.repo, "branch": tree.branch, "path": skill.path,
                                             "license": skill.license, "installed": ISO8601DateFormatter().string(from: Date())]
                if let data = try? JSONSerialization.data(withJSONObject: source, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: target.appendingPathComponent(".companion-source.json"))
                }
                note = "Installed \(skill.name). The agent now has it in every chat."
                objectWillChange.send()
            } catch {
                note = "Could not install \(skill.name): \(error.localizedDescription)"
            }
        }
    }

    /// Where an installed skill came from, when it was fetched from GitHub.
    static func source(of skill: Skill) -> (repo: String, license: String)? {
        let folder = (skill.file as NSString).deletingLastPathComponent
        let url = URL(fileURLWithPath: folder).appendingPathComponent(".companion-source.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repo = object["repository"] as? String else { return nil }
        return (repo, object["license"] as? String ?? "")
    }

    /// Moves one of the user's own skills to the Trash.
    func remove(_ skill: Skill) {
        guard !skill.fromProject else { return }
        let folder = URL(fileURLWithPath: (skill.file as NSString).deletingLastPathComponent)
        guard folder.path.hasPrefix(ProjectContext.skillsFolder.path) else {
            note = "\(skill.name) is not in Companion's skills folder, so it is left where it is."
            return
        }
        do {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            note = "Moved \(skill.name) to the Trash."
            objectWillChange.send()
        } catch {
            note = "Could not remove \(skill.name): \(error.localizedDescription)"
        }
    }
}
