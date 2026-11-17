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
        guard let hook = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let name = hook["hook_event_name"] as? String else {
            warn("hook claude: expected Claude Code hook JSON on stdin")
            exit(0)
        }
        guard var event = makeEvent(name: name, hook: hook) else { exit(0) } // hook we don't map

        if name == "PermissionRequest" {
            event.awaitSeconds = wait
            let decision = awaitDecision(event, wait: wait)
            if let output = decisionOutput(decision) { print(output) }
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
            event.event = .needsPermission
            event.request = PermissionRequestInfo(id: (hook["tool_use_id"] as? String) ?? UUID().uuidString,
                                                  tool: toolName, summary: d.ask, detail: d.detail)
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

    // MARK: Decision

    static func awaitDecision(_ event: AgentEvent, wait: Int) -> Decision {
        guard let line = try? EventCodec.encodeLine(event) else { return .deferred }
        do {
            let reply = try SocketClient.request(line, to: Paths.socketPath, timeout: TimeInterval(wait + 5))
            return reply.ok ? (reply.decision ?? .deferred) : .deferred
        } catch {
            warn("AgentBar unavailable (\(error)); Claude Code will ask in the terminal")
            return .deferred
        }
    }

    /// Claude Code PermissionRequest hook output. nil = no decision (Claude asks normally).
    static func decisionOutput(_ decision: Decision) -> String? {
        let body: [String: Any]
        switch decision {
        case .allow: body = ["behavior": "allow"]
        case .deny: body = ["behavior": "deny", "message": "The user denied this from AgentBar."]
        case .deferred: return nil
        }
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
