import Foundation

/// The agents AgentBar can connect to with one click, and how each one's hook config is written.
/// Every write goes through `ClaudeSetup.write` (keeps permissions, follows symlinks, private backup).
public enum Integration: String, CaseIterable, Sendable, Identifiable {
    case claude, cursor, gemini, antigravity

    public var id: String { rawValue }

    /// The `agent` name events are reported under.
    public var agentID: String {
        switch self {
        case .claude: return "claude-code"
        case .cursor: return "cursor"
        case .gemini: return "gemini-cli"
        case .antigravity: return "antigravity"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity"
        }
    }

    /// Where its hooks live (user level, so they apply to every project).
    public var configPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .claude: return home + "/.claude/settings.json"
        case .cursor: return home + "/.cursor/hooks.json"
        case .gemini: return home + "/.gemini/settings.json"
        case .antigravity: return home + "/.gemini/config/hooks.json"
        }
    }

    public var displayPath: String { configPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }

    /// Whether AgentBar can answer this agent's permission prompts, and if so whether it's opt-in.
    public var supportsApprovals: Bool { self != .gemini }
    public var approvalsAreOptional: Bool { self == .cursor || self == .antigravity }

    /// Seconds an IDE agent waits for an answer in AgentBar before asking in its own window.
    public static let ideWait = 60
}

