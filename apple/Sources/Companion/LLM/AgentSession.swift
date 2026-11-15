import Foundation

/// What the agent sees of the Mac at the start of a turn.
struct AgentObservation {
    let directory: String
    let frontApp: String
    let screenText: String
    let clickable: [String]
}

/// What one model turn came back with.
struct AgentTurn {
    /// Words to the user written alongside the steps.
    var notes: [String] = []
    /// The steps to take next, each carrying its tool call's id when the
    /// engine called tools natively.
    var steps: [ActionStep] = []
    /// The answer, when the model finished the task.
    var final: String?
    /// Why the model would not do the task.
    var refusal: String?
    /// Nothing to run this turn, but the task goes on (a cut-off reply, a
    /// call that has to be sent again).
    var again = false
}

/// One agent task as a single, continuous conversation with the model,
/// the way a coding agent works: every step it took and every result it got
/// stays in the conversation, in order, so it never works from a recap.
///
/// Claude and OpenAI-style engines (OpenAI, Farhelm) call real tools, which
/// the models are trained for; Claude also thinks before it acts. An engine
/// that cannot call tools (Ollama, the subscription tools, or a Farhelm
/// model that refuses them) gets the same conversation in the line-based
/// form ("RUN: ...").
///
/// The conversation is only shortened when it nears the model's window:
/// old command output and old screens are cut first, newest results stay
/// whole, and the task itself is never cut.
@MainActor
final class AgentSession {
    enum Wire {
        /// Claude's Messages API with tool use.
        case anthropic
        /// Chat completions with tool calls (OpenAI, Farhelm).
        case openAI
        /// Steps written as lines of text.
        case text
    }

    let config: LLMConfig
    private let task: String
    private let pinned: String
    private(set) var wire: Wire
    /// Real tool calls, not lines of text.
    var native: Bool { wire != .text }
    /// The conversation so far, in the engine's own form.
    private var messages: [[String: Any]] = []
    /// Tool calls in the last reply that still need their results.
    private var open: [String] = []
    /// What goes into the next message from the user's side: tool results
    /// (Claude's blocks, or OpenAI's tool messages) and lines of text.
    private var pendingBlocks: [[String: Any]] = []
    private var pendingText: [String] = []
    /// Tokens the conversation may take, and the longest reply.
    private let inputLimit: Int
    private let outputLimit: Int
    /// The screen last shown, so an unchanged one is not sent again.
    private var lastScreen = ""
    /// Pictures the user attached to the task, as files: given to the
    /// engine to look at with every turn.
    var pictures: [String] = []

    init(task: String, config: LLMConfig, pinned: String) {
        var config = config
        switch config.kind {
        case .anthropic: wire = .anthropic
        case .openai, .farhelm: wire = .openAI
        default: wire = .text
        }
        // Claude thinks first on agent work unless an effort was chosen.
        if config.effort == nil, config.kind == .anthropic { config.effort = "medium" }
        self.config = config
        self.task = task
        self.pinned = pinned
        let budget = ContextBudget.current
        inputLimit = budget.agentInputTokens
        outputLimit = budget.agentOutputTokens
    }

    // MARK: A turn

    /// Sends what happened since the last turn and gets the next steps.
    func next(_ seen: AgentObservation) async throws -> AgentTurn {
        appendObservation(seen)
        compactIfNeeded()
        switch wire {
        case .anthropic: return try await anthropicTurn()
        case .openAI:
            do {
                return try await openAITurn()
            } catch LLMError.http(let code, _) where (400..<500).contains(code) && code != 401 && code != 403 && messages.count == 1 {
                // The engine or its model takes no tools: the same task in
                // lines of text, from the start.
                wire = .text
                if let first = messages.first?["content"] as? String {
                    messages = [["role": "user", "content": first]]
                }
                return try await textTurn()
            }
        case .text: return try await textTurn()
        }
    }

