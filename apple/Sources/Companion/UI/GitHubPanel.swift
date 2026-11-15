import AppKit
import Combine
import SwiftUI

/// Pull requests and workflow runs for the folder's repository, through the
/// GitHub CLI (`gh`) and its own sign-in: Companion never sees a token.
/// Nothing here merges, closes or force-pushes; creating a pull request
/// pushes the branch the ordinary way first.
@MainActor
final class GitHubModel: ObservableObject {
    static let shared = GitHubModel()

    struct PullRequest: Identifiable, Hashable {
        let number: Int
        let title: String
        let author: String
        let branch: String
        let draft: Bool
        let url: String
        let review: String
        var id: Int { number }
    }

    struct Check: Identifiable, Hashable {
        let name: String
        /// "passed", "failed", "running", "skipped"
        let state: String
        let url: String
        var id: String { name + url }
    }

    struct Run: Identifiable, Hashable {
        let id: Int
        let title: String
        let workflow: String
        let branch: String
        /// "queued", "in_progress", "completed"
        let status: String
        /// "success", "failure", "cancelled"... when completed
        let conclusion: String
        let url: String
    }

    enum Availability { case unknown, missing, signedOut, ready, notGitHub }

    @Published private(set) var availability = Availability.unknown
    @Published private(set) var folder = ""
    @Published private(set) var pulls: [PullRequest] = []
    @Published private(set) var current: PullRequest?
    @Published private(set) var checks: [Check] = []
    @Published private(set) var runs: [Run] = []
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published var note = ""

