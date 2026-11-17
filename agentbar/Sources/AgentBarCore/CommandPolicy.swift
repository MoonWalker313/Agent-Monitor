import Foundation

/// Decides whether a shell command is routine: it only reads, so the user doesn't need to approve it.
///
/// Cursor and Antigravity run their approval hook before *every* terminal command, including ones
/// they'd run without asking. With "Only ask about commands that change things" on, AgentBar lets
/// routine commands through without a popup and still records them as activity.
///
/// The check is deliberately strict; anything it doesn't fully understand counts as a change and is
/// asked about: unknown programs, paths to programs, writes (`>`), substitutions (`$(…)`, backticks),
/// variables (`$X`, which could leak secrets), background jobs, and reads of credential files.
public enum CommandPolicy {
    public static let maxLength = 400

    /// The app's setting (Settings › Alerts), shared with the `agentbar` hooks through its preferences.
    public static let preferenceKey = "autoAllowReadOnly"
    public static let preferencesDomain = "dev.agentbar.AgentBar"

    /// On unless the user turned it off. AGENTBAR_AUTO_ALLOW_READONLY=0/1 overrides it (tests).
    public static var autoAllowEnabled: Bool {
        if let v = ProcessInfo.processInfo.environment["AGENTBAR_AUTO_ALLOW_READONLY"], !v.isEmpty { return v == "1" }
        return UserDefaults(suiteName: preferencesDomain)?.object(forKey: preferenceKey) as? Bool ?? true
    }

    /// Programs that only read or print.
    static let readOnlyPrograms: Set<String> = [
        "ls", "pwd", "cd", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "ag", "echo", "printf",
        "which", "type", "whoami", "id", "date", "cal", "file", "stat", "du", "df", "tree", "sort", "uniq",
        "cut", "tr", "basename", "dirname", "realpath", "readlink", "true", "uname", "sw_vers",
        "diff", "cmp", "column", "nl", "jq", "md5", "shasum", "sha256sum", "md5sum", "fd", "lsof", "ps",
        "uptime", "test", "[",
    ]

    /// git subcommands that only read. `git branch` and `git remote` are handled separately.
    static let readOnlyGit: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "reflog",
    ]

    /// Options of `find` that run something or write files.
    static let findWrites: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]

    /// Options that make an otherwise read-only program write a file or run another program.
    static let writingOptions: [String: [String]] = [
        "sort": ["-o", "--output"], "tree": ["-o"], "rg": ["--pre"], "fd": ["-x", "-X", "--exec", "--exec-batch"],
        "date": ["-s", "-f"], "file": ["-C"], "jq": ["--rawfile", "--slurpfile"],
    ]

    /// Text that suggests credentials or secrets: reading these still asks.
    static let sensitive = [
        ".ssh", ".aws", ".gnupg", ".env", "id_rsa", "id_ed25519", "id_ecdsa", ".netrc", "keychain", "credential",
        ".npmrc", ".pypirc", ".kube", ".docker/config", "secret", "token", "password", "passwd", ".pem", ".key",
        "printenv", "history",
    ]

    /// Redirects that don't write anywhere meaningful.
    private static let harmlessRedirect = try! NSRegularExpression(pattern: #"\s*(?:[12&]?>>?\s*/dev/null|[12]>&[12])"#)

    public static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return false }
        let lower = trimmed.lowercased()
        if sensitive.contains(where: lower.contains) { return false }
        var text = harmlessRedirect.stringByReplacingMatches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed),
                                                             withTemplate: "")
        // Anything that writes, substitutes, expands or escapes the simple parse below.
        for bad in [">", "<", "`", "$", "\n", "\r", "\\", "!", "{", "}", "(", ")"] where text.contains(bad) { return false }
        // Split into simple commands on && || ; |  (a lone & would background a job).
        for op in ["&&", "||", ";", "|"] { text = text.replacingOccurrences(of: op, with: "\u{0}") }
        if text.contains("&") { return false }
        let segments = text.split(separator: "\u{0}", omittingEmptySubsequences: false)
        return segments.allSatisfy { isReadOnlySegment(String($0)) }
    }

    private static func isReadOnlySegment(_ segment: String) -> Bool {
        let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let program = words.first else { return false } // empty segment: `a && && b`, trailing `|`
        // Quotes would need real shell parsing; a quoted operator splits wrongly. Allow plain quoted
        // arguments, but never a quote in the program name.
        if program.contains("\"") || program.contains("'") || program.contains("/") || program.contains("=") { return false }
        let args = Array(words.dropFirst())
        if args.count == 1, ["--version", "-v", "-V", "--help", "-h"].contains(args[0]),
           program.range(of: #"^[a-z0-9._+-]+$"#, options: .regularExpression) != nil {
            return true
        }
        switch program {
        case "find":
            return !args.contains(where: { findWrites.contains($0) })
        case "git":
            guard let sub = args.first else { return false }
            let rest = args.dropFirst()
            if rest.contains(where: { $0.hasPrefix("--output") || $0 == "-o" || $0.hasPrefix("--exec") || $0 == "--ext-diff" }) { return false }
            if readOnlyGit.contains(sub) { return true }
            if sub == "branch" { return rest.allSatisfy { ["-a", "-r", "-v", "-vv", "--list", "--show-current", "-l", "--all"].contains($0) } }
            if sub == "remote" { return rest.allSatisfy { $0 == "-v" } }
            return false
        case "uniq":
            // `uniq in out` writes `out`.
            return args.filter { !$0.hasPrefix("-") }.count <= 1
        default:
            guard readOnlyPrograms.contains(program) else { return false }
            let bad = writingOptions[program] ?? []
            return !args.contains { arg in bad.contains { arg == $0 || arg.hasPrefix($0 + "=") || ($0.count == 2 && arg.hasPrefix($0)) } }
        }
    }
}
