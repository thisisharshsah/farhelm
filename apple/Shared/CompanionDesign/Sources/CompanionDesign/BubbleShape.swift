import SwiftUI

/// Chat bubble outline: rounded, with a tighter corner on the side it
/// belongs to (left for the assistant, right for inputs).
public struct BubbleShape: InsettableShape {
    public enum Side: Sendable { case left, right }
    let side: Side
    var inset: CGFloat = 0

    public init(side: Side, inset: CGFloat = 0) {
        self.side = side
        self.inset = inset
    }

    public func path(in rect: CGRect) -> Path {
        let round = Theme.bubbleRadius
        let radii = RectangleCornerRadii(topLeading: round,
                                         bottomLeading: side == .left ? 4 : round,
                                         bottomTrailing: side == .right ? 4 : round,
                                         topTrailing: round)
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    public func inset(by amount: CGFloat) -> BubbleShape {
        BubbleShape(side: side, inset: inset + amount)
    }
}

