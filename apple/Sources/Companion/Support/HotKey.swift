import AppKit
import Carbon

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var refs: [EventHotKeyRef?] = []

    /// Registers a hotkey and returns a token that can unregister it.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32 {
        installIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x434D_504E), id: id) // 'CMPN'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
        registered[id] = ref
        return id
    }

    /// Removes a hotkey, so its key can be changed.
    func unregister(_ id: UInt32) {
        if let ref = registered[id] ?? nil {
            UnregisterEventHotKey(ref)
        }
        registered[id] = nil
        handlers[id] = nil
    }

    private var registered: [UInt32: EventHotKeyRef?] = [:]

    private func installIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.handlers[hkID.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}

enum HotKeys {
    /// Letters offered for the ask hotkey (with Cmd+Shift).
    static let askChoices: [(letter: String, keyCode: Int)] = [
        ("K", kVK_ANSI_K), ("J", kVK_ANSI_J), ("U", kVK_ANSI_U), ("I", kVK_ANSI_I),
        ("O", kVK_ANSI_O), ("G", kVK_ANSI_G), ("H", kVK_ANSI_H)
    ]
    private static var askToken: UInt32?

    /// Cmd+Shift+<letter>: open the panel with the cursor in the input box.
    /// Called again whenever the letter is changed in Settings.
    static func registerAsk(letter: String) {
        if let askToken {
            HotKeyCenter.shared.unregister(askToken)
        }
        let code = askChoices.first { $0.letter == letter }?.keyCode ?? kVK_ANSI_K
        askToken = HotKeyCenter.shared.register(keyCode: UInt32(code), modifiers: UInt32(cmdKey | shiftKey)) {
            Task { @MainActor in AppState.shared.askFromAnywhere() }
        }
    }

    /// Cmd+Shift+Space: show/hide panel. Cmd+Shift+Return: suggest reply. Cmd+Shift+A: answer screen.
    static func registerAll() {
        let cmdShift = UInt32(cmdKey | shiftKey)
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_Space), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.overlay?.togglePanel() }
        }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_Return), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.suggestNow() }
        }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_A), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.answerScreenNow() }
        }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_T), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.clickThrough.toggle() }
        }
        registerAsk(letter: UserDefaults.standard.string(forKey: "askHotKey") ?? "K")
    }
}
