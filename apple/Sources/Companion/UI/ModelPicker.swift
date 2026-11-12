import AppKit
import SwiftUI

extension LLMProviderKind {
    /// The engine's name on its own, without where it runs.
    var shortName: String {
        switch self {
        case .farhelm: return "Farhelm"
        case .anthropic: return "Claude"
        case .openai: return "OpenAI"
        case .ollama: return "Ollama"
        case .subscription: return "Subscriptions"
        }
    }

    var icon: String {
        switch self {
        case .farhelm: return "server.rack"
        case .anthropic: return "sparkle"
        case .openai: return "circle.hexagongrid"
        case .ollama: return "desktopcomputer"
        case .subscription: return "person.badge.key"
        }
    }

    /// Runs on this Mac, so nothing leaves it.
    var isLocal: Bool { self == .farhelm || self == .ollama }
}

/// An engine's own logo, drawn in one colour so it takes a tint like the
/// symbols around it. A subscription tool has its own. The logos are SVG
/// files in the app's Engines folder, named after the engine or the tool's
/// id, so a new one is added by dropping a file in; an engine without one
/// shows its symbol.
struct EngineLogo: View {
    let kind: LLMProviderKind
    var tool: String? = nil
    var size: CGFloat = 11

    private static var loaded: [String: NSImage?] = [:]

    private static func image(_ name: String) -> NSImage? {
        if let known = loaded[name] { return known }
        var image: NSImage?
        if let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Engines") {
            image = NSImage(contentsOf: url)
            image?.isTemplate = true
        }
        loaded[name] = image
        return image
    }

    var body: some View {
        if let image = Self.image(tool ?? kind.rawValue) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: kind.icon)
                .font(.system(size: size - 1, weight: .semibold))
        }
    }
}

/// Model identifiers written the way people say them: "claude-opus-5-5"
/// reads "Opus 5.5", "gpt-oss-20b" reads "GPT OSS 20B". The engine's name
/// is left out, since it is always shown beside the model.
enum ModelName {
    private static let acronyms: Set<String> = ["gpt", "oss", "llm", "ai", "xl", "hd", "it"]

    static func pretty(_ id: String) -> String {
        guard !id.isEmpty else { return "Auto" }
        var name = id.lowercased()
        for prefix in ["claude-", "models/"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        // Words and numbers, without a release date or "latest" on the end.
        let tokens = name
            .split(whereSeparator: { "-_:/ ".contains($0) })
            .map(String.init)
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) && $0 != "latest" }

