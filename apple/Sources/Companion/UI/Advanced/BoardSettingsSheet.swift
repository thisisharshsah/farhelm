import AppKit
import CompanionBoard
import SwiftUI

/// The board's settings as one sheet, opened from the board's header.
/// Every switch and limit that used to be in the three-dot menu lives
/// here, grouped by what it decides: how finished runs are reviewed, how
/// runs are set up, whether the supervisor recommends and runs the board,
/// the board's one permission grant (Auto) with the four it never covers,
/// and the budget. Each row has a one-line explanation, so the switches
/// are never read in isolation.
///
/// Defaults for a new board are set in `BoardSettings.init` and read, not
/// written, here: Review Finished Runs on, Own Branch on, Recommend an
/// Answer on, and the ones that stay off until the person turns them on:
/// Supervisor Mode, Auto, the Budget. Limit on In Progress and What Runs
/// May Do Unasked default to nil (no limit, follow the app's setting for
/// new chats). No row writes a value the person has already saved: each
/// writes only when its control moves.
struct BoardSettingsSheet: View {
    @ObservedObject private var advanced = Advanced.shared
    let project: Project
    let board: Board
    let onClose: () -> Void

    private static let width: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    reviewSection
                    runsSection
                    supervisorSection
                    permissionsSection
                    budgetSection
                }
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
        }
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(spacing: Design.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Board Settings")
                    .textRole(.title, .primary)
                    .fontWeight(.semibold)
                Text("How this project is run. Each change saves as the control moves.")
                    .textRole(.caption, .secondary)
            }
            Spacer(minLength: Design.Space.s)
            BoardButton("Done", prominent: true) { onClose() }
        }
        .padding(Design.Space.m)
    }

    private var reviewSection: some View {
        BoardSettingsSection(title: "Review",
                             help: "What a finished run passes through before it can be approved.") {
            BoardSettingsRow(title: "Review Finished Runs", icon: "checkmark.seal",
                             help: "A finished run is checked against the task, with a verdict, before the task can be done.") {
                Toggle("Review Finished Runs", isOn: Binding(
                    get: { board.settings.reviewGate },
                    set: { _ in advanced.change(project.id) { $0.settings.reviewGate.toggle() } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            BoardSettingsRow(title: "Checks Before Review", icon: "checklist",
                             help: "The commands run on each task's work before it is reviewed (its build, its tests), written in \(Checks.file) in the project's folder. Work whose checks fail is never approved without you.") {
                HStack(spacing: Design.Space.xs) {
                    BoardButton("Open \(Checks.file)", icon: "square.and.pencil") { openChecks() }
                        .disabled(project.folder == nil)
                    if project.folder == nil {
                        Text("No folder set")
                            .textRole(.caption, .tertiary)
                    }
                }
            }
        }
    }

    private var runsSection: some View {
        BoardSettingsSection(title: "Runs",
                             help: "How each task's run is set up, and how many may be in progress at once.") {
            BoardSettingsRow(title: "Own Branch", icon: "arrow.triangle.branch",
                             help: "Each task's runs work in a copy of the repository of their own, on a branch of their own; the work is merged into the board's branch once it is approved. Where the project is not a git repository, runs work in the project's folder.") {
                Toggle("Own Branch", isOn: Binding(
                    get: { board.settings.copyPerTask },
                    set: { advanced.setCopyPerTask($0, in: project.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            BoardSettingsRow(title: "Limit on In Progress", icon: "gauge.with.dots.needle.33percent",
                             help: "The most tasks wanted in progress at once. Over the limit, the board shows a warning; it does not stop a run.") {
                Picker("Limit on In Progress", selection: Binding(
                    get: { board.settings.wipLimit ?? -1 },
                    set: { value in
                        advanced.change(project.id) { $0.settings.wipLimit = value < 0 ? nil : value }
                    })) {
                    Text("No limit").tag(-1)
                    ForEach([1, 2, 3, 4, 5, 8], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 160, alignment: .leading)
            }
            BoardSettingsRow(title: "What Runs May Do Unasked", icon: "shield.lefthalf.filled",
                             help: "The access each run starts with. Left on the app's setting, a run follows what new chats use.") {
                Picker("What Runs May Do Unasked", selection: Binding(
                    get: { board.settings.runAccess ?? "" },
                    set: { value in
                        advanced.change(project.id) {
                            $0.settings.runAccess = value.isEmpty ? nil : value
                        }
                    })) {
                    Text("As set for new chats").tag("")
                    ForEach(AgentAccess.allCases) { access in
                        Text(access.title).tag(access.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    private var supervisorSection: some View {
        BoardSettingsSection(title: "Supervisor",
                             help: "Whether the supervisor recommends an answer where you are asked to choose, and whether its answer is taken as yours.") {
            BoardSettingsRow(title: "Recommend an Answer", icon: "star",
                             help: "Wherever you are asked to choose (a step that needs a yes, an agent's question, a task in Review), the supervisor says which answer it would take. Each time is a request to its model.") {
                Toggle("Recommend an Answer", isOn: Binding(
                    get: { board.settings.advice },
                    set: { on in
                        // Without recommendations there is no answer to take.
                        if !on, board.settings.followsAdvice {
                            advanced.setFollowsAdvice(false, in: project.id)
                        }
                        advanced.change(project.id) { $0.settings.advice = on }
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            BoardSettingsRow(title: "Supervisor Mode", icon: "star.fill",
                             help: "The supervisor runs the board for you: it starts tasks that are ready, answers for you where it would recommend an answer, and merges approved work one task at a time. Steps that name keys, act on the system, send work off this Mac, work other apps or reach outside the project's folder still wait for you.") {
                Toggle("Supervisor Mode", isOn: Binding(
                    get: { board.settings.supervisorAnswers },
                    set: { on in advanced.setFollowsAdvice(on, in: project.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!board.settings.advice)
            }
        }
    }

    private var permissionsSection: some View {
        BoardSettingsSection(title: "Permissions",
                             help: "Auto is the board's one grant, so a task of many runs goes on without a question at each edit, build, test or commit. Off again makes them ask again.") {
            BoardSettingsRow(title: "Auto", icon: "bolt.shield.fill",
                             help: "Every run the board starts, its supervisor and every chat in the project may edit, run commands, build, test and commit on their own branches without asking, within what is listed below.") {
                Toggle("Auto", isOn: Binding(
                    get: { board.settings.auto },
                    set: { advanced.setAuto($0, in: project.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            // The four kept rules, written out so no prompt to a model can
            // widen them: the list is in code (`AutoPermission.alwaysAsks`).
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text("Always asks, even with Auto on:")
                    .textRole(.caption, .secondary)
                    .fontWeight(.semibold)
                ForEach(AutoPermission.alwaysAsks, id: \.self) { kept in
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .iconWidth(.small)
                            .foregroundStyle(Design.Tone.caution.color)
                        Text(kept.sentence)
                            .textRole(.caption, .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Design.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.tile))
        }
    }

    private var budgetSection: some View {
        BoardSettingsSection(title: "Budget",
                             help: "The most this project's work may cost. Set a limit in tokens, in dollars, or both. No more runs start once a limit is used up.") {
            BoardSettingsRow(title: "Tokens", icon: "number",
                             help: "A ceiling on tokens: input, cached input and output alike. Reads \"200000\", \"200k\" or \"1.5m\". Leave empty for no limit.") {
                CommitField(placeholder: "No limit",
                            value: board.budget.tokens.map { ContextUse.short($0) } ?? "") { text in
                    setBudget(tokens: BoardText.parseTokens(text), dollars: board.budget.dollars)
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
            BoardSettingsRow(title: "Dollars", icon: "dollarsign.circle",
                             help: "A ceiling on what every request costs together, in dollars. Leave empty for no limit.") {
                CommitField(placeholder: "No limit",
                            value: board.budget.dollars.map { String(format: "%.2f", $0) } ?? "") { text in
                    let cleaned = text.replacingOccurrences(of: "$", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    setBudget(tokens: board.budget.tokens, dollars: Double(cleaned).flatMap { $0 > 0 ? $0 : nil })
                }
                .frame(maxWidth: 180, alignment: .leading)
            }
        }
    }

    private func setBudget(tokens: Int?, dollars: Double?) {
        advanced.change(project.id) { board in
            let next = Budget(tokens: tokens, dollars: dollars)
            guard next != board.budget else { return }
            board.budget = next
            board.log("Set the budget", by: .person, now: Date())
        }
    }

    private func openChecks() {
        guard let folder = project.folder else { return }
        let path = (folder as NSString).appendingPathComponent(Checks.file)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? Checks.starter(build: ProblemsModel.buildCommand(in: folder))
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        AppState.shared.openInWorkspace(path)
    }
}

/// A section of the sheet: a heading, a line of help under it, and its
/// rows. No background, so sections stand apart by their heading alone.
private struct BoardSettingsSection<Content: View>: View {
    let title: String
    var help: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                BoardHeading(title)
                if let help {
                    Text(help)
                        .textRole(.caption, .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                content()
            }
        }
    }
}

/// One row: a symbol and a title on one line with the control on the
/// right, and a one-line explanation under the title.
private struct BoardSettingsRow<Control: View>: View {
    let title: String
    let icon: String
    let help: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Image(systemName: icon)
                .iconWidth(.small)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textRole(.label, .primary)
                    .fontWeight(.medium)
                Text(help)
                    .textRole(.caption, .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Space.xs)
            control()
        }
        .padding(Design.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.tile))
    }
}

/// The one rule the small Auto badge in the board's header reads: it is
/// drawn when the board's Auto grant is on, and never otherwise. Kept
/// here, not inside a SwiftUI view, so a unit test can pin it.
enum BoardAutoBadge {
    static func shouldShow(for settings: BoardSettings) -> Bool {
        settings.showsAutoBadge
    }
}