import AppKit
import Foundation

/// One of a plan's limits as the tool reports it: how much of a window
/// (five hours, a week) is used and when it starts over.
struct PlanLimit: Identifiable, Equatable, Sendable {
    /// The window, as the tool names it ("five_hour", "primary").
    let id: String
    /// The window as shown: "5 hours", "Week".
    let name: String
    /// The share used, from 0 to 1. A tool may name a window and when it
    /// starts over without saying how much of it is used.
    let used: Double?
    let resets: Date?

    /// What is left, in whole percent.
    var left: Int? { used.map { Int(((1 - min(max($0, 0), 1)) * 100).rounded()) } }

    /// What is left, in words.
    var summary: String { left.map { "\($0)% left" } ?? "within limit" }

    /// When the window starts over: a time today, a day and time later.
    var restart: String? {
        guard let resets, resets > Date() else { return nil }
        return resets.timeIntervalSinceNow < 86_400
            ? resets.formatted(date: .omitted, time: .shortened)
            : resets.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// The limits in a tool's JSON, wherever they sit in it. Two shapes are
    /// known: Claude Code's `rate_limit_info`, sent along with a reply, and
    /// the `rateLimits` Codex answers with when asked.
    static func windows(in json: Any) -> [PlanLimit] {
        if let object = json as? [String: Any] {
            if let info = object["rate_limit_info"] as? [String: Any] { return claude(info) }
            if let limits = object["rateLimits"] as? [String: Any] { return codex(limits) }
            for value in object.values {
                let found = windows(in: value)
                if !found.isEmpty { return found }
            }
        } else if let list = json as? [Any] {
            for item in list {
                let found = windows(in: item)
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    private static func claude(_ info: [String: Any]) -> [PlanLimit] {
        var found: [PlanLimit] = []
        // Every window at once, when the tool gives them.
        if let all = info["unifiedWindows"] as? [String: Any] {
            let order = ["five_hour", "seven_day"]
            let keys = all.keys.sorted {
                (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1)
            }
            for key in keys {
                guard let window = all[key] as? [String: Any],
                      let used = number(window["utilization"]) else { continue }
                found.append(PlanLimit(id: key, name: name(of: key), used: used, resets: date(window["resetsAt"])))
            }
        }
        // Otherwise only the window the reply counts against. How much of
        // it is used is said once it is close; before that only when it
        // starts over.
        if found.isEmpty, let key = info["rateLimitType"] as? String {
            let used = number(info["utilization"]) ?? (info["status"] as? String == "rejected" ? 1 : nil)
            found.append(PlanLimit(id: key, name: name(of: key), used: used, resets: date(info["resetsAt"])))
        }
        return found
    }

    private static func codex(_ limits: [String: Any]) -> [PlanLimit] {
        ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any],
                  let percent = number(window["usedPercent"]) else { return nil }
            let minutes = number(window["windowDurationMins"]).map { Int($0) }
            let used: Double? = percent / 100
            return PlanLimit(id: key, name: minutes.map(name(ofMinutes:)) ?? key.capitalized,
                             used: used, resets: date(window["resetsAt"]))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// A time since 1970, given in seconds or in milliseconds.
    private static func date(_ value: Any?) -> Date? {
        guard let stamp = number(value), stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp > 100_000_000_000 ? stamp / 1000 : stamp)
    }

    private static func name(of key: String) -> String {
        switch key {
        case "five_hour": return "5 hours"
        case "seven_day": return "Week"
        default:
            // "seven_day_opus" is the week's limit for one model.
            if key.hasPrefix("seven_day_") {
                return "Week, " + key.dropFirst(10).replacingOccurrences(of: "_", with: " ").capitalized
            }
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func name(ofMinutes minutes: Int) -> String {
        if minutes == 10_080 { return "Week" }
        if minutes > 0, minutes % 1_440 == 0 { return "\(minutes / 1_440) days" }
        if minutes > 0, minutes % 60 == 0 { return "\(minutes / 60) hours" }
        return "\(minutes) min"
    }
}

/// A command-line agent that signs in with a subscription (Claude Code,
/// Codex, Antigravity, or any other tool described the same way). Companion
/// never sees the sign-in: it runs the vendor's own tool, hands it the
/// conversation on standard input and reads the answer from its output.
///
/// Adapters are data, not code. The built-in ones are written to
/// `cli-agents.json` in Companion's folder the first time; adding an entry
/// there adds a tool, with no rebuild.
struct CLIAgentAdapter: Codable, Identifiable, Equatable {
    /// How the tool's output is read.
    enum Format: String, Codable {
        /// Claude Code's `--output-format stream-json`.
        case claudeStream = "claude-stream"
        /// Codex's `exec --json`.
        case codexJSON = "codex-json"
        /// Gemini CLI's `--output-format stream-json`.
        case geminiStream = "gemini-stream"
        /// Antigravity CLI's `--output-format stream-json`.
        case antigravityStream = "antigravity-stream"
        /// Plain text: whatever the tool prints is the answer.
        case text
    }

    var id: String
    var name: String
    /// The program, as typed in a terminal.
    var command: String
    /// Its arguments. `{instruction}` is replaced by the one-line
    /// instruction; the conversation itself goes in on standard input.
    var arguments: [String]
    /// Added when a model is chosen; `{model}` is replaced by its name.
    var modelArguments: [String]?
    var format: Format
    /// Models to offer. Empty leaves the choice to the tool.
    var models: [String]?
    /// What to tell the user when the tool is there but not signed in.
    var signIn: String?
    /// Shell lines that install the tool, run in Terminal where the user
    /// sees them.
    var install: String?
    /// The command that starts the tool's own sign-in.
    var signInCommand: String?
    /// Arguments that make the tool say whether it is signed in, by
    /// exiting with 0 when it is.
    var statusArguments: [String]?
    /// For a tool that does not read the conversation from standard
    /// input: the whole of it is passed where `{instruction}` stands.
    var promptInArgument: Bool?
    /// Arguments that make the tool print the models it offers.
    var modelsArguments: [String]?
    /// A line to send the tool, once started with those arguments, that
    /// makes it answer with its models; the tool is stopped as soon as
    /// `modelsUntil` shows in what it prints.
    var modelsInput: String?
    var modelsUntil: String?
    /// A file the tool keeps its list of models in (`~` is the home
    /// folder): JSON, read for every "slug" in it.
    var modelsFile: String?
    /// The effort levels the tool takes, lowest first.
    var efforts: [String]?
    /// Added when an effort is chosen; `{effort}` is replaced by it.
    var effortArguments: [String]?
    /// Arguments that start the tool so that it can be asked what is left
    /// of the plan's limits; `limitsInput` is sent to it and it is stopped
    /// once `limitsUntil` shows in its answer. A tool that says so along
    /// with each reply needs none of these.
    var limitsArguments: [String]?
    var limitsInput: String?
    var limitsUntil: String?

    static let builtIn: [CLIAgentAdapter] = [
        // Reads are allowed, anything that would ask is denied: changes to
        // files go through Companion's own agent, which asks first.
        CLIAgentAdapter(id: "claude-code", name: "Claude Code", command: "claude",
                        arguments: ["-p", "{instruction}", "--output-format", "stream-json", "--verbose",
                                    "--include-partial-messages", "--permission-mode", "dontAsk"],
                        modelArguments: ["--model", "{model}"],
                        format: .claudeStream,
                        // No names are written in: only what the tool
                        // itself lists is offered.
                        models: [""],
                        signIn: "Run `claude` in Terminal once and sign in with your Claude account.",
                        install: "curl -fsSL https://claude.ai/install.sh | bash",
                        // Its own sign-in command: no session is started,
                        // so there is no folder to trust.
                        signInCommand: "claude auth status >/dev/null 2>&1 && echo 'Already signed in to Claude.' || claude auth login",
                        statusArguments: ["auth", "status"],
                        // It has no command that lists models, but it
                        // names them when a session is opened the way its
                        // own SDK opens one.
                        modelsArguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
                        modelsInput: "{\"type\":\"control_request\",\"request_id\":\"companion-models\",\"request\":{\"subtype\":\"initialize\"}}",
                        modelsUntil: "control_response",
                        efforts: ["low", "medium", "high", "xhigh", "max"],
                        effortArguments: ["--effort", "{effort}"]),
        CLIAgentAdapter(id: "codex", name: "Codex", command: "codex",
                        arguments: ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "{instruction}"],
                        modelArguments: ["-m", "{model}"],
                        format: .codexJSON,
                        models: [""],
                        signIn: "Run `codex` in Terminal once and sign in with your ChatGPT account.",
                        install: "if command -v brew >/dev/null; then brew install --cask codex; elif command -v npm >/dev/null; then npm install -g @openai/codex; else echo 'Homebrew (brew.sh) or Node.js (nodejs.org) is needed to install Codex. Install one, then try again.'; fi",
                        signInCommand: "codex login",
                        statusArguments: ["login", "status"],
                        modelsFile: "~/.codex/models_cache.json",
                        efforts: ["minimal", "low", "medium", "high", "xhigh"],
                        effortArguments: ["-c", "model_reasoning_effort={effort}"],
                        // Its own local server answers what is left of
                        // the plan, the way its apps ask it.
                        limitsArguments: ["app-server"],
                        limitsInput: "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"companion\",\"version\":\"1.0\"}}}\n{\"method\":\"initialized\",\"params\":{}}\n{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}",
                        limitsUntil: "usedPercent"),
        // Google's tool for personal Gemini plans; it took over from
        // Gemini CLI for them.
        CLIAgentAdapter(id: "antigravity", name: "Antigravity", command: "agy",
                        arguments: ["-p", "{instruction}", "--output-format", "stream-json"],
                        modelArguments: ["--model", "{model}"],
                        format: .antigravityStream,
                        models: [""],
                        signIn: "Run `agy` in Terminal once and sign in with your Google account.",
                        install: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
                        signInCommand: "agy",
                        promptInArgument: true,
                        modelsArguments: ["models"],
                        efforts: ["low", "medium", "high"],
                        effortArguments: ["--effort", "{effort}"])
    ]
}

/// The adapters Companion knows and which of their tools are on this Mac.
@MainActor
final class CLIAgents: ObservableObject {
    static let shared = CLIAgents()

    @Published private(set) var adapters: [CLIAgentAdapter] = CLIAgentAdapter.builtIn
    /// Where each installed tool lives, by adapter id.
    @Published private(set) var paths: [String: String] = [:]
    @Published private(set) var checking = false
    /// The PATH of the user's own shell, so a tool finds what it needs
    /// (node, for one) when Companion starts it.
    private(set) var shellPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    private var checked = false

    /// Built-in tools that have been withdrawn.
    private static let retired: Set<String> = ["gemini"]

    /// The file adapters are kept in, there to be added to.
    let file: URL = ContextStore.shared.baseDir.appendingPathComponent("cli-agents.json")

    private init() {
        load()
        restoreFound()
        // Looked for afresh in the background from launch, so the first
        // message never waits on the user's shell starting.
        Task { @MainActor in self.check() }
    }

    // MARK: What was found last time

    private static let foundKey = "cliAgentsFound"

    /// Where the tools were when last looked for, used at once while a
    /// fresh look runs: a tool still there is ready without asking the
    /// shell (which can take seconds with a heavy profile).
    private func restoreFound() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.foundKey) else { return }
        if let found = saved["paths"] as? [String: String] {
            paths = found.filter { FileManager.default.isExecutableFile(atPath: $0.value) }
        }
        if let path = saved["shellPath"] as? String, !path.isEmpty { shellPath = path }
    }

    private func saveFound() {
        UserDefaults.standard.set(["paths": paths, "shellPath": shellPath], forKey: Self.foundKey)
    }

    var installed: [CLIAgentAdapter] { adapters.filter { paths[$0.id] != nil } }

    func adapter(_ id: String) -> CLIAgentAdapter? { adapters.first { $0.id == id } }

    func name(of id: String) -> String { adapter(id)?.name ?? id }

    /// Reads the adapters file, writing the built-in ones the first time.
    /// Built-in adapters missing from an older file are added back.
    func load() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([CLIAgentAdapter].self, from: data), !saved.isEmpty {
            // Gemini CLI is gone: Google moved personal plans to
            // Antigravity. An entry left in an older file is dropped.
            let saved = saved.filter { !Self.retired.contains($0.id) }
            let known = Set(saved.map(\.id))
            // A file written by an older version lacks what was added
            // since: the built-in adapter fills in what is missing.
            let filled = saved.map { adapter -> CLIAgentAdapter in
                guard let base = CLIAgentAdapter.builtIn.first(where: { $0.id == adapter.id }) else { return adapter }
                var adapter = adapter
                // How a built-in tool is installed and signed in to is
                // Companion's to keep right, so it always comes from here.
                adapter.install = base.install
                adapter.signInCommand = base.signInCommand
                adapter.statusArguments = base.statusArguments
                adapter.name = base.name
                adapter.models = base.models
                adapter.modelsArguments = base.modelsArguments
                adapter.modelsInput = base.modelsInput
                adapter.modelsUntil = base.modelsUntil
                adapter.modelsFile = base.modelsFile
                adapter.efforts = base.efforts
                adapter.effortArguments = base.effortArguments
                adapter.limitsArguments = base.limitsArguments
                adapter.limitsInput = base.limitsInput
                adapter.limitsUntil = base.limitsUntil
                adapter.signIn = adapter.signIn ?? base.signIn
                return adapter
            }
            adapters = filled + CLIAgentAdapter.builtIn.filter { !known.contains($0.id) }
        } else {
            adapters = CLIAgentAdapter.builtIn
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            if let data = try? encoder.encode(adapters) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// Looks for each tool once; `again` looks afresh (after an install).
    func check(again: Bool = false) {
        guard !checking, again || !checked else { return }
        checking = true
        checked = true
        if again { load() }
        let commands = adapters.map { ($0.id, $0.command) }
        Task {
            let found = await Self.find(commands)
            // What was picked by hand wins, while it is still there.
            var paths = found.paths
            for (id, path) in self.chosen where FileManager.default.isExecutableFile(atPath: path) {
                paths[id] = path
            }
            self.paths = paths
            self.refreshSignIns()
            self.refreshModels()
            if let path = found.shellPath { self.shellPath = path }
            self.saveFound()
            self.checking = false
        }
    }

    /// Waits for the first look to finish, for a request that arrives
    /// before it has.
    func ready() async {
        check()
        // Known from last time: go now; the fresh look finishes behind.
        if !paths.isEmpty { return }
        while checking {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    /// Asks the user's own shell where each tool is, since an app started
    /// from the Dock does not have the shell's PATH. Falls back to the
    /// usual places.
    private static func find(_ commands: [(id: String, command: String)]) async -> (paths: [String: String], shellPath: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // The answers are written to a file, not printed: a shell
                // theme that takes over the output while it starts (as
                // Powerlevel10k's instant prompt does) would swallow them.
                let report = FileManager.default.temporaryDirectory
                    .appendingPathComponent("companion-tools-\(UUID().uuidString).txt")
                var script = "print -r -- \"__CP__$PATH\" >> \"$COMPANION_REPORT\"\n"
                // Where npm puts what it installs for everyone, which is
                // not always on the PATH.
                script += "print -r -- \"__NP__$(npm prefix -g 2>/dev/null)\" >> \"$COMPANION_REPORT\"\n"
                for (_, command) in commands where command.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) {
                    script += "print -r -- \"__CB__\(command)=$(whence -p \(command) 2>/dev/null)\" >> \"$COMPANION_REPORT\"\n"
                    // Installed as an alias: the alias says where it is.
                    script += "print -r -- \"__CA__\(command)=$(alias \(command) 2>/dev/null)\" >> \"$COMPANION_REPORT\"\n"
                }
                // The shell as the user has it (with its startup files);
                // if that gives nothing, a plain login shell.
                var output = ""
                for flags in ["-lic", "-lc"] where output.isEmpty {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = [flags, script]
                    var environment = ProcessInfo.processInfo.environment
                    environment["COMPANION_REPORT"] = report.path
                    process.environment = environment
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    guard (try? process.run()) != nil else { continue }
                    // A shell profile that hangs must not hang the app.
                    let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: limit)
                    process.waitUntilExit()
                    limit.cancel()
                    output = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
                }
                try? FileManager.default.removeItem(at: report)

                var shellPath: String?
                var npmFolder: String?
                var located: [String: String] = [:]
                for line in output.split(separator: "\n") {
                    if line.hasPrefix("__CP__") {
                        shellPath = String(line.dropFirst(6))
                    } else if line.hasPrefix("__NP__") {
                        let prefix = String(line.dropFirst(6))
                        if prefix.hasPrefix("/") { npmFolder = prefix + "/bin" }
                    } else if line.hasPrefix("__CB__") {
                        let parts = line.dropFirst(6).split(separator: "=", maxSplits: 1)
                        if parts.count == 2, parts[1].hasPrefix("/") {
                            located[String(parts[0])] = String(parts[1])
                        }
                    } else if line.hasPrefix("__CA__") {
                        // claude='/Users/me/.claude/local/claude'
                        let parts = line.dropFirst(6).split(separator: "=", maxSplits: 2)
                        if parts.count == 3 {
                            var target = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                            if target.hasPrefix("~") { target = NSHomeDirectory() + String(target.dropFirst()) }
                            if target.hasPrefix("/"), located[String(parts[0])] == nil {
                                located[String(parts[0])] = target
                            }
                        }
                    }
                }

                // Then the places these tools are usually installed, and
                // every folder on the shell's PATH.
                let home = NSHomeDirectory()
                var folders = ["\(home)/.claude/local", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                               "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/Library/pnpm",
                               "\(home)/.yarn/bin", "/opt/homebrew/bin", "/usr/local/bin"]
                // Node installed through nvm or fnm: one folder a version.
                for root in ["\(home)/.nvm/versions/node", "\(home)/.local/share/fnm/node-versions",
                             "\(home)/Library/Application Support/fnm/node-versions"] {
                    let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted().reversed()
                    for version in versions {
                        folders.append("\(root)/\(version)/bin")
                        folders.append("\(root)/\(version)/installation/bin")
                    }
                }
                if let npmFolder { folders.insert(npmFolder, at: 0) }
                folders += (shellPath ?? "").split(separator: ":").map(String.init)
                var paths: [String: String] = [:]
                for (id, command) in commands {
                    // An adapter may name the program by its full path.
                    let candidates = (command.hasPrefix("/") ? [command] : [])
                        + [located[command]].compactMap { $0 }
                        + folders.map { "\($0)/\(command)" }
                    if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                        paths[id] = path
                    }
                }
                // Tools started by Companion need node and friends: the
                // folders the tools were found in are put on their PATH.
                var path = shellPath ?? (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
                for folder in Set(paths.values.map { ($0 as NSString).deletingLastPathComponent }) where !path.split(separator: ":").contains(Substring(folder)) {
                    path = folder + ":" + path
                }
                for folder in ["/opt/homebrew/bin", "/usr/local/bin"] where !path.split(separator: ":").contains(Substring(folder)) {
                    path += ":" + folder
                }
                let shellPathFound: String? = path
                continuation.resume(returning: (paths: paths, shellPath: shellPathFound))
            }
        }
    }

    // MARK: Guided setup

    /// The tool being set up, while Companion waits for it to appear.
    @Published private(set) var settingUp: String?

    /// Sets a tool up in Terminal, where every step is in plain sight:
    /// installs it when it is missing, then starts its own sign-in, which
    /// opens the browser. Companion keeps looking meanwhile, and `done`
    /// runs once the tool is there.
    func setUp(_ adapter: CLIAgentAdapter, done: @escaping () -> Void) {
        let missing = paths[adapter.id] == nil
        var lines = ["#!/bin/zsh -l", "clear",
                     "echo 'Companion: setting up \(adapter.name)'", "echo"]
        if missing, let install = adapter.install {
            lines += ["echo 'This will install it with:'",
                      "echo \(Shell.quote("  " + install))", "echo",
                      "read '?Press Return to continue, or close this window to cancel. '",
                      install,
                      // A new install is not on this shell's PATH yet.
                      "export PATH=\"$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH\"",
                      // npm's own folder is not always on the PATH either.
                      "command -v npm >/dev/null && export PATH=\"$(npm prefix -g 2>/dev/null)/bin:$PATH\"",
                      "hash -r", "echo"]
        }
        if let signIn = adapter.signInCommand {
            // Started in an empty folder of its own, so a tool that asks
            // whether to trust the folder is asking about nothing.
            lines += ["command -v npm >/dev/null && export PATH=\"$(npm prefix -g 2>/dev/null)/bin:$PATH\"",
                      "mkdir -p \"$HOME/.companion-signin\" && cd \"$HOME/.companion-signin\"",
                      "echo 'Now sign in with your subscription. Your browser will open.'",
                      "echo 'If the tool stays open once you are signed in, quit it (Ctrl+C twice, or /exit).'",
                      "echo", signIn, "echo"]
        }
        lines += ["echo 'Done. You can close this window and go back to Companion.'"]
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("Set up \(adapter.name).command")
        do {
            try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return
        }
        NSWorkspace.shared.open(script)

        // Look for it every few seconds, for up to ten minutes.
        settingUp = adapter.id
        Task {
            for _ in 0..<200 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.settingUp == adapter.id else { return }
                if missing {
                    self.check(again: true)
                    while self.checking { try? await Task.sleep(nanoseconds: 100_000_000) }
                }
                guard let path = self.paths[adapter.id] else { continue }
                // There; now wait until it says it is signed in, which is
                // when the browser step has been finished.
                if let arguments = adapter.statusArguments {
                    let signed = await Self.succeeds(path, arguments, shellPath: self.shellPath)
                    self.signedIn[adapter.id] = signed
                    if !signed { continue }
                }
                self.settingUp = nil
                done()
                return
            }
            self.settingUp = nil
        }
    }