        var parts: [(isNumber: Bool, text: String)] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.allSatisfy(\.isNumber) {
                // "5", "5" is the version 5.5.
                var run = [token]
                while index + 1 < tokens.count, tokens[index + 1].allSatisfy(\.isNumber), tokens[index + 1].count <= 2 {
                    index += 1
                    run.append(tokens[index])
                }
                parts.append((true, run.joined(separator: ".")))
            } else if acronyms.contains(token) || isSize(token) {
                parts.append((false, token.uppercased()))
            } else {
                parts.append((false, token.prefix(1).uppercased() + token.dropFirst()))
            }
            index += 1
        }
        // A version written first ("3-5-sonnet") goes after the name.
        if parts.count > 1, parts[0].isNumber, let lastWord = parts.lastIndex(where: { !$0.isNumber }) {
            let version = parts.removeFirst()
            parts.insert(version, at: lastWord)
        }
        let result = parts.map(\.text).joined(separator: " ")
        return result.isEmpty ? id : result
    }

    /// A subscription tool's model, said the same way. A variant in
    /// brackets ("sonnet[1m]") goes after the name: "Sonnet (1M)".
    static func prettyTool(_ id: String) -> String {
        guard let open = id.firstIndex(of: "["), id.hasSuffix("]") else { return pretty(id) }
        let variant = id[id.index(after: open)..<id.index(before: id.endIndex)].uppercased()
        return "\(pretty(String(id[..<open]))) (\(variant))"
    }

    /// A parameter count such as "20b" or "7.5m".
    private static func isSize(_ token: String) -> Bool {
        guard let last = token.last, "bkm".contains(last), token.count > 1 else { return false }
        return token.dropLast().allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// The button in the chat box that shows which engine and model answer, and
/// opens the picker.
struct ModelPill: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var isOpen: Bool
    /// Told when the pointer comes over the button and leaves it.
    var onHover: (Bool) -> Void = { _ in }
    @State private var hover = false
    /// A subscription tool's models carry their version once it is asked.
    @ObservedObject private var agents = CLIAgents.shared

    private var model: String {
        switch settings.provider {
        case .farhelm: return ModelName.pretty(settings.farhelmModel)
        case .anthropic: return ModelName.pretty(settings.anthropicModel)
        case .openai: return ModelName.pretty(settings.openAIModel)
        case .ollama: return ModelName.pretty(settings.ollamaModel)
        case .subscription:
            // The logo says which tool; a tool left to pick its own model
            // shows the one it says it picks, when it says.
            if settings.cliModel.isEmpty {
                return agents.version(of: "", for: settings.cliAgent) ?? "Auto"
            }
            return agents.title(of: settings.cliModel, for: settings.cliAgent)
        }
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 5) {
                EngineLogo(kind: settings.provider,
                           tool: settings.provider == .subscription ? settings.cliAgent : nil,
                           size: 11)
                    .foregroundStyle(isOpen ? Theme.accent : Theme.ink.opacity(0.7))
                // The icon says which engine; only the model is spelled out.
                Text(model)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 210)
            .background(Capsule().fill((isOpen ? Theme.accent : Theme.ink).opacity(isOpen ? 0.14 : (hover ? 0.12 : 0.08))))
            .overlay(Capsule().strokeBorder((isOpen ? Theme.accent : Theme.ink).opacity(isOpen ? 0.40 : 0.16), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover {
            hover = $0
            onHover($0)
            // Looking at it is a reason to ask what is left, now and then.
            if $0, settings.provider == .subscription { agents.refreshLimits(olderThan: 60) }
        }
        // The tool is asked for its models once, so the version shows
        // without opening the list first.
        .task {
            guard settings.provider == .subscription else { return }
            await agents.ready()
            agents.refreshModels()
            agents.refreshLimits()
        }
    }
}

/// What shows above the model button while the pointer is over it: the
/// engine and model in full and, for a subscription tool, what is left of
/// the plan.
struct ModelHoverCard: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var agents = CLIAgents.shared

    private var subscription: Bool { settings.provider == .subscription }

    private var engine: String {
        subscription ? agents.name(of: settings.cliAgent) : settings.provider.shortName
    }

    private var model: String {
        switch settings.provider {
        case .farhelm: return ModelName.pretty(settings.farhelmModel)
        case .anthropic: return ModelName.pretty(settings.anthropicModel)
        case .openai: return ModelName.pretty(settings.openAIModel)
        case .ollama: return ModelName.pretty(settings.ollamaModel)
        case .subscription:
            if settings.cliModel.isEmpty {
                return agents.version(of: "", for: settings.cliAgent) ?? "Auto"
            }
            return agents.title(of: settings.cliModel, for: settings.cliAgent)
        }
    }

    /// Why there is nothing to show yet, for a subscription tool.
    private var waiting: String {
        guard let adapter = agents.adapter(settings.cliAgent) else { return "No usage reported." }
        if adapter.limitsArguments == nil, adapter.format != .claudeStream {
            return "\(adapter.name) does not report what is left of the plan."
        }
        if adapter.limitsArguments == nil {
            return "\(adapter.name) says what is left along with a reply. Send a message to see it."
        }
        if let trouble = agents.limitsTrouble[adapter.id] {
            return "\(adapter.name) did not say what is left. It answered: \(trouble)"
        }
        return "Asking \(adapter.name) what is left..."
    }

    private func tint(_ limit: PlanLimit) -> Color {
        guard let left = limit.left else { return Theme.mint }
        return left <= 10 ? Theme.rose : (left <= 30 ? Theme.amber : Theme.mint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                EngineLogo(kind: settings.provider, tool: subscription ? settings.cliAgent : nil, size: 13)
                    .foregroundStyle(Theme.accent)
                Text(engine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.95))
                Text(model)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if subscription {
                let limits = agents.limits[settings.cliAgent] ?? []
                if limits.isEmpty {
                    Text(waiting)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink.opacity(0.55))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(limits) { limit in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(limit.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.ink.opacity(0.85))
                                Spacer(minLength: 6)
                                Text(limit.summary)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(tint(limit))
                            }
                            // The bar is what is left, so it empties as
                            // the plan is used.
                            if let left = limit.left {
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.ink.opacity(0.10))
                                        Capsule().fill(tint(limit))
                                            .frame(width: max(3, proxy.size.width * CGFloat(left) / 100))
                                    }
                                }
                                .frame(height: 4)
                            }
                            if let restart = limit.restart {
                                Text("Starts over \(restart)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.ink.opacity(0.45))
                            }
                        }
                    }
                }
            } else {
                Text(settings.provider.isLocal ? "Runs on this Mac." : "Sent to its API, billed by use.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.55))
            }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        // It sits over the conversation, so it needs a solid base under the glass.
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.shade.opacity(0.82)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// The button beside the model that sets how hard it thinks. The levels
/// are the engine's own, and the choice is kept for each model.
struct EffortPill: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var agents = CLIAgents.shared
    @State private var hover = false

    var body: some View {
        let levels = settings.effortLevels
        let chosen = settings.chosenEffort
        // An engine with no levels of its own has nothing to set.
        if !levels.isEmpty {
            Menu {
                ForEach([""] + levels, id: \.self) { level in
                    Button {
                        settings.chosenEffort = level
                    } label: {
                        Label(AppSettings.effortLabel(level),
                              systemImage: level == chosen ? "checkmark" : Self.icon(level))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: Self.icon(chosen))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(chosen.isEmpty ? Theme.ink.opacity(0.7) : Theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                    Text(AppSettings.effortLabel(chosen))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.ink.opacity(hover ? 0.12 : 0.08)))
                .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.16), lineWidth: 0.75))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hover = $0 }
            .help("Effort for this model: how hard it thinks before answering. Auto leaves it to the model.")
        }
    }

    /// The symbol for an effort level: a gauge that fills as the model is
    /// asked to think harder. Auto, left to the model, shows a brain.
    static func icon(_ level: String) -> String {
        switch level.lowercased() {
        case "": return "brain"
        case "minimal", "none", "off": return "gauge.with.dots.needle.0percent"
        case "low": return "gauge.with.dots.needle.33percent"
        case "medium": return "gauge.with.dots.needle.50percent"
        case "high": return "gauge.with.dots.needle.67percent"
        case "xhigh", "max", "maximum": return "gauge.with.dots.needle.100percent"
        default: return "gauge.with.dots.needle.bottom.50percent"
        }
    }
}

