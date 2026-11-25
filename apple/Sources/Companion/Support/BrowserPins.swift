import Foundation

/// A page pinned to a project's browser: always at hand, above its tabs and
/// on its start page, in every chat of the project.
struct BrowserPin: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String

    /// The site, without "www.".
    var host: String {
        guard let host = URL(string: url)?.host else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What it is called where it is shown.
    var name: String { title.isEmpty ? host : title }
}

/// The pinned pages of each project, and of the chats in none, kept on this
/// Mac in one small file.
@MainActor
final class BrowserPins: ObservableObject {
    static let shared = BrowserPins()

    /// The most pages one project keeps pinned.
    static let limit = 24

    /// By project id; "" for chats in no project.
    @Published private(set) var sets: [String: [BrowserPin]] = [:]
    private let file: URL

    private init() {
        file = ContextStore.shared.baseDir.appendingPathComponent("browser-pins.json")
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: [BrowserPin]].self, from: data) {
            sets = saved
        }
    }

    private static func key(_ project: UUID?) -> String { project?.uuidString ?? "" }

    func pins(for project: UUID?) -> [BrowserPin] {
        sets[Self.key(project)] ?? []
    }

    /// The pin for a page, when it is pinned: the same site and path,
    /// whatever its query or fragment.
    func pin(for url: URL?, in project: UUID?) -> BrowserPin? {
        guard let url else { return nil }
        return pins(for: project).first { pin in
            guard let pinned = URL(string: pin.url) else { return false }
            return pinned.host == url.host && pinned.path == url.path
        }
    }

    /// Pins a page, or unpins it when it is pinned already.
    func toggle(_ url: URL, title: String, in project: UUID?) {
        if let pinned = pin(for: url, in: project) {
            unpin(pinned.id, in: project)
        } else {
            var list = pins(for: project)
            list.append(BrowserPin(url: url.absoluteString, title: String(title.prefix(80))))
            sets[Self.key(project)] = Array(list.suffix(Self.limit))
            save()
        }
    }

    func unpin(_ id: UUID, in project: UUID?) {
        sets[Self.key(project)]?.removeAll { $0.id == id }
        save()
    }

    /// Moves a pin to just before another one, or to the end.
    func move(_ id: UUID, before other: UUID?, in project: UUID?) {
        var list = pins(for: project)
        guard id != other, let from = list.firstIndex(where: { $0.id == id }) else { return }
        let pin = list.remove(at: from)
        if let other, let to = list.firstIndex(where: { $0.id == other }) {
            list.insert(pin, at: to)
        } else {
            list.append(pin)
        }
        sets[Self.key(project)] = list
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
