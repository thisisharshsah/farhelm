import SwiftUI

// The segmented switcher: two to five options in one capsule, with a glass
// indicator that slides to the chosen one. At compact width it shows icons
// only, each with a tooltip and an accessibility label; wider, an icon and
// the name. The arrow keys move the choice. VoiceOver reads a group with a
// label, and each segment as a button, the chosen one selected.

struct SwitcherOption<ID: Hashable>: Identifiable {
    let id: ID
    var title: String
    var symbol: String

    init(id: ID, title: String, symbol: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

struct SegmentedSwitcher<ID: Hashable>: View {
    let label: String
    /// Two to five options; more than five are left out.
    let options: [SwitcherOption<ID>]
    @Binding var selection: ID
    @Namespace private var indicator
    @Environment(\.widthClass) private var widthClass
    @Environment(\.density) private var density
    private var access = DesignAccess()

    init(_ label: String, options: [SwitcherOption<ID>], selection: Binding<ID>) {
        self.label = label
        self.options = Array(options.prefix(5))
        self._selection = selection
    }

    private var iconOnly: Bool { widthClass == .compact }

    private func choose(_ id: ID) {
        guard id != selection else { return }
        withAnimation(Design.Motion.standard.animation(reduceMotion: access.reduceMotion)) {
            selection = id
        }
    }

    private func step(_ delta: Int) {
        guard let index = options.firstIndex(where: { $0.id == selection }) else { return }
        choose(options[min(max(index + delta, 0), options.count - 1)].id)
    }

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            ForEach(options) { option in segment(option) }
        }
        .padding(Design.Space.xxs)
        .background(Design.Fill.line.style, in: Capsule())
        .fixedSize()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ option: SwitcherOption<ID>) -> some View {
        let selected = option.id == selection
        return Button { choose(option.id) } label: {
            Group {
                if iconOnly {
                    Image(systemName: option.symbol).iconWidth(density.icon)
                } else {
                    Label(option.title, systemImage: option.symbol)
                }
            }
            .textRole(density.textRole, selected ? .primary : .secondary)
            .fontWeight(selected ? .semibold : .regular)
            .padding(.horizontal, density.gap)
            .frame(minWidth: iconOnly ? density.control.height : nil, minHeight: density.control.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if selected {
                Color.clear
                    .glassSurface(Capsule(), tint: Design.Tone.accent.color)
                    .matchedGeometryEffect(id: "indicator", in: indicator)
            }
        }
        .help(option.title)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}