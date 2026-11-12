import AppKit
import SwiftUI

/// The terminal in the workspace's bottom panel: commands run in the
/// folder, each to the end, with what they printed shown under them. The
/// folder a command ends in carries over to the next, so `cd` works.
///
/// It is not a full terminal: programs that need typing into while they
/// run (an editor, a prompt) belong in Terminal itself.
@MainActor
final class TerminalLog: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let text: String
        /// A command you typed, as opposed to what it printed.
        let command: Bool
        let failed: Bool
    }

    @Published var command = ""
    @Published private(set) var lines: [Line] = []
    @Published private(set) var running = false
    @Published private(set) var directory: String
    private var past: [String] = []
    private var pastIndex = 0
    /// Told when a command has finished, so the files can be looked at again.
    var finished: () -> Void = {}

    init(folder: String) {
        directory = folder
    }

    // MARK: Terminal

    private static let marker = "__COMPANION_WS_CWD__"

    func runCommand() {
        let entered = command.trimmingCharacters(in: .whitespaces)
        guard !entered.isEmpty, !running else { return }
        command = ""
        past.append(entered)
        pastIndex = past.count
        if entered == "clear" {
            lines = []
            return
        }
        add(entered, command: true)
        running = true
        let folder = directory.isEmpty ? NSHomeDirectory() : directory
        Task {
            // The folder the command ends in is reported back, so `cd` carries over.
            let script = "\(entered)\n__s=$?\nprintf '\\n\(Self.marker)%s\\n' \"$PWD\"\nexit $__s"
            let result = await Shell.run(script, in: folder, timeout: 300)
            var output = result.output
            if let range = output.range(of: Self.marker, options: .backwards) {
                let reported = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !reported.isEmpty { directory = reported }
                output = String(output[..<range.lowerBound])
            }
            output = output.trimmingCharacters(in: .newlines)
            if !output.isEmpty { add(output, command: false, failed: !result.ok) }
            if !result.ok, output.isEmpty { add("exit \(result.code)", command: false, failed: true) }
            running = false
            finished()
        }
    }

    /// Empties the log; what was typed before stays for Up and Down.
    func clear() {
        lines = []
    }

    /// Up and down through what was typed before.
    func recall(_ step: Int) {
        guard !past.isEmpty else { return }
        pastIndex = min(max(pastIndex + step, 0), past.count)
        command = pastIndex < past.count ? past[pastIndex] : ""
    }

    private func add(_ text: String, command: Bool, failed: Bool = false) {
        lines.append(Line(id: (lines.last?.id ?? 0) + 1, text: text, command: command, failed: failed))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }
}

