import CompanionDesign
import CompanionKit
import SwiftUI

/// The Mac's projects, as its sidebar has them: each with its newest chat
/// and how long ago it was active. Tapping a project opens that chat on
/// the Mac and here; a project with no chats yet shows as such.
struct ProjectsView: View {
    @Environment(LiveSession.self) private var session
    /// Called once a chat is picked (the iPhone closes the sidebar).
    var picked: () -> Void = {}
    @State private var problem: String?

    private var palette: Palette { Design.palette() }

    var body: some View {
        VStack(spacing: 6) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.projects) { project in row(project) }
                    if session.projects.isEmpty {
                        Text(session.isLive ? "No projects yet." : "Reaching your Mac…")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.ink.opacity(0.45))
                            .padding(.top, 30)
                    }
                }
            }
            .refreshable { await session.refreshChats() }
            .task { await session.refreshChats() }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(palette.rose)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ project: ProjectSummary) -> some View {
        let open = project.chatID != nil && project.chatID == session.meta.chat
        return Button {
            guard let chatID = project.chatID else { return }
            Task {
                do {
                    try await session.open(chatID)
                    problem = nil
                    picked()
                } catch {
                    problem = error.localizedDescription
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink.opacity(0.55))
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.92))
                        .lineLimit(1)
                    Text(project.chatTitle ?? "No conversations")
                        .font(.system(size: 13, weight: open ? .semibold : .regular))
                        .foregroundStyle(palette.ink.opacity(project.chatID == nil ? 0.4 : 0.75))
                        .lineLimit(1)
                    if project.chatID != nil {
                        Text(project.updatedAt, format: .relative(presentation: .named))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.ink.opacity(0.4))
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(open ? palette.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(project.chatID == nil)
    }
}