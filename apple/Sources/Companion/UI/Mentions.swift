import SwiftUI

/// @mentions in the chat box: typing "@" and part of a name lists the
/// repository's files, as Go to File does, and choosing one attaches it to
/// the message, so the agent has it without being told where to look.
enum Mention {
    /// What follows an "@" at the end of the text being typed, or nil when
    /// the text does not end in a mention. "@" must start the text or follow
    /// a space, so an email address is never taken for one.
    static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        let rest = draft[draft.index(after: at)...]
        guard !rest.contains(where: { $0.isWhitespace }) else { return nil }
        return String(rest)
    }

    /// The text with the mention being typed replaced by the chosen file.
    static func complete(_ draft: String, with file: String) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]) + "@" + file + " "
    }
}

/// The list of files under the chat box's text while a mention is typed.
struct MentionList: View {
    let files: [String]
    let selection: Int
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(files.enumerated()), id: \.element) { index, file in
                Button { choose(file) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(index == selection ? Theme.accent : Theme.ink.opacity(0.55))
                            .frame(width: 14)
                        Text((file as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(0.95))
                            .lineLimit(1)
                        Text((file as NSString).deletingLastPathComponent)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.ink.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous)
                        .fill(index == selection ? Theme.accent.opacity(0.16) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("↑↓ to move, Return or Tab to attach, Esc to close")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink.opacity(0.4))
                .padding(.horizontal, 7)
                .padding(.top, 2)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.ink.opacity(0.05)))
    }
}
