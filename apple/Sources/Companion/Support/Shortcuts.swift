import AppKit
import Carbon
import Combine

/// A key combination: the key, the modifiers held with it, and how the key
/// is written (so it can be shown without asking the keyboard layout).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32
    var key: String

    /// The combination as it is printed on keys: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }

    static func cmdShift(_ keyCode: Int, _ key: String) -> KeyCombo {
        KeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(cmdKey | shiftKey), key: key)
    }

    /// The combination in a key press, or nil when it cannot be a global
    /// shortcut: it needs Command, Control or Option, and a real key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        guard carbon & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }
        guard let name = Self.name(of: event) else { return nil }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon
        key = name
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let named: [Int: String] = [
        kVK_Space: "␣", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    private static func name(of event: NSEvent) -> String? {
        if let known = named[Int(event.keyCode)] { return known }
        guard let characters = event.charactersIgnoringModifiers?.uppercased(),
              let first = characters.first, !first.isWhitespace, !first.isNewline else { return nil }
        return String(first)
    }
}

/// Everything Companion does from a global shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case panel, listen, reply, screen, ask, pill, clickThrough, stopAgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panel: return "Show or hide the panel"
        case .listen: return "Start or stop listening"
        case .reply: return "Draft a reply now"
        case .screen: return "Answer from the screen"
        case .ask: return "Ask from anywhere"
        case .pill: return "Shrink to the pill, or back"
        case .clickThrough: return "Click-through"
        case .stopAgent: return "Stop the agent"
        }
    }

    var detail: String {
        switch self {
        case .panel: return "From any app."
        case .listen: return "Hear the conversation, or stop."
        case .reply: return "Without waiting for the other person to finish."
        case .screen: return "Captures the screen and answers what is on it."
        case .ask: return "Opens the panel with the cursor in the box."
        case .pill: return "The small one-line version of the panel."
        case .clickThrough: return "Clicks pass to what is behind the panel."
        case .stopAgent: return "Ends the task it is working on."
        }
    }

    /// A short name for the footer.
    var short: String {
        switch self {
        case .panel: return "Panel"
        case .listen: return "Listen"
        case .reply: return "Reply"
        case .screen: return "Screen"
        case .ask: return "Ask"
        case .pill: return "Pill"
        case .clickThrough: return "Through"
        case .stopAgent: return "Stop"
        }
    }

    var standard: KeyCombo {
        switch self {
        case .panel: return .cmdShift(kVK_Space, "␣")
        case .listen: return .cmdShift(kVK_ANSI_L, "L")
        case .reply: return .cmdShift(kVK_Return, "↩")
        case .screen: return .cmdShift(kVK_ANSI_A, "A")
        case .ask: return .cmdShift(kVK_ANSI_K, "K")
        case .pill: return .cmdShift(kVK_ANSI_M, "M")
        case .clickThrough: return .cmdShift(kVK_ANSI_T, "T")
        case .stopAgent: return .cmdShift(kVK_ANSI_Period, ".")
        }
    }

    @MainActor
    func perform() {
        let app = AppState.shared
        switch self {
        case .panel: app.overlay?.togglePanel()
        case .listen: app.toggleListening()
        case .reply: app.suggestNow()
        case .screen: app.answerScreenNow()
        case .ask: app.askFromAnywhere()
        case .pill:
            app.overlay?.showPanel()
            app.overlay?.setCompact(!app.compact)
        case .clickThrough: app.clickThrough.toggle()
        case .stopAgent: app.stopAgent()
        }
    }
}

/// The global shortcuts: which keys do what, kept between launches, and
/// changeable from Settings. One place registers them, so adding an action
/// is one more case in `ShortcutAction`.
@MainActor
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    @Published private(set) var combos: [ShortcutAction: KeyCombo] = [:]
    private var tokens: [ShortcutAction: UInt32] = [:]
    private let storeKey = "shortcuts"

    private init() {
        var loaded: [ShortcutAction: KeyCombo] = [:]
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            for (name, combo) in saved {
                if let action = ShortcutAction(rawValue: name) { loaded[action] = combo }
            }
        } else if let letter = UserDefaults.standard.string(forKey: "askHotKey"), letter != "K",
                  let code = Self.legacyAskCodes[letter] {
            // The ask key chosen before shortcuts were editable.
            loaded[.ask] = .cmdShift(code, letter)
        }
        combos = loaded
    }

    private static let legacyAskCodes: [String: Int] = [
        "J": kVK_ANSI_J, "U": kVK_ANSI_U, "I": kVK_ANSI_I, "O": kVK_ANSI_O, "G": kVK_ANSI_G, "H": kVK_ANSI_H
    ]

    func combo(_ action: ShortcutAction) -> KeyCombo {
        combos[action] ?? action.standard
    }

    /// The shortcut as text, for labels and tooltips.
    func label(_ action: ShortcutAction) -> String {
        combo(action).display
    }

    func isChanged(_ action: ShortcutAction) -> Bool {
        combo(action) != action.standard
    }

    /// The action already using a combination, if any other one does.
    func owner(of combo: KeyCombo, besides action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first {
            $0 != action && self.combo($0).keyCode == combo.keyCode && self.combo($0).modifiers == combo.modifiers
        }
    }

    /// Gives an action a new combination. Returns the action that already
    /// has it when it is taken, and changes nothing in that case.
    @discardableResult
    func set(_ combo: KeyCombo, for action: ShortcutAction) -> ShortcutAction? {
        if let taken = owner(of: combo, besides: action) { return taken }
        combos[action] = combo == action.standard ? nil : combo
        save()
        register(action)
        return nil
    }

    func reset(_ action: ShortcutAction) {
        // Its standard keys may have been given to something else since.
        guard owner(of: action.standard, besides: action) == nil else { return }
        combos[action] = nil
        save()
        register(action)
    }

    func resetAll() {
        combos = [:]
        save()
        registerAll()
    }

    private func save() {
        var named: [String: KeyCombo] = [:]
        for (action, combo) in combos { named[action.rawValue] = combo }
        if let data = try? JSONEncoder().encode(named) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    // MARK: Registration

    func registerAll() {
        unregisterAll()
        for action in ShortcutAction.allCases { register(action) }
    }

    /// While a new shortcut is being recorded, none of them fire.
    func unregisterAll() {
        for token in tokens.values { HotKeyCenter.shared.unregister(token) }
        tokens = [:]
    }

    private func register(_ action: ShortcutAction) {
        if let token = tokens[action] {
            HotKeyCenter.shared.unregister(token)
        }
        let combo = combo(action)
        tokens[action] = HotKeyCenter.shared.register(keyCode: combo.keyCode, modifiers: combo.modifiers) {
            Task { @MainActor in action.perform() }
        }
    }
}
