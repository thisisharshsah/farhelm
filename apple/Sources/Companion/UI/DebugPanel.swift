import AppKit
import SwiftUI

/// The Debug tab of the workspace panel: run and step, the call stack, the
/// variables of the frame in view, the breakpoints, and a console that
/// shows what the program prints and evaluates expressions.
struct DebugTab: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var debug = DebugModel.shared
    @State private var expression = ""
    @State private var opened: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Variables")
                        if debug.scopes.isEmpty {
                            note(debug.isStopped ? "No variables here." : "Shown when the program is stopped.")
                        }
                        ForEach(debug.scopes.indices, id: \.self) { index in
                            let scope = debug.scopes[index]
                            if debug.scopes.count > 1 {
                                Text(scope.name)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink.opacity(0.55))
                                    .padding(.horizontal, 10)
                                    .padding(.top, 4)
                            }
                            variables(scope.variables, depth: 0)
                        }
                        section("Call stack")
                        if debug.frames.isEmpty { note("Shown when the program is stopped.") }
                        ForEach(debug.frames) { frame in
                            FrameRow(frame: frame, selected: frame.id == debug.selectedFrame, root: model.root) {
                                Task { await debug.select(frame) }
                            }
                        }
                        section("Breakpoints")
                        if debug.breakpoints.isEmpty {
                            note("F9 in the editor, or a click in the strip left of the code, sets one.")
                        }
                        ForEach(debug.breakpoints.keys.sorted(), id: \.self) { file in
                            ForEach((debug.breakpoints[file] ?? []).sorted(), id: \.self) { line in
                                BreakpointRow(name: model.relative(file), line: line,
                                              open: { model.open(file, line: line) },
                                              remove: { debug.toggle(file, line: line) })
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .frame(width: 280)
                Rectangle().fill(Theme.ink.opacity(0.07)).frame(width: 1)
                consoleView
            }
        }
    }

    private var status: String {
        switch debug.state {
        case .idle: return "Not running"
        case .building: return "Building \(debug.program)"
        case .starting: return "Starting \(debug.program)"
        case .running: return "Running \(debug.program)"
        case .stopped(let why): return why
        case .ended(let why): return why
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if debug.state == .building || debug.state == .starting {
                LoadingMark(state: .working, size: 13)
            }
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(debug.isStopped ? Theme.amber : Theme.ink.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if debug.active {
                if debug.isStopped {
                    IconButton("play.fill", help: "Continue (F5)", tint: Theme.mint) { debug.resume() }
                } else {
                    IconButton("pause.fill", help: "Pause") { debug.pause() }
                }
                IconButton("arrow.uturn.forward", help: "Step over (F10)") { debug.stepOver() }
                    .disabled(!debug.isStopped)
                IconButton("arrow.down.to.line", help: "Step into (F11)") { debug.stepIn() }
                    .disabled(!debug.isStopped)
                IconButton("arrow.up.to.line", help: "Step out (⇧F11)") { debug.stepOut() }
                    .disabled(!debug.isStopped)
                IconButton("arrow.clockwise", help: "Restart") { debug.restart() }
                IconButton("stop.fill", help: "Stop (⇧F5)", tint: Theme.rose) { debug.stop() }
            } else {
                IconButton("play.fill", help: "Start debugging (F5)", tint: Theme.mint) { debug.start(in: model.root) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var consoleView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(debug.console.isEmpty ? "What the program prints shows here." : debug.console)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(debug.console.isEmpty ? 0.45 : 0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: debug.console.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                TextField(debug.isStopped ? "Evaluate an expression" : "Stop at a breakpoint to evaluate", text: $expression)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .onSubmit {
                        let text = expression.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        debug.evaluate(text)
                        expression = ""
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.ink.opacity(0.04))
        }
    }

    private func variables(_ list: [DebugModel.Variable], depth: Int) -> AnyView {
        AnyView(ForEach(list) { variable in
            VariableRow(variable: variable, depth: depth, open: opened.contains(variable.reference)) {
                if opened.contains(variable.reference) {
                    opened.remove(variable.reference)
                    debug.collapse(variable)
                } else {
                    opened.insert(variable.reference)
                    debug.expand(variable)
                }
            }
            if variable.reference > 0, opened.contains(variable.reference), depth < 8,
               let children = debug.members[variable.reference] {
                variables(children, depth: depth + 1)
            }
        })
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.ink.opacity(0.45))
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 3)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink.opacity(0.45))
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VariableRow: View {
    let variable: DebugModel.Variable
    let depth: Int
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(variable.reference > 0 ? 0.45 : 0))
                .frame(width: 10)
            Text(variable.name)
                .foregroundStyle(Theme.accent)
            Text(variable.value)
                .foregroundStyle(Theme.ink.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.leading, 8 + CGFloat(depth) * 12)
        .padding(.trailing, 8)
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture { if variable.reference > 0 { toggle() } }
        .help(variable.type.isEmpty ? variable.value : "\(variable.type): \(variable.value)")
        .contextMenu {
            Button("Copy Value") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(variable.value, forType: .string)
            }
        }
    }
}

private struct FrameRow: View {
    let frame: DebugModel.Frame
    let selected: Bool
    let root: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(frame.name)
                .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(frame.path == nil ? 0.45 : 0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            if let path = frame.path {
                Text("\((path as NSString).lastPathComponent):\(frame.line)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink.opacity(0.45))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accent.opacity(0.14) : (hover ? Theme.ink.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

private struct BreakpointRow: View {
    let name: String
    let line: Int
    let open: () -> Void
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.rose).frame(width: 8, height: 8)
            Text("\(name):\(line)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if hover {
                IconButton("xmark", help: "Remove this breakpoint", action: remove)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(hover ? Theme.ink.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }
}
