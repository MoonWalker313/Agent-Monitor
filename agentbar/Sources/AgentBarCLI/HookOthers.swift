import Foundation
import AgentBarCore

// Hook adapters for Cursor, Gemini CLI and Antigravity. Each tool runs `agentbar hook <name>` with
// the hook's JSON on stdin. Observing hooks print nothing (or `{}` where the tool expects JSON) and
// never block the agent. Approval hooks always answer, so a silent failure can't let a command
// run unasked: when unsure they answer "ask", and the tool shows its own prompt.

enum OtherHooks {
    struct Options {
        var wait = Integration.ideWait
        /// The hook event, when the tool's input doesn't name it (Antigravity).
        var event: String?
    }

    static func run(_ adapter: String, _ args: ArraySlice<String>) -> Never {
        var options = Options()
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg == "--wait", let v = it.next(), let n = Int(v) { options.wait = min(max(n, 1), EventCodec.maxAwaitSeconds - 10) }
            if arg == "--event", let v = it.next() { options.event = v }
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        HookLog.write("\(adapter) \(options.event ?? "-") IN \(String(decoding: input.prefix(4_000), as: UTF8.self))")
        let hook = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
        switch adapter {
        case "cursor": Cursor.handle(hook, options)
        case "gemini": Gemini.handle(hook)
        case "antigravity": Antigravity.handle(hook, options)
        default: fail("unknown hook '\(adapter)'. Use: claude, cursor, gemini, antigravity")
        }
    }

    // MARK: Shared

    static func send(_ event: AgentEvent) {
        if let line = try? EventCodec.encodeLine(event) { _ = try? SocketClient.send([line], to: Paths.socketPath, timeout: 2) }
    }

    static func base(agent: String, session: String?, cwd: String?) -> AgentEvent {
        let sessionID = (session?.isEmpty == false ? session! : "unknown")
        let title = cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        return AgentEvent(agent: agent, sessionID: sessionID, event: .heartbeat, title: title, cwd: cwd,
                          activateBundleID: ClaudeHook.hostAppBundleID())
    }

