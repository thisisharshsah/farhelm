import SwiftUI

/// What is going on, on one line: the working mark and its words, on a
/// glass pill. The same as above the chat box on the Mac.
public struct StatusPill: View {
    let text: String
    let thinking: Bool
    var size: CGFloat

    public init(_ text: String, thinking: Bool = false, size: CGFloat = 11.5) {
        self.text = text
        self.thinking = thinking
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 7) {
            LoadingMark(state: thinking ? .thinking : .working, size: size * 1.45)
            Text(text)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 6)
        .padding(.trailing, 11)
        .frame(height: size * 2.25)
        .background(Capsule().fill(Theme.shade.opacity(0.45)))
        .liquidGlass(in: Capsule())
    }
}

/// The panel's ground: the shade the look sets, a little of the primary,
/// soft colored light in two corners and a sheen along the top. The Mac
/// puts it over the blurred desktop; the mobile apps use it as the screen.
public struct CompanionBackdrop: View {
    var depth: Double

    public init(depth: Double = 0.92) {
        self.depth = depth
    }

    public var body: some View {
        ZStack {
            Theme.shade.opacity(depth)
            Theme.accent.opacity(0.05)
            RadialGradient(colors: [Theme.accent.opacity(0.20), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Theme.lilac.opacity(0.12), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 300)
            LinearGradient(colors: [Theme.ink.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}
