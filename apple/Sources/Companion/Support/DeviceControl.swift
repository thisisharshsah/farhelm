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
    }

    let id = UUID()
    let kind: Kind
    let value: String

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
}

enum AgentDecision {
    case allow, always, deny
}

enum DeviceControlError: LocalizedError {
    case notAllowed
    case ownWindow
    case focusChanged
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
        case .cancelled:
            return "Stopped typing."
        case .unknownKey(let key):
            return "Did not recognize the key \"\(key)\", so nothing after it was run."
        }
    }
}

/// Types text and presses keys in whatever app is in front, by posting
/// keyboard events. Needs the Accessibility permission.
///
/// Safety: it only runs steps for a task the user gave, it stops the moment
/// the app in front changes mid-typing, and Escape cancels it.
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

        func check() throws {
            if cancelled { throw DeviceControlError.cancelled }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier {
                throw DeviceControlError.focusChanged
            }
        }
        for step in steps {
            try check()
            switch step.kind {
            case .type:
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
                        try check()
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
            case .click, .run, .open, .wait, .done, .ask:
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
    func click(_ wanted: String) -> (ok: Bool, detail: String) {
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
        guard AXUIElementPerformAction(match.element, kAXPressAction as CFString) == .success else {
            return (false, "found the \(kind) \"\(match.label)\" but it did not respond to a press")
        }
        return (true, "\(kind) \"\(match.label)\" in \(front.name)")
    }

    /// Brings an app to the front by name: a running one, or one installed
    /// in the usual places. Returns whether it was found.
    func open(app name: String) async -> Bool {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.localizedName?.lowercased() == wanted
        }) {
            return running.activate()
        }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications"]
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let match = entries.first(where: { $0.lowercased() == wanted + ".app" }) {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(match)
                return (try? await NSWorkspace.shared.openApplication(at: url, configuration: .init())) != nil
            }
        }
        return false
    }

    /// Reads a plan written by the model: lines of "TYPE: ..." and "KEY: ...".
    /// Returns nil with the model's reason when it says the request cannot
    /// be done from the keyboard.
    static func parsePlan(_ output: String) -> (steps: [ActionStep], refusal: String?) {
        var steps: [ActionStep] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "-*0123456789. ")).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch label {
            case "TYPE": steps.append(ActionStep(kind: .type, value: value))
            case "KEY", "PRESS": steps.append(ActionStep(kind: .key, value: value.lowercased()))
            case "CLICK": steps.append(ActionStep(kind: .click, value: value))
            case "RUN", "SHELL", "BASH", "CMD": steps.append(ActionStep(kind: .run, value: value))
            case "OPEN": steps.append(ActionStep(kind: .open, value: value))
            case "WAIT": steps.append(ActionStep(kind: .wait, value: value))
            case "DONE": steps.append(ActionStep(kind: .done, value: value))
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
