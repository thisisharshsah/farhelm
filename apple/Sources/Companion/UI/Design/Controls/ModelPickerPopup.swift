import AppKit
import SwiftUI

/// How a model rates on the three things a choice between models turns
/// on, each from 1 to 4. Only families whose standing is known are rated
/// (Anthropic's, by name); any other model shows no bars, since a guessed
/// rating would mislead more than none. A model that runs on this Mac
/// costs nothing by use.
enum ModelRatings {
    struct Rating {
        var smart: Int?
        var fast: Int?
        var cost: Int?
        var isEmpty: Bool { smart == nil && fast == nil && cost == nil }
    }

    static func rating(title: String, model: String, place: String) -> Rating {
        let name = (title + " " + model).lowercased()
        var rating = Rating()
        if name.contains("fable") || name.contains("mythos") || name.contains("opus") {
            rating = Rating(smart: 4, fast: 2, cost: 4)
        } else if name.contains("sonnet") {
            rating = Rating(smart: 3, fast: 3, cost: 2)
        } else if name.contains("haiku") {
            rating = Rating(smart: 2, fast: 4, cost: 1)
        }
        if place == "local" { rating.cost = 1 }
        return rating
    }
}

/// A rating as four small bars, like a signal meter, with its name under
/// it where there is room.
private struct MeterBars: View {
    let value: Int?
    let label: String
    let labelled: Bool
    let tint: Color

    var body: some View {
        if let value {
            VStack(spacing: 2) {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(1...4, id: \.self) { step in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(step <= value ? tint : Theme.ink.opacity(0.18))
                            .frame(width: 3, height: 2 + CGFloat(step) * 2.25)
                    }
                }
                .frame(height: 11, alignment: .bottom)
                if labelled {
                    Text(label)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.ink.opacity(0.42))
                }
            }
            .help("\(label): \(value) of 4")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) \(value) of 4")
        }
    }
}

/// The model picker: opens in place, just above the chat box. Compact to
/// begin with: the engines as a row of marks (the star is the models used
/// last, across engines), a line per model with its ratings as bars, and
/// under the list what there is to know about the model the pointer is
/// on. "More" widens it in place, with the engines' names, the bars'
/// names and a line about each model. Choosing a model switches engine
/// and model together and closes the list. Engines that are not set up
/// yet are not listed: the last row leads to where they are added.
struct ModelPicker: View {
    /// What a caller supplies to list its own models in this same picker
    /// (the board's task cards and supervisor): the listing, what choosing
    /// does, rows that are not models, and the footer rows. Without one the
    /// picker is the chat's.
    struct Source {
        struct Pinned: Identifiable {
            let id: String
            let title: String
            let detail: String
            let symbol: String
        }

        struct Footer: Identifiable {
            let title: String
            let symbol: String
            var closes = true
            let action: () -> Void
            var id: String { title }
        }

        var listing: ModelChoices.Listing
        var recentKey: String
        var pinned: [Pinned] = []
        var footers: [Footer] = []
        var choose: (String) -> Void
    }

    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @Binding var isOpen: Bool
    var source: Source? = nil
    /// The subscription tools on this Mac, listed once they are found.
    @ObservedObject private var agents = CLIAgents.shared

    @State private var query = ""
    /// The engine whose models show: an engine's id, or "recent".
    @State private var tab = "recent"
    @State private var wide = false
    /// The row the pointer or the arrow keys are on.
    @State private var highlighted: String?
    @FocusState private var searching: Bool

    private var recent: RecentChoices { RecentChoices(key: source?.recentKey ?? "modelPicker.recent", limit: 5) }

    struct Row: Identifiable {
        let id: String
        let engine: EngineCatalog.Engine
        let model: String
        let title: String
        let engineName: String
        let note: String?
        let place: String
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { isOpen = false }
    }

    /// Every model that can be chosen, in the order the engines list them.
    static func rows(_ listing: ModelChoices.Listing) -> [Row] {
        listing.sections.flatMap { section in
            section.items.compactMap { item -> Row? in
                guard let choice = listing.choices[item.id] else { return nil }
                return Row(id: item.id, engine: choice.engine, model: choice.model, title: item.title,
                           engineName: EngineCatalog.name(choice.engine),
                           note: EngineCatalog.note(choice.engine, choice.model),
                           place: section.id)
            }
        }
    }

