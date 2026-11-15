import CompanionDesign
import CompanionKit
import SwiftUI

/// The engines on the Mac and their models, as the Mac's model picker has
/// them: each engine collapsed, the one in use marked with its model; a tap
/// opens it, and a tap on a model makes it the one that answers.
struct ModelSheet: View {
    @Environment(LiveSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var open: Set<String> = []
    @State private var problem: String?
    @State private var loading = true

    private var palette: Palette { Design.palette() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 6) {
                    if loading && session.engines.isEmpty {
                        LoadingMark(state: .thinking, size: 32).padding(.top, 40)
                    }
                    ForEach(session.engines) { engine in
                        engineRow(engine)
                        if open.contains(engine.id) {
                            VStack(spacing: 2) {
                                ForEach(engine.models) { model in modelRow(engine, model) }
                            }
                            .padding(.leading, 18)
                            .transition(.opacity)
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(palette.rose)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do { try await session.refreshEngines() } catch { problem = error.localizedDescription }
            loading = false
        }
    }

    private func engineRow(_ engine: Engine) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                if open.contains(engine.id) { open.remove(engine.id) } else { open.insert(engine.id) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: engine.place == "account" ? "person.fill" : (engine.place == "local" ? "lock.fill" : "cloud"))
                    .font(.system(size: 12))
                    .foregroundStyle(engine.inUse ? palette.accent : palette.ink.opacity(0.5))
                    .frame(width: 18)
                Text(engine.name)
                    .font(.system(size: 15, weight: engine.inUse ? .semibold : .regular))
                    .foregroundStyle(engine.inUse ? palette.accent : palette.ink.opacity(0.9))
                Spacer()
                if engine.inUse {
                    Text(engine.models.first { $0.id == engine.current }?.title ?? "Default")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink.opacity(0.5))
                        .lineLimit(1)
                }
                Image(systemName: open.contains(engine.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.ink.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(engine.inUse ? palette.accent.opacity(0.10) : palette.ink.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelRow(_ engine: Engine, _ model: Engine.Model) -> some View {
        let chosen = engine.inUse && engine.current == model.id
        return Button {
            Task {
                do {
                    try await session.choose(engine: engine.id, model: model.id)
                    dismiss()
                } catch {
                    problem = error.localizedDescription
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(chosen ? palette.accent : palette.ink.opacity(0.35))
                Text(model.title)
                    .font(.system(size: 15, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(palette.ink.opacity(0.9))
                Spacer()
                if !model.note.isEmpty {
                    Text(model.note)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(chosen ? palette.accent.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