    /// The results of the last turn's steps. With tools, each goes back
    /// under its call's id, and a call without a result is told it did not
    /// run; in text they go back in order.
    func record(_ results: [(step: ActionStep, result: String)]) {
        switch wire {
        case .anthropic, .openAI:
            for id in open {
                let found = results.first { $0.step.callID == id }
                let text = found?.result
                    ?? "Not run: the turn ended before this call (results above it changed the plan, or the step limit was reached). Call it again if it is still needed."
                addResult(id, text.isEmpty ? "(done)" : text, failed: Self.failed(text))
            }
            open = []
        case .text:
            guard !results.isEmpty else { return }
            let text = results.enumerated()
                .map { "\($0.offset + 1). \($0.element.result.isEmpty ? $0.element.step.label : $0.element.result)" }
                .joined(separator: "\n")
            pendingText.append("## Results\n" + text)
        }
    }

    private static func failed(_ text: String) -> Bool {
        text.contains("FAILED") || text.contains("failed, exit") || text.contains("NOT confirmed") || text.hasPrefix("Not run")
            || text.contains("SKIPPED")
    }

    /// One call's result, in the engine's form.
    private func addResult(_ id: String, _ text: String, failed: Bool) {
        switch wire {
        case .anthropic:
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
            if failed { block["is_error"] = true }
            pendingBlocks.append(block)
        case .openAI:
            pendingBlocks.append(["role": "tool", "tool_call_id": id, "content": text])
        case .text:
            pendingText.append(text)
        }
        open.removeAll { $0 == id }
    }

    private func appendObservation(_ seen: AgentObservation) {
        let screen = Self.describe(seen)
        let changed = screen != lastScreen
        lastScreen = screen
        let now = changed ? "## Now\n" + screen : "## Now\nShell folder: \(seen.directory). The screen is as before."
        if messages.isEmpty {
            // The first message: the task, then where things stand.
            let first = "## Task\n\(task)\n\n\(now)"
            messages.append(wire == .anthropic
                ? ["role": "user", "content": [["type": "text", "text": first]]]
                : ["role": "user", "content": first])
            return
        }
        switch wire {
        case .anthropic:
            // Tool results first, then the words: the API's order.
            var blocks = pendingBlocks
            blocks.append(["type": "text", "text": (pendingText + [now]).joined(separator: "\n\n")])
            messages.append(["role": "user", "content": blocks])
        case .openAI:
            messages.append(contentsOf: pendingBlocks)
            messages.append(["role": "user", "content": (pendingText + [now]).joined(separator: "\n\n")])
        case .text:
            messages.append(["role": "user", "content": (pendingText + [now]).joined(separator: "\n\n")])
        }
        pendingBlocks = []
        pendingText = []
    }

    private static func describe(_ seen: AgentObservation) -> String {
        """
        Shell folder: \(seen.directory)
        App in front: \(seen.frontApp)
        Can be clicked: \(seen.clickable.isEmpty ? "(nothing by name: this app draws its own interface, or none is in front; do not click here)" : seen.clickable.prefix(120).joined(separator: " | "))
        Screen text:
        \(seen.screenText.isEmpty ? "(none)" : String(seen.screenText.prefix(6000)))
        """
    }

    /// Turns the calls of a reply into steps; calls that cannot run are
    /// answered at once.
    private func steps(from calls: [ToolCall], text: String, stop: String) -> AgentTurn {
        var turn = AgentTurn()
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if calls.isEmpty {
            if stop == "max_tokens" || stop == "length" {
                // Cut off mid-answer: carry on from where it stopped.
                pendingText.append("Your reply hit the output limit and was cut off. Carry on from where it stopped; write large files in parts (write_file the first part, then edit_file to add the rest).")
                if !words.isEmpty { turn.notes = [String(words.suffix(400))] }
                turn.again = true
                return turn
            }
            turn.final = words.isEmpty ? "Done." : words
            return turn
        }
        if !words.isEmpty { turn.notes = [words] }
        open = calls.map(\.id)
        for call in calls {
            if let problem = call.problem {
                addResult(call.id, problem, failed: true)
                continue
            }
            guard var step = AgentTools.step(name: call.name, input: call.input) else {
                addResult(call.id, "Unknown tool \(call.name). Use one of the tools listed.", failed: true)
                continue
            }
            step.callID = call.id
            turn.steps.append(step)
        }
        if turn.steps.isEmpty { turn.again = true }
        return turn
    }

