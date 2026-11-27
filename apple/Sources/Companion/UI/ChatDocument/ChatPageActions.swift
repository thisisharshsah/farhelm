import Foundation

/// How a `ChatPageAction` from the chat document reaches the app. Each
/// case calls the same app code the old message list's buttons call, so
/// the two drawings of the chat stay in step: copy through `AppState.copy`
/// (OverlayView `actions` row), regenerate through `regenerate`, edit
/// through `reuse` (which puts the prompt back in the chat box), delete
/// through `deleteTurn`. Read-aloud, thumbs up and thumbs down have no
/// button in the old list yet (T-73), so each has its own clearly named
/// app-side entry on AppState: `chatPageReadAloud`, `chatPageThumbsUp`,
/// `chatPageThumbsDown`.
@MainActor
func runChatPageAction(_ action: ChatPageAction, app: AppState) {
    guard let turn = app.conversation.turns.first(where: { $0.id == action.turnID }) else { return }
    switch action {
    case .copy:
        app.copy(turn.answer)
    case .readAloud:
        app.chatPageReadAloud(turn.id)
    case .thumbsUp:
        app.chatPageThumbsUp(turn.id)
    case .thumbsDown:
        app.chatPageThumbsDown(turn.id)
    case .regenerate:
        app.regenerate(turn.id)
    case .edit:
        app.reuse(turn.id)
    case .delete:
        app.deleteTurn(turn.id)
    case .openWork, .closeWork:
        // Pure page state the coordinator tracks for the next render.
        break
    }
}