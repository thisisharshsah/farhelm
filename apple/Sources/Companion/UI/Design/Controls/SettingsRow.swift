import SwiftUI

// The settings row: a label, a control and help text. Wider than compact the
// label has a column of its own and the control and its help sit together in
// the next, so the control and help share one leading edge down a list of
// rows. At compact width the label stacks over the control, with the help
// under it, all on the one leading edge. VoiceOver reads the row as a group
// named by its label.

struct SettingsRow<Control: View>: View {
    let label: String
    var help: String?
    var symbol: String?
    var labelWidth: CGFloat
    var control: Control
    @Environment(\.widthClass) private var widthClass
    @Environment(\.density) private var density

    init(_ label: String, help: String? = nil, symbol: String? = nil,
         labelWidth: CGFloat = Design.Space.xxl * 6, @ViewBuilder control: () -> Control) {
        self.label = label
        self.help = help
        self.symbol = symbol
        self.labelWidth = labelWidth
        self.control = control()
    }

    var body: some View {
        Group {
            if widthClass == .compact {
                VStack(alignment: .leading, spacing: density.gap) {
                    labelView
                    controlColumn
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: density.inset) {
                    labelView.frame(width: labelWidth, alignment: .leading)
                    controlColumn
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, density == .compact ? Design.Space.xxs : Design.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var labelView: some View {
        HStack(spacing: Design.Space.xs) {
            if let symbol {
                Image(systemName: symbol).iconWidth(density.icon).foregroundStyle(.secondary)
            }
            Text(label).textRole(density.textRole)
        }
        .accessibilityHidden(true)
    }

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            control.labelsHidden()
            if let help {
                Text(help)
                    .textRole(.caption, .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}