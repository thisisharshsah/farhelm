import AppKit
import SwiftUI

/// The whole output of what runs in the background, kept by channel, as an
/// editor's Output panel: each build in full, and every command the agent
/// ran with all it printed (the chat keeps only the end of it).
@MainActor
final class OutputLog: ObservableObject {
    static let shared = OutputLog()

    @Published private(set) var channels: [String: String] = [:]
    @Published var channel = "Build"
    /// The channels in the order they first wrote.
    @Published private(set) var order: [String] = []

    /// Each channel keeps its newest output, up to this many characters.
    private static let limit = 300_000

    /// A command that failed, with what it printed, to hand to the agent.
    struct Failure: Equatable {
        let command: String
        let output: String
    }
    /// Each channel's last command, when it failed; cleared when the next
    /// one goes well.
    @Published private(set) var failures: [String: Failure] = [:]

    /// Writes a command's output, noting whether it failed.
    func append(_ name: String, command: String, ok: Bool, _ text: String) {
        failures[name] = ok ? nil : Failure(command: command, output: String(text.suffix(6000)))
        append(name, text)
    }

    func append(_ name: String, _ text: String) {
        if channels[name] == nil {
            order.append(name)
            if channels.isEmpty { channel = name }
        }
        let stamp = Date().formatted(date: .omitted, time: .standard)
        var log = (channels[name] ?? "") + "[\(stamp)] " + text
        if !log.hasSuffix("\n") { log += "\n" }
        if log.count > Self.limit { log = String(log.suffix(Self.limit)) }
        channels[name] = log
    }

    func clear(_ name: String) {
        channels[name] = ""
        failures[name] = nil
    }
}

/// The Output tab of the workspace's bottom panel.
struct OutputTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var log = OutputLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if log.order.isEmpty {
                    Text("Builds and the agent's commands write here.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                } else {
                    Menu {
                        ForEach(log.order, id: \.self) { name in
                            Button(name) { log.channel = name }
                        }
                    } label: {
                        Text(log.channel)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Which output to show")
                }
                Spacer(minLength: 4)
                if let failure = log.failures[log.channel] {
                    Button {
                        app.fixCommand(failure.command, output: failure.output)
                    } label: {
                        Label("Fix", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Have the agent find why \(failure.command) failed and fix it")
                }
                IconButton("doc.on.doc", help: "Copy this output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.channels[log.channel] ?? "", forType: .string)
                }
                IconButton("trash", help: "Clear this output") { log.clear(log.channel) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Text(log.channels[log.channel] ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(0.82))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
                // New output scrolls into view.
                .onChange(of: log.channels[log.channel]?.count ?? 0) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}