    func stopSettingUp() { settingUp = nil }

    // MARK: Models

    /// The models each tool says it offers, as last asked.
    @Published private(set) var listed: [String: [String]] = [:]
    /// The tool's own name for each of its models, where it gives one,
    /// by tool and then by model.
    @Published private(set) var labels: [String: [String: String]] = [:]

    /// What the tool says about each of its models, the same way. This is
    /// where a tool that lists short names ("opus") gives the version.
    @Published private(set) var abouts: [String: [String: String]] = [:]

    /// A model's name as the tool itself gives it, if it does.
    func label(of model: String, for id: String) -> String? {
        labels[id]?[model]
    }

    /// A model's name with its version ("Opus 4.7"), read off the start of
    /// the tool's own description of it. Empty asks about its default.
    func version(of model: String, for id: String) -> String? {
        guard let about = abouts[id]?[model.isEmpty ? "default" : model] else { return nil }
        let lead = (about.components(separatedBy: " · ").first ?? "").trimmingCharacters(in: .whitespaces)
        guard !lead.isEmpty, lead.count <= 40, lead.contains(where: \.isNumber) else { return nil }
        return lead
    }

    /// A model as shown: with its version when the tool gives it, else the
    /// tool's name for it, else its identifier said plainly.
    func title(of model: String, for id: String) -> String {
        guard !model.isEmpty else { return "Auto" }
        return version(of: model, for: id) ?? label(of: model, for: id) ?? ModelName.prettyTool(model)
    }

