import Foundation

/// Folders the person let the agent's commands into, one at a time, the way
/// macOS itself asks about a folder.
///
/// The agent's commands start responsible for themselves (`AgentProcess`),
/// so macOS keeps them out of Documents, Desktop, Downloads and iCloud
/// Drive whatever access Companion has. For a folder allowed here, commands
/// start as Companion's own instead, and macOS then lets them in under
/// Companion's access to that place (asking the person once, in its own
/// dialog, if it has not yet). The price, said in the question: those
/// commands also carry the other access the person gave Companion. So it is
/// asked per folder, only by the person, and can be taken back.
enum ShellAccess {
    private static let key = "agentShellFolders"

    /// The folders allowed, as full paths.
    static var folders: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Whether macOS keeps self-responsible commands out of this place.
    static func isProtected(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let kept = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 }
        let place = (path as NSString).standardizingPath
        return kept.contains { place == $0 || place.hasPrefix($0 + "/") } || place.hasPrefix("/Volumes/")
    }

    /// Whether a place is an allowed folder, or inside one.
    static func allows(_ path: String) -> Bool {
        let place = (path as NSString).standardizingPath
        return folders.contains { place == $0 || place.hasPrefix($0 + "/") }
    }

    /// Whether a command runs with Companion's access: it starts in an
    /// allowed folder, or names one.
    static func covers(command: String, in directory: String) -> Bool {
        if allows(directory) { return true }
        let home = NSHomeDirectory()
        return folders.contains { folder in
            command.contains(folder) || (folder.hasPrefix(home) && command.contains("~" + folder.dropFirst(home.count)))
        }
    }

    static func allow(_ path: String) {
        let place = (path as NSString).standardizingPath
        guard !allows(place) else { return }
        // A folder that holds ones allowed before takes their place.
        let rest = folders.filter { !$0.hasPrefix(place + "/") }
        UserDefaults.standard.set(rest + [place], forKey: key)
    }

    static func revoke(_ path: String) {
        UserDefaults.standard.set(folders.filter { $0 != path }, forKey: key)
    }

    /// The folder to ask the person about after a command was refused: where
    /// it ran, else where the task started, when macOS keeps commands out of
    /// it and it has not been allowed. Nil when the refusal was about
    /// something else.
    static func folderToAsk(after output: String, in directory: String, start: String) -> String? {
        guard output.localizedCaseInsensitiveContains("Operation not permitted") else { return nil }
        return [directory, start].first { isProtected($0) && !allows($0) }
    }

    /// A path as people write it.
    static func shown(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
