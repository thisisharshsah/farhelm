import SwiftUI

// Size rules: the three width classes a layout adapts to, two densities
// for components, a stack that turns a row into a column when space runs
// out, and a column that keeps running text at a readable width.

extension Design {
    /// How wide the space a layout has is. A window's content reads it with
    /// `readsWidthClass()`; everything inside takes it from the environment.
    enum WidthClass: CaseIterable, Hashable, Comparable {
        case compact, regular, wide

        static let regularFrom: CGFloat = 600
        static let wideFrom: CGFloat = 1000

        init(width: CGFloat) {
            if width >= Self.wideFrom {
                self = .wide
            } else if width >= Self.regularFrom {
                self = .regular
            } else {
                self = .compact
            }
        }

        var name: String {
            switch self {
            case .compact: "Compact"
            case .regular: "Regular"
            case .wide: "Wide"
            }
        }

        /// A width inside the class, for the gallery.
        var sampleWidth: CGFloat {
            switch self {
            case .compact: 480
            case .regular: 800
            case .wide: 1180
            }
        }
    }

    /// How tightly components are set: compact for dense lists and side
    /// panels, regular everywhere else.
    enum Density: CaseIterable, Hashable {
        case compact, regular

        var name: String {
            switch self {
            case .compact: "Compact"
            case .regular: "Regular"
            }
        }

        var rowHeight: CGFloat {
            switch self {
            case .compact: Control.regular.height
            case .regular: Control.large.height
            }
        }

        /// The gap between neighbouring items.
        var gap: CGFloat {
            switch self {
            case .compact: Space.xs
            case .regular: Space.s
            }
        }

        /// The padding inside a component.
        var inset: CGFloat {
            switch self {
            case .compact: Space.s
            case .regular: Space.m
            }
        }

        var control: Control {
            switch self {
            case .compact: .small
            case .regular: .regular
            }
        }

        var icon: Icon {
            switch self {
            case .compact: .small
            case .regular: .regular
            }
        }

        var textRole: TextRole {
            switch self {
            case .compact: .label
            case .regular: .body
            }
        }
    }

    /// The widest a column of running text gets: about 70 characters of body text.
    static let readableWidth: CGFloat = 680

    /// Minimum and preferred widths for the panes that share
    /// Advanced mode's space: board, task detail and task chat.
    enum PaneWidth {
        static let boardMin: CGFloat = 280
        static let detailMin: CGFloat = 280
        static let chatMin: CGFloat = 300
        static let detailPreferred: CGFloat = 360
        static let chatPreferred: CGFloat = 400
    }
}

private struct WidthClassKey: EnvironmentKey {
    static let defaultValue = Design.WidthClass.regular
}

private struct DensityKey: EnvironmentKey {
    static let defaultValue = Design.Density.regular
}

extension EnvironmentValues {
    var widthClass: Design.WidthClass {
        get { self[WidthClassKey.self] }
        set { self[WidthClassKey.self] = newValue }
    }

    var density: Design.Density {
        get { self[DensityKey.self] }
        set { self[DensityKey.self] = newValue }
    }
}

// MARK: - Reading the width

struct WidthClassReader: ViewModifier {
    @State var widthClass: Design.WidthClass = .regular

    func body(content: Content) -> some View {
        content
            .environment(\.widthClass, widthClass)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onGeometryChange(for: Design.WidthClass.self) { proxy in
                Design.WidthClass(width: proxy.size.width)
            } action: { newValue in
                widthClass = newValue
            }
    }
}

extension View {
    /// Fills the width offered and tells everything inside which width class it is.
    func readsWidthClass() -> some View {
        modifier(WidthClassReader())
    }

    /// Keeps running text at a readable width, centred in wider space.
    func readableWidth(_ maxWidth: CGFloat = Design.readableWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Containers

/// A row that becomes a column: always at `columnsAt` and narrower, and at
/// any width where the row does not fit.
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat?
    var rowAlignment: VerticalAlignment
    var columnAlignment: HorizontalAlignment
    var columnsAt: Design.WidthClass?
    var content: Content
    @Environment(\.widthClass) var widthClass
    @Environment(\.density) var density

    init(spacing: CGFloat? = nil, rowAlignment: VerticalAlignment = .center,
         columnAlignment: HorizontalAlignment = .leading, columnsAt: Design.WidthClass? = .compact,
         @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.rowAlignment = rowAlignment
        self.columnAlignment = columnAlignment
        self.columnsAt = columnsAt
        self.content = content()
    }

    var body: some View {
        let gap = spacing ?? density.gap
        if let columnsAt, widthClass <= columnsAt {
            VStack(alignment: columnAlignment, spacing: gap) { content }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: rowAlignment, spacing: gap) { content }
                VStack(alignment: columnAlignment, spacing: gap) { content }
            }
        }
    }
}

/// Running text at a readable width, centred in wider space.
struct ReadableColumn<Content: View>: View {
    var maxWidth: CGFloat
    var content: Content

    init(maxWidth: CGFloat = Design.readableWidth, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        content.readableWidth(maxWidth)
    }
}