    // MARK: Claude, with tools

    private func anthropicTurn() async throws -> AgentTurn {
        let reply = try await AnthropicAgent.turn(system: Prompts.agentToolSystem, pinned: pinned, messages: messages,
                                                  tools: AgentTools.definitions, config: config, maxOutput: outputLimit)
        messages.append(["role": "assistant", "content": reply.blocks.isEmpty ? [["type": "text", "text": "(no reply)"]] : reply.blocks])
        if reply.stopReason == "refusal" {
            var turn = AgentTurn()
            turn.refusal = reply.text.isEmpty ? "the model declined this task." : reply.text
            return turn
        }
        return steps(from: reply.calls, text: reply.text, stop: reply.stopReason)
    }

    // MARK: OpenAI-style engines, with tools

    private func openAITurn() async throws -> AgentTurn {
        let reply = try await OpenAIAgent.turn(system: Prompts.agentToolSystem, pinned: pinned, messages: messages,
                                               tools: AgentTools.openAIDefinitions, config: config, maxOutput: outputLimit)
        var assistant: [String: Any] = ["role": "assistant", "content": reply.text.isEmpty ? NSNull() : reply.text]
        if !reply.calls.isEmpty {
            assistant["tool_calls"] = reply.calls.map { call -> [String: Any] in
                ["id": call.id, "type": "function",
                 "function": ["name": call.name, "arguments": call.arguments]]
            }
        }
        messages.append(assistant)
        return steps(from: reply.calls, text: reply.text, stop: reply.stopReason)
    }

    // MARK: Other engines, with lines of text

    private func textTurn() async throws -> AgentTurn {
        var request = ChatRequest(system: Prompts.agentConversationSystem,
                                  messages: messages.map { ChatMessage(role: $0["role"] as? String ?? "user",
                                                                       content: $0["content"] as? String ?? "") })
        request.pinned = pinned
        request.maxOutput = outputLimit
        request.pictures = pictures
        var output = ""
        for try await piece in try await LLM.stream(request.tagged("Agent"), config: config) {
            output += piece
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(["role": "assistant", "content": output.isEmpty ? "(no reply)" : output])
        var turn = AgentTurn()
        let plan = DeviceControl.parsePlan(output)
        if let refusal = plan.refusal {
            turn.refusal = refusal
            return turn
        }
        turn.notes = DeviceControl.notes(in: output)
        if let done = plan.steps.first(where: { $0.kind == .done }), plan.steps.count == 1 {
            turn.final = done.value
            return turn
        }
        turn.steps = Array(plan.steps.prefix(8))
        // Plain words with no steps and nothing said: that is the answer.
        if turn.steps.isEmpty, turn.notes.isEmpty { turn.final = output.isEmpty ? nil : output }
        if turn.steps.isEmpty, !turn.notes.isEmpty { pendingText.append("Carry on with the task.") }
        return turn
    }

    // MARK: Room

    private static func size(_ value: Any) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return 0 }
        return Int(Double(data.count) / 3.5)
    }

    /// Shortens the oldest material until the conversation fits, never
    /// the task or the newest turns.
    private func compactIfNeeded() {
        guard Self.size(messages) > inputLimit, messages.count > 6 else { return }
        let keepFrom = messages.count - 6
        for limit in [1_500, 600, 250] {
            for index in 1..<keepFrom {
                messages[index] = Self.shorten(messages[index], to: limit)
            }
            if Self.size(messages) <= inputLimit { return }
        }
    }

    private static let cutNote = "\n[...shortened to save room; read or run it again if it is needed]"

    private static func cut(_ text: String, _ limit: Int) -> String {
        if text.hasPrefix("## Now") { return "## Now\n(screen at that time left out)" }
        return text.count > limit + cutNote.count ? String(text.prefix(limit)) + cutNote : text
    }

    /// A tool call's input with its big texts cut (a file written earlier is
    /// on disk; it need not be carried in full).
    private static func shortenInput(_ input: [String: Any], _ limit: Int) -> [String: Any] {
        var input = input
        for key in ["content", "old_text", "new_text"] {
            if let text = input[key] as? String { input[key] = cut(text, limit) }
        }
        return input
    }

    private static func shorten(_ message: [String: Any], to limit: Int) -> [String: Any] {
        var message = message
        if let text = message["content"] as? String {
            message["content"] = cut(text, limit)
        }
        // OpenAI-style tool calls carry their input as a JSON string.
        if let calls = message["tool_calls"] as? [[String: Any]] {
            message["tool_calls"] = calls.map { call -> [String: Any] in
                guard var function = call["function"] as? [String: Any],
                      let arguments = function["arguments"] as? String,
                      let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: shortenInput(input, limit)) else { return call }
                function["arguments"] = String(decoding: data, as: UTF8.self)
                var copy = call
                copy["function"] = function
                return copy
            }
        }
        guard var blocks = message["content"] as? [[String: Any]] else { return message }
        // Claude's thinking from earlier turns is not needed again.
        blocks.removeAll { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
        if blocks.isEmpty { blocks = [["type": "text", "text": "(thought)"]] }
        for index in blocks.indices {
            switch blocks[index]["type"] as? String {
            case "text":
                if let text = blocks[index]["text"] as? String { blocks[index]["text"] = cut(text, limit) }
            case "tool_result":
                if let text = blocks[index]["content"] as? String { blocks[index]["content"] = cut(text, limit) }
            case "tool_use":
                if let input = blocks[index]["input"] as? [String: Any] { blocks[index]["input"] = shortenInput(input, limit) }
            default: break
            }
        }
        message["content"] = blocks
        return message
    }
}

