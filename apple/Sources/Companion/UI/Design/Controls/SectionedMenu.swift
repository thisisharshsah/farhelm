import SwiftUI

// A helper for sectioned menus: groups with titles, items with SF Symbols,
// keyboard shortcuts the menu shows beside them, a check on the chosen item
// and destructive items marked red. It builds a native `Menu`, so the system
// draws it (Liquid Glass on macOS 26) and handles the keyboard and VoiceOver.
// `SectionedMenuItems` is the same content for a context menu.

struct MenuEntry: Identifiable {
    let id: String
    var title: String
    var symbol: String?
    var shortcut: KeyboardShortcut?
    var isDestructive: Bool
    var isSelected: Bool
    var isDisabled: Bool
    var action: () -> Void

    init(_ title: String, symbol: String? = nil, shortcut: KeyboardShortcut? = nil,
         destructive: Bool = false, selected: Bool = false, disabled: Bool = false,
         action: @escaping () -> Void = {}) {
        self.id = title
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.isDestructive = destructive
        self.isSelected = selected
        self.isDisabled = disabled
        self.action = action
    }

    /// The shortcut as a menu writes it, such as "⇧⌘N".
    var shortcutText: String? {
        guard let shortcut else { return nil }
        var text = ""
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        switch shortcut.key {
        case .delete: text += "\u{232B}"
        case .return: text += "\u{21A9}"
        case .escape: text += "\u{238B}"
        case .tab: text += "\u{21E5}"
        case .space: text += "Space"
        default: text += String(shortcut.key.character).uppercased()
        }
        return text
    }
}

struct MenuGroup: Identifiable {
    let id: String
    var title: String?
    var entries: [MenuEntry]

    init(_ title: String? = nil, entries: [MenuEntry]) {
        self.id = title ?? entries.first?.title ?? "group"
        self.title = title
        self.entries = entries
    }
}

/// The items of a sectioned menu, for a `Menu` or a `.contextMenu`.
struct SectionedMenuItems: View {
    let groups: [MenuGroup]

    var body: some View {
        ForEach(groups) { group in
            if let title = group.title {
                Section(title) { items(group) }
            } else {
                Section { items(group) }
            }
        }
    }

    private func items(_ group: MenuGroup) -> some View {
        ForEach(group.entries) { entry in
            Button(role: entry.isDestructive ? .destructive : nil, action: entry.action) {
                if entry.isSelected {
                    Label(entry.title, systemImage: "checkmark")
                } else if let symbol = entry.symbol {
                    Label(entry.title, systemImage: symbol)
                } else {
                    Text(entry.title)
                }
            }
            .keyboardShortcut(entry.shortcut)
            .disabled(entry.isDisabled)
            .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
        }
    }
}

/// A button that opens a sectioned menu.
struct SectionedMenu: View {
    let title: String
    var symbol: String?
    let groups: [MenuGroup]
    @Environment(\.density) private var density

    init(_ title: String, symbol: String? = nil, groups: [MenuGroup]) {
        self.title = title
        self.symbol = symbol
        self.groups = groups
    }

    var body: some View {
        Menu {
            SectionedMenuItems(groups: groups)
        } label: {
            if let symbol {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
        .menuStyle(.button)
        .glassButton(size: density.control)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityHint("Opens a menu")
    }
}