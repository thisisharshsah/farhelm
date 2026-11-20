import Foundation

/// The side of the app in use. One at a time; the buttons in the top bar
/// switch between them.
enum AppMode: String, CaseIterable, Identifiable {
    /// Plain conversation.
    case chat
    /// Work on a repository: files and editor, search, changes, terminal.
    case code
    /// A project run as a whole: its plan as a board of tasks, kept by a
    /// supervisor model that gives each task to the model that suits it,
    /// with what every chat, task and model costs.
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .code: return "Code"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .advanced: return "square.stack.3d.up"
        }
    }

    var help: String {
        switch self {
        case .chat: return "Chat"
        case .code: return "Code: work on a repository. Files and editor, search, changes with undo, terminal."
        case .advanced:
            return "Advanced: run a project. A supervisor plans the work as a board, gives each task to the model that suits it, and tracks every token."
        }
    }
}
