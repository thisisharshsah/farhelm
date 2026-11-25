import AppKit
import EventKit
import Foundation

/// The agent's way into the Mac's own services: Spotlight, the clipboard,
/// Calendar, Reminders, Mail and Notes. Looking is free; anything that
/// changes something (an event, a reminder, a draft, a note, the
/// clipboard) is shown first, as other changes are. Mail is drafted,
/// never sent: the person sends it.
enum MacServices {
    /// One service: its name, mark and the actions it has.
    struct Service {
        let id: String
        let title: String
        let icon: String
        /// Actions that only look.
        let looks: Set<String>
        /// Actions that change something.
        let changes: Set<String>
    }

    static let all: [Service] = [
        Service(id: "spotlight", title: "Spotlight", icon: "magnifyingglass.circle", looks: ["find"], changes: []),
        Service(id: "clipboard", title: "Clipboard", icon: "doc.on.clipboard", looks: ["read"], changes: ["write"]),
        Service(id: "calendar", title: "Calendar", icon: "calendar", looks: ["events"], changes: ["add"]),
        Service(id: "reminders", title: "Reminders", icon: "checklist", looks: ["list"], changes: ["add", "complete"]),
        Service(id: "mail", title: "Mail", icon: "envelope", looks: ["recent", "read"], changes: ["draft"]),
        Service(id: "notes", title: "Notes", icon: "note.text", looks: ["search", "read"], changes: ["append", "create"]),
    ]

    static func service(_ id: String) -> Service? { all.first { $0.id == id.lowercased() } }

    /// Whether the action changes something, so it is shown first.
    static func changes(_ service: String, _ action: String) -> Bool {
        guard let found = Self.service(service) else { return true }
        return !found.looks.contains(action.lowercased())
    }

    /// The step in words, for the approval card and the work list.
    static func words(_ service: String, _ action: String, _ args: [String: Any]) -> String {
        func s(_ key: String) -> String { (args[key] as? String) ?? (args[key].map { "\($0)" } ?? "") }
        switch (service, action) {
        case ("spotlight", _): return "find \u{201C}\(s("query"))\u{201D}" + (s("name") == "true" || s("name") == "1" ? " in file names" : "")
        case ("clipboard", "read"): return "read what is copied"
        case ("clipboard", "write"): return "copy \(s("text").count) characters"
        case ("calendar", "events"):
            let days = Int(s("days")) ?? 7
            return "events in the next \(days) day\(days == 1 ? "" : "s")" + (s("query").isEmpty ? "" : " about \u{201C}\(s("query"))\u{201D}")
        case ("calendar", "add"): return "add \u{201C}\(s("title"))\u{201D} at \(s("start"))"
        case ("reminders", "list"): return "open reminders" + (s("list").isEmpty ? "" : " in \(s("list"))")
        case ("reminders", "add"): return "add \u{201C}\(s("title"))\u{201D}" + (s("due").isEmpty ? "" : ", due \(s("due"))")
        case ("reminders", "complete"): return "mark \u{201C}\(s("title"))\u{201D} done"
        case ("mail", "recent"): return "recent mail" + (s("query").isEmpty ? "" : " about \u{201C}\(s("query"))\u{201D}")
        case ("mail", "read"): return "read the message \u{201C}\(s("subject"))\u{201D}"
        case ("mail", "draft"): return "draft to \(s("to")): \u{201C}\(s("subject"))\u{201D} (not sent)"
        case ("notes", "search"): return "notes about \u{201C}\(s("query"))\u{201D}"
        case ("notes", "read"): return "read the note \u{201C}\(s("name"))\u{201D}"
        case ("notes", "append"): return "add to the note \u{201C}\(s("name"))\u{201D}"
        case ("notes", "create"): return "new note \u{201C}\(s("name"))\u{201D}"
        default: return action
        }
    }

    // MARK: Running