/// Turns command output with ANSI escape codes into styled text: colours
/// (16, 256 and 24-bit) and bold are kept, other escape codes are dropped.
/// Runs with no colour are left plain so the view's own colour shows.
enum ANSI {
    static func styled(_ text: String) -> AttributedString {
        guard text.contains("\u{1B}") else { return AttributedString(text) }
        var result = AttributedString()
        var foreground: Color?
        var bold = false
        var chunk = ""

        func flush() {
            guard !chunk.isEmpty else { return }
            var piece = AttributedString(chunk)
            if let foreground { piece.foregroundColor = foreground }
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
            chunk = ""
        }

        func apply(_ params: String) {
            let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            var k = 0
            while k < codes.count {
                let code = codes[k]
                switch code {
                case 0: foreground = nil; bold = false
                case 1: bold = true
                case 22: bold = false
                case 30...37: foreground = basic(code - 30)
                case 90...97: foreground = basic(code - 90 + 8)
                case 39: foreground = nil
                case 38, 48:
                    var picked: Color?
                    if k + 2 < codes.count, codes[k + 1] == 5 {
                        picked = indexed(codes[k + 2]); k += 2
                    } else if k + 4 < codes.count, codes[k + 1] == 2 {
                        picked = Color(red: Double(codes[k + 2]) / 255,
                                       green: Double(codes[k + 3]) / 255,
                                       blue: Double(codes[k + 4]) / 255)
                        k += 4
                    }
                    if code == 38, let picked { foreground = picked }
                default: break
                }
                k += 1
            }
        }

        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            guard scalar == "\u{1B}" else {
                chunk.unicodeScalars.append(scalar)
                i += 1
                continue
            }
            flush()
            i += 1
            guard i < scalars.count else { break }
            if scalars[i] == "[" {
                // Control sequence: parameters, then one final letter.
                i += 1
                var params = ""
                while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) {
                    params.unicodeScalars.append(scalars[i])
                    i += 1
                }
                guard i < scalars.count else { break }
                if scalars[i] == "m" { apply(params) }
                i += 1
            } else if scalars[i] == "]" {
                // Operating system command (a window title, a link): skipped.
                while i < scalars.count, scalars[i] != "\u{07}", scalars[i] != "\u{1B}" { i += 1 }
                if i < scalars.count, scalars[i] == "\u{07}" { i += 1 } else if i + 1 < scalars.count { i += 2 }
            } else if scalars[i] == "(" || scalars[i] == ")" {
                i += 2
            } else {
                i += 1
            }
        }
        flush()
        return result
    }

    private static func basic(_ n: Int) -> Color {
        switch n {
        case 0: return Color(white: 0.45)
        case 1: return Color(red: 0.87, green: 0.33, blue: 0.33)
        case 2: return Color(red: 0.40, green: 0.75, blue: 0.40)
        case 3: return Color(red: 0.85, green: 0.70, blue: 0.30)
        case 4: return Color(red: 0.40, green: 0.55, blue: 0.95)
        case 5: return Color(red: 0.78, green: 0.45, blue: 0.85)
        case 6: return Color(red: 0.35, green: 0.75, blue: 0.80)
        case 7: return Color(white: 0.80)
        case 8: return Color(white: 0.55)
        case 9: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case 10: return Color(red: 0.50, green: 0.90, blue: 0.50)
        case 11: return Color(red: 1.0, green: 0.85, blue: 0.40)
        case 12: return Color(red: 0.55, green: 0.70, blue: 1.0)
        case 13: return Color(red: 0.92, green: 0.58, blue: 1.0)
        case 14: return Color(red: 0.45, green: 0.90, blue: 0.95)
        default: return Color(white: 0.95)
        }
    }

    private static func indexed(_ value: Int) -> Color {
        let n = max(0, min(255, value))
        if n < 16 { return basic(n) }
        if n >= 232 { return Color(white: Double(n - 232) / 23 * 0.9 + 0.05) }
        let c = n - 16
        func level(_ x: Int) -> Double { x == 0 ? 0 : (Double(x) * 40 + 55) / 255 }
        return Color(red: level(c / 36), green: level((c / 6) % 6), blue: level(c % 6))
    }
}

/// The Terminal tab of the workspace's bottom panel.
struct TerminalPane: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        // The log is made the first time the tab shows, and kept.
        TerminalTab(model: model.terminalLog())
    }
}

private struct TerminalTab: View {
    @ObservedObject var model: TerminalLog
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.lines.isEmpty {
                            Text("Run commands here, in the workspace's folder. Each one runs to the end and shows what it printed; programs that need you to type while they run (an editor, a prompt) belong in Terminal itself.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.lines) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.command ? AttributedString("$ " + line.text) : ANSI.styled(line.text))
                                    .font(.system(size: 11, weight: line.command ? .semibold : .regular, design: .monospaced))
                                    .foregroundStyle(line.command ? Theme.accent
                                                     : (line.failed ? Theme.rose : Theme.ink.opacity(0.86)))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if !line.command {
                                    // Copies what the command printed, without the colour codes.
                                    Button {
                                        let plain = String(ANSI.styled(line.text).characters)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(plain, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Theme.ink.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copy output")
                                }
                            }
                            .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(10)
                }
                .onChange(of: model.lines.count) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            Rectangle()
                .fill(Theme.ink.opacity(0.07))
                .frame(height: 1)
            HStack(spacing: 6) {
                // The whole folder, with ~ for home; long paths lose their start, not their end.
                Text(((model.directory.isEmpty ? NSHomeDirectory() : model.directory) as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 260, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(model.directory)
                Text("$")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                TextField(model.running ? "Running…" : "Command", text: $model.command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                    .focused($focused)
                    .disabled(model.running)
                    .onSubmit {
                        model.runCommand()
                        focused = true
                    }
                    .onKeyPress(.upArrow) {
                        model.recall(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.recall(1)
                        return .handled
                    }
                if model.running {
                    LoadingMark(state: .working, size: 14)
                }
                Button {
                    model.clear()
                    focused = true
                } label: {
                    Image(systemName: "eraser")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                .help("Clear (Cmd+K)")
                .disabled(model.lines.isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
        .onAppear { focused = true }
    }
}
