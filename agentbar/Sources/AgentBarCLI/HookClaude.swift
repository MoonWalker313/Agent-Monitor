import Foundation
import AgentBarCore

// `agentbar hook claude` — Claude Code hook adapter (plan §4.6).
// Claude Code runs it with the hook's JSON on stdin. It maps the hook to an AgentBar event.
//
// PermissionRequest is special: it waits (up to --wait seconds) for Allow/Deny in AgentBar and
// prints Claude Code's decision JSON. If AgentBar isn't running, the user picks "Answer in
// terminal", or time runs out, it prints nothing, so Claude Code shows its normal prompt.
//
// It never fails the hook: every path exits 0.

enum ClaudeHook {
    static let agent = "claude-code"
    static let defaultWait = 300

    static func run(_ args: ArraySlice<String>) -> Never {
        var wait = defaultWait
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--wait":
                guard let v = it.next(), let n = Int(v) else { warn("--wait needs a number of seconds"); exit(0) }
                wait = min(max(n, 1), EventCodec.maxAwaitSeconds - 10)
            default:
                warn("unknown argument '\(arg)' (ignored)")
            }
        }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        HookLog.write("claude IN \(String(decoding: input.prefix(4_000), as: UTF8.self))")
        guard let hook = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let name = hook["hook_event_name"] as? String else {
            warn("hook claude: expected Claude Code hook JSON on stdin")
            exit(0)
        }
        // Cursor also runs Claude Code's hooks (with its own payloads). AgentBar's Cursor adapter
        // handles Cursor, so ignore these here instead of showing the session twice.
        if hook["cursor_version"] != nil { exit(0) }
        guard var event = makeEvent(name: name, hook: hook) else { exit(0) } // hook we don't map

        if name == "PermissionRequest" {
            let tool = hook["tool_name"] as? String
            let input = hook["tool_input"] as? [String: Any] ?? [:]
            if tool == "AskUserQuestion", event.request?.isQuestion != true {
                // Questions AgentBar can't show as options: let Claude ask in the terminal, and say so.
                event.request = nil
                event.message = "Has a question for you in the terminal"
                if let line = try? EventCodec.encodeLine(event) { _ = try? SocketClient.send([line], to: Paths.socketPath) }
                exit(0)
            }
            event.awaitSeconds = wait
            let reply = awaitReply(event, wait: wait)
            let output: String?
            switch tool {
            case "AskUserQuestion":
                output = questionOutput(reply, input: input, shown: event.request?.questions ?? [])
            case "ExitPlanMode":
                // Approving a plan needs the input echoed back; "keep planning" tells Claude to revise.
                output = reply.decision == .allow ? decisionOutput(["behavior": "allow", "updatedInput": input])
                    : reply.decision == .deny ? decisionOutput(["behavior": "deny", "message": "The user wants to keep planning. Ask what to change, then present a revised plan."])
                    : nil
            default:
                output = decisionOutput(reply.decision ?? .deferred)
            }
            if let output { print(output) }
            exit(0)
        }

        if let line = try? EventCodec.encodeLine(event) {
            _ = try? SocketClient.send([line], to: Paths.socketPath)
        }
        exit(0)
    }

    // MARK: Mapping

    static func makeEvent(name: String, hook: [String: Any]) -> AgentEvent? {
        let session = (hook["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let cwd = hook["cwd"] as? String
        let title = cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        var event = AgentEvent(agent: agent, sessionID: session, event: .heartbeat, title: title, cwd: cwd,
                               activateBundleID: hostAppBundleID())
        let toolName = hook["tool_name"] as? String
        let toolInput = hook["tool_input"] as? [String: Any] ?? [:]

        switch name {
        case "SessionStart":
            event.event = .started
            event.message = "Session started"
        case "UserPromptSubmit":
            event.event = .working
            if let prompt = (hook["prompt"] as? String).map(oneLine), !prompt.isEmpty {
                event.message = "Working on: \(prompt)"
                event.activity = "You asked: \(prompt)"
            }
        case "PreToolUse":
            event.event = .heartbeat // keeps stale detection accurate; activity is recorded after the tool runs
        case "PostToolUse":
            event.event = .heartbeat
            if let toolName { event.activity = describe(toolName, toolInput).done }
        case "PostToolUseFailure":
            event.event = .heartbeat
            if let toolName { event.activity = "Failed: \(describe(toolName, toolInput).done)" }
        case "PermissionRequest":
            let d = describe(toolName ?? "tool", toolInput)
            let id = (hook["tool_use_id"] as? String) ?? UUID().uuidString
            event.event = .needsPermission
            switch toolName {
            case "AskUserQuestion":
                let questions = parseQuestions(toolInput)
                let summary = questions.map { $0.count == 1 ? $0[0].question : "Answer \($0.count) questions" }
                event.request = PermissionRequestInfo(id: id, tool: toolName, summary: summary ?? "Answer a question",
                                                      questions: questions)
            case "ExitPlanMode":
                let plan = (toolInput["plan"] as? String).map { truncate($0, EventCodec.maxDetailLength) }
                event.request = PermissionRequestInfo(id: id, tool: toolName, summary: "Approve the plan and start working",
                                                      detail: plan)
            default:
                event.request = PermissionRequestInfo(id: id, tool: toolName, summary: d.ask, detail: d.detail)
            }
        case "Notification":
            let type = hook["notification_type"] as? String
            let message = (hook["message"] as? String).map(oneLine)
            if type == "permission_prompt" {
                // Shown in the terminal (no hook decision, or the user deferred). Keep "needs you" without a card.
                event.event = .needsPermission
                event.message = message ?? "Waiting for permission in the terminal"
            } else if type == "idle_prompt" {
                event.event = .needsInput
                event.message = message ?? "Waiting for your next message"
            } else {
                event.event = .needsInput
                event.message = message
            }
        case "Stop":
            event.event = .finished
            event.message = "Finished. Ready for your review."
        case "StopFailure":
            event.event = .error
            event.message = (hook["error"] as? String).map(oneLine) ?? "Claude stopped with an error"
        case "SessionEnd":
            event.event = .stopped
            event.message = "Session ended"
        default:
            return nil
        }
        return event
    }

    /// Human-readable descriptions of a tool call: what it asks for, what it did, and the exact detail.
    static func describe(_ tool: String, _ input: [String: Any]) -> (ask: String, done: String, detail: String?) {
        func base(_ key: String) -> String? { (input[key] as? String).map { ($0 as NSString).lastPathComponent } }
        switch tool {
        case "Bash":
            let command = input["command"] as? String
            let short = command.map { truncate(oneLine($0), 60) } ?? "a command"
            let description = (input["description"] as? String).map(oneLine)
            return (ask: description.map { "Run: \($0)" } ?? "Run a shell command",
                    done: "Ran \(short)", detail: command)
        case "Edit", "MultiEdit":
            let file = base("file_path") ?? "a file"
            return ("Edit \(file)", "Edited \(file)", input["file_path"] as? String)
        case "Write":
            let file = base("file_path") ?? "a file"
            return ("Write \(file)", "Wrote \(file)", input["file_path"] as? String)
        case "NotebookEdit":
            let file = base("notebook_path") ?? "a notebook"
            return ("Edit notebook \(file)", "Edited \(file)", input["notebook_path"] as? String)
        case "Read":
            let file = base("file_path") ?? "a file"
            return ("Read \(file)", "Read \(file)", input["file_path"] as? String)
        case "WebFetch":
            let url = input["url"] as? String
            let host = url.flatMap { URL(string: $0)?.host } ?? "a web page"
            return ("Fetch \(host)", "Fetched \(host)", url)
        case "WebSearch":
            let q = (input["query"] as? String).map(oneLine) ?? ""
            return ("Search the web", "Searched: \(truncate(q, 50))", q)
        case "Glob", "Grep":
            let pattern = input["pattern"] as? String ?? ""
            return ("\(tool) for \(truncate(pattern, 40))", "Searched files: \(truncate(pattern, 40))", pattern)
        default:
            let pretty = prettyTool(tool)
            return ("Use \(pretty)", "Used \(pretty)", compactJSON(input))
        }
    }

    // MARK: Questions

    /// AskUserQuestion's `questions`, cleaned exactly as AgentBar will show them. nil if they can't be shown.
    static func parseQuestions(_ input: [String: Any]) -> [Question]? {
        guard let raw = input["questions"] as? [[String: Any]] else { return nil }
        var questions: [Question] = []
        for q in raw {
            guard let text = q["question"] as? String, let options = q["options"] as? [[String: Any]] else { return nil }
            let parsed = options.compactMap { o in (o["label"] as? String).map { Question.Option(label: $0, description: o["description"] as? String) } }
            guard parsed.count == options.count else { return nil }
            questions.append(Question(question: text, header: q["header"] as? String, options: parsed,
                                      multiSelect: q["multiSelect"] as? Bool))
        }
        return EventCodec.cleanQuestions(questions)
    }

    /// Output for an answered AskUserQuestion: Claude's own input plus `answers`, written with the
    /// original (uncleaned) question text and labels. Anything unexpected → nil, so Claude asks itself.
    static func questionOutput(_ reply: ServerReply, input: [String: Any], shown: [Question]) -> String? {
        switch reply.decision {
        case .deny:
            return decisionOutput(["behavior": "deny", "message": "The user chose not to answer this from AgentBar."])
        case .allow:
            guard let answers = reply.answers, Question.validate(answers, for: shown),
                  let raw = input["questions"] as? [[String: Any]], raw.count == shown.count else { return nil }
            var original: [String: String] = [:]
            for (q, rawQ) in zip(shown, raw) {
                guard let answer = answers[q.question], let rawText = rawQ["question"] as? String,
                      let rawOptions = rawQ["options"] as? [[String: Any]], rawOptions.count == q.options.count else { return nil }
                let picked = q.options.map(\.label).contains(answer) ? [answer] : answer.components(separatedBy: ", ")
                var labels: [String] = []
                for label in picked {
                    guard let i = q.options.firstIndex(where: { $0.label == label }),
                          let rawLabel = rawOptions[i]["label"] as? String else { return nil }
                    labels.append(rawLabel)
                }
                original[rawText] = labels.joined(separator: ", ")
            }
            var updated = input
            updated["answers"] = original
            return decisionOutput(["behavior": "allow", "updatedInput": updated])
        default:
            return nil
        }
    }

    // MARK: Decision

    static func awaitDecision(_ event: AgentEvent, wait: Int) -> Decision {
        awaitReply(event, wait: wait).decision ?? .deferred
    }

    /// Waits for the user's answer. Any failure (AgentBar closed, timeout, bad reply) is a deferral.
    static func awaitReply(_ event: AgentEvent, wait: Int) -> ServerReply {
        let deferred = ServerReply(ok: true, decision: .deferred)
        guard let line = try? EventCodec.encodeLine(event) else { return deferred }
        do {
            let reply = try SocketClient.request(line, to: Paths.socketPath, timeout: TimeInterval(wait + 5))
            return reply.ok && reply.decision != nil ? reply : deferred
        } catch {
            warn("AgentBar unavailable (\(error)); Claude Code will ask in the terminal")
            return deferred
        }
    }

    /// Claude Code PermissionRequest hook output. nil = no decision (Claude asks normally).
    static func decisionOutput(_ decision: Decision) -> String? {
        switch decision {
        case .allow: return decisionOutput(["behavior": "allow"])
        case .deny: return decisionOutput(["behavior": "deny", "message": "The user denied this from AgentBar."])
        case .deferred: return nil
        }
    }

    static func decisionOutput(_ body: [String: Any]) -> String? {
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Helpers

    /// The app the agent runs in, so AgentBar can bring it to the front.
    static func hostAppBundleID() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["__CFBundleIdentifier"], BundleIDPolicy.isValid(id) { return id }
        switch env["TERM_PROGRAM"] {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }

    static func prettyTool(_ tool: String) -> String {
        // mcp__server__tool → "tool (server)"
        let parts = tool.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" { return "\(parts[2...].joined(separator: "__")) (\(parts[1]))" }
        return tool
    }

    static func compactJSON(_ value: [String: Any]) -> String? {
        guard !value.isEmpty, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func truncate(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("agentbar: \(message)\n".utf8))
    }
}
