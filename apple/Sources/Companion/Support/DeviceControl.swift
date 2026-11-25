import AppKit
import ApplicationServices
import Carbon

/// One thing Companion does at the keyboard on the user's behalf.
struct ActionStep: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Type this text where the cursor is.
        case type
        /// Press a key or shortcut, such as "enter" or "cmd+a".
        case key
        /// Press a button, menu item, checkbox or link, found by its label.
        case click
        /// Run a shell command and read its output.
        case run
        /// Bring an app to the front by name.
        case open
        /// Wait a few seconds for something to load.
        case wait
        /// The task is finished; the value says what was done.
        case done
        /// The agent needs the user: a question, or why it cannot go on.
        case ask
        /// Read a file (or some of its lines), or list a folder.
        case read
        /// Find text in files.
        case search
        /// Create or replace a file; `body` is its content.
        case write
        /// Change one exact piece of a file: `body` becomes `replacement`.
        case edit
        /// Load a web page as text.
        case fetch
        /// Search the web.
        case web
        /// The agent's own checklist for a longer task.
        case plan
        /// A question handed to a helper that reads and searches in a
        /// context of its own and gives back only its findings.
        case delegate
        /// A step in the user's Chrome, through Companion's extension:
        /// `body` holds the command and its arguments as JSON.
        case browser
        /// A terminal beside the chat, running a command the user works
        /// in with the agent (an ssh session to a server or a cluster).
        case terminal
        /// Look through the person's saved chats: "search: words", or
        /// "read: chat-number | what to look for".
        case chats
        /// One of the Mac's own services (Spotlight, the clipboard,
        /// Calendar, Reminders, Mail, Notes): `body` holds the service,
        /// the action and its values as JSON.
        case mac
        /// The agent's notes on where the chat's work stands (`workNotes`).
        case notes

        /// Works an app through the keyboard or the pointer.
        var usesKeyboard: Bool {
            self == .type || self == .key || self == .open || self == .click
        }
    }

    let id = UUID()
    let kind: Kind
    let value: String
    /// A file's new content (write), or the text to be replaced (edit).
    var body = ""
    /// What the replaced text becomes (edit).
    var replacement = ""
    /// What the step is for, from the WHY: line before it.
    var why: String? = nil
    /// The tool call this step came from, when the engine called tools
    /// natively; its result goes back under this id.
    var callID: String? = nil

    var label: String {
        switch kind {
        case .type: return "Type: \(value)"
        case .key: return "Press: \(value)"
        case .click: return "Click: \(value)"
        case .run: return "Run: \(value)"
        case .open: return "Open: \(value)"
        case .wait: return "Wait \(value) s"
        case .done: return "Done: \(value)"
        case .ask: return value
        case .read: return "Read: \(value)"
        case .search: return "Search: \(value)"
        case .write: return "Write: \(value)"
        case .edit: return "Edit: \(value)"
        case .fetch: return "Fetch: \(value)"
        case .web: return "Web search: \(value)"
        case .plan: return "Plan: \(value)"
        case .delegate: return "Delegate: \(value)"
        case .browser: return "Browser: \(value)"
        case .terminal: return "Terminal: \(value)"
        case .chats: return "Chats: \(value)"
        case .notes: return "Task notes: \(value)"
        case .mac: return "\(macCommand.flatMap { MacServices.service($0.service)?.title } ?? "Mac"): \(value)"
        }
    }
}

/// Steps the agent wants to take, shown to the user for a yes or no.
struct AgentProposal: Identifiable {
    let id = UUID()
    let steps: [ActionStep]
    /// The folder shell commands will run in.
    let directory: String
    /// What "always allow" would remember; empty when it cannot apply.
    let remember: [String]
    /// The sites the browser steps act on, which "Allow on this site"
    /// stops asking about for the rest of the task.
    var sites: [String] = []
}

enum AgentDecision {
    case allow, always, deny
}