    /// The models to offer for a tool: its own default first, then what it
    /// lists itself, then the names Companion knows for it.
    func models(for id: String) -> [String] {
        var all = [""]
        for model in (listed[id] ?? []) + (adapter(id)?.models ?? []) where !model.isEmpty && !all.contains(model) {
            all.append(model)
        }
        return all
    }

    /// Asks every installed tool that can say which models it offers.
    func refreshModels() {
        let shellPath = self.shellPath
        for adapter in installed {
            let id = adapter.id
            if let file = adapter.modelsFile {
                let path = (file as NSString).expandingTildeInPath
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    var found: [String] = []
                    Self.slugs(in: json, into: &found)
                    if !found.isEmpty { listed[id] = found }
                }
            }
            if let arguments = adapter.modelsArguments, let path = paths[id] {
                let input = adapter.modelsInput
                let until = adapter.modelsUntil
                Task {
                    let output = await Self.output(of: path, arguments, shellPath: shellPath, input: input, until: until)
                    // A tool that answers in JSON names its models as
                    // "value"s under "models"; otherwise the names are
                    // read off what it printed.
                    var found: [String] = []
                    var names: [String: String] = [:]
                    var abouts: [String: String] = [:]
                    for line in output.split(separator: "\n") {
                        guard let data = String(line).data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) else { continue }
                        Self.modelValues(in: json, under: false, into: &found, names: &names, abouts: &abouts)
                    }
                    if !names.isEmpty { self.labels[id] = names }
                    if !abouts.isEmpty { self.abouts[id] = abouts }
                    if found.isEmpty, input == nil { found = Self.modelNames(in: output) }
                    found.removeAll { $0 == "default" }
                    if !found.isEmpty { self.listed[id] = found }
                }
            }
        }
    }

    /// Every "slug" in a tool's own list of models, in order.
    private static func slugs(in json: Any, into found: inout [String]) {
        if let object = json as? [String: Any] {
            if let slug = object["slug"] as? String, !found.contains(slug) { found.append(slug) }
            for (key, value) in object where key != "slug" { slugs(in: value, into: &found) }
        } else if let list = json as? [Any] {
            for item in list { slugs(in: item, into: &found) }
        }
    }

    /// Every model named under a "models" list in a tool's JSON answer.
    private static func modelValues(in json: Any, under models: Bool, into found: inout [String],
                                    names: inout [String: String], abouts: inout [String: String]) {
        if let object = json as? [String: Any] {
            if models, let value = (object["value"] ?? object["id"] ?? object["slug"]) as? String, !found.contains(value) {
                found.append(value)
                // The tool's own name for it, when it gives one.
                if let name = (object["displayName"] ?? object["display_name"] ?? object["name"]) as? String,
                   !name.isEmpty {
                    names[value] = name
                }
                if let about = object["description"] as? String, !about.isEmpty {
                    abouts[value] = about
                }
            }
            for (key, value) in object {
                modelValues(in: value, under: key == "models", into: &found, names: &names, abouts: &abouts)
            }
        } else if let list = json as? [Any] {
            for item in list {
                if models, let name = item as? String, !found.contains(name) { found.append(name) }
                modelValues(in: item, under: models, into: &found, names: &names, abouts: &abouts)
            }
        }
    }

    /// Model names in what a tool printed: on each line, the first word
    /// that looks like one ("gemini-3-pro", "gpt-5.1-codex").
    private static func modelNames(in output: String) -> [String] {
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: { " \t|│*•".contains($0) })
            guard let name = words.first(where: { word in
                word.count >= 4 && word.contains("-") && word.first?.isLetter == true
                    && word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-._".contains($0)) }
            }) else { continue }
            if !names.contains(String(name)) { names.append(String(name)) }
        }
        return names
    }

    /// What a tool prints for the given arguments. With `input`, that
    /// line is sent to it first and it is stopped once `until` shows in
    /// its output (or after a while).
    private static func output(of path: String, _ arguments: [String], shellPath: String,
                               input: String? = nil, until: String? = nil) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = shellPath
                environment["NO_COLOR"] = "1"
                process.environment = environment
                // Somewhere empty, so nothing of the user's is loaded.
                let neutral = FileManager.default.temporaryDirectory.appendingPathComponent("companion-cli", isDirectory: true)
                try? FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
                process.currentDirectoryURL = neutral
                let pipe = Pipe()
                let stdin = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = input == nil ? FileHandle.nullDevice : stdin
                let collected = ErrorText()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                    } else {
                        collected.add(chunk)
                    }
                }
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: "")
                    return
                }
                if let input {
                    try? stdin.fileHandleForWriting.write(contentsOf: Data((input + "\n").utf8))
                }
                // Wait for it to finish, or for the answer being looked
                // for, for at most fifteen seconds.
                let deadline = Date().addingTimeInterval(15)
                while process.isRunning, Date() < deadline {
                    if let until, collected.text.contains(until) { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                // A moment for the rest of that line to arrive.
                if process.isRunning {
                    Thread.sleep(forTimeInterval: 0.2)
                    try? stdin.fileHandleForWriting.close()
                    process.terminate()
                }
                process.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.05)
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: collected.text)
            }
        }
    }

    // MARK: What is left of the plan

    /// Each tool's limits as it last reported them. A tool that does not
    /// say has none here.
    @Published private(set) var limits: [String: [PlanLimit]] = [:]

    /// Takes what a tool just reported. A report of one window leaves the
    /// others as they were.
    func noteLimits(_ found: [PlanLimit], for id: String) {
        var all = limits[id] ?? []
        for limit in found {
            if let index = all.firstIndex(where: { $0.id == limit.id }) {
                all[index] = limit
            } else {
                all.append(limit)
            }
        }
        limits[id] = all
    }

    /// Why a tool that was asked has no limits to show: the end of what
    /// it answered instead, kept so the trouble can be seen.
    @Published private(set) var limitsTrouble: [String: String] = [:]
    /// When the tools were last asked.
    private var limitsAsked = Date.distantPast

    /// Asks every installed tool that can be asked, unless they were asked
    /// within `seconds`. One that reports with its replies is heard there.
    func refreshLimits(olderThan seconds: TimeInterval = 0) {
        guard Date().timeIntervalSince(limitsAsked) >= seconds else { return }
        limitsAsked = Date()
        let shellPath = self.shellPath
        for adapter in installed {
            guard let arguments = adapter.limitsArguments, let path = paths[adapter.id] else { continue }
            let id = adapter.id
            let input = adapter.limitsInput
            let until = adapter.limitsUntil
            Task {
                let output = await Self.output(of: path, arguments, shellPath: shellPath, input: input, until: until)
                var found: [PlanLimit] = []
                for line in output.split(separator: "\n") where found.isEmpty {
                    guard let data = String(line).data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) else { continue }
                    found = PlanLimit.windows(in: json)
                }
                if found.isEmpty {
                    let tail = output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(240)
                    self.limitsTrouble[id] = tail.isEmpty ? "It gave no answer." : String(tail)
                } else {
                    self.limitsTrouble[id] = nil
                    self.noteLimits(found, for: id)
                }
            }
        }
    }

    /// What is left, on one line: "5 hours 76% left · Week 87% left".
    func limitsLine(for id: String) -> String? {
        guard let all = limits[id], !all.isEmpty else { return nil }
        return all.map { "\($0.name) \($0.summary)" }.joined(separator: " · ")
    }

    /// The same with when each window starts over, a line each.
    func limitsDetail(for id: String) -> String? {
        guard let all = limits[id], !all.isEmpty else { return nil }
        return all.map { limit in
            "\(limit.name): \(limit.summary)" + (limit.restart.map { ", starts over \($0)" } ?? "")
        }.joined(separator: "\n")
    }

    // MARK: Signed in or not

    /// Whether each tool says it is signed in. A tool that cannot say is
    /// left out.
    @Published private(set) var signedIn: [String: Bool] = [:]

    /// Asks every installed tool that can say whether it is signed in.
    func refreshSignIns() {
        let asks = adapters.compactMap { adapter -> (String, String, [String])? in
            guard let path = paths[adapter.id], let arguments = adapter.statusArguments else { return nil }
            return (adapter.id, path, arguments)
        }
        let shellPath = self.shellPath
        Task {
            for (id, path, arguments) in asks {
                let ok = await Self.succeeds(path, arguments, shellPath: shellPath)
                self.signedIn[id] = ok
            }
        }
    }

    private static func succeeds(_ path: String, _ arguments: [String], shellPath: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = shellPath
                process.environment = environment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: false)
                    return
                }
                let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: limit)
                process.waitUntilExit()
                limit.cancel()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    // MARK: Trying it

    /// What the last try of each tool came back with, by adapter id.
    @Published private(set) var trials: [String: String] = [:]
    @Published private(set) var trying: String?

    /// Sends the tool one short message, exactly as a chat would, and
    /// keeps what came back: its answer, or the reason it gave none.
    func tryOut(_ adapter: CLIAgentAdapter, model: String) {
        guard trying == nil else { return }
        trying = adapter.id
        trials[adapter.id] = nil
        Task {
            let request = ChatRequest(system: "Answer in one short sentence.", user: "Say hello and name the model you are.")
            let config = LLMConfig(kind: .subscription, apiKey: "", model: adapter.id, baseURL: model)
            var answer = ""
            do {
                for try await piece in try await CLIAgentClient.stream(request, config: config) {
                    answer += piece
                }
                let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                self.trials[adapter.id] = text.isEmpty ? "It ran but said nothing." : "Works. It said: \(text.prefix(200))"
                // An answer is proof enough of being signed in.
                if !text.isEmpty { self.signedIn[adapter.id] = true }
            } catch {
                self.trials[adapter.id] = "Did not work. \(error.localizedDescription)"
            }
            self.trying = nil
        }
    }

    // MARK: Chosen by hand

    /// Where the user said a tool is, when it could not be found.
    private static let chosenKey = "cliAgentChosenPaths"

    private var chosen: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.chosenKey) as? [String: String] ?? [:]
    }

    /// Remembers where a tool is, as picked by the user.
    func locate(_ id: String, at path: String) {
        var all = chosen
        all[id] = path
        UserDefaults.standard.set(all, forKey: Self.chosenKey)
        paths[id] = path
        let folder = (path as NSString).deletingLastPathComponent
        if !shellPath.split(separator: ":").contains(Substring(folder)) {
            shellPath = folder + ":" + shellPath
        }
    }
}