/// The model picker: opens in place, just above the chat box.
///
/// Each engine is a row that opens to show its models; the engine in use
/// starts open. Tapping a model switches engine and model together and
/// closes the list. Engines that are not set up yet are not
/// listed: the last row leads to where they are added.
struct ModelPicker: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @Binding var isOpen: Bool
    /// Engines whose models are showing.
    @State private var expanded: Set<String> = []
    /// The subscription tools on this Mac, listed once they are found.
    @ObservedObject private var agents = CLIAgents.shared

    /// A model's name as shown.
    private func title(_ group: EngineGroup, _ model: String) -> String {
        guard group.kind == .subscription else { return ModelName.pretty(model) }
        // The tool's own name for the model when it gives one; otherwise
        // its identifier, said the way the other engines' models are.
        return agents.title(of: model, for: group.tool ?? "")
    }

    /// One row of the list with the models under it: an engine, or, for
    /// subscriptions, each tool as an engine of its own.
    private struct EngineGroup: Identifiable {
        let kind: LLMProviderKind
        /// The subscription tool (an adapter's id), for that kind.
        var tool: String?
        let models: [String]
        var id: String { kind.rawValue + "|" + (tool ?? "") }
    }

    /// Whether this is the engine (and, for a subscription, the tool)
    /// that answers now.
    private func inUse(_ group: EngineGroup) -> Bool {
        settings.provider == group.kind && (group.tool == nil || group.tool == settings.cliAgent)
    }

    /// An engine is listed when it is the one in use or has what it needs
    /// (a key for the hosted ones; the local ones need none here).
    private func ready(_ kind: LLMProviderKind) -> Bool {
        if kind == settings.provider { return true }
        switch kind {
        case .farhelm: return !(Keychain.read("farhelm") ?? "").isEmpty
        case .anthropic: return !(Keychain.read("anthropic") ?? "").isEmpty
        case .openai: return !(Keychain.read("openai") ?? "").isEmpty
        case .ollama: return true
        case .subscription: return !agents.installed.isEmpty
        }
    }

    private var groups: [EngineGroup] {
        LLMProviderKind.allCases.filter(ready).flatMap { kind -> [EngineGroup] in
            switch kind {
            case .farhelm:
                return [EngineGroup(kind: kind, models: [""] + app.farhelmModels)]
            case .anthropic:
                var list = app.anthropicModels
                if !list.contains(settings.anthropicModel) { list.insert(settings.anthropicModel, at: 0) }
                return [EngineGroup(kind: kind, models: list)]
            case .openai:
                return [EngineGroup(kind: kind, models: [settings.openAIModel])]
            case .ollama:
                return [EngineGroup(kind: kind, models: [settings.ollamaModel])]
            case .subscription:
                // Each installed tool is listed as an engine of its own,
                // with the models it offers under it.
                return agents.installed.map { adapter in
                    var list = agents.models(for: adapter.id)
                    if adapter.id == settings.cliAgent, !list.contains(settings.cliModel) {
                        list.append(settings.cliModel)
                    }
                    return EngineGroup(kind: kind, tool: adapter.id, models: list)
                }
            }
        }
    }

    /// The model this engine would use.
    private func current(_ group: EngineGroup) -> String {
        switch group.kind {
        case .farhelm: return settings.farhelmModel
        case .anthropic: return settings.anthropicModel
        case .openai: return settings.openAIModel
        case .ollama: return settings.ollamaModel
        case .subscription: return group.tool == settings.cliAgent ? settings.cliModel : ""
        }
    }

    private func choose(_ group: EngineGroup, _ model: String) {
        settings.provider = group.kind
        switch group.kind {
        case .farhelm: settings.farhelmModel = model
        case .anthropic: settings.anthropicModel = model
        case .openai: settings.openAIModel = model
        case .ollama: settings.ollamaModel = model
        case .subscription:
            settings.cliAgent = group.tool ?? settings.cliAgent
            settings.cliModel = model
        }
        close()
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { isOpen = false }
    }

    private func note(_ group: EngineGroup, _ model: String) -> String? {
        let kind = group.kind
        if kind == .farhelm, model.isEmpty { return "Farhelm picks" }
        // The tool says which model its default is, when it does.
        if kind == .subscription, model.isEmpty {
            return agents.version(of: "", for: group.tool ?? "") ?? "The tool picks"
        }
        guard kind == .anthropic else { return nil }
        if model.contains("haiku") { return "Fastest" }
        if model.contains("sonnet") { return "Balanced" }
        if model.contains("opus") { return "Most capable" }
        return nil
    }

    /// As tall as what is open, up to a limit; beyond that it scrolls.
    private var listHeight: CGFloat {
        let rows = groups.filter { expanded.contains($0.id) }.reduce(0) { $0 + $1.models.count }
        let lines = groups.filter { $0.tool.flatMap { agents.limits[$0] }?.isEmpty == false }.count
        return min(CGFloat(rows) * 29 + CGFloat(groups.count) * 29 + CGFloat(lines) * 17 + 46, 286)
    }

    private func toggle(_ group: EngineGroup) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expanded.contains(group.id) {
                expanded.remove(group.id)
            } else {
                expanded.insert(group.id)
            }
        }
        if group.kind == .farhelm { app.loadFarhelmModels() }
        if group.kind == .anthropic { app.loadAnthropicModels() }
        if group.kind == .subscription { agents.refreshModels() }
    }

    /// An engine's row: tap to open or close its models.
    private func engineRow(_ group: EngineGroup) -> some View {
        let open = expanded.contains(group.id)
        let inUse = self.inUse(group)
        let model = current(group)
        let subscription = group.kind == .subscription
        return HStack(spacing: 8) {
            EngineLogo(kind: group.kind, tool: group.tool, size: 12.5)
                .foregroundStyle(inUse ? Theme.accent : Theme.ink.opacity(0.65))
                .frame(width: 18)
            Text(group.tool.map { agents.name(of: $0) } ?? group.kind.shortName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(inUse ? Theme.accent : Theme.ink.opacity(0.94))
            Image(systemName: subscription ? "person.fill" : (group.kind.isLocal ? "lock.fill" : "cloud"))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .help(subscription ? "On your subscription, through its own tool"
                      : (group.kind.isLocal ? "Runs on this Mac" : "Sent to its API"))
            Spacer(minLength: 6)
            // Closed, the row still says which model that engine would use.
            if !open {
                Text(title(group, model))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.5))
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.ink.opacity(open ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { toggle(group) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    engineRow(group)
                    // What is left of the plan, for a tool that says.
                    if let tool = group.tool, let left = agents.limitsLine(for: tool) {
                        Text(left)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.ink.opacity(0.5))
                            .lineLimit(1)
                            .padding(.leading, 34)
                            .padding(.bottom, 3)
                            .help(agents.limitsDetail(for: tool) ?? left)
                    }
                    if expanded.contains(group.id) {
                        ForEach(group.models, id: \.self) { model in
                            ModelRow(name: title(group, model),
                                     note: note(group, model),
                                     selected: inUse(group) && current(group) == model) {
                                choose(group, model)
                            }
                            .help(model.isEmpty
                                  ? (group.kind == .subscription ? "The tool picks the model" : "Farhelm picks the model")
                                  : model)
                            .padding(.leading, 18)
                            .transition(.opacity)
                        }
                    }
                }
                Rectangle()
                    .fill(Theme.ink.opacity(0.08))
                    .frame(height: 1)
                    .padding(.vertical, 4)
                Button {
                    close()
                    app.openSettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11.5))
                        Text("Add or change engines")
                            .font(.system(size: 11.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: listHeight)
        .padding(6)
        // It sits over other things, so it needs a solid base under the glass.
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.shade.opacity(0.82)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onAppear {
            // It opens compact: just the engines, each showing its model.
            // Tap one to see its models.
            expanded = []
            if ready(.farhelm) { app.loadFarhelmModels() }
            if ready(.anthropic) { app.loadAnthropicModels() }
            agents.check()
            agents.refreshLimits()
        }
        .onExitCommand { close() }
    }
}

private struct ModelRow: View {
    let name: String
    let note: String?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? Theme.accent : Theme.ink.opacity(0.25))
            Text(name)
                .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(Theme.ink.opacity(selected ? 0.96 : 0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.14) : Theme.ink.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}