/// A tool call, whichever engine made it.
struct ToolCall {
    let id: String
    let name: String
    let input: [String: Any]
    /// The input as the engine sent it (OpenAI keeps it as a string).
    var arguments = "{}"
    /// Why the call cannot run (its input was cut off).
    let problem: String?
}

// MARK: - The tools, for engines that call them natively

extension AgentTools {
    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String],
                             why: Bool = true) -> [String: Any] {
        var properties = properties
        if why {
            properties["why"] = ["type": "string",
                                 "description": "A short plain line shown to the user above this step: what it is for."]
        }
        return ["name": name, "description": description,
                "input_schema": ["type": "object", "properties": properties, "required": required]]
    }

    private static let text = ["type": "string"]

    /// What the agent can do, as the API describes tools.
    static let definitions: [[String: Any]] = [
        tool("run_command", "Run a zsh command in the shell and get its output and exit code. The shell keeps the folder a previous cd left it in. Each command must finish on its own: no interactive programs; start a server in the background with nohup and & if the task needs one.",
             ["command": text], required: ["command"]),
        tool("read_file", "Read a text file with line numbers, or list a folder. Give start_line and end_line for part of a long file.",
             ["path": text, "start_line": ["type": "integer"], "end_line": ["type": "integer"]], required: ["path"]),
        tool("search_files", "Find text in files. Results are file:line: text.",
             ["text": text, "path": ["type": "string", "description": "Folder or file to look in; the shell folder when left out."]],
             required: ["text"]),
        tool("edit_file", "Replace one exact piece of a file. old_text must be copied exactly from the file (read it first) and be there exactly once; include enough lines around the change to make it unique.",
             ["path": text, "old_text": text, "new_text": text], required: ["path", "old_text", "new_text"]),
        tool("write_file", "Create a file, or replace one entirely, with this content. Change an existing file with edit_file instead.",
             ["path": text, "content": text], required: ["path", "content"]),
        tool("web_search", "Search the web. You get titles, addresses and a line of each; fetch_page one to read it.",
             ["query": text], required: ["query"]),
        tool("fetch_page", "Load a web page as text.", ["url": text], required: ["url"]),
        tool("delegate", "Hand a question to a helper that reads and searches many files or pages in a context of its own and gives back a short report, so none of what it reads takes up your room. It sees nothing of this task: put everything it needs in the question.",
             ["question": text], required: ["question"], why: false),
        tool("update_plan", "Your checklist for a task of more than three steps. Send the whole list each time an item changes state. Mark each item [x] done, [>] doing now, or leave it unmarked for to do.",
             ["items": ["type": "array", "items": text]], required: ["items"], why: false),
        tool("ask_user", "Ask the user one question when a choice is theirs or you cannot go on, with two to four short answers to pick from. The task pauses until they answer.",
             ["question": text, "options": ["type": "array", "items": text]], required: ["question"], why: false),
        tool("browser", "Work on a web page with the user watching. By default in Companion's own browser, which opens beside the chat so the user works side by side with you (iCloud Passwords fills sign-ins there, in a bar over the page); set in to chrome to work in the user's own Chrome instead, where their existing sign-ins and tabs are (needs Companion's Chrome connection). Actions: open (url, optional new_tab), read (the page's text and its numbered elements), click (target: an element's number from the last read), type (target, text, optional submit), scroll (direction up or down), back, key (key such as Enter), tabs (list them), focus (tab: switch to it), extensions (the Chrome extensions in Companion's browser), add_extension (url: a Chrome Web Store link or ID; the user sees what it may do and agrees; web_search the store to find one). Read before clicking or typing, and read again after a page changes. Never type passwords: password fields are refused; when a sign-in or sign-up needs one, ask_user to sign in in Chrome with iCloud Passwords, then carry on.",
             ["action": ["type": "string", "enum": ["open", "read", "click", "type", "scroll", "back", "key", "tabs", "focus", "upload", "downloads", "history", "extensions", "add_extension"]],
              "url": text, "new_tab": ["type": "boolean"], "target": ["type": "integer"], "text": text,
              "submit": ["type": "boolean"], "direction": ["type": "string", "enum": ["up", "down"]],
              "key": text, "tab": ["type": "integer"],
              "paths": ["type": "array", "items": text, "description": "upload: files on this Mac to put in the file field (target)"],
              "query": ["type": "string", "description": "history: words to find among pages opened in Companion's browser before"],
              "in": ["type": "string", "enum": ["companion", "chrome"]]], required: ["action"]),
        tool("open_terminal", "Open a terminal beside the chat running a command, for work the user does with you side by side: above all an ssh session to a server or cluster (ssh user@host, with -J for a jump host). The user signs in there (password, Duo); it becomes a shared connection your own run_command steps can reuse. Use this, not a browser, for anything reached over ssh.",
             ["command": text], required: ["command"]),
        tool("open_app", "Bring an app to the front by name.", ["name": text], required: ["name"]),
        tool("click", "Press a button, checkbox, link or tab in the front window by its label (as listed under Can be clicked), or a menu path such as File > Export….",
             ["label": text], required: ["label"]),
        tool("type_text", "Type text where the cursor is in the app in front.", ["text": text], required: ["text"]),
        tool("press_key", "Press a key or shortcut: enter, tab, escape, space, delete, arrows, or shortcuts like cmd+a, cmd+l, shift+tab.",
             ["keys": text], required: ["keys"]),
        tool("wait", "Wait 1 to 10 seconds for something to load.", ["seconds": ["type": "number"]], required: ["seconds"], why: false)
    ]

    /// A tool call as a step the agent runs.
    static func step(name: String, input: [String: Any]) -> ActionStep? {
        func string(_ key: String) -> String { (input[key] as? String) ?? (input[key].map { "\($0)" } ?? "") }
        let why = (input["why"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let step: ActionStep
        switch name {
        case "run_command": step = ActionStep(kind: .run, value: string("command"))
        case "read_file":
            var value = string("path")
            if let start = input["start_line"] as? Int {
                let end = (input["end_line"] as? Int) ?? (start + 200)
                value += ":\(start)-\(max(start, end))"
            }
            step = ActionStep(kind: .read, value: value)
        case "search_files":
            let path = string("path")
            step = ActionStep(kind: .search, value: string("text") + (path.isEmpty ? "" : " in " + path))
        case "edit_file":
            step = ActionStep(kind: .edit, value: string("path"), body: string("old_text"), replacement: string("new_text"))
        case "write_file": step = ActionStep(kind: .write, value: string("path"), body: string("content"))
        case "web_search": step = ActionStep(kind: .web, value: string("query"))
        case "fetch_page": step = ActionStep(kind: .fetch, value: string("url"))
        case "delegate": step = ActionStep(kind: .delegate, value: string("question"))
        case "update_plan":
            let items = (input["items"] as? [Any])?.compactMap { $0 as? String } ?? []
            step = ActionStep(kind: .plan, value: items.joined(separator: " | "))
        case "ask_user":
            let options = (input["options"] as? [Any])?.compactMap { $0 as? String } ?? []
            step = ActionStep(kind: .ask, value: ([string("question")] + options.prefix(4)).joined(separator: " | "))
        case "browser":
            let action = string("action")
            var args: [String: Any] = [:]
            for key in ["url", "text", "direction", "key"] { if let value = input[key] as? String { args[key] = value } }
            for key in ["target", "tab"] { if let value = input[key] as? Int { args[key] = value } }
            if let submit = input["submit"] as? Bool { args["submit"] = submit }
            if let newTab = input["new_tab"] as? Bool { args["newTab"] = newTab }
            if let place = input["in"] as? String { args["in"] = place }
            if let paths = input["paths"] as? [Any] { args["paths"] = paths.compactMap { $0 as? String } }
            if let query = input["query"] as? String { args["query"] = query }
            guard let made = ActionStep.browser(action, args) else { return nil }
            step = made
        case "open_app": step = ActionStep(kind: .open, value: string("name"))
        case "open_terminal": step = ActionStep(kind: .terminal, value: string("command"))
        case "click": step = ActionStep(kind: .click, value: string("label"))
        case "type_text": step = ActionStep(kind: .type, value: string("text"))
        case "press_key": step = ActionStep(kind: .key, value: string("keys").lowercased())
        case "wait": step = ActionStep(kind: .wait, value: string("seconds"))
        default: return nil
        }
        var result = step
        result.why = why
        return result
    }
}

// MARK: - Claude's Messages API with tools

/// One reply from Claude: its content blocks as sent (thinking included, as
/// the API needs them back), its words, and its tool calls.
struct AnthropicAgentReply {
    var blocks: [[String: Any]] = []
    var text = ""
    var calls: [ToolCall] = []
    var stopReason = ""
}

enum AnthropicAgent {
    static func turn(system: String, pinned: String, messages: [[String: Any]], tools: [[String: Any]],
                     config: LLMConfig, maxOutput: Int) async throws -> AnthropicAgentReply {
        do {
            return try await send(system: system, pinned: pinned, messages: messages, tools: tools,
                                  config: config, maxOutput: maxOutput, thinking: true)
        } catch LLMError.http(let code, let body) where code == 400 && (body.lowercased().contains("thinking") || body.lowercased().contains("adaptive")) {
            // A model without adaptive thinking: the same turn without it.
            return try await send(system: system, pinned: pinned, messages: Self.withoutThinking(messages), tools: tools,
                                  config: config, maxOutput: maxOutput, thinking: false)
        }
    }

    private static func withoutThinking(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            guard var blocks = message["content"] as? [[String: Any]] else { return message }
            blocks.removeAll { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
            var copy = message
            copy["content"] = blocks.isEmpty ? [["type": "text", "text": "(thought)"]] : blocks
            return copy
        }
    }

    private static func send(system: String, pinned: String, messages: [[String: Any]], tools: [[String: Any]],
                             config: LLMConfig, maxOutput: Int, thinking: Bool) async throws -> AnthropicAgentReply {
        guard !config.apiKey.isEmpty else {
            throw LLMError.notConfigured("Add your Anthropic API key in Settings, or switch provider.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ModelCatalog.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        // The instructions, the tools and the conversation up to the newest
        // message are cached, so each turn only pays for what is new.
        var systemBlocks: [[String: Any]] = [["type": "text", "text": system]]
        if !pinned.isEmpty { systemBlocks.append(["type": "text", "text": pinned]) }
        systemBlocks[systemBlocks.count - 1]["cache_control"] = ["type": "ephemeral"]
        var wire = messages
        if var last = wire.last, var blocks = last["content"] as? [[String: Any]], !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
            last["content"] = blocks
            wire[wire.count - 1] = last
        }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxOutput,
            "stream": true,
            "system": systemBlocks,
            "tools": tools,
            "messages": wire
        ]
        if thinking {
            body["thinking"] = ["type": "adaptive"]
        }
        if let effort = config.effort {
            body["output_config"] = ["effort": effort]
        }
        request.httpBody = try LLM.jsonBody(body)

        let started = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try await LLM.ensureOK(response, bytes: bytes)

        var reply = AnthropicAgentReply()
        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = LLM.parse(payload[...]), let type = event["type"] as? String else { continue }
            switch type {
            case "message_start":
                if let used = (event["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    input = used["input_tokens"] as? Int ?? 0
                    cacheRead = used["cache_read_input_tokens"] as? Int ?? 0
                    cacheWrite = used["cache_creation_input_tokens"] as? Int ?? 0
                }
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { continue }
                blocks[index] = block
            case "content_block_delta":
                guard let index = event["index"] as? Int, let delta = event["delta"] as? [String: Any] else { continue }
                // Adds a piece of streamed text to one field of a block.
                func append(_ field: String, _ key: String) {
                    guard var block = blocks[index] else { return }
                    block[field] = (block[field] as? String ?? "") + (delta[key] as? String ?? "")
                    blocks[index] = block
                }
                switch delta["type"] as? String {
                case "text_delta": append("text", "text")
                case "thinking_delta": append("thinking", "thinking")
                case "signature_delta": append("signature", "signature")
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default: break
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                    reply.stopReason = stop
                }
                if let used = event["usage"] as? [String: Any], let produced = used["output_tokens"] as? Int {
                    output = produced
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "The model stopped with an error."
                throw LLMError.network(message)
            default: break
            }
        }

        for index in blocks.keys.sorted() {
            guard var block = blocks[index] else { continue }
            if block["type"] as? String == "tool_use" {
                let json = partialJSON[index] ?? ""
                let parsed: [String: Any]?
                if json.isEmpty {
                    parsed = [:]
                } else {
                    parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                }
                block["input"] = parsed ?? [:]
                reply.calls.append(ToolCall(id: block["id"] as? String ?? UUID().uuidString,
                                            name: block["name"] as? String ?? "",
                                            input: parsed ?? [:],
                                            arguments: json.isEmpty ? "{}" : json,
                                            problem: parsed == nil
                                            ? "This call was cut off at the output limit before its input was complete, so it did not run. Send it again; write a large file in parts (write_file the first part, then edit_file to add the rest)."
                                            : nil))
            } else if block["type"] as? String == "text" {
                reply.text += (reply.text.isEmpty ? "" : "\n") + (block["text"] as? String ?? "")
            }
            // Empty text blocks are refused when sent back.
            if block["type"] as? String == "text", (block["text"] as? String ?? "").isEmpty { continue }
            reply.blocks.append(block)
        }

        let record = UsageRecord(engine: config.kind.rawValue, model: config.model, purpose: "Agent",
                                 input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output,
                                 exact: true, seconds: Date().timeIntervalSince(started))
        await MainActor.run {
            var filed = record
            filed.conversation = AppState.shared.conversation.id
            UsageStore.shared.add(filed)
        }
        return reply
    }
}

extension AgentTools {
    /// The same tools in the chat completions form.
    static let openAIDefinitions: [[String: Any]] = definitions.map { tool -> [String: Any] in
        ["type": "function",
         "function": ["name": tool["name"] ?? "", "description": tool["description"] ?? "",
                      "parameters": tool["input_schema"] ?? [:]]]
    }
}

// MARK: - Chat completions with tools (OpenAI, Farhelm)

struct OpenAIAgentReply {
    var text = ""
    var calls: [ToolCall] = []
    var stopReason = ""
}

enum OpenAIAgent {
    static func turn(system: String, pinned: String, messages: [[String: Any]], tools: [[String: Any]],
                     config: LLMConfig, maxOutput: Int) async throws -> OpenAIAgentReply {
        let endpoint: URL
        let isOpenAI = config.kind == .openai
        if isOpenAI {
            endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        } else {
            let base = config.baseURL.hasSuffix("/") ? String(config.baseURL.dropLast()) : config.baseURL
            guard let url = URL(string: base + "/v1/chat/completions") else {
                throw LLMError.notConfigured("Invalid gateway URL in Settings.")
            }
            endpoint = url
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // How long the connection may sit with nothing arriving. OpenAI's
        // API streams, so five minutes of silence means it is stuck; a
        // local gateway's model can think quietly for much longer.
        request.timeoutInterval = config.kind == .openai ? 300 : 86_400
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }

        var instructions = pinned.isEmpty ? system : system + "\n\n" + pinned
        // Open-weight reasoning models read their effort from the instructions.
        if let effort = config.effort, config.model.isEmpty || config.model.lowercased().contains("gpt-oss") {
            instructions = "Reasoning: \(effort)\n\n" + instructions
        }
        var body: [String: Any] = [
            "stream": true,
            "messages": [["role": "system", "content": instructions]] + messages,
            "tools": tools,
            "tool_choice": "auto"
        ]
        if !config.model.isEmpty { body["model"] = config.model }
        if isOpenAI {
            body["max_completion_tokens"] = maxOutput
            body["stream_options"] = ["include_usage": true]
            body["parallel_tool_calls"] = true
            if let effort = config.effort { body["reasoning_effort"] = effort }
        } else {
            body["max_tokens"] = maxOutput
        }
        request.httpBody = try LLM.jsonBody(body)

        let started = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            if !isOpenAI { throw LLMError.network("Farhelm runner not reachable at \(config.baseURL). Is it running on this Mac?") }
            throw error
        }
        try await LLM.ensureOK(response, bytes: bytes)

        var reply = OpenAIAgentReply()
        // Calls arrive in pieces, by their place in the list.
        var ids: [Int: String] = [:], names: [Int: String] = [:], arguments: [Int: String] = [:]
        var input: Int?, cached = 0, output: Int?
        var received = 0
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let event = LLM.parse(payload[...]) else { continue }
            if let used = event["usage"] as? [String: Any] {
                cached = (used["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
                if let prompt = used["prompt_tokens"] as? Int { input = max(prompt - cached, 0) }
                output = used["completion_tokens"] as? Int
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            if let stop = choice["finish_reason"] as? String { reply.stopReason = stop }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let text = delta["content"] as? String {
                reply.text += text
                received += text.utf8.count
            }
            for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = piece["index"] as? Int ?? 0
                if let id = piece["id"] as? String, !id.isEmpty { ids[index] = id }
                if let function = piece["function"] as? [String: Any] {
                    if let name = function["name"] as? String { names[index, default: ""] += name }
                    if let part = function["arguments"] as? String {
                        arguments[index, default: ""] += part
                        received += part.utf8.count
                    }
                }
            }
        }
        for index in names.keys.sorted() {
            let json = arguments[index] ?? ""
            let parsed: [String: Any]? = json.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            reply.calls.append(ToolCall(id: ids[index] ?? "call_\(index)_\(UUID().uuidString.prefix(8))",
                                        name: names[index] ?? "",
                                        input: parsed ?? [:],
                                        arguments: parsed == nil ? "{}" : (json.isEmpty ? "{}" : json),
                                        problem: parsed == nil
                                            ? "This call was cut off before its input was complete, so it did not run. Send it again; write a large file in parts."
                                            : nil))
        }

        let sent = (try? JSONSerialization.data(withJSONObject: messages).count) ?? 0
        let record = UsageRecord(engine: config.kind.rawValue, model: config.model, purpose: "Agent",
                                 input: input ?? ContextUse.tokens(sent + instructions.utf8.count), cacheRead: cached, cacheWrite: 0,
                                 output: output ?? ContextUse.tokens(received),
                                 exact: input != nil && output != nil, seconds: Date().timeIntervalSince(started))
        await MainActor.run {
            var filed = record
            filed.conversation = AppState.shared.conversation.id
            UsageStore.shared.add(filed)
        }
        return reply
    }
}
