import SwiftUI

/// The chat box's words as typed, readable by the chat around the box
/// without watching them: a plain reference, so typing changes nothing
/// the rest of the window draws from.
final class ChatBoxText {
    var text = ""
    /// Sets what the field shows, from outside it. A send moves the words
    /// into the draft and clears it in the same moment, so the draft ends
    /// as it began and the field would never hear of it.
    var set: (String) -> Void = { _ in }
}

/// The chat box's text field, in a view of its own. Its words live here
/// while typing, so a key redraws this field alone and not the whole
/// chat (the thread, the sidebar, the browser beside it), which in a long
/// chat lagged behind the keys. What the chat around it needs is passed
/// up only when it changes: whether anything is typed, and the @mention
/// being typed. The words reach `app.draft` once typing pauses, and at
/// once on send; a change from elsewhere (another chat's draft,
/// dictation, a chosen @mention) comes back in.
struct ChatBoxField: View {
    @EnvironmentObject var app: AppState
    let placeholder: String
    let fontSize: CGFloat
    let box: ChatBoxText
    var focus: FocusState<Bool>.Binding
    @Binding var hasText: Bool
    @Binding var mentionQuery: String?
    /// A key the @mention list may take: true when it did.
    let onKey: (KeyEquivalent) -> Bool
    let onSubmit: () -> Void

    @State private var typed = ""
    @State private var sync: Task<Void, Never>?

    var body: some View {
        TextField(placeholder, text: $typed, axis: .vertical)
            .textFieldStyle(.plain)
            // Commands, paths and code are typed here: no word is ever
            // changed into another (sh -c is not "-coming").
            .autocorrectionDisabled(true)
            .font(.system(size: fontSize))
            .foregroundStyle(Theme.ink.opacity(0.95))
            .lineLimit(1...6)
            .focused(focus)
            .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab, .escape]) { press in
                onKey(press.key) ? .handled : .ignored
            }
            .onChange(of: typed) { _, new in
                box.text = new
                let filled = !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if filled != hasText { hasText = filled }
                let query = Mention.query(in: new)
                if query != mentionQuery { mentionQuery = query }
                sync?.cancel()
                sync = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    if app.draft != typed { app.draft = typed }
                }
            }
            .onChange(of: app.draft) { _, new in
                // Set from elsewhere: that wins over a pause not yet synced.
                if new != typed { sync?.cancel(); sync = nil; typed = new }
            }
            .onAppear {
                typed = app.draft
                box.text = app.draft
                box.set = { text in
                    sync?.cancel()
                    sync = nil
                    typed = text
                }
            }
            .onSubmit {
                sync?.cancel()
                sync = nil
                if app.draft != typed { app.draft = typed }
                onSubmit()
                if app.draft != typed { typed = app.draft }
            }
    }
}
