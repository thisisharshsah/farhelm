import CompanionDesign
import CompanionKit
import SwiftUI

/// The engines on the Mac and their models, in the same searchable picker
/// the Mac chooses a model with: one section for each engine, the model in
/// use checked, and a tap on a model makes it the one that answers. The
/// sheet and its bar are the system's glass; the list sits on a plain
/// background.
struct ModelSheet: View {
    @Environment(LiveSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var loading = true

    /// One model of one engine.
    private struct Choice: Hashable {
        let engine: String
        let model: String
    }

    private var sections: [SelectionSection<Choice>] {
        session.engines.map { engine in
            SelectionSection(
                id: engine.id, title: engine.name, symbol: Self.symbol(engine.place),
                items: engine.models.map { model in
                    SelectionItem(id: Choice(engine: engine.id, model: model.id), title: model.title,
                                  subtitle: model.note.isEmpty ? nil : model.note,
                                  badges: Self.badges(engine.place), keywords: [engine.name])
                })
        }
    }

    private var current: Choice? {
        session.engines.first(where: \.inUse).map { Choice(engine: $0.id, model: $0.current) }
    }

    private static func symbol(_ place: String) -> String {
        switch place {
        case "account": "person.fill"
        case "local": "lock.fill"
        default: "cloud"
        }
    }

    private static func badges(_ place: String) -> [SelectionBadge] {
        switch place {
        case "local": [SelectionBadge("On the Mac", symbol: "lock.fill", tone: .positive)]
        case "account": [SelectionBadge("Account", symbol: "person.fill")]
        default: []
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Design.Space.xs) {
                if loading && session.engines.isEmpty {
                    LoadingMark(state: .thinking, size: Design.Space.xxl)
                        .padding(.top, Design.Space.xxl)
                    Spacer(minLength: 0)
                } else {
                    SearchablePicker(title: "Model", sections: sections, selection: current,
                                     prompt: "Search models", maxHeight: .infinity, framed: false,
                                     autoFocus: false, onSelect: choose, onClose: { dismiss() })
                }
                if let problem {
                    Text(problem)
                        .font(Design.TextRole.caption.font)
                        .foregroundStyle(Design.Tone.critical.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Design.Space.m)
                        .padding(.bottom, Design.Space.xs)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Design.Fill.content.style)
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

    private func choose(_ choice: Choice) {
        Task {
            do {
                try await session.choose(engine: choice.engine, model: choice.model)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