    static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for k in keys { if let v = dict[k] as? String, !v.isEmpty { return v } }
        return nil
    }

    static func file(_ path: String?) -> String? { path.map { ($0 as NSString).lastPathComponent } }

    /// Asks AgentBar and waits. Any failure (AgentBar closed, timeout, bad reply) is `.deferred`.
    static func ask(_ event: AgentEvent, wait: Int) -> Decision {
        var e = event
        e.awaitSeconds = wait
        return ClaudeHook.awaitDecision(e, wait: wait)
    }

    static func printJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            HookLog.write("OUT \(text)")
            print(text)
        }
    }

    static let denied = "The user denied this from AgentBar."

    /// A routine, read-only command (`ls`, `git status`…) when the user only wants to be asked about
    /// changes: record it as activity, no popup. The caller then answers "allow".
    static func passRoutine(_ command: String?, event: AgentEvent) -> Bool {
        guard let command, CommandPolicy.autoAllowEnabled, CommandPolicy.isReadOnly(command) else { return false }
        var e = event
        e.event = .working
        e.request = nil
        e.activity = "Ran \(ClaudeHook.truncate(ClaudeHook.oneLine(command), 60))"
        send(e)
        return true
    }

    // MARK: Cursor

    enum Cursor {
        static func handle(_ hook: [String: Any], _ options: Options) -> Never {
            let name = hook["hook_event_name"] as? String ?? ""
            let root = (hook["workspace_roots"] as? [String])?.first
            let cwd = root ?? hook["cwd"] as? String
            var event = OtherHooks.base(agent: Integration.cursor.agentID,
                                        session: OtherHooks.string(hook, ["conversation_id", "session_id"]), cwd: cwd)
            if root == nil { event.title = "Cursor (no folder open)" }
            switch name {
            case "beforeShellExecution":
                // Approval hook: must always print a decision.
                let command = hook["command"] as? String ?? ""
                if OtherHooks.passRoutine(command, event: event) {
                    OtherHooks.printJSON(["permission": "allow"])
                    exit(0)
                }
                event.event = .needsPermission
                event.request = PermissionRequestInfo(id: UUID().uuidString,
                                                      tool: "Terminal", summary: "Run a terminal command",
                                                      detail: command.isEmpty ? nil : command)
                let decision = command.isEmpty ? .deferred : OtherHooks.ask(event, wait: options.wait)
                switch decision {
                case .allow: OtherHooks.printJSON(["permission": "allow"])
                case .deny: OtherHooks.printJSON(["permission": "deny", "user_message": "Denied in AgentBar.", "agent_message": OtherHooks.denied])
                case .deferred: OtherHooks.printJSON(["permission": "ask"])
                }
                exit(0)
            case "sessionStart":
                event.event = .started
                event.message = "Session started"
            case "beforeSubmitPrompt":
                // Observing only: print nothing, so Cursor carries on with the prompt.
                event.event = .working
                if let prompt = (hook["prompt"] as? String).map(ClaudeHook.oneLine), !prompt.isEmpty {
                    event.message = "Working on: \(prompt)"
                    event.activity = "You asked: \(prompt)"
                }
            case "afterShellExecution":
                event.event = .working
                if let cmd = hook["command"] as? String { event.activity = "Ran \(ClaudeHook.truncate(ClaudeHook.oneLine(cmd), 60))" }
            case "afterFileEdit":
                event.event = .working
                event.activity = "Edited \(OtherHooks.file(hook["file_path"] as? String) ?? "a file")"
            case "stop":
                if let input = hook["input_tokens"] as? Int, let output = hook["output_tokens"] as? Int {
                    event.usage = Usage(inputTokens: input, outputTokens: output)
                }
                switch hook["status"] as? String {
                case "error": event.event = .error; event.message = "Cursor stopped with an error"
                case "aborted": event.event = .stopped; event.message = "Stopped"
                default: event.event = .finished; event.message = "Finished. Ready for your review."
                }
            case "sessionEnd":
                event.event = .stopped
                event.message = "Session ended"
            default:
                exit(0)
            }
            OtherHooks.send(event)
            exit(0)
        }
    }

    // MARK: Gemini CLI

    enum Gemini {
        static func handle(_ hook: [String: Any]) -> Never {
            let name = hook["hook_event_name"] as? String ?? ""
            var event = OtherHooks.base(agent: Integration.gemini.agentID, session: hook["session_id"] as? String,
                                        cwd: hook["cwd"] as? String)
            switch name {
            case "SessionStart":
                event.event = .started
                event.message = "Session started"
            case "BeforeAgent":
                event.event = .working
                if let prompt = (hook["prompt"] as? String).map(ClaudeHook.oneLine), !prompt.isEmpty {
                    event.message = "Working on: \(prompt)"
                    event.activity = "You asked: \(prompt)"
                }
            case "AfterTool":
                // A tool ran, so any permission prompt was answered: back to running.
                event.event = .working
                event.activity = describe(hook["tool_name"] as? String ?? "tool", hook["tool_input"] as? [String: Any] ?? [:])
            case "Notification":
                event.event = .needsPermission
                let message = (hook["message"] as? String).map(ClaudeHook.oneLine)
                event.message = "Waiting for your permission in Gemini CLI" + (message.map { ": \($0)" } ?? "")
            case "AfterAgent":
                event.event = .finished
                event.message = "Finished. Ready for your review."
            case "SessionEnd":
                event.event = .stopped
                event.message = "Session ended"
            default:
                print("{}"); exit(0)
            }
            OtherHooks.send(event)
            print("{}") // Gemini CLI reads stdout as JSON; an empty object changes nothing.
            exit(0)
        }

        static func describe(_ tool: String, _ input: [String: Any]) -> String {
            switch tool {
            case "run_shell_command":
                return "Ran \(ClaudeHook.truncate(ClaudeHook.oneLine(input["command"] as? String ?? "a command"), 60))"
            case "write_file": return "Wrote \(OtherHooks.file(input["file_path"] as? String) ?? "a file")"
            case "replace": return "Edited \(OtherHooks.file(input["file_path"] as? String) ?? "a file")"
            case "read_file", "read_many_files": return "Read \(OtherHooks.file(input["file_path"] as? String) ?? "files")"
            case "web_fetch": return "Fetched a web page"
            case "google_web_search": return "Searched the web"
            default: return "Used \(ClaudeHook.prettyTool(tool))"
            }
        }
    }

    // MARK: Antigravity

    // Follows the hooks guide that ships with Antigravity (agy-customizations/docs/hooks.md):
    // camelCase input, and every event answers with a JSON object on stdout.
    enum Antigravity {
        static func handle(_ hook: [String: Any], _ options: Options) -> Never {
            let name = hook["hookEventName"] as? String ?? options.event ?? ""
            let cwd = (hook["workspacePaths"] as? [String])?.first ?? hook["cwd"] as? String
            var event = OtherHooks.base(agent: Integration.antigravity.agentID, session: hook["conversationId"] as? String, cwd: cwd)
            let call = hook["toolCall"] as? [String: Any] ?? [:]
            let tool = call["name"] as? String ?? "tool"
            let args = call["args"] as? [String: Any] ?? [:]
            let error = (hook["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var reply: [String: Any] = [:]
            switch name {
            case "PreToolUse" where tool == IntegrationSetup.antigravityQuestionTool:
                OtherHooks.printJSON(question(args, event: event, wait: options.wait))
                exit(0)
            case "PreToolUse":
                // Approval hook (installed only for run_command): always answer.
                let command = OtherHooks.string(args, ["CommandLine", "commandLine", "command", "cmd"])
                if OtherHooks.passRoutine(command, event: event) {
                    OtherHooks.printJSON(["decision": "allow"])
                    exit(0)
                }
                event.event = .needsPermission
                // Antigravity describes each command in plain words ("List directory contents").
                let summary = OtherHooks.string(args, ["toolSummary"]) ?? "Run a terminal command"
                event.request = PermissionRequestInfo(id: UUID().uuidString, tool: "Terminal",
                                                      summary: summary, detail: command)
                let decision = command == nil ? .deferred : OtherHooks.ask(event, wait: options.wait)
                switch decision {
                case .allow: OtherHooks.printJSON(["decision": "allow"])
                case .deny: OtherHooks.printJSON(["decision": "deny", "reason": OtherHooks.denied])
                case .deferred: OtherHooks.printJSON(["decision": "ask"])
                }
                exit(0)
            case "SessionStart":
                event.event = .started
                event.message = "Session started"
            case "PreInvocation":
                event.event = .working
                if (hook["invocationNum"] as? Int ?? 0) == 0,
                   let prompt = (hook["lastUserInput"] as? String).map(ClaudeHook.oneLine), !prompt.isEmpty {
                    event.message = "Working on: \(prompt)"
                    event.activity = "You asked: \(prompt)"
                }
            case "PostToolUse" where tool == IntegrationSetup.antigravityQuestionTool:
                event.event = .working
                let first = ((args["questions"] as? [[String: Any]])?.first?["question"] as? String).map { ClaudeHook.truncate(ClaudeHook.oneLine($0), 80) }
                event.activity = "Asked you: \(first ?? "a question")"
            case "PostToolUse":
                event.event = .working
                let done = describe(tool, args)
                event.activity = error != nil ? "Failed: \(done)" : done
            case "Stop":
                reply = ["decision": "stop"] // anything but "continue" lets the agent stop
                switch hook["terminationReason"] as? String {
                case "USER_CANCELED":
                    event.event = .stopped
                    event.message = "Stopped"
                case "ERROR", "MAX_TOKEN_BUDGET_EXCEEDED":
                    event.event = .error
                    event.message = error.map { ClaudeHook.truncate(ClaudeHook.oneLine($0), 200) } ?? "Antigravity stopped with an error"
                default:
                    if hook["fullyIdle"] as? Bool == false {
                        event.event = .heartbeat // background work still running
                    } else {
                        event.event = .finished
                        event.message = "Finished. Ready for your review."
                    }
                }
            default:
                print("{}"); exit(0)
            }
            OtherHooks.send(event)
            OtherHooks.printJSON(reply)
            exit(0)
        }

        /// `ask_question`: `{"questions":[{"question": str, "options": [str], "is_multi_select": bool}]}`.
        static func parseQuestions(_ args: [String: Any]) -> [Question]? {
            guard let raw = args["questions"] as? [[String: Any]] else { return nil }
            var questions: [Question] = []
            for q in raw {
                guard let text = q["question"] as? String, let options = q["options"] as? [String] else { return nil }
                questions.append(Question(question: text, options: options.map { Question.Option(label: $0) },
                                          multiSelect: q["is_multi_select"] as? Bool))
            }
            return EventCodec.cleanQuestions(questions)
        }

        /// Shows Antigravity's question in AgentBar. Antigravity's hooks can't hand a tool its result, so
        /// an answer is delivered as the reason for not showing the question again: the agent reads it and
        /// carries on. Anything else lets the tool run, and Antigravity asks in its own window as usual.
        static func question(_ args: [String: Any], event base: AgentEvent, wait: Int) -> [String: Any] {
            let runInApp: [String: Any] = ["decision": "allow"]
            var event = base
            guard let questions = parseQuestions(args), let raw = args["questions"] as? [[String: Any]], raw.count == questions.count else {
                event.event = .needsInput
                event.message = "Has a question for you in Antigravity"
                OtherHooks.send(event)
                return runInApp
            }
            event.event = .needsPermission
            let summary = OtherHooks.string(args, ["toolSummary"]) ?? (questions.count == 1 ? questions[0].question : "Answer \(questions.count) questions")
            event.request = PermissionRequestInfo(id: UUID().uuidString, tool: "Question", summary: summary, questions: questions)
            var e = event
            e.awaitSeconds = wait
            let reply = ClaudeHook.awaitReply(e, wait: wait)
            guard reply.decision == .allow, let answers = reply.answers, Question.validate(answers, for: questions) else { return runInApp }
            // Antigravity's own answers read "A1: <option>"; keep that shape, using the original option text.
            var lines: [String] = []
            for (i, (q, rawQ)) in zip(questions, raw).enumerated() {
                guard let answer = answers[q.question], let rawOptions = rawQ["options"] as? [String],
                      rawOptions.count == q.options.count else { return runInApp }
                let picked = q.options.map(\.label).contains(answer) ? [answer] : answer.components(separatedBy: ", ")
                let original = picked.compactMap { label in q.options.firstIndex { $0.label == label }.map { rawOptions[$0] } }
                guard original.count == picked.count else { return runInApp }
                lines.append("A\(i + 1): \(original.joined(separator: ", "))")
            }
            let reason = "The user already answered this question in AgentBar, so it wasn't shown again. Their answer:\n"
                + lines.joined(separator: "\n") + "\nContinue with this answer; don't ask the question again."
            return ["decision": "deny", "reason": reason]
        }

        static func describe(_ tool: String, _ args: [String: Any]) -> String {
            let path = OtherHooks.file(OtherHooks.string(args, ["Path", "TargetFile", "AbsolutePath", "FilePath", "path", "file_path"]))
            let t = tool.lowercased()
            // Antigravity's tool names vary between versions (write_file, write_to_file…), so match by meaning.
            if t == "run_command" || t.contains("command") {
                return "Ran \(ClaudeHook.truncate(ClaudeHook.oneLine(OtherHooks.string(args, ["CommandLine", "commandLine", "command"]) ?? "a command"), 60))"
            }
            if t.contains("write") || t.contains("create_file") { return "Wrote \(path ?? "a file")" }
            if t.contains("replace") || t.contains("edit") { return "Edited \(path ?? "a file")" }
            if t.contains("view") || t.contains("read_file") || t.contains("list_dir") { return "Read \(path ?? "a file")" }
            if t.contains("grep") || t.contains("find") || t.contains("search") && !t.contains("web") { return "Searched files" }
            if t.contains("url") || t.contains("web") || t.contains("browser") { return "Looked something up online" }
            return "Used \(ClaudeHook.prettyTool(tool))"
        }
    }
}

/// Opt-in diagnostics: while `~/Library/Application Support/AgentBar/hook-debug` exists, every hook call
/// appends what it received and what it answered to `hook-debug.log` (0600) next to it. Off by default;
/// delete the flag file to stop. Prompts can appear in the log, so delete it after troubleshooting.
enum HookLog {
    static var enabled: Bool { FileManager.default.fileExists(atPath: Paths.supportDirectory + "/hook-debug") }
    static var path: String { Paths.supportDirectory + "/hook-debug.log" }

    static func write(_ line: String) {
        guard enabled else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8))
        try? handle.close()
    }
}

/// `agentbar connect|disconnect <agent> [--approvals]`
enum ConnectCommand {
    static func run(_ verb: String, _ args: ArraySlice<String>) -> Never {
        guard let name = args.first, let integration = Integration.allCases.first(where: { $0.rawValue == name }) else {
            fail("usage: agentbar \(verb) claude|cursor|gemini|antigravity [--approvals]")
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        do {
            if verb == "connect" {
                try IntegrationSetup.connectFile(integration, cli: exe, approvals: args.contains("--approvals"))
                print("Connected \(integration.displayName) (\(integration.displayPath)). Restart its open sessions or windows.")
            } else {
                try IntegrationSetup.disconnectFile(integration)
                print("Disconnected \(integration.displayName).")
            }
            exit(0)
        } catch {
            fail("\(error)")
        }
    }
}
