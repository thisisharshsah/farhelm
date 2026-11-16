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
        case .compatible: return "More services"
        case .subscription: return "Subscriptions"
        }
    }

    var icon: String {
        switch self {
        case .farhelm: return "server.rack"
        case .anthropic: return "sparkle"
        case .openai: return "circle.hexagongrid"
        case .ollama: return "desktopcomputer"
        case .compatible: return "square.grid.2x2"
        case .subscription: return "person.badge.key"
        }
    }

    /// Runs on this Mac, so nothing leaves it. More services depends on the
    /// service: see `AppSettings.engineRunsHere` and `EngineCatalog.place`.
    var isLocal: Bool { self == .farhelm || self == .ollama }
}

extension AppSettings {
    /// The tool or service whose logo stands for the engine in use, if any.
    var logoTool: String? {
        switch provider {
        case .subscription: return cliAgent
        case .compatible: return service
        default: return nil
        }
    }
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

    /// The engine behind a turn's label ("Claude Code · Opus", "Farhelm ·
    /// auto"): the name before the dot is an engine's, or a subscription
    /// tool's. nil when it is neither, as for a tool since removed.
    static func mark(of label: String) -> (kind: LLMProviderKind, tool: String?)? {
        let name = (label.components(separatedBy: " · ").first ?? label).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let kind = LLMProviderKind.allCases.first(where: { $0 != .subscription && $0.shortName == name }) {
            return (kind, nil)
        }
        // A service of More services, by its own name ("Gemini · …").
        if let service = CompatibleService.choices.first(where: { $0.name == name }) {
            return (.compatible, service.id)
        }
        // A tool's name, also as it was written before ("Codex (ChatGPT)").
        if let adapter = CLIAgents.shared.adapters.first(where: { name == $0.name || name.hasPrefix($0.name + " ") }) {
            return (.subscription, adapter.id)
        }
        return nil
    }

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
    /// With little room it is the engine's mark alone, without the name.
    var compact = false
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
        case .compatible: return ModelName.pretty(settings.model(for: settings.compatibleService))
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
                // The engine's mark sits on a small disc, like the mark
                // inside Auto beside it.
                EngineLogo(kind: settings.provider, tool: settings.logoTool, size: 10)
                    .foregroundStyle(isOpen ? Theme.accent : Theme.ink.opacity(0.75))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill((isOpen ? Theme.accent : Theme.ink).opacity(isOpen ? 0.22 : 0.12)))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                // The icon says which engine; only the model is spelled out.
                if !compact {
                    Text(model)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.5))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.leading, 3)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
            .frame(maxWidth: 210)
            // A bubble, like the choices the AI offers: in the primary, lit
            // while its list is open.
            .bubbleSurface(tint: Theme.accent, lit: isOpen)
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

/// Manual asks about every step. Auto runs steps without asking, and comes
/// in two kinds, shown by a mark that sits inside the Auto side itself: a
/// pencil for Edit (file edits and commands inside the chat's repository;
/// the rest still asks) and a bolt for Full (nothing asks but keys and
/// credentials). A click on the mark changes the kind. The choice is kept
/// with the chat and read each round, so it applies from the agent's next
/// steps on.
struct AccessToggles: View {
    @EnvironmentObject var app: AppState
    /// The chosen side's own small bubble slides from one side to the other.
    @Namespace private var chosen

    private func side<Content: View>(on: Bool, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(on ? tint : Theme.ink.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if on {
                    Capsule()
                        .fill(tint.opacity(0.18))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "chosen", in: chosen)
                }
            }
            .contentShape(Capsule())
    }

    var body: some View {
        let access = app.agentAccess
        let auto = access != .manual
        let tint = access == .full ? Theme.rose : Theme.amber
        HStack(spacing: 2) {
            side(on: !auto, tint: Theme.ink) {
                Text("Manual")
            }
            .onTapGesture { app.setAgentAccess(.manual) }
            .help(AgentAccess.manual.detail)

            // Auto and its kind are one piece: the word, then the mark.
            side(on: auto, tint: tint) {
                HStack(spacing: 5) {
                    Text("Auto")
                    if auto {
                        Image(systemName: access.icon)
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(tint.opacity(0.22)))
                            .contentShape(Circle())
                            .onTapGesture {
                                app.setAgentAccess(access == .full ? .autoEdit : .full)
                            }
                            .help(access == .full
                                  ? "Full access. \(AgentAccess.full.detail)\nClick for edits only."
                                  : "Edits. \(AgentAccess.autoEdit.detail)\nClick for full access.")
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
            .onTapGesture {
                // From Manual, Auto starts as edits; the mark goes further.
                if !auto { app.setAgentAccess(.autoEdit) }
            }
            .help(auto ? "Auto: steps run without asking. The mark says how far: click it to change." : "Let steps run without asking.")
        }
        .padding(2)
        // A bubble too: neutral on Manual, in the color of how far Auto
        // goes once it is on. It glows under the pointer without moving.
        .bubbleSurface(tint: auto ? tint : nil, lifts: false)
        .fixedSize()
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: access)
    }
}

