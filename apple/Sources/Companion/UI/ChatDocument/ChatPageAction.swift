import Foundation

/// A message the chat page sends back to the app when one of a turn's
/// tools is pressed or its work timeline is opened or closed. The page
/// posts the JSON `{"kind": "<name>", "turn": "<uuid>"}` through one
/// `WKScriptMessageHandler` channel; anything else is refused by returning
/// nil here, so an unknown or malformed message runs nothing.
enum ChatPageAction: Equatable {
    case copy(turn: UUID)
    case readAloud(turn: UUID)
    case thumbsUp(turn: UUID)
    case thumbsDown(turn: UUID)
    case regenerate(turn: UUID)
    case edit(turn: UUID)
    case delete(turn: UUID)
    case openWork(turn: UUID)
    case closeWork(turn: UUID)

    /// The turn this action is about.
    var turnID: UUID {
        switch self {
        case .copy(let t), .readAloud(let t), .thumbsUp(let t), .thumbsDown(let t),
             .regenerate(let t), .edit(let t), .delete(let t),
             .openWork(let t), .closeWork(let t):
            return t
        }
    }

    /// The name chat.js posts and the HTML writes into `data-action`.
    var kind: String {
        switch self {
        case .copy: return "copy"
        case .readAloud: return "readAloud"
        case .thumbsUp: return "thumbsUp"
        case .thumbsDown: return "thumbsDown"
        case .regenerate: return "regenerate"
        case .edit: return "edit"
        case .delete: return "delete"
        case .openWork: return "openWork"
        case .closeWork: return "closeWork"
        }
    }

    init?(json: Any) {
        guard let dict = json as? [String: Any],
              let kind = dict["kind"] as? String,
              let turnString = dict["turn"] as? String,
              let turn = UUID(uuidString: turnString) else { return nil }
        switch kind {
        case "copy": self = .copy(turn: turn)
        case "readAloud": self = .readAloud(turn: turn)
        case "thumbsUp": self = .thumbsUp(turn: turn)
        case "thumbsDown": self = .thumbsDown(turn: turn)
        case "regenerate": self = .regenerate(turn: turn)
        case "edit": self = .edit(turn: turn)
        case "delete": self = .delete(turn: turn)
        case "openWork": self = .openWork(turn: turn)
        case "closeWork": self = .closeWork(turn: turn)
        default: return nil
        }
    }
}