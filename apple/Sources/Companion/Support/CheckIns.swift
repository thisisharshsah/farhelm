import Foundation
import UserNotifications

/// A time the agent comes back to a task on its own: a job, a build, a
/// queue it is watching. Until then the chat is free for anything else;
/// a clock in the chat and in the list shows what it waits for, with
/// Check now and Cancel. When the time comes the person is alerted and
/// the agent carries on in that chat.
struct CheckIn: Codable, Identifiable, Equatable {
    var id = UUID()
    let chatID: UUID
    let due: Date
    /// What it will look at ("job 42062 and its log").
    let note: String
    /// The task it carries on.
    let task: String
    var made = Date()
}

@MainActor
final class CheckIns: ObservableObject {
    static let shared = CheckIns()

    @Published private(set) var all: [CheckIn] = []
    private var timers: [UUID: Task<Void, Never>] = [:]
    private let file = ContextStore.shared.baseDir.appendingPathComponent("check-ins.json")

    private init() {
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([CheckIn].self, from: data) {
            all = saved
        }
        // Kept across a relaunch; one whose time passed while the app was
        // closed comes due a moment after it opens.
        for checkIn in all { schedule(checkIn) }
    }

    func pending(in chat: UUID) -> [CheckIn] {
        all.filter { $0.chatID == chat }.sorted { $0.due < $1.due }
    }

    @discardableResult
    func add(chat: UUID, after seconds: TimeInterval, note: String, task: String) -> CheckIn {
        // One check-in per chat: a new one replaces the one before.
        for old in all where old.chatID == chat { cancel(old.id) }
        let checkIn = CheckIn(chatID: chat, due: Date().addingTimeInterval(seconds), note: note, task: task)
        all.append(checkIn)
        save()
        schedule(checkIn)
        Self.askToAlert()
        return checkIn
    }

    func cancel(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        all.removeAll { $0.id == id }
        save()
    }

    /// Now rather than at its time.
    func checkNow(_ id: UUID) {
        guard let checkIn = all.first(where: { $0.id == id }) else { return }
        fire(checkIn)
    }

    private func schedule(_ checkIn: CheckIn) {
        timers[checkIn.id]?.cancel()
        timers[checkIn.id] = Task { @MainActor [weak self] in
            let wait = max(2, checkIn.due.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fire(checkIn)
        }
    }

    private func fire(_ checkIn: CheckIn) {
        // The chat's agent is busy: a minute later.
        guard AppState.shared.resumeCheckIn(checkIn) else {
            timers[checkIn.id] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.fire(checkIn)
            }
            return
        }
        timers[checkIn.id]?.cancel()
        timers[checkIn.id] = nil
        all.removeAll { $0.id == checkIn.id }
        save()
        Self.alert(title: "Checking again", body: checkIn.note)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Alerts

    private static var asked = false

    private static func askToAlert() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func alert(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Companion: " + title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// "12:40 PM", or "tomorrow 9:05 AM".
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return formatter.string(from: date)
    }
}