/// A question the agent stops to ask in the middle of a task, with a few
/// answers to pick from. The user can also type an answer of their own.
struct AgentQuestion: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let options: [String]
    /// It is the task's own check-in after many steps ("Carry on?"), not
    /// a question about the work.
    var isCheckIn = false

    /// "Which branch? | main | develop" is a question with two answers.
    init(_ text: String) {
        let parts = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        question = parts.first ?? text
        options = Array(parts.dropFirst().prefix(4))
    }
}

enum DeviceControlError: LocalizedError {
    case notAllowed
    case ownWindow
    case focusChanged
    case focusMoved
    case secureField
    case cancelled
    case unknownKey(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed:
            return "Companion needs the Accessibility permission to type for you. Allow it in System Settings > Privacy & Security > Accessibility, then try again."
        case .ownWindow:
            return "The keys would have gone into Companion itself, so nothing was typed. Click into the app and field you mean (or name the app in your message) and try again."
        case .focusChanged:
            return "Stopped typing: the app in front changed."
        case .focusMoved:
            return "Stopped typing: another window came to the front."
        case .secureField:
            return "Stopped: the cursor is in a password field. Passwords are entered by you, never typed by the agent."
        case .cancelled:
            return "Stopped typing."
        case .unknownKey(let key):
            return "Did not recognize the key \"\(key)\", so nothing after it was run."
        }
    }
}

/// Where keys would go right now: the app in front, its focused window and
/// the focused element. The basis of Orbit's lease, for the keyboard.
struct FocusIdentity {
    let pid: pid_t
    let window: AXUIElement?
    let element: AXUIElement?
    /// The focused element is a password field.
    let secure: Bool

    /// Keys typed now land where they would have landed then: the same
    /// field, not just the same app.
    func sameField(as other: FocusIdentity) -> Bool {
        pid == other.pid && Self.same(element, other.element)
    }

    /// A press now happens in the window it was planned for.
    func sameWindow(as other: FocusIdentity) -> Bool {
        pid == other.pid && Self.same(window, other.window)
    }

    private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }
}

/// Types text and presses keys in whatever app is in front, by posting
/// keyboard events. Needs the Accessibility permission.
///
/// Safety: it only runs steps for a task the user gave; it never types into
/// a password field; it stops the moment the app in front changes, another
/// window comes to the front mid-typing, or the cursor lands in a password
/// field; and Escape cancels it.
@MainActor
final class DeviceControl {
    static let shared = DeviceControl()

    private var cancelled = false
    private var escapeMonitor: Any?
    private(set) var running = false

    var allowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to the Accessibility setting.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func cancel() {
        cancelled = true
    }

    /// Where keys would go now, or nil when that cannot be told: no
    /// Accessibility permission, or Companion itself is in front.
    func focusIdentity() -> FocusIdentity? {
        guard allowed, let running = NSWorkspace.shared.frontmostApplication,
              running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let focused = element(app, kAXFocusedUIElementAttribute)
        return FocusIdentity(pid: running.processIdentifier,
                             window: element(app, kAXFocusedWindowAttribute),
                             element: focused,
                             secure: focused.map(Redaction.isSecure) ?? false)
    }

    /// Orbit's lease: whether a keyboard or press step may go ahead, given
    /// where focus was when the step was planned. Returns why not, or nil.
    ///
    /// Text is never typed into a password field. Keys go only where the
    /// plan expected them: the same field, not just the same app. A press
    /// happens only in the window the plan was made in. `planned` is nil
    /// once an earlier step of the same plan has moved focus on purpose;
    /// then only the password rule applies.
    func leaseRefusal(for kind: ActionStep.Kind, planned: FocusIdentity?) -> String? {
        guard let now = focusIdentity() else { return nil }
        if kind == .type, now.secure {
            return "the cursor is in a password field, and passwords are entered by the user, never typed by the agent"
        }
        guard let planned else { return nil }
        if now.pid != planned.pid {
            return "a different app is in front than when this step was planned"
        }
        switch kind {
        case .type, .key:
            return now.sameField(as: planned) ? nil : "the cursor moved to another field after this step was planned"
        case .click:
            return now.sameWindow(as: planned) ? nil : "a different window is in front than when this step was planned"
        default:
            return nil
        }
    }

