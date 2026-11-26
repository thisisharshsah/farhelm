import CompanionDesign
import CompanionKit
import SwiftUI

/// The chats, as the Mac's sidebar has them: search and New at the top,
/// the chats newest first (a running task and one waiting on you marked),
/// and at the bottom the Mac in use and how it is reached. Picking a chat
/// opens it on the Mac and here.
struct SidebarView: View {
    @Environment(MacStore.self) private var store
    @Environment(LiveSession.self) private var session
    /// Called once a chat is picked (the iPhone closes the sidebar).
    var picked: () -> Void = {}
    @State private var query = ""
    @State private var pairing = false
    @State private var problem: String?
    @AppStorage("sidebarShowsProjects") private var showProjects = false

    private var palette: Palette { Design.palette() }

    private var shown: [ChatSummary] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return session.chats }
        return session.chats.filter { $0.title.localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        VStack(spacing: Design.Space.s) {
            // Search and New, as at the top of the Mac's sidebar.
            HStack(spacing: Design.Space.xs) {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: "magnifyingglass")
                        .iconWidth(.regular)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search", text: $query)
                        .textRole(.body)
                        .textInputAutocapitalization(.never)
                }
                .padding(Design.Space.xs)
                .background(Design.Fill.raised.style, in: Design.Radius.shape(Design.Radius.control))
                Button {
                    run {
                        try await session.newChat()
                        picked()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .glassButton(.prominent, size: .large)
                .disabled(!session.isLive)
                .accessibilityLabel("New chat")
            }

            SegmentedSwitcher("Show", options: [
                SwitcherOption(id: false, title: "Chats", symbol: "bubble.left"),
                SwitcherOption(id: true, title: "Projects", symbol: "folder")
            ], selection: $showProjects)

            if showProjects {
                ProjectsView(picked: picked)
            } else {
            ScrollView {
                LazyVStack(spacing: Design.Space.xxs) {
                    ForEach(shown) { chat in row(chat) }
                    if shown.isEmpty {
                        Text(session.isLive ? (query.isEmpty ? "No chats yet." : "Nothing matches.") : "Reaching your Mac…")
                            .textRole(.body, .secondary)
                            .padding(.top, Design.Space.xxl)
                    }
                }
            }
            .refreshable { await session.refreshChats() }
            }

            if let problem {
                Text(problem)
                    .font(Design.TextRole.caption.font)
                    .foregroundStyle(palette.rose)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            macRow
        }
        .padding(Design.Space.s)
        .sheet(isPresented: $pairing) {
            NavigationStack { PairView() }
        }
    }

    private func row(_ chat: ChatSummary) -> some View {
        let open = chat.id == session.meta.chat
        return Button {
            run {
                try await session.open(chat.id)
                picked()
            }
        } label: {
            HStack(spacing: Design.Space.xs) {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(chat.title)
                        .textRole(.body)
                        .fontWeight(open ? .semibold : .regular)
                    Text(chat.date, format: .relative(presentation: .named))
                        .textRole(.caption, .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if chat.waiting == true {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .textRole(.label)
                        .foregroundStyle(palette.amber)
                        .accessibilityLabel("Waiting for you")
                } else if chat.running == true || (open && session.meta.busy) {
                    LoadingMark(state: .working, size: Design.Icon.regular.width)
                        .accessibilityLabel("Working")
                }
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, Design.Space.xs)
            .background(Design.Radius.shape(Design.Radius.control)
                .fill(open ? palette.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The Mac in use, how it is reached, and the Macs menu.
    private var macRow: some View {
        HStack(spacing: Design.Space.s) {
            switch session.link {
            case .connecting:
                LoadingMark(state: .thinking, size: Design.Icon.regular.width)
            case .live:
                Circle().fill(palette.mint).frame(width: 8, height: 8).frame(width: 18)
            case .failed:
                Circle().fill(palette.rose).frame(width: 8, height: 8).frame(width: 18)
            case .idle:
                Circle().fill(palette.ink.opacity(0.3)).frame(width: 8, height: 8).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.selected?.name ?? "No Mac")
                    .textRole(.heading, .primary)
                    .lineLimit(1)
                    .foregroundStyle(palette.ink.opacity(0.9))
                Text(linkText)
                    .textRole(.caption, .secondary)
                    .lineLimit(2)
                    .foregroundStyle(palette.ink.opacity(0.45))
            }
            Spacer(minLength: 4)
            if case .failed = session.link {
                Button("Retry") { session.restart() }
                    .textRole(.caption, .primary)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
            }
            GlassesButton()
            Menu {
                if store.macs.count > 1 {
                    // A native menu section with a check on the Mac in use.
                    Section("Mac") {
                        ForEach(store.macs) { mac in
                            Button {
                                store.selectedID = mac.id
                                session.restart()
                            } label: {
                                if mac.id == store.selected?.id {
                                    Label(mac.name, systemImage: "checkmark")
                                } else {
                                    Text(mac.name)
                                }
                            }
                        }
                    }
                }
                Button("Pair Another Mac…", systemImage: "plus") { pairing = true }
                if let mac = store.selected {
                    Button("Forget \(mac.name)", systemImage: "trash", role: .destructive) {
                        store.remove(mac.id)
                        session.restart()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .textRole(.label)
                    .foregroundStyle(palette.ink.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(palette.ink.opacity(0.08)))
            }
            .accessibilityLabel("Macs")
        }
        .padding(Design.Space.s)
        .background(Design.Radius.shape(Design.Radius.tile).fill(palette.ink.opacity(0.05)))
    }

    private var linkText: String {
        switch session.link {
        case .live(.relay): return "Through your relay"
        case .live(.direct(let host)), .live(.local(let host)):
            return host.hasPrefix("100.") ? "Over Tailscale" : "On this network"
        case .connecting: return "Connecting…"
        case .failed(let why): return why
        case .idle: return "Paused"
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