    /// The rows that show: what the search finds across every engine, the
    /// models used last, or one engine's models.
    private func shown(_ all: [Row], current: String?) -> [Row] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !words.isEmpty {
            return all.filter { ($0.title + " " + $0.engineName + " " + $0.model).lowercased().contains(words) }
        }
        if tab == "recent" {
            var ids = recent.ids()
            if let current, !ids.contains(current) { ids.insert(current, at: 0) }
            let found = ids.compactMap { id in all.first { $0.id == id } }
            if !found.isEmpty { return found }
            // Nothing chosen yet: the models of the engine in use.
            if let engine = all.first(where: { $0.id == current })?.engine.id {
                return all.filter { $0.engine.id == engine }
            }
            return all
        }
        return all.filter { $0.engine.id == tab }
    }

    private func choose(_ row: Row) {
        recent.record(row.id)
        if let source {
            source.choose(row.id)
        } else {
            EngineCatalog.choose(row.engine, row.model)
        }
        close()
    }

    private func move(_ step: Int, in list: [Row]) {
        guard !list.isEmpty else { return }
        let place = list.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : list.count)
        highlighted = list[min(max(place + step, 0), list.count - 1)].id
    }

    var body: some View {
        let listing = source?.listing ?? ModelChoices.listing()
        let all = Self.rows(listing)
        let list = shown(all, current: listing.current)
        let engines = all.reduce(into: [EngineCatalog.Engine]()) { found, row in
            if !found.contains(where: { $0.id == row.engine.id }) { found.append(row.engine) }
        }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                TextField("Search models", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searching)
                    .onSubmit {
                        if let row = list.first(where: { $0.id == highlighted }) ?? list.first { choose(row) }
                    }
                Button(wide ? "Less" : "More") {
                    withAnimation(.easeOut(duration: 0.14)) { wide.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(wide ? Theme.accent : Theme.ink.opacity(0.7))
                .help(wide ? "Back to the compact list" : "Show the engines' names and a line about each model")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            HStack(spacing: 4) {
                tabButton("recent", name: "Recent", help: "The models used last") {
                    Image(systemName: "star.fill").font(.system(size: 10.5))
                }
                ForEach(engines) { engine in
                    tabButton(engine.id, name: EngineCatalog.name(engine), help: EngineCatalog.name(engine)) {
                        EngineLogo(kind: engine.kind, tool: engine.tool, size: 13)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    if list.isEmpty {
                        Text(query.isEmpty ? "No models here yet" : "No model by that name")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink.opacity(0.5))
                            .padding(.vertical, 16)
                    }
                    if query.isEmpty, let pinned = source?.pinned {
                        ForEach(pinned) { pin in pinnedView(pin) }
                    }
                    ForEach(list) { row in
                        rowView(row, current: listing.current, withEngine: tab == "recent" || !query.isEmpty)
                    }
                }
                .padding(4)
            }
            // As tall as its rows, up to a cap, then it scrolls. Given
            // only a cap, a list that scrolls took no height at all here
            // (it hangs over the chat with nothing to size it), and the
            // picker opened with its models hidden.
            .frame(height: min(CGFloat(max(list.count, 1)) * (wide ? 46 : 31) + 8, 264))

            Divider()

            detail(list.first { $0.id == highlighted } ?? all.first { $0.id == listing.current })

            Divider()

            ForEach(source?.footers ?? [Source.Footer(title: "Add or change engines", symbol: "plus.circle") {
                app.openSettings()
            }]) { footer in
                Button {
                    if footer.closes { close() }
                    footer.action()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: footer.symbol).font(.system(size: 11))
                        Text(footer.title).font(.system(size: 11.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: wide ? 590 : 306)
        .glassPanel(radius: Design.Radius.card)
        // It sits over other things, so it needs a solid base under the glass.
        .background(Design.Radius.shape(Design.Radius.card).fill(Theme.shade.opacity(0.82)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model")
        .onExitCommand(perform: close)
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.downArrow) { move(1, in: list); return .handled }
        .onKeyPress(.upArrow) { move(-1, in: list); return .handled }
        .onChange(of: query) { highlighted = nil }
        .onChange(of: tab) { highlighted = nil }
        .onAppear {
            // With nothing chosen before, it opens on the engine in use.
            if recent.ids().isEmpty, let engine = all.first(where: { $0.id == listing.current })?.engine.id {
                tab = engine
            }
            highlighted = listing.current
            searching = true
            if EngineCatalog.ready(.farhelm) { app.loadFarhelmModels() }
            if EngineCatalog.ready(.anthropic) { app.loadAnthropicModels() }
            agents.check()
            agents.refreshLimits()
            agents.refreshModels()
        }
    }

    /// One of the marks that choose whose models show.
    private func tabButton<Mark: View>(_ id: String, name: String, help: String,
                                       @ViewBuilder mark: () -> Mark) -> some View {
        let on = tab == id && query.isEmpty
        let symbol = mark()
        return Button {
            query = ""
            tab = id
        } label: {
            HStack(spacing: 5) {
                symbol
                if wide {
                    Text(name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(on ? Theme.ink.opacity(0.95) : Theme.ink.opacity(0.6))
            // Compact, the marks share the row evenly; widened, each is as
            // wide as its name, so no name is cut short.
            .padding(.horizontal, wide ? 7 : 0)
            .frame(maxWidth: wide ? nil : .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(on ? Theme.accent.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(on ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pinnedView(_ pin: Source.Pinned) -> some View {
        Button {
            source?.choose(pin.id)
            close()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: pin.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                VStack(alignment: .leading, spacing: 1) {
                    Text(pin.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.95))
                        .lineLimit(1)
                    Text(pin.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pin.title)
    }

    /// A model: its name, and its ratings as bars.
    private func rowView(_ row: Row, current: String?, withEngine: Bool) -> some View {
        let isCurrent = row.id == current
        let isOn = row.id == highlighted
        let rating = ModelRatings.rating(title: row.title, model: row.model, place: row.place)
        let tint = isCurrent ? Theme.accent : Theme.ink.opacity(0.78)
        return Button { choose(row) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 9) {
                    if withEngine {
                        EngineLogo(kind: row.engine.kind, tool: row.engine.tool, size: 11)
                            .foregroundStyle(Theme.ink.opacity(0.55))
                    }
                    Text(row.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    MeterBars(value: rating.smart, label: "Smart", labelled: wide, tint: tint)
                    MeterBars(value: rating.fast, label: "Fast", labelled: wide, tint: tint)
                    MeterBars(value: rating.cost, label: "Cost", labelled: wide, tint: tint)
                }
                if wide {
                    Text(([row.engineName] + (row.note.map { [$0] } ?? [])).joined(separator: " \u{00B7} "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(isCurrent ? Theme.accent.opacity(0.14) : Theme.ink.opacity(isOn ? 0.07 : 0)))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(isCurrent ? Theme.accent.opacity(0.45) : Color.clear, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { highlighted = row.id } }
        .accessibilityLabel(row.title + ", " + row.engineName)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// What there is to know about the model the pointer is on: where it
    /// runs and what that costs, and what is left of the plan.
    private func detail(_ row: Row?) -> some View {
        var parts: [String] = []
        if let row {
            parts.append(row.engineName)
            if let note = row.note { parts.append(note) }
            switch row.place {
            case "local": parts.append("Runs on this Mac, nothing leaves it")
            case "api": parts.append("Billed by use")
            default: parts.append("In your plan")
            }
            if row.engine.kind == .subscription, let tool = row.engine.tool, let left = agents.limitsLine(for: tool) {
                parts.append(left)
            }
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(row?.title ?? "No model chosen")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.95))
                .lineLimit(1)
            Text(parts.joined(separator: " \u{00B7} "))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink.opacity(0.62))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !wide {
                Text("Bars: smart, fast, cost")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.ink.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