    static func run(_ service: String, _ action: String, _ args: [String: Any]) async -> AgentTools.Outcome {
        func s(_ key: String) -> String { (args[key] as? String) ?? (args[key].map { "\($0)" } ?? "") }
        switch (service, action) {
        case ("spotlight", "find"): return await spotlight(s("query"), names: s("name") == "true" || s("name") == "1")
        case ("clipboard", "read"): return await MainActor.run { readClipboard() }
        case ("clipboard", "write"):
            let text = s("text")
            return await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return AgentTools.Outcome(ok: true, text: "Copied \(text.count) characters.")
            }
        case ("calendar", "events"): return await events(days: Int(s("days")) ?? 7, query: s("query"))
        case ("calendar", "add"):
            return await addEvent(title: s("title"), start: s("start"), end: s("end"),
                                  minutes: Int(s("minutes")) ?? 60, calendar: s("calendar"), notes: s("notes"))
        case ("reminders", "list"): return await reminders(list: s("list"))
        case ("reminders", "add"): return await addReminder(title: s("title"), due: s("due"), list: s("list"), notes: s("notes"))
        case ("reminders", "complete"): return await completeReminder(title: s("title"))
        case ("mail", "recent"): return await AppleScript.run(Scripts.mailRecent, [s("query"), s("count").isEmpty ? "15" : s("count")])
        case ("mail", "read"): return await AppleScript.run(Scripts.mailRead, [s("subject")])
        case ("mail", "draft"): return await AppleScript.run(Scripts.mailDraft, [s("to"), s("subject"), s("body")])
        case ("notes", "search"): return await AppleScript.run(Scripts.notesSearch, [s("query")])
        case ("notes", "read"): return await AppleScript.run(Scripts.notesRead, [s("name")])
        case ("notes", "append"): return await AppleScript.run(Scripts.notesAppend, [s("name"), html(s("text"))])
        case ("notes", "create"): return await AppleScript.run(Scripts.notesCreate, [s("name"), html(s("name")), html(s("text"))])
        default:
            return AgentTools.Outcome(ok: false, text: "There is no \(action) for \(service).")
        }
    }

    /// Text as a note's HTML: its marks escaped, its lines kept.
    private static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: Spotlight

    private static func spotlight(_ query: String, names: Bool) async -> AgentTools.Outcome {
        guard !query.isEmpty else { return AgentTools.Outcome(ok: false, text: "Give something to find.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let output = await Task.detached { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", home] + (names ? ["-name", query] : [query])
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do { try process.run() } catch { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
        let skipped = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/DerivedData/", "/.build/"]
        let paths = output.split(separator: "\n").map(String.init).filter { path in
            !skipped.contains { path.contains($0) }
        }
        guard !paths.isEmpty else { return AgentTools.Outcome(ok: true, text: "Spotlight found nothing for that.") }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        let dated = paths.map { path -> (String, Date) in
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
            return (path, date)
        }.sorted { $0.1 > $1.1 }
        let lines = dated.prefix(40).map { "\(($0.0 as NSString).abbreviatingWithTildeInPath)  (\(formatter.string(from: $0.1)))" }
        return AgentTools.Outcome(ok: true, text: lines.joined(separator: "\n")
            + (paths.count > 40 ? "\n\u{2026} \(paths.count - 40) more; search more narrowly." : ""))
    }

    // MARK: Clipboard

    @MainActor private static func readClipboard() -> AgentTools.Outcome {
        let board = NSPasteboard.general
        if let text = board.string(forType: .string), !text.isEmpty {
            return AgentTools.Outcome(ok: true, text: String(text.prefix(20_000)))
        }
        if let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return AgentTools.Outcome(ok: true, text: "Copied files:\n" + files.map(\.path).joined(separator: "\n"))
        }
        if board.data(forType: .png) != nil || board.data(forType: .tiff) != nil {
            return AgentTools.Outcome(ok: true, text: "A picture is copied (no text).")
        }
        return AgentTools.Outcome(ok: true, text: "Nothing is copied.")
    }

    // MARK: Calendar and Reminders

    private static let store = EKEventStore()

    private static func access(_ type: EKEntityType) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: type)
        if status == .fullAccess { return true }
        if status == .denied || status == .restricted { return false }
        do {
            return type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        } catch { return false }
    }

    private static func refused(_ app: String) -> AgentTools.Outcome {
        AgentTools.Outcome(ok: false, text: "Companion has no access to \(app). The user can allow it in System Settings > Privacy & Security > \(app).")
    }

    /// A date from "2026-11-25 14:00", an ISO date, or plain words ("tomorrow at 3pm").
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let iso = ISO8601DateFormatter().date(from: trimmed) { return iso }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            if let found = formatter.date(from: trimmed) { return found }
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))?.date
    }

    private static let shown: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, h:mm a"
        return formatter
    }()

    private static func events(days: Int, query: String) async -> AgentTools.Outcome {
        guard await access(.event) else { return refused("Calendars") }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: max(1, min(days, 60)), to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var found = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if !query.isEmpty {
            let lower = query.lowercased()
            found = found.filter { ($0.title ?? "").lowercased().contains(lower) || ($0.location ?? "").lowercased().contains(lower) }
        }
        guard !found.isEmpty else { return AgentTools.Outcome(ok: true, text: "No events then.") }
        let lines = found.prefix(60).map { event -> String in
            let when = event.isAllDay ? "all day " + (shown.string(from: event.startDate).components(separatedBy: ",").first ?? "")
                : shown.string(from: event.startDate) + " to " + DateFormatter.localizedString(from: event.endDate, dateStyle: .none, timeStyle: .short)
            var line = "\(when) | \(event.title ?? "(no title)") | \(event.calendar.title)"
            if let place = event.location, !place.isEmpty { line += " | \(place)" }
            return line
        }
        return AgentTools.Outcome(ok: true, text: lines.joined(separator: "\n"))
    }

    private static func addEvent(title: String, start: String, end: String, minutes: Int,
                                 calendar: String, notes: String) async -> AgentTools.Outcome {
        guard await access(.event) else { return refused("Calendars") }
        guard !title.isEmpty, let begins = date(start) else {
            return AgentTools.Outcome(ok: false, text: "Give a title and a start, such as 2026-11-25 14:00.")
        }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = begins
        event.endDate = date(end) ?? begins.addingTimeInterval(Double(max(5, minutes)) * 60)
        event.notes = notes.isEmpty ? nil : notes
        event.calendar = store.calendars(for: .event).first { $0.title.lowercased() == calendar.lowercased() && $0.allowsContentModifications }
            ?? store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return AgentTools.Outcome(ok: true, text: "Added \u{201C}\(title)\u{201D} on \(shown.string(from: begins)) to \(event.calendar.title).")
        } catch {
            return AgentTools.Outcome(ok: false, text: "Could not add it: \(error.localizedDescription)")
        }
    }

    private static func fetchReminders(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
    }

    private static func reminders(list: String) async -> AgentTools.Outcome {
        guard await access(.reminder) else { return refused("Reminders") }
        let lists = store.calendars(for: .reminder).filter { list.isEmpty || $0.title.lowercased() == list.lowercased() }
        let found = await fetchReminders(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
        guard !found.isEmpty else { return AgentTools.Outcome(ok: true, text: "No open reminders.") }
        let sorted = found.sorted {
            ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
        }
        let lines = sorted.prefix(60).map { reminder -> String in
            var line = "\(reminder.title ?? "(no title)") | \(reminder.calendar.title)"
            if let due = reminder.dueDateComponents?.date { line += " | due \(shown.string(from: due))" }
            return line
        }
        return AgentTools.Outcome(ok: true, text: lines.joined(separator: "\n"))
    }

    private static func addReminder(title: String, due: String, list: String, notes: String) async -> AgentTools.Outcome {
        guard await access(.reminder) else { return refused("Reminders") }
        guard !title.isEmpty else { return AgentTools.Outcome(ok: false, text: "Give the reminder a title.") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes.isEmpty ? nil : notes
        reminder.calendar = store.calendars(for: .reminder).first { $0.title.lowercased() == list.lowercased() }
            ?? store.defaultCalendarForNewReminders()
        if let when = date(due) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            reminder.addAlarm(EKAlarm(absoluteDate: when))
        }
        do {
            try store.save(reminder, commit: true)
            return AgentTools.Outcome(ok: true, text: "Added the reminder \u{201C}\(title)\u{201D} to \(reminder.calendar.title).")
        } catch {
            return AgentTools.Outcome(ok: false, text: "Could not add it: \(error.localizedDescription)")
        }
    }

    private static func completeReminder(title: String) async -> AgentTools.Outcome {
        guard await access(.reminder) else { return refused("Reminders") }
        let open = await fetchReminders(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        let matches = open.filter { ($0.title ?? "").lowercased() == title.lowercased() }
        guard matches.count == 1, let reminder = matches.first else {
            return AgentTools.Outcome(ok: false, text: matches.isEmpty ? "No open reminder is called that." : "More than one reminder is called that; name it exactly.")
        }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            return AgentTools.Outcome(ok: true, text: "Marked \u{201C}\(title)\u{201D} done.")
        } catch {
            return AgentTools.Outcome(ok: false, text: "Could not change it: \(error.localizedDescription)")
        }
    }
}

