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
        VStack(spacing: Design.Space.xs) {
            ScrollView {
                LazyVStack(spacing: Design.Space.xxs) {
                    ForEach(session.projects) { project in row(project) }
                    if session.projects.isEmpty {
                        Text(session.isLive ? "No projects yet." : "Reaching your Mac…")
                            .textRole(.body, .secondary)
                            .padding(.top, Design.Space.xxl)
                    }
                }
            }
            .refreshable { await session.refreshChats() }
            .task { await session.refreshChats() }

            if let problem {
                Text(problem)
                    .font(Design.TextRole.caption.font)
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
            HStack(alignment: .top, spacing: Design.Space.s) {
                Image(systemName: "folder")
                    .iconWidth(.regular)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(project.name)
                        .textRole(.body)
                        .fontWeight(.semibold)
                    Text(project.folder.map(Self.shortened) ?? "No folder")
                        .textRole(.caption, .secondary)
                        .truncationMode(.middle)
                    Text(project.chatTitle ?? "No conversations")
                        .textRole(.label, .secondary)
                        .fontWeight(open ? .semibold : .regular)
                    if project.chatID != nil {
                        Text(project.updatedAt, format: .relative(presentation: .named))
                            .textRole(.caption, .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xs)
            .background(Design.Radius.shape(Design.Radius.control)
                .fill(open ? palette.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(project.chatID == nil)
    }

    /// A Mac path with its home folder (/Users/name) shown as ~.
    static func shortened(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users", !parts[2].isEmpty else { return path }
        return (["~"] + parts.dropFirst(3)).joined(separator: "/")
    }
}