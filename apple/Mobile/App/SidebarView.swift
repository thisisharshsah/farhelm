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
        VStack(spacing: 10) {
            // Search and New, as at the top of the Mac's sidebar.
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink.opacity(0.5))
                    TextField("Search", text: $query)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(palette.ink.opacity(0.07)))
                Button {
                    run {
                        try await session.newChat()
                        picked()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.shade)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(palette.accentGradient))
                }
                .buttonStyle(.plain)
                .disabled(!session.isLive)
                .accessibilityLabel("New chat")
            }

            Picker("Show", selection: $showProjects) {
                Text("Chats").tag(false)
                Text("Projects").tag(true)
            }
            .pickerStyle(.segmented)

            if showProjects {
                ProjectsView(picked: picked)
            } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { chat in row(chat) }
                    if shown.isEmpty {
                        Text(session.isLive ? (query.isEmpty ? "No chats yet." : "Nothing matches.") : "Reaching your Mac…")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.ink.opacity(0.45))
                            .padding(.top, 30)
                    }
                }
            }
            .refreshable { await session.refreshChats() }
            }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(palette.rose)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            macRow
        }
        .padding(12)
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
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.system(size: 15, weight: open ? .semibold : .regular))
                        .foregroundStyle(palette.ink.opacity(open ? 0.96 : 0.82))
                        .lineLimit(1)
                    Text(chat.date, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink.opacity(0.4))
                }
                Spacer(minLength: 4)
                if chat.waiting == true {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.amber)
                        .accessibilityLabel("Waiting for you")
                } else if chat.running == true || (open && session.meta.busy) {
                    LoadingMark(state: .working, size: 16)
                        .accessibilityLabel("Working")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(open ? palette.accent.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The Mac in use, how it is reached, and the Macs menu.
    private var macRow: some View {
        HStack(spacing: 10) {
            switch session.link {
            case .connecting:
                LoadingMark(state: .thinking, size: 18)
            case .live:
                Circle().fill(palette.mint).frame(width: 8, height: 8).frame(width: 18)
            case .failed:
                Circle().fill(palette.rose).frame(width: 8, height: 8).frame(width: 18)
            case .idle:
                Circle().fill(palette.ink.opacity(0.3)).frame(width: 8, height: 8).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.selected?.name ?? "No Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.9))
                    .lineLimit(1)
                Text(linkText)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink.opacity(0.45))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if case .failed = session.link {
                Button("Retry") { session.restart() }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accent)
            }
            Menu {
                if store.macs.count > 1 {
                    Picker("Mac", selection: Binding(get: { store.selected?.id ?? "" },
                                                     set: { id in
                                                         store.selectedID = id
                                                         session.restart()
                                                     })) {
                        ForEach(store.macs) { mac in Text(mac.name).tag(mac.id) }
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(palette.ink.opacity(0.08)))
            }
            .accessibilityLabel("Macs")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.ink.opacity(0.05)))
    }

    private var linkText: String {
        switch session.link {
        case .live(let host): return host.hasPrefix("100.") ? "Over Tailscale" : "On this network"
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
