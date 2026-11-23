import SwiftUI

// The multi-select filter: a row of chips that toggle on and off, a count of
// the filters that are on, and Clear. Chips wrap onto more lines when the
// width runs out. Each chip is a button for VoiceOver, selected when on, and
// the count is announced when it changes.

struct FilterOption<ID: Hashable>: Identifiable {
    let id: ID
    var title: String
    var symbol: String?
    /// How many items it would show, when known.
    var count: Int?

    init(id: ID, title: String, symbol: String? = nil, count: Int? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.count = count
    }
}

struct FilterChips<ID: Hashable>: View {
    let title: String
    let options: [FilterOption<ID>]
    @Binding var selection: Set<ID>
    @Environment(\.density) private var density
    private var access = DesignAccess()

    init(_ title: String = "Filters", options: [FilterOption<ID>], selection: Binding<Set<ID>>) {
        self.title = title
        self.options = options
        self._selection = selection
    }

    private var active: Int { options.filter { selection.contains($0.id) }.count }

    private var activeText: String { active == 1 ? "1 active" : "\(active) active" }

    private func toggle(_ id: ID) {
        withAnimation(Design.Motion.quick.animation(reduceMotion: access.reduceMotion)) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        }
    }

    private func clear() {
        withAnimation(Design.Motion.quick.animation(reduceMotion: access.reduceMotion)) {
            selection.removeAll()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.gap) {
            HStack(spacing: Design.Space.xs) {
                Text(title).textRole(density.textRole, .secondary)
                if active > 0 {
                    SelectionBadgeView(badge: SelectionBadge(activeText, tone: .accent))
                        .transition(.opacity)
                }
                Spacer(minLength: Design.Space.xs)
                Button("Clear", action: clear)
                    .buttonStyle(.plain)
                    .textRole(density.textRole, .secondary)
                    .foregroundStyle(active > 0 ? Design.Tone.accent.color : Color.secondary)
                    .disabled(active == 0)
                    .help("Turn every filter off")
                    .accessibilityLabel("Clear filters")
            }
            FlowLayout(spacing: Design.Space.xs) {
                ForEach(options) { option in chip(option) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: active) {
            AccessibilityNotification.Announcement(active == 0 ? "No filters" : activeText).post()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func chip(_ option: FilterOption<ID>) -> some View {
        let on = selection.contains(option.id)
        let tint = Design.Tone.accent.color
        return Button { toggle(option.id) } label: {
            HStack(spacing: Design.Space.xxs) {
                if on {
                    Image(systemName: "checkmark").iconWidth(.small)
                } else if let symbol = option.symbol {
                    Image(systemName: symbol).iconWidth(.small)
                }
                Text(option.title).lineLimit(1)
                if let count = option.count {
                    Text(count, format: .number).textRole(.number, .secondary)
                }
            }
            .textRole(density.textRole, on ? .primary : .secondary)
            .fontWeight(on ? .semibold : .regular)
            .padding(.horizontal, density.gap)
            .frame(minHeight: density.control.height)
            .background(on ? tint.opacity(access.highContrast ? 0.32 : 0.2) : Color.clear, in: Capsule())
            .background(Design.Fill.line.style, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? tint : Color.primary.opacity(access.highContrast ? 0.5 : 0.12),
                                            lineWidth: on || access.highContrast ? 1 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityValue(option.count.map { "\($0) items" } ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(on ? "Turns this filter off" : "Turns this filter on")
    }
}