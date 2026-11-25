import AppKit
import CEFKit
import SwiftUI

/// Code mode's editor as VS Code: code-server, VS Code's open-source core
/// inside Companion, in a Chromium page on the panel, with the chat beside
/// it. Its extensions come from Open VSX. Companion signs in for the person
/// and opens the chat's repository.
struct VSCodePane: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var server = CodeServer.shared

    var body: some View {
        Group {
            switch server.state {
            case .ready:
                if let page = server.page {
                    EditorPage(tab: page, server: server)
                } else {
                    waiting("Opening the folder…")
                }
            case .failed(let problem):
                failed(problem)
            case .starting, .stopped:
                waiting("Starting VS Code…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelCard()
        .task(id: app.workspaceRoot) {
            await server.start()
            server.open(app.workspaceRoot)
        }
        .onAppear {
            server.showing = true
            // VS Code has its own explorer, so the conversations fold away
            // to give it the room; hovering their button still peeks them.
            if app.sidebarPinned {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { app.sidebarPinned = false }
                app.overlay?.setSidebar(false)
            }
        }
        .onDisappear { server.showing = false }
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 10) {
            LoadingMark(state: .working, size: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ problem: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Theme.ink.opacity(0.45))
            Text(problem)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Try again") {
                    Task {
                        await server.start()
                        server.open(app.workspaceRoot)
                    }
                }
                Button("Use Companion's editor") {
                    UserDefaults.standard.set(false, forKey: CodeServer.editorKey)
                    app.objectWillChange.send()
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The editor's page, set into the panel. On its sign-in page, the
/// password is typed in for the person.
private struct EditorPage: View {
    @ObservedObject var tab: ChromiumTab
    let server: CodeServer

    var body: some View {
        ZStack {
            LoadingMark(state: .working, size: 16)
            ChromiumHost(tab: tab, browser: tab.browser)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous))
        .padding(Theme.panelGap)
        // Signed in whenever the sign-in page shows, however it got there
        // (it may have loaded before this page was on screen), and again
        // after a moment if the first try met a page still settling.
        .task(id: "\(tab.address)|\(tab.loading)") {
            for _ in 0..<6 {
                guard !Task.isCancelled, tab.address.contains("/login") else { return }
                if !tab.loading { tab.evaluate(server.signInScript()) { _, _ in } }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