/// AppleScript run as its own process, with the values passed as
/// arguments (never spliced into the script), for Mail and Notes. The
/// first use asks the user to let Companion control the app.
enum AppleScript {
    static func run(_ script: String, _ arguments: [String]) async -> AgentTools.Outcome {
        await Task.detached { () -> AgentTools.Outcome in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script] + arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                return AgentTools.Outcome(ok: false, text: "Could not run it: \(error.localizedDescription)")
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let problem = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus != 0 {
                let said = String(decoding: problem, as: UTF8.self)
                if said.contains("-1743") || said.lowercased().contains("not authorized") {
                    return AgentTools.Outcome(ok: false, text: "Companion is not allowed to control that app. The user can allow it in System Settings > Privacy & Security > Automation.")
                }
                return AgentTools.Outcome(ok: false, text: said.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return AgentTools.Outcome(ok: true, text: text.isEmpty ? "Done." : String(text.prefix(20_000)))
        }.value
    }
}

/// The scripts, each reading its values from `argv`.
private enum Scripts {
    static let mailRecent = """
    on run argv
        set wanted to item 1 of argv
        set limit to (item 2 of argv) as integer
        set out to ""
        tell application "Mail"
            set found to 0
            repeat with m in (messages of inbox)
                set s to subject of m
                set f to sender of m
                if wanted is "" or s contains wanted or f contains wanted then
                    set mark to ""
                    if read status of m is false then set mark to " | unread"
                    set out to out & (date received of m as string) & " | " & f & " | " & s & mark & linefeed
                    set found to found + 1
                    if found is greater than or equal to limit then exit repeat
                end if
            end repeat
        end tell
        if out is "" then return "No mail like that in the inbox."
        return out
    end run
    """