    func run(_ steps: [ActionStep]) async throws {
        guard allowed else {
            requestAccess()
            throw DeviceControlError.notAllowed
        }
        // Never into Companion itself: not when it is the app in front, and
        // not when one of its windows holds keyboard focus.
        guard let target = NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              NSApp.keyWindow == nil else {
            throw DeviceControlError.ownWindow
        }
        guard !running else { return }
        running = true
        cancelled = false
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in self?.cancel() }
            }
        }
        defer {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            running = false
        }

        // A hotkey may have started this: wait until its keys are released,
        // or the typed letters would be read as shortcuts.
        for _ in 0..<40 {
            let held = CGEventSource.flagsState(.combinedSessionState)
            if held.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        /// Where this step's typing started.
        var focusAtStart: FocusIdentity?
        func check(typing: Bool = false) throws {
            if cancelled { throw DeviceControlError.cancelled }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                throw DeviceControlError.focusChanged
            }
            guard typing, let focusAtStart, let now = focusIdentity() else { return }
            if now.secure { throw DeviceControlError.secureField }
            if focusAtStart.window != nil, !now.sameWindow(as: focusAtStart) {
                throw DeviceControlError.focusMoved
            }
        }
        for step in steps {
            try check()
            focusAtStart = step.kind == .type ? focusIdentity() : nil
            // The agent's pointer sits on the field it types or presses into.
            if step.kind == .type || step.kind == .key, let point = focusedPoint() {
                await AgentCursor.shared.move(to: point, note: step.kind == .type ? "Typing" : "Pressing \(step.value)", press: false)
            }
            switch step.kind {
            case .type:
                try check(typing: true)
                // A line break is sent as Shift+Return, which adds a line in
                // chat boxes instead of sending the message.
                let lines = step.value.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    if index > 0 {
                        press(CGKeyCode(kVK_Return), flags: .maskShift)
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                    let units = Array(line.utf16)
                    var start = 0
                    while start < units.count {
                        try check(typing: true)
                        let end = min(start + 16, units.count)
                        type(Array(units[start..<end]))
                        start = end
                        try await Task.sleep(nanoseconds: 12_000_000)
                    }
                }
            case .key:
                guard let (code, flags) = Self.parseKey(step.value) else {
                    throw DeviceControlError.unknownKey(step.value)
                }
                press(code, flags: flags)
            default:
                break // carried out by the agent loop, not at the keyboard
            }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func type(_ units: [UniChar]) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.flags = []
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func press(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: keyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Key names

    private static let named: [String: Int] = [
        "enter": kVK_Return, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "space": kVK_Space, "delete": kVK_Delete, "backspace": kVK_Delete, "up": kVK_UpArrow,
        "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow, "home": kVK_Home,
        "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift,
        "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl
    ]

    /// "enter", "cmd+a", "shift+tab" and the like.
    static func parseKey(_ text: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map(String.init)
        guard let last = parts.last, let code = named[last] else { return nil }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = modifiers[part] else { return nil }
            flags.insert(flag)
        }
        return (CGKeyCode(code), flags)
    }

    // MARK: - Pressing things by label (Accessibility)

    /// Kinds of control that can be pressed.
    private static let pressable: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXLink", "AXPopUpButton",
        "AXMenuButton", "AXDisclosureTriangle", "AXTab", "AXSwitch", "AXToggle"
    ]

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func role(of element: AXUIElement) -> String {
        (attribute(element, kAXRoleAttribute) as? String) ?? ""
    }

    /// What a control is called: its title, or failing that its description
    /// (icon buttons) or its text.
    private func label(of element: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let text = attribute(element, name) as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    private static func normalize(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The app in front as an accessibility element, with a short timeout
    /// so an unresponsive app cannot hang the agent.
    private func frontApp() -> (app: AXUIElement, name: String)? {
        guard let running = NSWorkspace.shared.frontmostApplication,
              running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.5)
        return (app, running.localizedName ?? "the app")
    }

    /// Every pressable control under an element, breadth first, bounded.
    private func controls(under root: AXUIElement, limit: Int = 2500) -> [(element: AXUIElement, role: String, label: String)] {
        var found: [(element: AXUIElement, role: String, label: String)] = []
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let current = queue.removeFirst()
            visited += 1
            let kind = role(of: current)
            if Self.pressable.contains(kind) {
                let name = label(of: current)
                if !name.isEmpty { found.append((current, kind, name)) }
            }
            queue.append(contentsOf: children(of: current))
        }
        return found
    }

    /// The labels of what can be pressed in the front window, for the agent
    /// to choose from.
    func clickableLabels(limit: Int = 60) -> [String] {
        guard allowed, let front = frontApp(),
              let window = element(front.app, kAXFocusedWindowAttribute) ?? element(front.app, kAXMainWindowAttribute)
        else { return [] }
        var seen: Set<String> = []
        var labels: [String] = []
        for control in controls(under: window, limit: 1500) where control.label.count <= 60 {
            if seen.insert(Self.normalize(control.label)).inserted {
                labels.append(control.label)
                if labels.count >= limit { break }
            }
        }
        return labels
    }

    /// Presses the control with the given label in the app in front.
    ///
    /// A plain label is looked for in the front window: an exact match
    /// first, then one that starts with it, then one that contains it. A
    /// path such as "File > Export…" walks the menu bar. Returns whether
    /// something was pressed and what, or why not.
    func click(_ wanted: String) async -> (ok: Bool, detail: String) {
        guard allowed else {
            requestAccess()
            return (false, DeviceControlError.notAllowed.localizedDescription)
        }
        guard let front = frontApp() else {
            return (false, "there is no other app in front to click in")
        }
        let path = wanted.components(separatedBy: ">").map(Self.normalize).filter { !$0.isEmpty }
        guard let last = path.last else { return (false, "no label was given") }

        var scope: AXUIElement?
        if path.count > 1 {
            // Menu path: start at the menu bar and descend one name at a time.
            scope = element(front.app, kAXMenuBarAttribute)
            for name in path.dropLast() {
                guard let current = scope else { break }
                scope = controls(under: current, limit: 600).first { Self.normalize($0.label) == name }?.element
            }
            guard scope != nil else {
                return (false, "the menu \"\(path.dropLast().joined(separator: " > "))\" was not found in \(front.name)")
            }
        } else {
            scope = element(front.app, kAXFocusedWindowAttribute) ?? element(front.app, kAXMainWindowAttribute)
        }
        guard let scope else { return (false, "\(front.name) has no window to click in") }

        let candidates = controls(under: scope)
        let match = candidates.first { Self.normalize($0.label) == last }
            ?? candidates.first { Self.normalize($0.label).hasPrefix(last) }
            ?? candidates.first { Self.normalize($0.label).contains(last) }
        guard let match else {
            return (false, "nothing called \"\(wanted)\" can be clicked in \(front.name)")
        }
        let kind = match.role.replacingOccurrences(of: "AX", with: "").lowercased()
        // Where it is on screen, noted before the press in case the press
        // takes it away (a menu item, a dialog's button).
        lastClickPoint = frame(of: match.element).map(Self.cocoaCenter)
        // The agent's pointer goes there first, so the person sees what is
        // about to be pressed.
        if let point = lastClickPoint {
            await AgentCursor.shared.move(to: point, note: "Clicking \(match.label)", press: true)
        }
        guard AXUIElementPerformAction(match.element, kAXPressAction as CFString) == .success else {
            return (false, "found the \(kind) \"\(match.label)\" but it did not respond to a press")
        }
        return (true, "\(kind) \"\(match.label)\" in \(front.name)")
    }

    // MARK: Where things are on screen (for the orbit that shows the agent at work)

    /// The middle of the last control that was pressed, in Cocoa screen
    /// coordinates.
    private(set) var lastClickPoint: CGPoint?

    /// An element's frame as accessibility reports it: from the top left of
    /// the main display.
    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// A point given from the top left of the main display, as Cocoa wants
    /// it: from the bottom left.
    private static func cocoa(_ point: CGPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }

    private static func cocoaCenter(_ rect: CGRect) -> CGPoint {
        cocoa(CGPoint(x: rect.midX, y: rect.midY))
    }

    /// Where the keys go now: the middle of the focused control (its left
    /// part for a wide field), in Cocoa screen coordinates.
    func focusedPoint() -> CGPoint? {
        guard allowed, let front = frontApp(),
              let focused = element(front.app, kAXFocusedUIElementAttribute),
              let box = frame(of: focused), box.width > 0 else { return focusPoint() }
        return Self.cocoa(CGPoint(x: box.minX + min(box.width / 2, 40), y: box.midY))
    }

    /// The middle of the window in front, in Cocoa screen coordinates.
    func focusPoint() -> CGPoint? {
        guard allowed, let front = frontApp(),
              let window = element(front.app, kAXFocusedWindowAttribute) ?? element(front.app, kAXMainWindowAttribute),
              let rect = frame(of: window) else { return nil }
        return Self.cocoaCenter(rect)
    }

    /// Where the text caret is in the app in front, in Cocoa screen
    /// coordinates. Apps that do not report their caret give the middle of
    /// the field being typed in; nil when even that is unknown.
    func caretPoint() -> CGPoint? {
        guard allowed, let front = frontApp(),
              let focused = element(front.app, kAXFocusedUIElementAttribute) else { return nil }
        if let range = attribute(focused, kAXSelectedTextRangeAttribute) {
            var value: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero {
                    return Self.cocoa(CGPoint(x: rect.maxX, y: rect.midY))
                }
            }
        }
        return frame(of: focused).map(Self.cocoaCenter)
    }

    /// Brings an app to the front by name: a running one, or one installed
    /// in the usual places. Returns whether it was found.
    /// The names people use for apps, and the apps' own names: "Chrome"
    /// is "Google Chrome", "VS Code" is "Visual Studio Code".
    static let appAliases: [String: String] = [
        "chrome": "google chrome", "google chrome": "google chrome", "vscode": "visual studio code",
        "vs code": "visual studio code", "code": "visual studio code", "word": "microsoft word",
        "excel": "microsoft excel", "powerpoint": "microsoft powerpoint", "outlook": "microsoft outlook",
        "teams": "microsoft teams", "zoom": "zoom.us", "settings": "system settings",
        "system preferences": "system settings", "iterm": "iterm", "iterm2": "iterm",
        "edge": "microsoft edge", "brave": "brave browser", "firefox": "firefox", "arc": "arc"
    ]

    /// An app's name as the user or the model wrote it, made plain.
    static func plainAppName(_ name: String) -> String {
        let plain = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        return appAliases[plain] ?? plain
    }

    /// Whether an app's own name is the one asked for: the same, or the
    /// asked-for name as a whole word of it ("Chrome" in "Google Chrome").
    static func appName(_ actual: String?, matches wanted: String) -> Bool {
        guard let actual = actual?.lowercased(), !wanted.isEmpty else { return false }
        let plain = plainAppName(wanted)
        if actual == plain { return true }
        let words = actual.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains(plain) || (plain.count > 3 && actual.hasPrefix(plain))
    }

    func open(app name: String) async -> Bool {
        let wanted = Self.plainAppName(name)
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // The exact name first, then a name it is part of.
        if let app = running.first(where: { $0.localizedName?.lowercased() == wanted })
            ?? running.first(where: { Self.appName($0.localizedName, matches: name) }) {
            if app.isHidden { app.unhide() }
            return app.activate(options: [.activateAllWindows])
        }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications", "/Applications/Utilities"]
        var partial: URL?
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let match = entries.first(where: { $0.lowercased() == wanted + ".app" }) {
                return await launch(URL(fileURLWithPath: folder).appendingPathComponent(match))
            }
            if partial == nil, let match = entries
                .filter({ $0.hasSuffix(".app") && Self.appName(($0 as NSString).deletingPathExtension, matches: name) })
                .min(by: { $0.count < $1.count }) {
                partial = URL(fileURLWithPath: folder).appendingPathComponent(match)
            }
        }
        if let partial { return await launch(partial) }
        return false
    }

    private func launch(_ url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
    }

    /// Reads a plan written by the model: lines of "TYPE: ..." and "KEY: ...".
    /// Returns nil with the model's reason when it says the request cannot
    /// be done from the keyboard.
    /// What the agent says to the user in a round (`SAY:` lines), in order.
    /// Lines inside a WRITE or EDIT block, and the answer after DONE, are
    /// not notes.
    static func notes(in output: String) -> [String] {
        var notes: [String] = []
        var inBlock = false
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "<<<" { inBlock = true; continue }
            if line == ">>>" { inBlock = false; continue }
            guard !inBlock else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("DONE:") || upper.hasPrefix("ASK:") { break }
            if upper.hasPrefix("SAY:") {
                let text = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { notes.append(text) }
            }
        }
        return notes
    }

    static func parsePlan(_ output: String) -> (steps: [ActionStep], refusal: String?) {
        var steps: [ActionStep] = []
        let lines = output.components(separatedBy: .newlines)
        var number = 0

        /// The lines between "<<<" and ">>>" that follow a WRITE or EDIT,
        /// moving past them. nil when there is no such block.
        func block() -> [String]? {
            var cursor = number + 1
            while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }
            guard cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces) == "<<<" else { return nil }
            var content: [String] = []
            cursor += 1
            while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces) != ">>>" {
                content.append(lines[cursor])
                cursor += 1
            }
            number = cursor
            return content
        }

        /// A WHY: line, kept for the step that comes after it.
        var why: String?
        while number < lines.count {
            defer { number += 1 }
            let line = lines[number].trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. ")).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if label == "WHY" {
                why = value
                continue
            }
            let before = steps.count
            defer {
                if steps.count > before, let reason = why {
                    steps[steps.count - 1].why = reason
                    why = nil
                }
            }
            switch label {
            case "TYPE": steps.append(ActionStep(kind: .type, value: value))
            case "KEY", "PRESS": steps.append(ActionStep(kind: .key, value: value.lowercased()))
            case "CLICK": steps.append(ActionStep(kind: .click, value: value))
            case "RUN", "SHELL", "BASH", "CMD": steps.append(ActionStep(kind: .run, value: value))
            case "OPEN": steps.append(ActionStep(kind: .open, value: value))
            case "WAIT": steps.append(ActionStep(kind: .wait, value: value))
            case "READ": steps.append(ActionStep(kind: .read, value: value))
            case "SEARCH", "GREP": steps.append(ActionStep(kind: .search, value: value))
            case "FETCH": steps.append(ActionStep(kind: .fetch, value: value))
            case "WEB": steps.append(ActionStep(kind: .web, value: value))
            case "PLAN", "TODO": steps.append(ActionStep(kind: .plan, value: value))
            case "DELEGATE", "RESEARCH", "EXPLORE": steps.append(ActionStep(kind: .delegate, value: value))
            case "TERMINAL", "SSH": steps.append(ActionStep(kind: .terminal, value: value))
            case "CHATS", "HISTORY": steps.append(ActionStep(kind: .chats, value: value))
            case "MAC": if let step = ActionStep.mac(line: value) { steps.append(step) }
            case "BROWSER", "CHROME":
                // BROWSER: in Companion's own browser; CHROME: in the user's Chrome.
                if let step = ActionStep.browser(line: value) {
                    if label == "CHROME", let made = step.browserCommand,
                       let inChrome = ActionStep.browser(made.command, made.args.merging(["in": "chrome"]) { $1 }) {
                        steps.append(inChrome)
                    } else {
                        steps.append(step)
                    }
                }
            case "WRITE":
                // The file's content follows, between <<< and >>>.
                guard let content = block() else { continue }
                steps.append(ActionStep(kind: .write, value: value, body: content.joined(separator: "\n")))
            case "EDIT":
                // The old text, a line of ===, then the new text.
                guard let content = block(),
                      let divider = content.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "===" }) else { continue }
                steps.append(ActionStep(kind: .edit, value: value,
                                        body: content[..<divider].joined(separator: "\n"),
                                        replacement: content[(divider + 1)...].joined(separator: "\n")))
            case "DONE":
                // The answer can run over several lines (a list, a table):
                // everything after DONE: belongs to it.
                let rest = lines[(number + 1)...].joined(separator: "\n")
                let whole = (value + "\n" + rest).trimmingCharacters(in: .whitespacesAndNewlines)
                steps.append(ActionStep(kind: .done, value: whole))
            case "ASK": steps.append(ActionStep(kind: .ask, value: value))
            case "CANNOT": return ([], value)
            default: continue
            }
            // Nothing after "done" or a question is meant to run.
            if let last = steps.last, last.kind == .done || last.kind == .ask { break }
        }
        return (Array(steps.prefix(12)), nil)
    }
}