/// The same choice as one small button with a menu, for a chat box with no
/// room for the switches. It is colored while anything runs on its own, so
/// that is never forgotten.
struct AccessPill: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    /// With little room it is the mark alone.
    var compact = false
    @State private var hover = false

    private func tint(_ access: AgentAccess) -> Color {
        switch access {
        case .manual: return Theme.ink
        case .autoEdit: return Theme.amber
        case .full: return Theme.rose
        }
    }

    private func item(_ access: AgentAccess, chosen: AgentAccess) -> some View {
        Button {
            app.setAgentAccess(access)
        } label: {
            if access == chosen {
                Label(access.title, systemImage: "checkmark")
            } else {
                Text(access.title)
            }
        }
        .help(access.detail)
    }

    var body: some View {
        let chosen = app.agentAccess
        let color = tint(chosen)
        Menu {
            item(.manual, chosen: chosen)
            Section("Auto: nothing to accept") {
                item(.autoEdit, chosen: chosen)
                item(.full, chosen: chosen)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chosen.icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(chosen == .manual ? Theme.ink.opacity(0.7) : color)
                // Manual is the quiet state: only the automatic ones are
                // spelled out, and not even those with little room.
                if chosen != .manual, !compact {
                    Text(chosen.short)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .bubbleSurface(tint: chosen == .manual ? nil : color, lit: chosen != .manual, lifts: false)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .help("\(chosen.title). \(chosen.detail)")
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
        if subscription { return agents.name(of: settings.cliAgent) }
        if settings.provider == .compatible { return settings.compatibleService.name }
        return settings.provider.shortName
    }

    private var model: String {
        switch settings.provider {
        case .farhelm: return ModelName.pretty(settings.farhelmModel)
        case .anthropic: return ModelName.pretty(settings.anthropicModel)
        case .openai: return ModelName.pretty(settings.openAIModel)
        case .ollama: return ModelName.pretty(settings.ollamaModel)
        case .compatible: return ModelName.pretty(settings.model(for: settings.compatibleService))
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
                EngineLogo(kind: settings.provider, tool: settings.logoTool, size: 13)
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
                Text(settings.engineRunsHere ? "Runs on this Mac." : "Sent to its API, billed by use.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink.opacity(0.55))
            }
        }
        .padding(10)
        .frame(maxWidth: 240, alignment: .leading)
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
    /// The bar that sets it, open above the chat box.
    @Binding var isOpen: Bool
    /// With little room it is the ball alone, without the level's name.
    var compact = false
    @State private var hover = false

    var body: some View {
        let levels = settings.effortLevels
        let chosen = settings.chosenEffort
        // An engine with no levels of its own has nothing to set.
        if !levels.isEmpty {
            // The button takes its color from the ball: neutral while the
            // choice is left to the model, and the look's color, deeper
            // the hotter it burns, once a level is set.
            let heat = EffortBar.heat(of: chosen, in: levels)
            let lit = !chosen.isEmpty
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    // The same ball of fire as on the bar, small: it burns
                    // brighter the harder the model is asked to think.
                    // Burning, still at rest; it flickers while the pointer
                    // is on it or its bar is open.
                    Fireball(heat: heat, size: 11, alive: lit, flickers: hover || isOpen)
                    if !compact {
                        Text(AppSettings.effortLabel(chosen))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(lit ? Theme.accent : Theme.ink.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .bubbleSurface(tint: lit ? Theme.accent : nil, lit: isOpen)
                .shadow(color: Theme.accent.opacity(lit ? 0.10 + 0.22 * heat : 0), radius: 2 + 4 * heat)
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.2), value: chosen)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { hover = $0 }
            .help("Effort for this model: how hard it thinks before answering. Click to set it.")
        }
    }
}

/// The bar that sets the effort: the levels the engine takes, lowest to
/// highest, with a ball of fire to drag along it. The track behind the
/// ball fills in the look's colors, and the ball burns brighter the
/// further it goes. The first stop leaves the choice to the model.
struct EffortBar: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var isOpen: Bool

    /// How hot a level is, from 0 for the model's own choice to 1 for the
    /// highest the engine takes.
    static func heat(of level: String, in levels: [String]) -> Double {
        guard let index = levels.firstIndex(of: level), !levels.isEmpty else { return 0 }
        return Double(index + 1) / Double(levels.count)
    }

    var body: some View {
        // Auto first, then the engine's own levels.
        let stops = [""] + settings.effortLevels
        let chosen = settings.chosenEffort
        let index = stops.firstIndex(of: chosen) ?? 0
        let last = max(1, stops.count - 1)
        let fraction = Double(index) / Double(last)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Effort")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.94))
                Spacer(minLength: 6)
                Text(AppSettings.effortLabel(chosen))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(chosen.isEmpty ? Theme.ink.opacity(0.6) : Theme.accent)
                    .contentTransition(.opacity)
            }
            GeometryReader { geometry in
                let inset: CGFloat = 12
                let width = max(1, geometry.size.width - inset * 2)
                let x = inset + width * fraction
                ZStack(alignment: .leading) {
                    // The track, and the trail of fire behind the ball.
                    Capsule()
                        .fill(Theme.ink.opacity(0.10))
                        .frame(height: 6)
                        .padding(.horizontal, inset - 3)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.15), Theme.lilac.opacity(0.75), Theme.accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, x - inset + 6), height: 6)
                        .padding(.leading, inset - 3)
                        .shadow(color: Theme.accent.opacity(0.35 + 0.35 * fraction), radius: 4)
                    // A mark at each level.
                    ForEach(stops.indices, id: \.self) { stop in
                        Circle()
                            .fill(stop <= index ? Color.white.opacity(0.7) : Theme.ink.opacity(0.28))
                            .frame(width: 3, height: 3)
                            .position(x: inset + width * Double(stop) / Double(last), y: geometry.size.height / 2)
                    }
                    Fireball(heat: fraction, size: 16 + 8 * fraction, alive: index > 0)
                        .position(x: x, y: geometry.size.height / 2)
                }
                // The whole bar takes the pointer: a click or a drag
                // anywhere on it moves the ball to the nearest level.
                .overlay {
                    BarTrack { place in
                        let along = min(max((place - inset) / width, 0), 1)
                        let nearest = Int((along * Double(last)).rounded())
                        let level = stops[min(max(nearest, 0), stops.count - 1)]
                        if level != settings.chosenEffort {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                settings.chosenEffort = level
                            }
                        }
                    }
                }
            }
            .frame(height: 30)
            // The levels by name, under their marks.
            HStack(spacing: 0) {
                ForEach(stops.indices, id: \.self) { stop in
                    Text(AppSettings.effortLabel(stops[stop]))
                        .font(.system(size: 9.5, weight: stop == index ? .semibold : .regular))
                        .foregroundStyle(stop == index ? Theme.accent : Theme.ink.opacity(0.5))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: stop == 0 ? .leading : (stop == last ? .trailing : .center))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                settings.chosenEffort = stops[stop]
                            }
                        }
                }
            }
            Text("How hard this model thinks before it answers. Higher is more careful and slower. Kept for each model.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: 280, alignment: .leading)
        // It sits over the conversation, so it needs a solid base under the glass.
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.shade.opacity(0.82)))
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onExitCommand { isOpen = false }
    }
}

