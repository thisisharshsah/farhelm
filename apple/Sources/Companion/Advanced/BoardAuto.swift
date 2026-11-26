import CompanionBoard
import Foundation

extension Advanced {
    /// How the board's Auto (`BoardSettings.auto`) stands for a chat's
    /// steps, or nil when the chat is in no project. It is read at every
    /// round, not kept on the chat, so the board's one setting reaches its
    /// runs, its supervisor and every other chat in the project alike, and
    /// turning it off makes them ask again from their next step.
    func autoRules(for chat: UUID, repository: String, directory: String) -> ((ActionStep) -> AutoPermission.Decision)? {
        let app = AppState.shared
        guard let id = app.anyChat(chat)?.projectID,
              let project = app.projects.first(where: { $0.id == id }) else { return nil }
        let board = store.load(id, live: Set(app.jobs.keys))
        guard board.settings.auto else { return nil }
        let worker: AutoPermission.Worker = board.supervisorChat == chat
            ? .supervisor : (board.item(runIn: chat) != nil ? .taskRun : .projectChat)
        // A task's copy is its own repository: Auto reaches as far as it.
        let place = Delegation.Place(project: repository.isEmpty ? (project.folder ?? "") : repository,
                                     directory: directory, home: NSHomeDirectory())
        let settings = board.settings
        return { step in
            AutoPermission.decide(Advanced.ruled(step, directory: directory), in: place, settings: settings, by: worker)
        }
    }
}