extension ActionStep {
    /// The commands that only look, and change nothing.
    static let browserLooks: Set<String> = ["read", "look", "tabs", "scroll", "focus", "downloads", "history", "extensions"]

    /// A Chrome step from a command and its arguments.
    static func browser(_ command: String, _ args: [String: Any]) -> ActionStep? {
        let known = ["open", "read", "look", "tabs", "click", "type", "scroll", "back", "key", "focus", "upload", "downloads", "history",
                     "extensions", "add_extension", "dialog"]
        guard known.contains(command) else { return nil }
        let words: String
        switch command {
        case "open": words = "open \(args["url"] as? String ?? "")"
        case "click": words = "click \(PageLabels.named(args["target"]))"
        case "type":
            words = ((args["target"].map { "\($0)" } ?? "").isEmpty ? "type where the cursor is" : "type into \(PageLabels.named(args["target"]))") + ": \(args["text"] as? String ?? "")" + ((args["submit"] as? Bool) == true ? " (and submit)" : "")
        case "scroll": words = "scroll \(args["direction"] as? String ?? "down")"
        case "key": words = "press \(args["key"] as? String ?? "Enter")"
        case "focus": words = "switch to tab \(args["tab"] ?? "?")"
        case "upload":
            let files = (args["paths"] as? [Any])?.compactMap { $0 as? String } ?? []
            words = "upload \(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) into \(PageLabels.named(args["target"]))"
        case "downloads": words = "list the downloads"
        case "extensions": words = "list the browser's extensions"
        case "add_extension": words = "add the extension \(args["url"] as? String ?? "")"
        case "history": words = "look in the browser's history for \(args["query"] as? String ?? "")"
        case "read": words = "read the page"
        case "dialog":
            let accept = (args["accept"] as? Bool) ?? ((args["accept"] as? String) == "true")
            let message = PageLabels.dialog.count > 90 ? String(PageLabels.dialog.prefix(89)) + "\u{2026}" : PageLabels.dialog
            words = "answer the page's question \u{201C}\(message)\u{201D} with " + (accept ? "OK" : "Cancel")
        case "look": words = "look at the page"
        case "tabs": words = "list the tabs"
        default: words = command
        }
        let payload: [String: Any] = ["command": command, "args": args]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return ActionStep(kind: .browser, value: words, body: String(decoding: data, as: UTF8.self))
    }

