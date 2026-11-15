import Foundation

/// What was being written in each chat, kept per chat as on the Mac:
/// switching chats puts each chat's words back in the box, and the words
/// outlive the app. Files picked for a message are kept while the app runs
/// (by then they are already on the Mac). Keys name the Mac and the chat.
@MainActor
final class Drafts {
    static let shared = Drafts()

    private let storeKey = "chatDrafts"
    private var files: [String: [PhoneFile]] = [:]

    private var texts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storeKey) }
    }

    /// The key for a chat on a Mac; empty while no chat is open.
    static func key(mac: String?, chat: String) -> String {
        chat.isEmpty ? "" : "\(mac ?? "")/\(chat)"
    }

    func text(for key: String) -> String {
        key.isEmpty ? "" : texts[key] ?? ""
    }

    func setText(_ text: String, for key: String) {
        guard !key.isEmpty else { return }
        var all = texts
        let kept: String? = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard all[key] != kept else { return }
        all[key] = kept
        texts = all
    }

    func files(for key: String) -> [PhoneFile] {
        files[key] ?? []
    }

    func setFiles(_ list: [PhoneFile], for key: String) {
        guard !key.isEmpty else { return }
        files[key] = list.isEmpty ? nil : list
    }
}
