@_exported import CompanionDesign
import SwiftUI

// The phone target compiles the Mac's design files themselves
// (apple/Sources/Companion/UI/Design: Tokens, SizeRules, GlassSurfaces and
// the selection controls), so both apps read one set of tokens. Those files
// are not copied here and not edited; this file only fills in what they
// call that iOS does not have.

#if os(iOS)
extension View {
    /// `SearchablePicker` closes on the Mac's Escape command. iOS has no
    /// such command (SwiftUI marks it unavailable there), and a sheet is
    /// closed by its own button or by dragging it down, so this does nothing.
    func onExitCommand(perform action: (() -> Void)?) -> some View { self }
}
#endif

// MARK: - Sizes for the shared package's components

/// The shared package's components (`ChoiceBubbles`, `StatusPill`,
/// `PlanChecklist`, `StepTrail`) take a point size. This gives them the size
/// of a text role at the person's Dynamic Type setting, so they grow with
/// every other text on the screen and no size is written at the call.
struct RoleSized<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let role: Design.TextRole
    private let content: (CGFloat) -> Content

    init(_ role: Design.TextRole, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.role = role
        self.content = content
    }

    var body: some View { content(role.points(at: typeSize)) }
}

#if os(iOS)
extension Design.TextRole {
    /// The system text style this role's font is, for UIKit's metrics.
    private var uiStyle: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title2
        case .heading: .headline
        case .body, .code, .number: .body
        case .label: .callout
        case .caption: .caption1
        }
    }

    /// The role's point size at a Dynamic Type size.
    func points(at size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        return UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: traits).pointSize
    }
}
#endif