    private static func json(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func refresh(in folder: String) {
        guard !folder.isEmpty, !loading else { return }
        if folder != self.folder {
            pulls = []
            current = nil
            checks = []
            runs = []
            note = ""
        }
        self.folder = folder
        loading = true
        Task { @MainActor in
            defer { loading = false }
            let found = await Shell.run("command -v gh", in: folder, timeout: 10)
            guard found.ok else { availability = .missing; return }
            let auth = await Shell.run("gh auth status", in: folder, timeout: 15)
            guard auth.ok else { availability = .signedOut; return }
            async let pullList = Shell.run(
                "gh pr list --limit 30 --json number,title,author,headRefName,isDraft,url,reviewDecision", in: folder, timeout: 30)
            async let mine = Shell.run(
                "gh pr view --json number,title,author,headRefName,isDraft,url,reviewDecision,statusCheckRollup", in: folder, timeout: 30)
            async let runList = Shell.run(
                "gh run list --limit 15 --json databaseId,displayTitle,workflowName,headBranch,status,conclusion,url", in: folder, timeout: 30)
            let (p, m, r) = await (pullList, mine, runList)
            guard folder == self.folder else { return }
            if !p.ok, p.output.lowercased().contains("not a git repository") || p.output.lowercased().contains("no git remotes")
                || p.output.lowercased().contains("none of the git remotes") {
                availability = .notGitHub
                return
            }
            availability = .ready
            pulls = (Self.json(p.output) as? [[String: Any]] ?? []).compactMap(Self.pull)
            if m.ok, let object = Self.json(m.output) as? [String: Any] {
                current = Self.pull(object)
                checks = (object["statusCheckRollup"] as? [[String: Any]] ?? []).map(Self.check)
            } else {
                current = nil
                checks = []
            }
            runs = (Self.json(r.output) as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["databaseId"] as? Int else { return nil }
                return Run(id: id, title: item["displayTitle"] as? String ?? "", workflow: item["workflowName"] as? String ?? "",
                           branch: item["headBranch"] as? String ?? "", status: item["status"] as? String ?? "",
                           conclusion: item["conclusion"] as? String ?? "", url: item["url"] as? String ?? "")
            }
        }
    }

    private static func pull(_ item: [String: Any]) -> PullRequest? {
        guard let number = item["number"] as? Int else { return nil }
        return PullRequest(number: number, title: item["title"] as? String ?? "",
                           author: (item["author"] as? [String: Any])?["login"] as? String ?? "",
                           branch: item["headRefName"] as? String ?? "", draft: item["isDraft"] as? Bool ?? false,
                           url: item["url"] as? String ?? "", review: item["reviewDecision"] as? String ?? "")
    }

    /// A check run or a commit status, by the state it is in.
    private static func check(_ item: [String: Any]) -> Check {
        let name = (item["name"] ?? item["context"]) as? String ?? "Check"
        let url = (item["detailsUrl"] ?? item["targetUrl"]) as? String ?? ""
        let status = (item["status"] as? String ?? "").uppercased()
        let outcome = ((item["conclusion"] ?? item["state"]) as? String ?? "").uppercased()
        let state: String
        if status == "IN_PROGRESS" || status == "QUEUED" || outcome == "PENDING" || outcome == "EXPECTED" {
            state = "running"
        } else if ["SUCCESS", "NEUTRAL"].contains(outcome) {
            state = "passed"
        } else if ["SKIPPED", "CANCELLED", "STALE"].contains(outcome) {
            state = "skipped"
        } else if outcome.isEmpty {
            state = "running"
        } else {
            state = "failed"
        }
        return Check(name: name, state: state, url: url)
    }

    /// Runs a gh command, then reads everything again.
    private func act(_ command: String, done: String) {
        guard !busy, !folder.isEmpty else { return }
        busy = true
        note = ""
        let folder = self.folder
        Task { @MainActor in
            let result = await Shell.run("GIT_TERMINAL_PROMPT=0 " + command, in: folder, timeout: 120)
            busy = false
            note = result.ok ? done : String(result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
            GitModel.shared.refresh()
            refresh(in: folder)
        }
    }

    /// Switches to a pull request's branch (git refuses if local changes
    /// would be lost).
    func checkout(_ pull: PullRequest) {
        act("gh pr checkout \(pull.number)", done: "On #\(pull.number)'s branch now.")
    }

    func rerunFailed(_ run: Run) {
        act("gh run rerun \(run.id) --failed", done: "The failed jobs of \(run.workflow) are running again.")
    }

    /// The end of a failed run's log, for the agent.
    func failedLog(_ run: Run) async -> String {
        let result = await Shell.run("gh run view \(run.id) --log-failed", in: folder, timeout: 60)
        return String(result.output.suffix(6000))
    }

    /// The title and body to start a pull request with: the branch's commits.
    func draft() async -> (title: String, body: String) {
        let base = await Shell.run("gh repo view --json defaultBranchRef --jq .defaultBranchRef.name", in: folder, timeout: 20)
        let main = base.ok ? base.output.trimmingCharacters(in: .whitespacesAndNewlines) : "main"
        let log = await Shell.run("git log --format=%s \(Shell.quote("origin/" + main))..HEAD", in: folder, timeout: 15)
        let subjects = log.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let title = subjects.last ?? ""
        let body = subjects.count > 1 ? subjects.reversed().map { "- " + $0 }.joined(separator: "\n") : ""
        return (title, body)
    }

    /// Pushes the branch (never forced), then opens the pull request. The
    /// body carries no credit to any AI, model or tool.
    func create(title: String, body: String, draft: Bool) {
        let cleanTitle = CommitHygiene.clean(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let cleanBody = CommitHygiene.clean(body)
        let command = "git push -u origin HEAD && gh pr create --title \(Shell.quote(cleanTitle)) --body \(Shell.quote(cleanBody))"
            + (draft ? " --draft" : "")
        act(command, done: "Pull request opened.")
    }
}

/// The GitHub tab of the workspace panel.
struct GitHubTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var hub = GitHubModel.shared
    @ObservedObject private var git = GitModel.shared
    @State private var creating = false
    @State private var title = ""
    @State private var bodyText = ""
    @State private var draft = false
    @State private var checkingOut: GitHubModel.PullRequest?
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(header).lineLimit(1)
                if hub.loading || hub.busy { LoadingMark(state: .working, size: 12) }
                Spacer(minLength: 4)
                IconButton("arrow.clockwise", help: "Look again") { hub.refresh(in: model.root) }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 28)
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            if !hub.note.isEmpty { workspaceNote(hub.note) }
            switch hub.availability {
            case .unknown:
                workspaceNote("Asking GitHub...")
            case .missing:
                setup("The GitHub CLI is not installed. Install it (brew install gh), then sign in; Companion uses its sign-in and never sees a token.",
                      button: "Install with Homebrew", command: "brew install gh && gh auth login")
            case .signedOut:
                setup("Sign in to GitHub with the GitHub CLI. Companion uses its sign-in and never sees a token.",
                      button: "Sign In in a Terminal", command: "gh auth login")
            case .notGitHub:
                workspaceNote("This folder's repository has no GitHub remote.")
            case .ready:
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("This branch")
                        if let pull = hub.current {
                            PullRow(pull: pull, checkout: nil)
                            ForEach(hub.checks) { check in CheckRow(check: check) }
                        } else if creating {
                            createForm
                        } else {
                            HStack {
                                Text(git.branch.isEmpty ? "No pull request." : "No pull request for \(git.branch).")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.ink.opacity(0.6))
                                Spacer()
                                Button("Create Pull Request…") { startCreating() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                        }
                        section("Pull requests")
                        if hub.pulls.isEmpty {
                            row("None open.")
                        }
                        ForEach(hub.pulls) { pull in
                            PullRow(pull: pull, checkout: { checkingOut = pull })
                        }
                        section("Workflow runs")
                        if hub.runs.isEmpty {
                            row("None yet.")
                        }
                        ForEach(hub.runs) { run in
                            RunRow(run: run, rerun: { hub.rerunFailed(run) }, fix: {
                                Task {
                                    let log = await hub.failedLog(run)
                                    app.fixCommand("the \(run.workflow) workflow (run \(run.id) on \(run.branch))", output: log)
                                }
                            })
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .onAppear { hub.refresh(in: model.root) }
        .onReceive(timer) { _ in hub.refresh(in: model.root) }
        .confirmationDialog(checkingOut.map { "Switch to #\($0.number)'s branch, \($0.branch)?" } ?? "",
                            isPresented: Binding(get: { checkingOut != nil }, set: { if !$0 { checkingOut = nil } }),
                            titleVisibility: .visible) {
            Button("Switch") {
                if let pull = checkingOut { hub.checkout(pull) }
                checkingOut = nil
            }
            Button("Cancel", role: .cancel) { checkingOut = nil }
        } message: {
            Text("Git refuses if your changes here would be lost.")
        }
    }

    private var header: String {
        switch hub.availability {
        case .ready:
            let failing = hub.runs.filter { $0.conclusion == "failure" }.count
            return "\(hub.pulls.count) open" + (failing > 0 ? " · \(failing) failed runs" : "")
        default: return "GitHub"
        }
    }

    private func setup(_ text: String, button: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            workspaceNote(text)
            Button(button) {
                model.run(ProjectTask(name: button, command: command, source: "GitHub"))
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.ink.opacity(0.45))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }

    private func row(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.ink.opacity(0.5))
            .padding(.horizontal, 10)
            .frame(height: 22)
    }

    private func startCreating() {
        creating = true
        Task {
            let found = await hub.draft()
            if title.isEmpty { title = found.title }
            if bodyText.isEmpty { bodyText = found.body }
        }
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
            TextField("What it changes and why", text: $bodyText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .lineLimit(3...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.07)))
            HStack(spacing: 10) {
                Toggle("Draft", isOn: $draft)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                Spacer()
                Button("Cancel") { creating = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                Button("Push and Open") {
                    hub.create(title: title, body: bodyText, draft: draft)
                    creating = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || hub.busy)
                .help("Push this branch (never forced), then open the pull request on GitHub")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private func openLink(_ url: String) {
    if let link = URL(string: url), !url.isEmpty { NSWorkspace.shared.open(link) }
}

private struct PullRow: View {
    let pull: GitHubModel.PullRequest
    let checkout: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: pull.draft ? "circle.dashed" : "arrow.triangle.pull")
                .font(.system(size: 10.5))
                .foregroundStyle(pull.draft ? Theme.ink.opacity(0.5) : Theme.mint)
            Text("#\(pull.number)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.55))
            Text(pull.title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
            if pull.review == "APPROVED" {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundStyle(Theme.mint)
                    .help("Approved")
            } else if pull.review == "CHANGES_REQUESTED" {
                Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 10)).foregroundStyle(Theme.amber)
                    .help("Changes requested")
            }
            Spacer(minLength: 4)
            if hover {
                if let checkout {
                    IconButton("arrow.down.to.line", help: "Switch to this branch", action: checkout)
                }
                IconButton("safari", help: "Open on GitHub") { openLink(pull.url) }
            } else {
                Text(pull.author)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(hover ? Theme.ink.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { openLink(pull.url) }
    }
}

private struct CheckRow: View {
    let check: GitHubModel.Check

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: check.state == "passed" ? "checkmark.circle.fill"
                  : (check.state == "failed" ? "xmark.circle.fill" : (check.state == "running" ? "clock" : "minus.circle")))
                .font(.system(size: 10))
                .foregroundStyle(check.state == "passed" ? Theme.mint
                                 : (check.state == "failed" ? Theme.rose : Theme.ink.opacity(0.5)))
            Text(check.name)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture { openLink(check.url) }
    }
}

private struct RunRow: View {
    let run: GitHubModel.Run
    let rerun: () -> Void
    let fix: () -> Void
    @State private var hover = false

    private var failed: Bool { run.conclusion == "failure" || run.conclusion == "timed_out" }

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if run.status != "completed" {
                    LoadingMark(state: .working, size: 11)
                } else {
                    Image(systemName: run.conclusion == "success" ? "checkmark.circle.fill"
                          : (failed ? "xmark.circle.fill" : "minus.circle"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(run.conclusion == "success" ? Theme.mint : (failed ? Theme.rose : Theme.ink.opacity(0.5)))
                }
            }
            .frame(width: 12)
            Text(run.workflow)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineLimit(1)
            Text(run.title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hover {
                if failed {
                    Button(action: fix) {
                        Label("Fix", systemImage: "sparkles")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Have the agent read the failed log and fix the cause")
                    IconButton("arrow.clockwise", help: "Run the failed jobs again", action: rerun)
                }
                IconButton("safari", help: "Open on GitHub") { openLink(run.url) }
            } else {
                Text(run.branch)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(hover ? Theme.ink.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
