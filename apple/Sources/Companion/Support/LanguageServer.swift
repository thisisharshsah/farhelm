import Foundation

/// One change to a file's text from a language server: a range, by line
/// and UTF-16 column from 0, and the text to put there.
struct LSPEdit {
    let startLine: Int
    let startCharacter: Int
    let endLine: Int
    let endCharacter: Int
    let newText: String

    init?(_ object: [String: Any]) {
        guard let range = object["range"] as? [String: Any],
              let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int, let startCharacter = start["character"] as? Int,
              let endLine = end["line"] as? Int, let endCharacter = end["character"] as? Int,
              let newText = object["newText"] as? String else { return nil }
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.endLine = endLine
        self.endCharacter = endCharacter
        self.newText = newText
    }

    /// The character offset of a line and column in a text.
    static func offset(line: Int, character: Int, in text: NSString) -> Int {
        var location = 0
        var current = 0
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        let lineEnd = NSMaxRange(text.lineRange(for: NSRange(location: min(location, text.length), length: 0)))
        return min(location + character, lineEnd, text.length)
    }

    /// The range this edit covers in a text.
    func range(in text: NSString) -> NSRange {
        let start = Self.offset(line: startLine, character: startCharacter, in: text)
        let end = max(start, Self.offset(line: endLine, character: endCharacter, in: text))
        return NSRange(location: start, length: end - start)
    }

    /// The text with every edit made, last first so the places stay right.
    static func apply(_ edits: [LSPEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        let ranges = edits.map { ($0.range(in: text as NSString), $0.newText) }
            .sorted { $0.0.location > $1.0.location }
        for (range, newText) in ranges where NSMaxRange(range) <= result.length {
            result.replaceCharacters(in: range, with: newText)
        }
        return result as String
    }
}

/// A place a symbol is used, from 1, with its line's text.
struct LSPLocation: Identifiable, Hashable {
    let path: String
    let line: Int
    let column: Int
    var preview = ""
    var id: String { "\(path):\(line):\(column)" }
}

/// One completion a server offers: what is shown, and what is typed in.
struct LSPCompletion {
    let label: String
    let insert: String
    let detail: String
}

/// Live language servers for the workspace editor (the Language Server
/// Protocol, as VS Code uses): errors and warnings while you type, hover
/// information and go to definition.
///
/// One server runs per folder and language, started the first time a file
/// of that language is opened, if the server is installed:
/// sourcekit-lsp for Swift (comes with Xcode), clangd for C and
/// Objective-C, typescript-language-server, pyright or pylsp, rust-analyzer
/// and gopls. Nothing is installed by Companion; a language without its
/// server just has no live checking, and Build still works.
@MainActor
final class LanguageServers {
    static let shared = LanguageServers()

    private var clients: [String: LanguageClient] = [:]
    /// Languages found to have no server here, so the look is not repeated.
    private var missing: Set<String> = []
    private var pendingChange: [String: Task<Void, Never>] = [:]

    /// The language a file is written in, by LSP's names.
    static func language(of path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh": return "cpp"
        case "m": return "objective-c"
        case "mm": return "objective-cpp"
        case "ts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        default: return nil
        }
    }

    /// The server for a language: one family of languages shares a server.
    private static func family(_ language: String) -> String {
        switch language {
        case "c", "cpp", "objective-c", "objective-cpp": return "clang"
        case "typescript", "typescriptreact", "javascript", "javascriptreact": return "typescript"
        default: return language
        }
    }

    /// The command lines to try, first found wins. `xcrun --find` names the
    /// tools that come with Xcode.
    private static func candidates(_ family: String) -> [String] {
        switch family {
        case "swift": return ["$(xcrun --find sourcekit-lsp 2>/dev/null)", "sourcekit-lsp"]
        case "clang": return ["$(xcrun --find clangd 2>/dev/null)", "clangd"]
        case "typescript": return ["typescript-language-server --stdio"]
        case "python": return ["pyright-langserver --stdio", "pylsp"]
        case "rust": return ["rust-analyzer"]
        case "go": return ["gopls"]
        default: return []
        }
    }

