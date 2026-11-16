import CompanionKit
import Foundation
import MWDATDisplay

/// What the glasses show: the latest reply, the chats, the projects, or
/// one project's chats.
enum GlassPage: Equatable, Sendable {
    case reply
    case chats
    case projects
    case project
}

/// What a tap on the glasses asks for.
enum GlassAction: Equatable, Sendable {
    /// An answer to the agent's question.
    case say(String)
    case stop
    case show(GlassPage)
    /// A project's chats (its id).
    case project(String)
    /// Open a chat (its id) on the Mac.
    case open(String)
    /// Another part of a long reply.
    case part(Int)
}

/// One screen for the glasses' display, in plain values, so the same screen
/// is not sent twice and what it holds can be read without glasses. `view`
/// turns it into what the display takes. The display has no scrolling and
/// no pointer: a long reply is shown a part at a time, and lists are short.
struct GlassScreen: Equatable, Sendable {
    /// A line to tap: a chat or a project.
    struct Row: Equatable, Sendable {
        var title: String
        var note: String
        var action: GlassAction
    }

    /// A button.
    struct Key: Equatable, Sendable {
        var label: String
        var action: GlassAction
        /// A way around rather than the thing to do next.
        var quiet = false
    }

    var heading: String
    var text: String
    /// The agent's question, or that it waits for an approval.
    var ask = ""
    var rows: [Row] = []
    /// The buttons, a row of them at a time.
    var keys: [[Key]] = []
    /// Which part of a long reply shows, and of how many.
    var part = 0
    var parts = 1
}

extension GlassScreen {
    /// How much of a reply shows at once, and how many chats or projects.
    /// First values, to be set right on real glasses.
    static let partSize = 280
    static let rowLimit = 5

    /// The open chat's latest reply, a part at a time, with the agent's
    /// question and its choices, Stop while it works, and the way to the
    /// chats and the projects. While a reply is being written its end
    /// shows; a finished one starts at its beginning.
    static func reply(meta: ChatMeta, latest: Turn?, part wanted: Int?, note: String) -> GlassScreen {
        let words: String
        if let turn = latest {
            if !turn.error.isEmpty {
                words = turn.error
            } else if !turn.reply.isEmpty {
                words = plain(turn.reply)
            } else {
                let doing = meta.agentStatus.isEmpty ? meta.status : meta.agentStatus
                words = (doing.isEmpty ? "Working" : doing) + " …"
            }
        } else {
            words = "No messages yet."
        }
        let all = pieces(of: words)
        let writing = latest?.streaming == true && latest?.reply.isEmpty == false
        let index = min(max(wanted ?? (writing ? all.count - 1 : 0), 0), all.count - 1)

        var heading = short(meta.title.isEmpty ? "Companion" : meta.title, 32)
        if all.count > 1 { heading += " · \(index + 1)/\(all.count)" }
        if !note.isEmpty { heading += " · " + note }
        var screen = GlassScreen(heading: heading,
                                 text: all[index] + (writing && index == all.count - 1 ? " …" : ""))
        screen.part = index
        screen.parts = all.count

        if let question = meta.question, !question.isEmpty {
            screen.ask = short(question, 160)
            let options = (meta.options ?? []).prefix(4).map { Key(label: short($0, 28), action: .say($0)) }
            if !options.isEmpty { screen.keys.append(Array(options)) }
        } else if meta.awaitingApproval {
            screen.ask = "Waiting for approval on the Mac."
        }
        if all.count > 1 {
            var turn: [Key] = []
            if index > 0 { turn.append(Key(label: "Earlier", action: .part(index - 1), quiet: true)) }
            if index < all.count - 1 { turn.append(Key(label: "More", action: .part(index + 1))) }
            screen.keys.append(turn)
        }
        var last: [Key] = []
        if meta.busy { last.append(Key(label: "Stop", action: .stop)) }
        last.append(Key(label: "Chats", action: .show(.chats), quiet: true))
        last.append(Key(label: "Projects", action: .show(.projects), quiet: true))
        screen.keys.append(last)
        return screen
    }

    /// A short list of chats to open: the recent ones, or one project's.
    static func chats(_ chats: [ChatSummary], heading: String, open: String, back: [Key]) -> GlassScreen {
        var screen = GlassScreen(heading: short(heading, 40), text: chats.isEmpty ? "No chats yet." : "")
        screen.rows = chats.prefix(rowLimit).map { chat in
            Row(title: short(chat.title.isEmpty ? "New chat" : chat.title, 40),
                note: chat.waiting == true ? "Waiting for you" : chat.running == true ? "Working"
                    : chat.id == open ? "Open now" : "",
                action: .open(chat.id))
        }
        screen.keys = [back]
        return screen
    }

    /// A short list of the Mac's projects, each with the end of its folder.
    static func projects(_ projects: [ProjectSummary]) -> GlassScreen {
        var screen = GlassScreen(heading: "Projects", text: projects.isEmpty ? "No projects yet." : "")
        screen.rows = projects.prefix(rowLimit).map { project in
            Row(title: short(project.name, 40), note: tail(project.folder), action: .project(project.id))
        }
        screen.keys = [[latestKey]]
        return screen
    }

    static let latestKey = Key(label: "Latest reply", action: .show(.reply), quiet: true)

    /// A text in parts of at most `size` characters, cut between words.
    static func pieces(of text: String, size: Int = partSize) -> [String] {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var parts: [String] = []
        while rest.count > size {
            var cut = rest.index(rest.startIndex, offsetBy: size)
            // Back to the end of a word, unless that leaves under half a part.
            if let space = rest[..<cut].lastIndex(where: { $0.isWhitespace }),
               rest.distance(from: rest.startIndex, to: space) > size / 2 {
                cut = space
            }
            parts.append(rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[cut...].drop(while: { $0.isWhitespace })
        }
        if !rest.isEmpty || parts.isEmpty { parts.append(String(rest)) }
        return parts
    }

    /// A reply without the marks the display would show as they are.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    /// One line, cut to `limit` characters.
    static func short(_ text: String, _ limit: Int) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// The end of a folder's path: all a small display has room for.
    static func tail(_ folder: String?) -> String {
        guard let folder, !folder.isEmpty else { return "No folder" }
        return folder.split(separator: "/").suffix(2).joined(separator: "/")
    }

    /// The screen as the display takes it. `act` is called (off the main
    /// thread) with what a tap on the glasses asks for.
    func view(_ act: @escaping @Sendable (GlassAction) -> Void) -> FlexBox {
        let groups = keys.filter { !$0.isEmpty }
        return FlexBox(direction: .column, spacing: 10) {
            FlexBox(direction: .column, spacing: 6) {
                Text(heading, style: .meta, color: .secondary)
                if !text.isEmpty {
                    Text(text, style: .body)
                }
                if !ask.isEmpty {
                    Text(ask, style: .heading)
                }
            }
            .padding(20)
            .background(.card)
            for row in rows {
                FlexBox(direction: .column) {
                    Text(row.title, style: .body)
                    if !row.note.isEmpty {
                        Text(row.note, style: .meta, color: .secondary)
                    }
                }
                .padding(16)
                .background(.card)
                .onTap { act(row.action) }
            }
            for group in groups {
                ButtonGroup {
                    for key in group {
                        Button(label: key.label, style: key.quiet ? .secondary : .primary, onClick: { act(key.action) })
                    }
                }
            }
        }
    }
}