/// Takes the mouse for a bar that is dragged along. It is an AppKit view so
/// that a press on it is never taken for a drag of the whole panel. It
/// reports where the pointer is across it, from its left edge.
private struct BarTrack: NSViewRepresentable {
    let moved: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackView {
        let view = TrackView()
        view.moved = moved
        return view
    }

    func updateNSView(_ view: TrackView, context: Context) {
        view.moved = moved
    }

    final class TrackView: NSView {
        var moved: ((CGFloat) -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func report(_ event: NSEvent) {
            moved?(convert(event.locationInWindow, from: nil).x)
        }

        override func mouseDown(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
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
    private func title(_ group: EngineGroup, _ model: String) -> String { EngineCatalog.title(group, model) }

    /// One row of the list with the models under it: an engine, or, for
    /// subscriptions, each tool as an engine of its own.
    private typealias EngineGroup = EngineCatalog.Engine

    /// Whether this is the engine (and, for a subscription, the tool)
    /// that answers now.
    private func inUse(_ group: EngineGroup) -> Bool { EngineCatalog.inUse(group) }

    /// An engine is listed when it is the one in use or has what it needs
    /// (a key for the hosted ones; the local ones need none here).
    private func ready(_ kind: LLMProviderKind) -> Bool { EngineCatalog.ready(kind) }

    private var groups: [EngineGroup] { EngineCatalog.engines }

    /// The model this engine would use.
    private func current(_ group: EngineGroup) -> String { EngineCatalog.current(group) }

    private func choose(_ group: EngineGroup, _ model: String) {
        EngineCatalog.choose(group, model)
        close()
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { isOpen = false }
    }

    private func note(_ group: EngineGroup, _ model: String) -> String? { EngineCatalog.note(group, model) }

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

    /// An engine's row: tap to use that engine with the model it last used
    /// (or its default); the chevron opens its models to pick another.
    private func engineRow(_ group: EngineGroup) -> some View {
        let open = expanded.contains(group.id)
        let inUse = self.inUse(group)
        let model = current(group)
        let subscription = group.kind == .subscription
        let local = EngineCatalog.place(group) == "local"
        return HStack(spacing: 8) {
            EngineLogo(kind: group.kind, tool: group.tool, size: 12.5)
                .foregroundStyle(inUse ? Theme.accent : Theme.ink.opacity(0.65))
                .frame(width: 18)
            Text(EngineCatalog.name(group))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(inUse ? Theme.accent : Theme.ink.opacity(0.94))
            Image(systemName: subscription ? "person.fill" : (local ? "lock.fill" : "cloud"))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .help(subscription ? "On your subscription, through its own tool"
                      : (local ? "Runs on this Mac" : "Sent to its API"))
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
            Button { toggle(group) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.ink.opacity(0.55))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 22, height: 20)
                    .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                        .fill(Theme.ink.opacity(open ? 0.1 : 0.05)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide the models" : "Choose a model")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(Theme.ink.opacity(open ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { choose(group, model) }
        .help("Use \(EngineCatalog.name(group)) with \(model.isEmpty ? "its default model" : title(group, model))")
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
                                  ? (group.kind == .subscription ? "The tool picks the model"
                                     : group.kind == .compatible ? "Choose its model in Settings" : "Farhelm picks the model")
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
            // Every engine opens collapsed, the one in use marked with its
            // model; a click shows its models.
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
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .fill(selected ? Theme.accent.opacity(0.14) : Theme.ink.opacity(hover ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

/// The models of the engine in use, as the model button's right-click
/// menu: the quickest way to change model without changing engine.
struct CurrentEngineModels: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var agents = CLIAgents.shared
    /// Opens the full picker, for another engine.
    let showAll: () -> Void

    private var models: [String] {
        var list: [String]
        switch settings.provider {
        case .subscription: list = agents.models(for: settings.cliAgent)
        case .anthropic: list = app.anthropicModels
        case .farhelm: list = [""] + app.farhelmModels
        case .openai: list = [settings.openAIModel]
        case .ollama: list = [settings.ollamaModel]
        case .compatible: list = [current]
        }
        if !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    private var current: String {
        switch settings.provider {
        case .subscription: return settings.cliModel
        case .anthropic: return settings.anthropicModel
        case .farhelm: return settings.farhelmModel
        case .openai: return settings.openAIModel
        case .ollama: return settings.ollamaModel
        case .compatible: return settings.model(for: settings.compatibleService)
        }
    }

    private func name(_ model: String) -> String {
        if model.isEmpty {
            switch settings.provider {
            case .subscription: return "Default (the tool picks)"
            case .compatible: return "No model chosen"
            default: return "Default"
            }
        }
        return settings.provider == .subscription
            ? agents.title(of: model, for: settings.cliAgent)
            : ModelName.pretty(model)
    }

    private func pick(_ model: String) {
        switch settings.provider {
        case .subscription:
            settings.cliModel = model
            UserDefaults.standard.set(model, forKey: "lastModel." + settings.cliAgent)
        case .anthropic: settings.anthropicModel = model
        case .farhelm: settings.farhelmModel = model
        case .openai: settings.openAIModel = model
        case .ollama: settings.ollamaModel = model
        case .compatible: settings.serviceModels[settings.compatibleService.id] = model
        }
    }

    var body: some View {
        ForEach(models, id: \.self) { model in
            Button { pick(model) } label: {
                if model == current {
                    Label(name(model), systemImage: "checkmark")
                } else {
                    Text(name(model))
                }
            }
        }
        Divider()
        Button("All engines and models…", action: showAll)
    }
}
