import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// One thing the agent did, as the shared trail shows it.
public struct TrailStep: Hashable, Sendable {
    /// "run", "read", "edit", "search", "web", "note", "ask", ...
    public var kind: String
    /// The command, file or action.
    public var title: String
    /// What it was for, when the agent said.
    public var why: String?
    /// The end of what it printed.
    public var output: String?
    public var failed: Bool

    public init(kind: String, title: String, why: String? = nil, output: String? = nil, failed: Bool = false) {
        self.kind = kind
        self.title = title
        self.why = why
        self.output = output
        self.failed = failed
    }
}

/// The agent's work as a transcript: a thin line down the left with a dot
/// for each step, titled by what it was for, opening to what went in and
/// what came out. What it said along the way reads as text in the line.
public struct StepTrail: View {
    let steps: [TrailStep]
    /// The last step is still going.
    let live: Bool
    var textSize: CGFloat

    public init(steps: [TrailStep], live: Bool, textSize: CGFloat = 12) {
        self.steps = steps
        self.live = live
        self.textSize = textSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                TrailRow(step: step,
                         live: live && index == steps.count - 1,
                         first: index == 0,
                         last: index == steps.count - 1,
                         textSize: textSize)
            }
        }
    }
}

/// A step's dot. The live one breathes, worked out from the clock at a low
/// frame rate: a `repeatForever` animation redraws at the display's full
/// rate, up to 120 times a second, for as long as the step runs.
private struct TrailDot: View {
    let color: Color
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if live && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
                dot.opacity(Self.breath(at: context.date))
            }
        } else {
            dot
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    /// From full to 0.35 and back every 1.6 seconds, eased at both ends.
    private static func breath(at date: Date) -> Double {
        let turn = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
        return 0.35 + 0.65 * (1 + cos(turn * 2 * .pi)) / 2
    }
}

private struct TrailRow: View {
    let step: TrailStep
    let live: Bool
    let first: Bool
    let last: Bool
    let textSize: CGFloat
    @State private var open = false

    private var dotTop: CGFloat { textSize * 0.75 }

    var body: some View {
        content
            .padding(.leading, 18)
            .padding(.bottom, last ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.ink.opacity(0.14))
                    .frame(width: 1)
                    .frame(maxHeight: last ? dotTop : .infinity, alignment: .top)
                    .padding(.top, first ? dotTop : 0)
                    .padding(.leading, 3.5)
            }
            .overlay(alignment: .topLeading) {
                TrailDot(color: dotColor, live: live)
                    .padding(.top, dotTop - 3)
            }
    }

    private var dotColor: Color {
        if step.failed { return Theme.rose }
        if live { return Theme.accent }
        switch step.kind {
        case "note", "think": return Theme.ink.opacity(0.3)
        case "ask": return Theme.amber
        default: return Theme.mint.opacity(0.85)
        }
    }

    private var hasCard: Bool { step.kind != "note" && (step.output?.isEmpty == false || step.why != nil) }

    @ViewBuilder
    private var content: some View {
        if step.kind == "note" {
            Text(step.title)
                .font(.system(size: textSize + 1))
                .foregroundStyle(Theme.ink.opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    guard hasCard else { return }
                    withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step.why ?? step.title)
                            .font(.system(size: textSize, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(step.failed ? 0.85 : 0.75))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if hasCard {
                            Image(systemName: open ? "chevron.down" : "chevron.right")
                                .font(.system(size: textSize * 0.7, weight: .bold))
                                .foregroundStyle(Theme.ink.opacity(0.4))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    TrailIOCard(input: step.why == nil ? nil : step.title, output: step.output, textSize: textSize * 0.92)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// What went in and what came out, three lines of each until clicked, with
/// a copy button on hover. The Mac's work trail and the phone's share it.
public struct TrailIOCard: View {
    let input: String?
    let output: String?
    var textSize: CGFloat
    @State private var expanded = false
    @State private var hover = false
    @State private var copied = false

    public init(input: String?, output: String?, textSize: CGFloat = 11) {
        self.input = input
        self.output = output
        self.textSize = textSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input, !input.isEmpty {
                row("IN", input)
            }
            if let output, !output.isEmpty {
                if input?.isEmpty == false {
                    Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 1)
                }
                row("OUT", output)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.shade.opacity(0.32)))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
            .strokeBorder(Theme.ink.opacity(0.10), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if hover || expanded, Clipboard.available {
                Button {
                    let text = [input.map { "$ " + $0 }, output].compactMap { $0 }.joined(separator: "\n")
                    Clipboard.copy(text)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: textSize * 0.9, weight: .semibold))
                        .foregroundStyle(copied ? Theme.mint : Theme.ink.opacity(0.6))
                        .frame(width: textSize * 2, height: textSize * 2)
                        .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous).fill(Theme.shade.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityLabel("Copy")
            }
        }
        .contentShape(Rectangle())
        .whenHovered { hover = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
    }

    private func row(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: textSize * 0.86, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .frame(width: textSize * 2.4, alignment: .leading)
            Text(text.trimmingCharacters(in: .newlines))
                .font(.system(size: textSize, design: .monospaced))
                .foregroundStyle(Theme.ink.opacity(label == "IN" ? 0.88 : 0.72))
                .lineLimit(expanded ? nil : 3)
                .truncationMode(.tail)
                .selectableText()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// The system clipboard, where there is one.
enum Clipboard {
    static var available: Bool {
        #if os(watchOS)
        return false
        #else
        return true
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    /// Follows the pointer over the view, where there is a pointer.
    @ViewBuilder
    func whenHovered(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(watchOS)
        self
        #else
        self.onHover(perform: action)
        #endif
    }

    /// Text that can be selected and copied, where the platform allows it.
    @ViewBuilder
    func selectableText() -> some View {
        #if os(watchOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }
}