    static let mailRead = """
    on run argv
        set wanted to item 1 of argv
        tell application "Mail"
            repeat with m in (messages of inbox)
                if subject of m contains wanted then
                    return "From: " & sender of m & linefeed & "Date: " & (date received of m as string) & linefeed & "Subject: " & subject of m & linefeed & linefeed & content of m
                end if
            end repeat
        end tell
        return "No message in the inbox has that subject."
    end run
    """

    static let mailDraft = """
    on run argv
        set toAddress to item 1 of argv
        set theSubject to item 2 of argv
        set theBody to item 3 of argv
        tell application "Mail"
            set draft to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            tell draft to make new to recipient at end of to recipients with properties {address:toAddress}
            activate
        end tell
        return "A draft is open in Mail for the user to check and send. It was not sent."
    end run
    """

    static let notesSearch = """
    on run argv
        set wanted to item 1 of argv
        set out to ""
        tell application "Notes"
            set found to 0
            repeat with n in (notes whose name contains wanted)
                set out to out & name of n & " | " & (modification date of n as string) & linefeed
                set found to found + 1
                if found is greater than or equal to 25 then exit repeat
            end repeat
            if found is 0 then
                repeat with n in (notes whose plaintext contains wanted)
                    set out to out & name of n & " | " & (modification date of n as string) & linefeed
                    set found to found + 1
                    if found is greater than or equal to 25 then exit repeat
                end repeat
            end if
        end tell
        if out is "" then return "No note mentions that."
        return out
    end run
    """

    static let notesRead = """
    on run argv
        set wanted to item 1 of argv
        tell application "Notes"
            set found to (notes whose name is wanted)
            if (count of found) is 0 then set found to (notes whose name contains wanted)
            if (count of found) is 0 then return "No note is called that."
            return plaintext of item 1 of found
        end tell
    end run
    """

    static let notesAppend = """
    on run argv
        set wanted to item 1 of argv
        set addition to item 2 of argv
        tell application "Notes"
            set found to (notes whose name is wanted)
            if (count of found) is 0 then return "No note is called that."
            set n to item 1 of found
            set body of n to (body of n) & "<div>" & addition & "</div>"
        end tell
        return "Added to the note."
    end run
    """

    static let notesCreate = """
    on run argv
        set theName to item 1 of argv
        set shownName to item 2 of argv
        set theText to item 3 of argv
        tell application "Notes"
            make new note at default account with properties {name:theName, body:"<h1>" & shownName & "</h1><div>" & theText & "</div>"}
        end tell
        return "Created the note."
    end run
    """
}
