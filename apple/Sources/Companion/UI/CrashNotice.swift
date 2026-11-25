import AppKit
import CompanionBoard
import SwiftUI

/// One quiet line at the top of the chat after a launch that followed a
/// crash, with a button that makes the crash a task on the board (the
/// report goes with it). It takes no room when there is nothing to tell,
/// and it is a line, not an alert: the person was in the middle of
/// something when the app went, and is again now.
struct CrashNotice: View {
    @ObservedObject private var crashes = CrashRecorder.shared

    var body: some View {
        if let record = crashes.toTell {
            line("Companion quit unexpectedly last time", help: record.reason) {
                if crashes.project != nil {
                    BoardButton("Add to board", icon: "plus") { crashes.addToBoard() }
                        .help("Adds it to the board as a task, with the report attached")
                } else {
                    // With no project there is no board to add it to; the
                    // report can still be read.
                    BoardButton("Show report", icon: "doc.text") {
                        NSWorkspace.shared.activateFileViewerSelecting([crashes.file(of: record)])
                    }
                }
                IconButton("xmark", help: "Dismiss") { crashes.dismiss() }
            }
        } else if let said = crashes.said {
            line(said, help: "") { EmptyView() }
        }
    }

    private func line<Buttons: View>(_ text: String, help: String,
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(help)
            Spacer(minLength: 8)
            buttons()
        }
        .frame(minHeight: 24)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
        .transition(.opacity)
    }
}