public enum IntegrationSetup {
    /// True for a hook command AgentBar wrote for this adapter, quoted path or not.
    public static func isAgentBarCommand(_ command: String, adapter: String) -> Bool {
        command.range(of: #"agentbar'?\s+hook\s+"# + adapter + #"\b"#, options: .regularExpression) != nil
    }

    static func command(cli: String, adapter: String) -> String { "\(ClaudeSetup.quote(cli)) hook \(adapter)" }

    // MARK: Transforms (pure, tested)

    public static func connect(_ integration: Integration, _ settings: [String: Any], cli: String, approvals: Bool = false) -> [String: Any] {
        switch integration {
        case .claude: return ClaudeSetup.connect(settings, cli: cli)
        case .cursor: return connectCursor(disconnect(.cursor, settings), cli: cli, approvals: approvals)
        case .gemini: return connectGemini(disconnect(.gemini, settings), cli: cli)
        case .antigravity: return connectAntigravity(disconnect(.antigravity, settings), cli: cli, approvals: approvals)
        }
    }

    public static func disconnect(_ integration: Integration, _ settings: [String: Any]) -> [String: Any] {
        switch integration {
        case .claude: return ClaudeSetup.disconnect(settings)
        case .cursor: return removeCursorHooks(settings)
        case .gemini: return removeNestedHooks(settings, adapter: "gemini")
        case .antigravity:
            var s = settings
            s[antigravityKey] = nil
            return s
        }
    }

    public static func isConnected(_ integration: Integration, _ settings: [String: Any]) -> Bool {
        switch integration {
        case .claude: return ClaudeSetup.isConnected(settings)
        case .cursor:
            return ((settings["hooks"] as? [String: Any]) ?? [:]).values.contains { value in
                ((value as? [Any]) ?? []).contains { isAgentBarCommand((($0 as? [String: Any])?["command"] as? String) ?? "", adapter: "cursor") }
            }
        case .gemini:
            return ((settings["hooks"] as? [String: Any]) ?? [:]).values.contains { value in
                ((value as? [Any]) ?? []).contains { group in
                    (((group as? [String: Any])?["hooks"] as? [Any]) ?? []).contains {
                        isAgentBarCommand((($0 as? [String: Any])?["command"] as? String) ?? "", adapter: "gemini")
                    }
                }
            }
        case .antigravity: return settings[antigravityKey] != nil
        }
    }

    /// Whether the opt-in "answer terminal commands in AgentBar" hook is installed.
    public static func approvalsOn(_ integration: Integration, _ settings: [String: Any]) -> Bool {
        switch integration {
        case .claude: return isConnected(.claude, settings)
        case .gemini: return false
        case .cursor:
            return (((settings["hooks"] as? [String: Any])?["beforeShellExecution"] as? [Any]) ?? []).contains {
                isAgentBarCommand((($0 as? [String: Any])?["command"] as? String) ?? "", adapter: "cursor")
            }
        case .antigravity:
            return ((settings[antigravityKey] as? [String: Any])?["PreToolUse"]) != nil
        }
    }

    // Cursor: { "version": 1, "hooks": { "<event>": [ { "command": "...", "timeout": 5 } ] } }
    static let cursorEvents = ["sessionStart", "beforeSubmitPrompt", "afterShellExecution", "afterFileEdit", "stop", "sessionEnd"]

    static func connectCursor(_ settings: [String: Any], cli: String, approvals: Bool) -> [String: Any] {
        var s = settings
        if s["version"] == nil { s["version"] = 1 }
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        let cmd = command(cli: cli, adapter: "cursor")
        for event in cursorEvents {
            hooks[event] = (hooks[event] as? [Any] ?? []) + [["command": cmd, "timeout": 5]]
        }
        if approvals {
            // Cursor runs the command if a hook stays silent, so the hook always answers (allow, deny or
            // ask) and its own timeout is longer than AgentBar's wait.
            hooks["beforeShellExecution"] = (hooks["beforeShellExecution"] as? [Any] ?? [])
                + [["command": "\(cmd) --wait \(Integration.ideWait)", "timeout": Integration.ideWait + 15]]
        }
        s["hooks"] = hooks
        return s
    }

    static func removeCursorHooks(_ settings: [String: Any]) -> [String: Any] {
        var s = settings
        guard var hooks = s["hooks"] as? [String: Any] else { return s }
        for (event, value) in hooks {
            guard let list = value as? [Any] else { continue }
            let kept = list.filter { !isAgentBarCommand((($0 as? [String: Any])?["command"] as? String) ?? "", adapter: "cursor") }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        if s["hooks"] == nil, s.count == 1, s["version"] != nil { s["version"] = nil }
        return s
    }

    // Gemini CLI: same nested shape as Claude Code; timeouts are in milliseconds.
    static let geminiEvents = ["SessionStart", "BeforeAgent", "AfterTool", "Notification", "AfterAgent", "SessionEnd"]

    static func connectGemini(_ settings: [String: Any], cli: String) -> [String: Any] {
        var s = settings
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        let cmd = command(cli: cli, adapter: "gemini")
        for event in geminiEvents {
            let handler: [String: Any] = ["type": "command", "command": cmd, "name": "agentbar", "timeout": 5_000]
            hooks[event] = (hooks[event] as? [Any] ?? []) + [["hooks": [handler]]]
        }
        s["hooks"] = hooks
        return s
    }

    static func removeNestedHooks(_ settings: [String: Any], adapter: String) -> [String: Any] {
        var s = settings
        guard var hooks = s["hooks"] as? [String: Any] else { return s }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { group in
                guard var g = group as? [String: Any], let handlers = g["hooks"] as? [Any] else { return group }
                let remaining = handlers.filter { !isAgentBarCommand((($0 as? [String: Any])?["command"] as? String) ?? "", adapter: adapter) }
                if remaining.isEmpty { return nil }
                g["hooks"] = remaining
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        return s
    }

    // Antigravity: { "<hook name>": { "<Event>": [ { "matcher"?: "...", "hooks": [ { "type": "command", ... } ] } ] } }
    public static let antigravityKey = "agentbar"
    static let antigravityEvents = ["SessionStart", "PreInvocation", "PostToolUse", "Stop"]

    static func connectAntigravity(_ settings: [String: Any], cli: String, approvals: Bool) -> [String: Any] {
        var s = settings
        let cmd = command(cli: cli, adapter: "antigravity")
        var ours: [String: Any] = [:]
        // Antigravity's format (its built-in hooks guide): tool events are grouped under a `matcher`;
        // SessionStart / PreInvocation / Stop are a flat list of handlers. A wrong shape makes it
        // reject the whole file. Each entry also names its event, as a fallback to `hookEventName`.
        for event in antigravityEvents {
            let handler: [String: Any] = ["type": "command", "command": "\(cmd) --event \(event)", "timeout": 5]
            ours[event] = event == "PostToolUse" ? [["matcher": "*", "hooks": [handler]]] : [handler]
        }
        if approvals {
            ours["PreToolUse"] = [["matcher": "run_command",
                                   "hooks": [["type": "command", "command": "\(cmd) --event PreToolUse --wait \(Integration.ideWait)",
                                              "timeout": Integration.ideWait + 15]]]]
        }
        s[antigravityKey] = ours
        return s
    }

    // MARK: Files

    public static func isConnected(_ integration: Integration) -> Bool {
        (try? isConnected(integration, ClaudeSetup.read(integration.configPath))) ?? false
    }

    public static func approvalsOn(_ integration: Integration) -> Bool {
        (try? approvalsOn(integration, ClaudeSetup.read(integration.configPath))) ?? false
    }

    public static func connectFile(_ integration: Integration, cli: String, approvals: Bool = false, path: String? = nil) throws {
        let p = path ?? integration.configPath
        try ClaudeSetup.write(connect(integration, try ClaudeSetup.read(p), cli: cli, approvals: approvals), to: p)
    }

    public static func disconnectFile(_ integration: Integration, path: String? = nil) throws {
        let p = path ?? integration.configPath
        let current = try ClaudeSetup.read(p)
        guard isConnected(integration, current) else { return }
        try ClaudeSetup.write(disconnect(integration, current), to: p)
    }
}