enum CLIAgentClient {
    private static let instruction = "Follow the instructions and answer the last user message of the conversation given on standard input. Reply with the answer only."

    /// What the run needs, gathered on the main actor.
    private struct Plan {
        let adapter: CLIAgentAdapter
        let path: String
        let shellPath: String
        let directory: String
        /// The effort chosen for this tool, or empty for its own default.
        let effort: String
    }

    static func stream(_ request: ChatRequest, config: LLMConfig) async throws -> AsyncThrowingStream<String, Error> {
        await CLIAgents.shared.ready()
        let plan: Plan = try await MainActor.run {
            let agents = CLIAgents.shared
            guard let adapter = agents.adapter(config.model) ?? agents.installed.first else {
                throw LLMError.notConfigured("No subscription tool was found on this Mac. Install Claude Code, Codex or Antigravity, sign in, then choose it in Settings > Engine.")
            }
            guard let path = agents.paths[adapter.id] else {
                throw LLMError.notConfigured("\(adapter.name) was not found on this Mac (looked for `\(adapter.command)`). Install it and sign in, then try again.")
            }
            // In code the tool starts in the chat's repository, so it can
            // read it. Otherwise it starts somewhere empty and neutral.
            // Work with a folder of its own (an agent task in a repository,
            // whichever chat is open) starts there.
            let app = AppState.shared
            var directory = WorkScope.current?.directory
                ?? (app.codeMode && app.hasWorkFolder ? app.agentStartDirectory : "")
            if directory.isEmpty || !FileManager.default.fileExists(atPath: directory) {
                let neutral = FileManager.default.temporaryDirectory.appendingPathComponent("companion-cli", isDirectory: true)
                try? FileManager.default.createDirectory(at: neutral, withIntermediateDirectories: true)
                directory = neutral.path
            }
            // An effort this tool does not take is not passed on.
            let wanted = AppSettings.shared.chosenEffort
            let effort = (adapter.efforts ?? []).contains(wanted) ? wanted : ""
            return Plan(adapter: adapter, path: path, shellPath: agents.shellPath, directory: directory, effort: effort)
        }

        // Most tools read the conversation from standard input and take a
        // one-line instruction. One that does not is given all of it as
        // its prompt, the oldest part cut if it would be too long for a
        // command line.
        let inArgument = plan.adapter.promptInArgument == true
        var whole = prompt(for: request)
        // Attached pictures: the tool looks at them itself (Claude Code with
        // its Read tool, allowed into their folders; Codex takes them as
        // images), so it sees the picture and not only its words.
        let pictures = request.pictures.filter { FileManager.default.fileExists(atPath: $0) }
        if !pictures.isEmpty {
            whole += "\n<pictures>\nThe user attached these pictures. Look at each one (open it with your Read tool) before answering; what they show matters, not only any text in them:\n"
                + pictures.map { "- " + $0 }.joined(separator: "\n") + "\n</pictures>\n"
        }
        let instruction = inArgument
            ? "Follow the instructions and answer the last user message of the conversation. Reply with the answer only.\n\n" + String(whole.suffix(180_000))
            : Self.instruction
        var arguments = plan.adapter.arguments.map { $0.replacingOccurrences(of: "{instruction}", with: instruction) }
        let model = config.baseURL
        var options: [String] = []
        if !model.isEmpty, let extra = plan.adapter.modelArguments {
            options += extra.map { $0.replacingOccurrences(of: "{model}", with: model) }
        }
        if !plan.effort.isEmpty, let extra = plan.adapter.effortArguments {
            options += extra.map { $0.replacingOccurrences(of: "{effort}", with: plan.effort) }
        }
        switch plan.adapter.id {
        case "claude-code":
            // Reading is allowed in the pictures' folders.
            for folder in Set(pictures.map { ($0 as NSString).deletingLastPathComponent }) {
                options += ["--add-dir", folder]
            }
        case "codex":
            for picture in pictures { options += ["--image", picture] }
        default:
            break
        }
        if !options.isEmpty {
            // Options go before the instruction for tools that take it last.
            if let last = arguments.last, last == instruction {
                arguments.insert(contentsOf: options, at: arguments.count - 1)
            } else {
                arguments.append(contentsOf: options)
            }
        }

        // The tool runs commands of its own: not counted as Companion by
        // macOS (see `AgentProcess`).
        let process = AgentProcess()
        process.executableURL = URL(fileURLWithPath: plan.path)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.directory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = plan.shellPath
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw LLMError.network("Could not start \(plan.adapter.name): \(error.localizedDescription)")
        }

