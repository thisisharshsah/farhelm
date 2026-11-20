import CompanionBoard
import Foundation
import os

/// Every project's board, kept on this Mac: one JSON file per project in
/// Application Support/Companion/boards, named after the project. The
/// board's rules live in `CompanionBoard`; this only reads, keeps and
/// writes. Every change goes through `update`, which writes the board
/// whole and in one step, so a board on disk is always one that was whole.
@MainActor
final class BoardStore: ObservableObject {
    static let shared = BoardStore()

    /// The boards read so far, by project.
    @Published private(set) var boards: [UUID: Board] = [:]

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.harshsah.companion", category: "board")

    private init() {
        directory = ContextStore.shared.baseDir.appendingPathComponent("boards", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Readable and the same from one save to the next, so a board can
        // be looked at, compared and kept under version control.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func url(_ project: UUID) -> URL {
        directory.appendingPathComponent("\(project.uuidString).json")
    }

    /// A project's board, read from disk the first time it is asked for.
    /// A project with none gets an empty one, written once it holds
    /// something. `live` names the chats with an agent at work: a run the
    /// board still calls running in any other chat was cut off when the
    /// app last quit, and is closed.
    @discardableResult
    func load(_ project: UUID, live: Set<UUID> = []) -> Board {
        if let known = boards[project] { return known }
        var board = read(project) ?? Board(project: project, now: Date())
        if board.closeLostRuns(except: live, now: Date()) > 0 { write(board) }
        boards[project] = board
        return board
    }

    /// Changes a project's board and saves it. Nothing is written, and
    /// nobody is told, when the change changes nothing.
    func update(_ project: UUID, _ change: (inout Board) -> Void) {
        var board = load(project)
        let before = board
        change(&board)
        guard board != before else { return }
        boards[project] = board
        write(board)
    }

    /// Boards kept here that belong to none of `known` projects and have
    /// something on them, the one changed last first. A project that was
    /// taken off the list and added again as a new project left its
    /// board behind under the id it had; it is found here, to be brought
    /// back (`adopt`). Files put aside under other names are not boards.
    func strays(known: Set<UUID>) -> [Board] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file -> Board? in
            guard file.pathExtension == "json",
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !known.contains(id),
                  let data = try? Data(contentsOf: file),
                  let board = try? decoder.decode(Board.self, from: data),
                  board.project == id, !board.isBlank else { return nil }
            return board
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Makes a board that was left behind the board of `project`, whose
    /// own has nothing on it and makes way. Runs it still calls running
    /// were cut off long ago and are closed. The file it was read from is
    /// put aside under another name, never deleted. Returns the board, or
    /// nil when it could not be read (nothing is changed then).
    func adopt(_ stray: UUID, into project: UUID, live: Set<UUID>) -> Board? {
        let file = url(stray)
        guard stray != project, let data = try? Data(contentsOf: file),
              var board = try? decoder.decode(Board.self, from: data) else { return nil }
        board.rehome(to: project, now: Date())
        board.closeLostRuns(except: live, now: Date())
        boards[project] = board
        boards[stray] = nil
        write(board)
        let aside = directory.appendingPathComponent("\(stray.uuidString).brought-back-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        return board
    }

    private func read(_ project: UUID) -> Board? {
        let file = url(project)
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            return try decoder.decode(Board.self, from: data)
        } catch {
            // A board that cannot be read is never written over: it is
            // put aside under another name, and a new one is started.
            log.error("board \(project.uuidString, privacy: .public) could not be read: \(error.localizedDescription, privacy: .public)")
            let aside = directory.appendingPathComponent("\(project.uuidString).unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            return nil
        }
    }

    private func write(_ board: Board) {
        do {
            try encoder.encode(board).write(to: url(board.project), options: .atomic)
        } catch {
            log.error("board \(board.project.uuidString, privacy: .public) could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The board as Markdown, to paste into a document or an issue: the
    /// goal being worked toward with its tasks, then the goals before it.
    func markdown(_ project: UUID, name: String) -> String {
        guard let board = boards[project] else { return "" }
        var lines = ["# \(name)", ""]
        if !board.goal.isEmpty { lines += [board.goal, ""] }
        for status in WorkStatus.allCases {
            let items = board.items(in: status)
            guard !items.isEmpty else { continue }
            lines += ["## \(status.title)", ""]
            for item in items {
                let model = item.assignment.map { " (\($0.label))" } ?? ""
                lines.append("- [\(status == .done ? "x" : " ")] **\(item.key)** \(item.title)\(model)")
                for line in item.acceptance { lines.append("  - \(line)") }
            }
            lines.append("")
        }
        let earlier = board.earlierGoals
        if !earlier.isEmpty {
            lines += ["## Earlier goals", ""]
            for goal in earlier {
                let progress = board.progress(of: goal.id)
                let words = goal.text.isEmpty ? "Never put into words" : goal.text.replacingOccurrences(of: "\n", with: " ")
                lines.append("### \(goal.key) \(words)")
                lines += ["", "\(goal.status.title), \(progress.done) of \(progress.all) tasks done.", ""]
                for item in board.items(of: goal.id) {
                    lines.append("- [\(item.status == .done ? "x" : " ")] **\(item.key)** \(item.title)")
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