    /// "open https://…", "click 12", "type 4 | text", "submit 4 | text",
    /// "scroll down", "key Enter", "read", "tabs", "back", "focus 123".
    static func browser(line: String) -> ActionStep? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let command = String(trimmed.prefix { !$0.isWhitespace }).lowercased()
        let rest = trimmed.dropFirst(command.count).trimmingCharacters(in: .whitespaces)
        func number(_ text: String) -> Int? { Int(text.trimmingCharacters(in: CharacterSet(charactersIn: " []#"))) }
        switch command {
        case "open": return browser("open", ["url": rest, "newTab": false])
        case "click": return number(rest).flatMap { browser("click", ["target": $0]) }
        case "type", "submit":
            let parts = rest.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let target = number(parts[0]) else { return nil }
            return browser("type", ["target": target, "text": parts[1], "submit": command == "submit"])
        case "scroll": return browser("scroll", ["direction": rest.lowercased().hasPrefix("up") ? "up" : "down"])
        case "key": return browser("key", ["key": rest.isEmpty ? "Enter" : rest])
        case "focus": return number(rest).flatMap { browser("focus", ["tab": $0]) }
        case "read", "look", "tabs", "back", "downloads", "extensions": return browser(command, [:])
        case "extension": return browser("add_extension", ["url": rest])
        case "history": return browser("history", ["query": rest])
        // "dialog ok", "dialog cancel", "dialog ok | text for a prompt".
        case "dialog":
            let parts = rest.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let accept = ["ok", "accept", "yes", "true"].contains((parts.first ?? "").lowercased())
            var args: [String: Any] = ["accept": accept]
            if parts.count > 1 { args["text"] = parts[1] }
            return browser("dialog", args)
        case "upload":
            // "upload 7 | ~/a.csv, ~/b.csv"
            let parts = rest.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let target = number(parts[0]) else { return nil }
            let files = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return browser("upload", ["target": target, "paths": files])
        default: return nil
        }
    }

    /// The command and arguments of a Chrome step.
    /// A Mac service step: which service, which action, and its values.
    var macCommand: (service: String, action: String, args: [String: Any])? {
        guard kind == .mac,
              let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let service = object["service"] as? String, let action = object["action"] as? String else { return nil }
        return (service, action, object["args"] as? [String: Any] ?? [:])
    }

    /// A step on one of the Mac's services, or nil for one it does not have.
    static func mac(_ service: String, _ action: String, _ args: [String: Any]) -> ActionStep? {
        let service = service.lowercased(), action = action.lowercased()
        guard let known = MacServices.service(service),
              known.looks.contains(action) || known.changes.contains(action) else { return nil }
        let payload: [String: Any] = ["service": service, "action": action, "args": args]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return ActionStep(kind: .mac, value: MacServices.words(service, action, args), body: String(decoding: data, as: UTF8.self))
    }

    /// "calendar events {"days": 3}": a service, an action, and its values
    /// as JSON when it needs any.
    static func mac(line: String) -> ActionStep? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        var args: [String: Any] = [:]
        if parts.count == 3, let object = (try? JSONSerialization.jsonObject(with: Data(parts[2].utf8))) as? [String: Any] {
            args = object
        } else if parts.count == 3 {
            args = ["query": parts[2]]
        }
        return mac(parts[0], parts[1], args)
    }

    var browserCommand: (command: String, args: [String: Any])? {
        guard kind == .browser,
              let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let command = object["command"] as? String else { return nil }
        return (command, object["args"] as? [String: Any] ?? [:])
    }
}
