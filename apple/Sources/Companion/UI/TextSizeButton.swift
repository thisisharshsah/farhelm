import SwiftUI

/// "Aa" over the conversation: the chat's text size, a step at a time.
/// The same as Settings > Look > Chat text, kept where it is needed.
struct TextSizeButton: View {
    @ObservedObject private var settings = AppSettings.shared
    /// Open: the tools it sits among stay up while the pointer is in it.
    @Binding var open: Bool
    @State private var hover = false

    private var percent: Int { Int((settings.chatTextScale / AppSettings.chatTextDefault * 100).rounded()) }

    var body: some View {
        // A toolbar group of one: the same size as the groups beside it.
        ToolbarGroup {
            button
        }
    }

    private var button: some View {
        Button { open.toggle() } label: {
            Text("Aa")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(open ? Theme.accent : Theme.ink.opacity(hover ? 1 : 0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.ink.opacity(hover || open ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .onHover { hover = $0 }
        .buttonStyle(.plain)
        .help("Chat text size")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                IconButton("textformat.size.smaller", help: "Smaller") { settings.chatText(-1) }
                    .disabled(settings.chatTextScale <= AppSettings.chatTextRange.lowerBound)
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 44)
                IconButton("textformat.size.larger", help: "Larger") { settings.chatText(1) }
                    .disabled(settings.chatTextScale >= AppSettings.chatTextRange.upperBound)
                Button("Reset") { settings.chatText(0) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(10)
        }
    }
}