        // The whole conversation goes in on standard input, so its length
        // is never a problem for the command line.
        let payload = Data((inArgument ? "" : whole).utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: payload)
            try? input.fileHandleForWriting.close()
        }
        // What the tool says on its error channel, kept for a failure.
        let complaints = ErrorText()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                complaints.add(chunk)
            }
        }

        let adapter = plan.adapter
        let started = Date()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var said = false
                var failure: String?
                // Codex names its thread first; what it makes (pictures)
                // is kept in a folder of that name.
                var thread: String?
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        // What is left of the plan, when the tool says so
                        // along with its answer.
                        if line.contains("rate_limit_info"), let event = LLM.parse(line[...]) {
                            let found = PlanLimit.windows(in: event)
                            if !found.isEmpty {
                                let id = adapter.id
                                Task { @MainActor in CLIAgents.shared.noteLimits(found, for: id) }
                            }
                        }
                        if adapter.format == .codexJSON, thread == nil, line.contains("thread.started"),
                           let event = LLM.parse(line[...]) {
                            thread = event["thread_id"] as? String
                        }
                        switch read(line, as: adapter.format, said: said, usage: request.usage) {
                        case .text(let text):
                            said = true
                            continuation.yield(text)
                        case .failed(let message):
                            failure = message
                        case .nothing:
                            break
                        }
                    }
                    process.waitUntilExit()
                    if let failure {
                        throw LLMError.network("\(adapter.name): \(failure)")
                    }
                    if process.terminationStatus != 0, !said {
                        let detail = complaints.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let hint = adapter.signIn.map { " \($0)" } ?? ""
                        throw LLMError.network("\(adapter.name) stopped without an answer.\(detail.isEmpty ? "" : " \(String(detail.suffix(300)))")\(hint)")
                    }
                    // What the tool made besides words (Codex's own image
                    // tool keeps its pictures in its own folder, and its
                    // answer often only says that it made one): each is
                    // shown in the answer.
                    if adapter.format == .codexJSON {
                        let made = Self.codexMedia(thread: thread, since: started)
                        if !made.isEmpty {
                            continuation.yield((said ? "\n\n" : "") + made.map { "![Made by Codex](\($0))" }.joined(separator: "\n\n"))
                        }
                    }
                    continuation.finish()
                    // A reply used some of the plan: ask what is left now.
                    if adapter.limitsArguments != nil {
                        Task { @MainActor in CLIAgents.shared.refreshLimits() }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// The pictures and films Codex made in this run, copied to a folder
    /// of Companion's own so they stay when Codex tidies up: those in its
    /// thread's folder, or, when it did not name its thread, whatever it
    /// has written since the run began.
    private static func codexMedia(thread: String?, since started: Date) -> [String] {
        let files = FileManager.default
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
        let root = (home as NSString).appendingPathComponent("generated_images")
        var folders: [String] = []
        if let thread, !thread.isEmpty, !thread.contains("/") {
            folders = [(root as NSString).appendingPathComponent(thread)]
        } else {
            folders = ((try? files.contentsOfDirectory(atPath: root)) ?? []).map { (root as NSString).appendingPathComponent($0) }
        }
        var found: [(path: String, written: Date)] = []
        for folder in folders {
            for name in (try? files.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = (folder as NSString).appendingPathComponent(name)
                guard GeneratedMedia.kinds.contains((name as NSString).pathExtension.lowercased()),
                      let written = (try? files.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      written >= started.addingTimeInterval(-2) else { continue }
                found.append((path, written))
            }
        }
        guard !found.isEmpty else { return [] }
        let kept = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Companion/Generated", isDirectory: true)
        try? files.createDirectory(at: kept, withIntermediateDirectories: true)
        let stamp = Int(started.timeIntervalSince1970)
        return found.sorted { $0.written < $1.written }.prefix(8).map { item in
            let copy = kept.appendingPathComponent("\(stamp)-" + (item.path as NSString).lastPathComponent).path
            if !files.fileExists(atPath: copy) { try? files.copyItem(atPath: item.path, toPath: copy) }
            return files.fileExists(atPath: copy) ? copy : item.path
        }
    }

    /// The request as one text: what to do, then the conversation.
    private static func prompt(for request: ChatRequest) -> String {
        var text = "<instructions>\n\(request.fullSystem)\n</instructions>\n\n<conversation>\n"
        for message in request.messages {
            text += "<\(message.role)>\n\(message.content)\n</\(message.role)>\n"
        }
        text += "</conversation>\n"
        return text
    }

    private enum Piece {
        case text(String)
        case failed(String)
        case nothing
    }

    /// One line of a tool's output, as the part of the answer it carries.
    private static func read(_ line: String, as format: CLIAgentAdapter.Format, said: Bool, usage: UsageProbe?) -> Piece {
        if format == .text { return .text(line + "\n") }
        guard let event = LLM.parse(line[...]),
              let type = (event["type"] ?? event["event"]) as? String else { return .nothing }
        switch format {
        case .claudeStream:
            if type == "stream_event",
               let inner = event["event"] as? [String: Any],
               let delta = inner["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                return .text(text)
            }
            if type == "result" {
                if let counts = event["usage"] as? [String: Any] {
                    usage?.input = counts["input_tokens"] as? Int
                    usage?.output = counts["output_tokens"] as? Int
                }
                let result = event["result"] as? String ?? ""
                if event["is_error"] as? Bool == true {
                    return .failed(result.isEmpty ? "the run failed." : result)
                }
                // No partial text arrived: the result is the whole answer.
                if !said, !result.isEmpty { return .text(result) }
            }
        case .codexJSON:
            if type == "item.completed",
               let item = event["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String, !text.isEmpty {
                return .text(said ? "\n\n" + text : text)
            }
            if type == "error" || type == "turn.failed" {
                let nested = (event["error"] as? [String: Any])?["message"] as? String
                return .failed(event["message"] as? String ?? nested ?? "the run failed.")
            }
        case .geminiStream:
            if type == "message", event["role"] as? String == "assistant",
               let text = event["content"] as? String, !text.isEmpty {
                return .text(text)
            }
            if type == "result", let status = event["status"] as? String, status == "error" {
                let nested = (event["error"] as? [String: Any])?["message"] as? String
                return .failed(nested ?? "the run failed.")
            }
        case .antigravityStream:
            if type == "step_update" {
                let step = event["step_update"] as? [String: Any] ?? event
                let kind = (step["step_type"] ?? event["step_type"]) as? String
                if kind == "agent_response", let text = step["text_delta"] as? String, !text.isEmpty {
                    return .text(text)
                }
            }
            if type == "result" {
                let result = event["result"] as? [String: Any] ?? event
                if let counts = result["usage"] as? [String: Any] {
                    usage?.input = counts["input_tokens"] as? Int
                    usage?.output = counts["output_tokens"] as? Int
                }
                let status = result["status"] as? String ?? "SUCCESS"
                if status != "SUCCESS" {
                    let detail = result["error"] as? String ?? (result["error"] as? [String: Any])?["message"] as? String
                    return .failed(detail ?? "the run ended as \(status.lowercased()).")
                }
                // No partial text arrived: the result is the whole answer.
                if !said, let text = result["response"] as? String, !text.isEmpty { return .text(text) }
            }
        case .text:
            break
        }
        return .nothing
    }
}

/// Collects a tool's error output from its own reading queue.
private final class ErrorText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func add(_ chunk: Data) {
        lock.lock()
        if data.count < 400_000 { data.append(chunk) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