    /// Finds the server's program: the first candidate whose first word is
    /// a program here. The login shell is asked, so PATH is the user's own.
    private static func resolve(_ family: String, in root: String) async -> [String]? {
        for candidate in candidates(family) {
            let probe = "set -- \(candidate); [ -n \"$1\" ] && command -v \"$1\""
            let found = await Shell.run(probe, in: root, timeout: 15)
            let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard found.ok, !path.isEmpty, !path.contains("\n") else { continue }
            var words = candidate.components(separatedBy: " ").filter { !$0.isEmpty }
            if candidate.hasPrefix("$(") {
                words = [path]
            } else {
                words[0] = path
            }
            return words
        }
        return nil
    }

    private func key(_ root: String, _ family: String) -> String { root + "\u{1}" + family }

    /// The running server for a file, starting it if need be.
    private func client(for path: String, root: String) async -> (LanguageClient, String)? {
        guard !root.isEmpty, let language = Self.language(of: path) else { return nil }
        let family = Self.family(language)
        let id = key(root, family)
        if let client = clients[id], client.alive { return (client, language) }
        guard !missing.contains(id) else { return nil }
        guard let command = await Self.resolve(family, in: root) else {
            missing.insert(id)
            return nil
        }
        let client = LanguageClient(command: command, root: root)
        guard await client.start() else {
            missing.insert(id)
            return nil
        }
        clients[id] = client
        return (client, language)
    }

    // MARK: The editor's side

    /// A file was opened in the editor.
    func opened(_ path: String, text: String, root: String) {
        Task {
            guard let found = await client(for: path, root: root) else { return }
            found.0.open(path, language: found.1, text: text)
        }
    }

    /// The text was changed. Sent after a short pause in the typing.
    func changed(_ path: String, text: String, root: String) {
        pendingChange[path]?.cancel()
        pendingChange[path] = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let found = await client(for: path, root: root) else { return }
            found.0.change(path, text: text)
        }
    }

    func saved(_ path: String, root: String) {
        Task {
            guard let found = await client(for: path, root: root) else { return }
            found.0.save(path)
        }
    }

    /// What the server says about the symbol at a place (line and column
    /// from 0, column in UTF-16 units), as plain text.
    func hover(_ path: String, line: Int, character: Int, root: String) async -> String? {
        guard let found = await client(for: path, root: root) else { return nil }
        return await found.0.hover(path, line: line, character: character)
    }

    /// The symbols of a file (types, functions, properties), nested; nil
    /// when no server knows the language.
    func symbols(_ path: String, root: String) async -> [CodeSymbol]? {
        guard let found = await client(for: path, root: root) else { return nil }
        return await found.0.symbols(path)
    }

    /// Where the symbol at a place is defined: a file and a line from 1.
    func definition(_ path: String, line: Int, character: Int, root: String) async -> (path: String, line: Int)? {
        guard let found = await client(for: path, root: root) else { return nil }
        return await found.0.definition(path, line: line, character: character)
    }

    /// Sends the text now, so what is asked next sees the latest typing.
    private func sync(_ found: (LanguageClient, String), path: String, text: String?) {
        guard let text else { return }
        pendingChange[path]?.cancel()
        pendingChange[path] = nil
        found.0.change(path, text: text)
    }

    /// What can be typed at a place: nil when no server knows the language.
    func completions(_ path: String, text: String, line: Int, character: Int, root: String) async -> [LSPCompletion]? {
        guard let found = await client(for: path, root: root) else { return nil }
        sync(found, path: path, text: text)
        return await found.0.completions(path, line: line, character: character)
    }

    /// Every place the symbol at a place is used, its declaration included.
    func references(_ path: String, text: String, line: Int, character: Int, root: String) async -> [LSPLocation]? {
        guard let found = await client(for: path, root: root) else { return nil }
        sync(found, path: path, text: text)
        return await found.0.references(path, line: line, character: character)
    }

    /// The edits, file by file, that rename the symbol at a place.
    func rename(_ path: String, text: String, line: Int, character: Int, to name: String, root: String) async -> [String: [LSPEdit]]? {
        guard let found = await client(for: path, root: root) else { return nil }
        sync(found, path: path, text: text)
        return await found.0.rename(path, line: line, character: character, to: name)
    }

    /// The edits that format a file the server's way.
    func format(_ path: String, text: String, tabSize: Int, spaces: Bool, root: String) async -> [LSPEdit]? {
        guard let found = await client(for: path, root: root) else { return nil }
        sync(found, path: path, text: text)
        return await found.0.format(path, tabSize: tabSize, spaces: spaces)
    }

    /// Stops every server, as when the app quits.
    func stopAll() {
        for client in clients.values { client.stop() }
        clients = [:]
    }
}

