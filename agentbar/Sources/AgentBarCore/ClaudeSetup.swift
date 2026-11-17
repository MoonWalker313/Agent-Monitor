import Foundation

/// Adds or removes AgentBar's hooks in a Claude Code settings file (`~/.claude/settings.json`),
/// touching nothing else in it. Every write keeps a backup next to the file first.
public enum ClaudeSetup {
    public static let marker = "agentbar hook claude"

    /// True for a hook command AgentBar wrote, with or without a quoted path:
    /// `/…/agentbar hook claude` or `'/…/Agent Bar.app/…/agentbar' hook claude`.
    public static func isAgentBarCommand(_ command: String) -> Bool {
        command.range(of: #"agentbar'?\s+hook\s+claude"#, options: .regularExpression) != nil
    }
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                "PermissionRequest", "Notification", "Stop", "SessionEnd"]

    public enum SetupError: Error, CustomStringConvertible, Equatable {
        case unreadable(String)
        case notAnObject
        public var description: String {
            switch self {
            case .unreadable(let why): return "Claude Code's settings file couldn't be read: \(why)"
            case .notAnObject: return "Claude Code's settings file isn't in the expected format, so AgentBar left it alone."
            }
        }
    }

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path
    }

    // MARK: Pure transforms (tested)

    /// Settings with AgentBar's hooks added. Existing hooks (yours or other tools') are kept;
    /// existing AgentBar hooks are replaced so the command path stays current.
    public static func connect(_ settings: [String: Any], cli: String, wait: Int = 300) -> [String: Any] {
        var settings = disconnect(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let command = "\(quote(cli)) hook claude"
        for event in events {
            let isPermission = event == "PermissionRequest"
            let handler: [String: Any] = ["type": "command",
                                          "command": isPermission ? "\(command) --wait \(wait)" : command,
                                          "timeout": isPermission ? wait + 10 : 5]
            var groups = hooks[event] as? [Any] ?? []
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Settings with every AgentBar hook removed, and any group or event left empty dropped.
    public static func disconnect(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            let kept: [Any] = groups.compactMap { group in
                guard var g = group as? [String: Any], let handlers = g["hooks"] as? [Any] else { return group }
                let remaining = handlers.filter { h in
                    !isAgentBarCommand((h as? [String: Any])?["command"] as? String ?? "")
                }
                if remaining.isEmpty { return nil }
                g["hooks"] = remaining
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    public static func isConnected(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            ((value as? [Any]) ?? []).contains { group in
                (((group as? [String: Any])?["hooks"] as? [Any]) ?? []).contains {
                    isAgentBarCommand(($0 as? [String: Any])?["command"] as? String ?? "")
                }
            }
        }
    }

    /// Paths with spaces need quoting in a shell command.
    static func quote(_ path: String) -> String {
        path.contains(" ") ? "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'" : path
    }

    // MARK: File operations

    public static func read(_ path: String = defaultPath) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw SetupError.unreadable(error.localizedDescription) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw SetupError.unreadable("it isn't valid JSON") }
        guard let dict = object as? [String: Any] else { throw SetupError.notAnObject }
        return dict
    }

    /// Backs up the current file (`settings.json.agentbar-backup`), then writes atomically.
    public static func write(_ settings: [String: Any], to path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            let backup = path + ".agentbar-backup"
            try? FileManager.default.removeItem(atPath: backup)
            try FileManager.default.copyItem(atPath: path, toPath: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    public static func connectFile(cli: String, path: String = defaultPath) throws {
        try write(connect(try read(path), cli: cli), to: path)
    }

    public static func disconnectFile(path: String = defaultPath) throws {
        let current = try read(path)
        guard isConnected(current) else { return }
        try write(disconnect(current), to: path)
    }
}