/// One language server: a process spoken to in JSON-RPC over its standard
/// input and output, each message preceded by a Content-Length header.
@MainActor
final class LanguageClient {
    let command: [String]
    let root: String
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Any?, Never>] = [:]
    private var versions: [String: Int] = [:]
    private var ready = false

    var alive: Bool { process?.isRunning == true }

    init(command: [String], root: String) {
        self.command = command
        self.root = root
    }

    static func uri(_ path: String) -> String { URL(fileURLWithPath: path).absoluteString }
    static func path(_ uri: String) -> String? { URL(string: uri)?.path }

    // MARK: Starting and stopping

    func start() async -> Bool {
        // Writing to a server that has died must fail as an error, not end
        // Companion with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.received(data) }
        }
        do {
            try process.run()
        } catch {
            return false
        }
        self.process = process
        input = stdin.fileHandleForWriting

        let capabilities: [String: Any] = [
            "textDocument": [
                "synchronization": ["didSave": true, "dynamicRegistration": false],
                "hover": ["contentFormat": ["plaintext", "markdown"]],
                "definition": ["linkSupport": false],
                "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                "completion": ["completionItem": ["snippetSupport": false, "documentationFormat": ["plaintext"]],
                               "contextSupport": true],
                "references": [:],
                "rename": ["prepareSupport": false],
                "formatting": [:],
                "publishDiagnostics": ["relatedInformation": false]
            ],
            "workspace": ["workspaceFolders": true]
        ]
        let params: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": Self.uri(root),
            "capabilities": capabilities,
            "workspaceFolders": [["uri": Self.uri(root), "name": (root as NSString).lastPathComponent]]
        ]
        let answer = await request("initialize", params, timeout: 30)
        guard answer != nil else {
            stop()
            return false
        }
        notify("initialized", [:])
        ready = true
        return true
    }

    func stop() {
        if ready { notify("exit", nil) }
        process?.terminate()
        process = nil
        ready = false
    }

    // MARK: Documents

    func open(_ path: String, language: String, text: String) {
        versions[path] = 1
        notify("textDocument/didOpen", ["textDocument": [
            "uri": Self.uri(path), "languageId": language, "version": 1, "text": text
        ]])
    }

    func change(_ path: String, text: String) {
        let version = (versions[path] ?? 1) + 1
        versions[path] = version
        // No range: the whole text, which every server takes.
        notify("textDocument/didChange", [
            "textDocument": ["uri": Self.uri(path), "version": version],
            "contentChanges": [["text": text]]
        ])
    }

    func save(_ path: String) {
        notify("textDocument/didSave", ["textDocument": ["uri": Self.uri(path)]])
    }

    func hover(_ path: String, line: Int, character: Int) async -> String? {
        let result = await request("textDocument/hover", position(path, line, character), timeout: 8)
        guard let hover = result as? [String: Any] else { return nil }
        return Self.text(of: hover["contents"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func definition(_ path: String, line: Int, character: Int) async -> (path: String, line: Int)? {
        let result = await request("textDocument/definition", position(path, line, character), timeout: 10)
        let first: [String: Any]?
        if let list = result as? [[String: Any]] { first = list.first } else { first = result as? [String: Any] }
        guard let location = first else { return nil }
        let uri = (location["uri"] ?? location["targetUri"]) as? String
        let range = (location["range"] ?? location["targetSelectionRange"]) as? [String: Any]
        guard let uri, let file = Self.path(uri),
              let start = range?["start"] as? [String: Any], let line = start["line"] as? Int else { return nil }
        return (file, line + 1)
    }

    func symbols(_ path: String) async -> [CodeSymbol]? {
        let result = await request("textDocument/documentSymbol", ["textDocument": ["uri": Self.uri(path)]], timeout: 8)
        guard let list = result as? [[String: Any]] else { return nil }
        var found: [CodeSymbol] = []
        func start(_ range: Any?) -> Int? {
            ((range as? [String: Any])?["start"] as? [String: Any])?["line"] as? Int
        }
        func end(_ range: Any?) -> Int? {
            ((range as? [String: Any])?["end"] as? [String: Any])?["line"] as? Int
        }
        // Either nested symbols (with children) or a flat list with places.
        func walk(_ items: [[String: Any]], depth: Int) {
            for item in items {
                guard let name = item["name"] as? String else { continue }
                let location = (item["location"] as? [String: Any])?["range"]
                let full = item["range"] ?? location
                let line = (start(item["selectionRange"] ?? full) ?? 0) + 1
                found.append(CodeSymbol(name: name, kind: item["kind"] as? Int ?? 0, line: line,
                                        endLine: end(full).map { $0 + 1 }, depth: depth))
                if let children = item["children"] as? [[String: Any]] { walk(children, depth: depth + 1) }
            }
        }
        walk(list, depth: 0)
        return found.isEmpty ? nil : found
    }

    func completions(_ path: String, line: Int, character: Int) async -> [LSPCompletion] {
        let result = await request("textDocument/completion", position(path, line, character), timeout: 6)
        let items: [[String: Any]]
        if let list = result as? [[String: Any]] {
            items = list
        } else {
            items = (result as? [String: Any])?["items"] as? [[String: Any]] ?? []
        }
        // In the server's order of preference, each once.
        let sorted = items.enumerated().sorted {
            let a = $0.element["sortText"] as? String ?? "", b = $1.element["sortText"] as? String ?? ""
            return a == b ? $0.offset < $1.offset : a < b
        }
        var seen = Set<String>()
        var found: [LSPCompletion] = []
        for (_, item) in sorted {
            guard let label = item["label"] as? String else { continue }
            let edit = (item["textEdit"] as? [String: Any])?["newText"] as? String
            let insert = (item["insertText"] as? String) ?? edit ?? label
            guard !insert.isEmpty, seen.insert(insert).inserted else { continue }
            found.append(LSPCompletion(label: label.trimmingCharacters(in: .whitespaces), insert: insert,
                                       detail: item["detail"] as? String ?? ""))
            if found.count >= 200 { break }
        }
        return found
    }

    func references(_ path: String, line: Int, character: Int) async -> [LSPLocation] {
        var params = position(path, line, character)
        params["context"] = ["includeDeclaration": true]
        let result = await request("textDocument/references", params, timeout: 15)
        let list = result as? [[String: Any]] ?? []
        var lines: [String: [String]] = [:]
        return list.compactMap { item in
            guard let uri = item["uri"] as? String, let file = Self.path(uri),
                  let start = (item["range"] as? [String: Any])?["start"] as? [String: Any],
                  let line = start["line"] as? Int else { return nil }
            if lines[file] == nil {
                lines[file] = ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            }
            let text = lines[file].flatMap { line < $0.count ? $0[line] : nil } ?? ""
            return LSPLocation(path: file, line: line + 1, column: (start["character"] as? Int ?? 0) + 1,
                               preview: text.trimmingCharacters(in: .whitespaces))
        }
        .sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
    }

    func rename(_ path: String, line: Int, character: Int, to name: String) async -> [String: [LSPEdit]] {
        var params = position(path, line, character)
        params["newName"] = name
        let result = await request("textDocument/rename", params, timeout: 20) as? [String: Any] ?? [:]
        var edits: [String: [LSPEdit]] = [:]
        // A WorkspaceEdit: "changes" by URI, or "documentChanges" by document.
        if let changes = result["changes"] as? [String: [[String: Any]]] {
            for (uri, list) in changes {
                if let file = Self.path(uri) { edits[file, default: []] += list.compactMap(LSPEdit.init) }
            }
        }
        if let documents = result["documentChanges"] as? [[String: Any]] {
            for document in documents {
                guard let uri = (document["textDocument"] as? [String: Any])?["uri"] as? String,
                      let file = Self.path(uri),
                      let list = document["edits"] as? [[String: Any]] else { continue }
                edits[file, default: []] += list.compactMap(LSPEdit.init)
            }
        }
        return edits
    }

    func format(_ path: String, tabSize: Int, spaces: Bool) async -> [LSPEdit] {
        let params: [String: Any] = ["textDocument": ["uri": Self.uri(path)],
                                     "options": ["tabSize": tabSize, "insertSpaces": spaces]]
        let result = await request("textDocument/formatting", params, timeout: 20)
        return (result as? [[String: Any]] ?? []).compactMap(LSPEdit.init)
    }

    private func position(_ path: String, _ line: Int, _ character: Int) -> [String: Any] {
        ["textDocument": ["uri": Self.uri(path)], "position": ["line": line, "character": character]]
    }

    /// Hover contents come as a string, a {kind, value}, a {language, value}
    /// or a list of those.
    private static func text(of contents: Any?) -> String? {
        if let string = contents as? String { return string }
        if let object = contents as? [String: Any] { return object["value"] as? String }
        if let list = contents as? [Any] {
            let parts = list.compactMap { text(of: $0) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return nil
    }

    // MARK: JSON-RPC

    private func send(_ message: [String: Any]) {
        guard let input, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        do {
            try input.write(contentsOf: data)
        } catch {
            stop()
        }
    }

    private func notify(_ method: String, _ params: Any?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        send(message)
    }

    private func request(_ method: String, _ params: Any?, timeout: Double) async -> Any? {
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        return await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
            waiting[id] = done
            send(message)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // No answer in time: carry on without one.
                if let late = self.waiting.removeValue(forKey: id) { late.resume(returning: nil) }
            }
        }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var length = 0
            for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer[bodyStart..<bodyEnd]
            buffer = Data(buffer[bodyEnd...])
            if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                handle(message)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        // An answer to one of ours.
        if let id = message["id"] as? Int, message["method"] == nil {
            waiting.removeValue(forKey: id)?.resume(returning: message["result"])
            return
        }
        guard let method = message["method"] as? String else { return }
        // A request from the server: answered with nothing, so it never waits.
        if let id = message["id"] {
            // Settings asked for come back empty, one for each item asked.
            if method == "workspace/configuration",
               let items = (message["params"] as? [String: Any])?["items"] as? [Any] {
                send(["jsonrpc": "2.0", "id": id, "result": items.map { _ in NSNull() }])
            } else {
                send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            }
        }
        if method == "textDocument/publishDiagnostics",
           let params = message["params"] as? [String: Any],
           let uri = params["uri"] as? String, let file = Self.path(uri) {
            let list = params["diagnostics"] as? [[String: Any]] ?? []
            let problems: [Problem] = list.compactMap { item in
                guard let range = item["range"] as? [String: Any],
                      let start = range["start"] as? [String: Any],
                      let line = start["line"] as? Int,
                      let message = item["message"] as? String else { return nil }
                let column = start["character"] as? Int ?? 0
                let severity: Problem.Severity
                switch item["severity"] as? Int ?? 1 {
                case 1: severity = .error
                case 2: severity = .warning
                default: severity = .note
                }
                return Problem(file: (file as NSString).standardizingPath, line: line + 1, column: column + 1,
                               severity: severity, message: message)
            }
            ProblemsModel.shared.setLive(problems, for: (file as NSString).standardizingPath, root: root)
        }
    }
}
