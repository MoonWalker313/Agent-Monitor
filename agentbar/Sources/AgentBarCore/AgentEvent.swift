import Foundation

/// Event kinds in schema v1 (see docs/event-schema.md).
public enum EventKind: String, Codable, CaseIterable, Sendable {
    case started
    case working
    case heartbeat
    case needsInput = "needs_input"
    case needsPermission = "needs_permission"
    case finished
    case error
    case stopped
}

/// Token/cost usage reported with an event. Values are deltas since the agent's last report.
public struct Usage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
    }

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
}

/// Details of a permission the agent is asking for, shown on the Allow/Deny card.
public struct PermissionRequestInfo: Codable, Equatable, Sendable {
    /// Unique per request within a session (e.g. a tool-use id).
    public var id: String
    /// Tool or capability, e.g. "Bash", "Edit", "WebFetch".
    public var tool: String?
    /// One-line, human-readable description of what the agent wants to do.
    public var summary: String?
    /// The exact thing being approved (command, file path, URL…). Shown in full, monospaced.
    public var detail: String?

    public init(id: String, tool: String? = nil, summary: String? = nil, detail: String? = nil) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.detail = detail
    }
}

/// The user's answer to a permission request.
public enum Decision: String, Codable, Sendable {
    case allow
    case deny
    /// Don't decide here: let the agent ask in its own UI (e.g. the terminal prompt).
    case deferred = "defer"
}

/// One event sent by an agent adapter. Wire format: one JSON object per line.
public struct AgentEvent: Codable, Equatable, Sendable {
    public var v: Int?
    public var agent: String
    public var sessionID: String
    public var event: EventKind
    /// ISO 8601. Optional; server time is used if missing or more than 5 minutes off.
    public var timestamp: String?
    public var title: String?
    public var message: String?
    public var cwd: String?
    public var openURL: String?
    public var activateBundleID: String?
    public var usage: Usage?
    /// Short description of what the agent just did ("Edited Socket.swift"). Kept as recent activity.
    public var activity: String?
    /// Permission details for `needs_permission`.
    public var request: PermissionRequestInfo?
    /// If set (with `needs_permission` + `request`), the connection stays open and the reply is sent
    /// when the user clicks Allow/Deny, or with `"decision":"defer"` after this many seconds (max 600).
    public var awaitSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case v, agent, event, timestamp, title, message, cwd, usage, activity, request
        case sessionID = "session_id"
        case openURL = "open_url"
        case activateBundleID = "activate_bundle_id"
        case awaitSeconds = "await_seconds"
    }

    public init(agent: String, sessionID: String, event: EventKind, title: String? = nil, message: String? = nil,
                cwd: String? = nil, openURL: String? = nil, activateBundleID: String? = nil, usage: Usage? = nil,
                timestamp: String? = nil, activity: String? = nil, request: PermissionRequestInfo? = nil,
                awaitSeconds: Int? = nil) {
        self.v = 1
        self.agent = agent
        self.sessionID = sessionID
        self.event = event
        self.title = title
        self.message = message
        self.cwd = cwd
        self.openURL = openURL
        self.activateBundleID = activateBundleID
        self.usage = usage
        self.timestamp = timestamp
        self.activity = activity
        self.request = request
        self.awaitSeconds = awaitSeconds
    }
}

/// Reply line the server writes back for every event line it receives.
public struct ServerReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    /// Optional fields that were dropped (e.g. a disallowed open_url). The event itself was accepted.
    public var warnings: [String]?
    public var running: Int?
    public var waiting: Int?
    /// For awaited permission requests: the user's answer.
    public var decision: Decision?
    /// For `deny`: text to pass back to the agent.
    public var decisionMessage: String?

    enum CodingKeys: String, CodingKey {
        case ok, error, warnings, running, waiting, decision
        case decisionMessage = "decision_message"
    }

    public init(ok: Bool, error: String? = nil, warnings: [String]? = nil, running: Int? = nil, waiting: Int? = nil,
                decision: Decision? = nil, decisionMessage: String? = nil) {
        self.ok = ok
        self.error = error
        self.warnings = warnings
        self.running = running
        self.waiting = waiting
        self.decision = decision
        self.decisionMessage = decisionMessage
    }

    public static func failure(_ message: String) -> ServerReply { ServerReply(ok: false, error: message) }
}

public enum EventValidationError: Error, Equatable, CustomStringConvertible {
    case invalidJSON(String)
    case unsupportedVersion(Int)
    case invalidField(String)
    case tooLarge
    case rateLimited

    public var description: String {
        switch self {
        case .invalidJSON(let why): return "invalid event JSON: \(why)"
        case .unsupportedVersion(let v): return "unsupported schema version \(v) (expected 1)"
        case .invalidField(let f): return "invalid or empty field '\(f)'"
        case .tooLarge: return "event exceeds \(EventCodec.maxLineBytes) bytes"
        case .rateLimited: return "rate limited: more than \(RateLimiter.defaultRate) events/s for this session"
        }
    }
}

/// A validated event plus the time it should be applied at and any non-fatal warnings.
public struct DecodedEvent: Equatable, Sendable {
    public var event: AgentEvent
    public var date: Date
    public var warnings: [String]
}

/// Decoding + validation + sanitizing. Everything arriving on the socket is untrusted.
/// Required fields that are invalid reject the event; optional fields that are invalid are
/// dropped with a warning so a slightly-off adapter still shows up.
public enum EventCodec {
    public static let maxLineBytes = 16 * 1024
    public static let maxIDLength = 128
    public static let maxTitleLength = 80
    public static let maxMessageLength = 280
    public static let maxCwdLength = 1024
    public static let maxClockSkew: TimeInterval = 5 * 60
    public static let maxTokensPerEvent = 10_000_000
    public static let maxCostPerEvent = 1_000.0
    public static let maxActivityLength = 120
    public static let maxToolLength = 64
    public static let maxDetailLength = 2_000
    public static let maxAwaitSeconds = 600

    public static func decode(_ data: Data, now: Date = Date()) throws -> DecodedEvent {
        guard data.count <= maxLineBytes else { throw EventValidationError.tooLarge }
        var event: AgentEvent
        do {
            event = try JSONDecoder().decode(AgentEvent.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw EventValidationError.invalidJSON("missing field '\(key.stringValue)'")
        } catch let DecodingError.dataCorrupted(ctx) {
            let field = ctx.codingPath.last?.stringValue
            throw EventValidationError.invalidJSON(field.map { "bad value for '\($0)'" } ?? "malformed JSON")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw EventValidationError.invalidJSON("wrong type for '\(ctx.codingPath.last?.stringValue ?? "?")'")
        } catch {
            throw EventValidationError.invalidJSON("malformed JSON")
        }
        if let v = event.v, v != 1 { throw EventValidationError.unsupportedVersion(v) }

        event.agent = Sanitizer.clean(event.agent, maxLength: maxIDLength)
        event.sessionID = Sanitizer.clean(event.sessionID, maxLength: maxIDLength)
        guard !event.agent.isEmpty else { throw EventValidationError.invalidField("agent") }
        guard !event.sessionID.isEmpty else { throw EventValidationError.invalidField("session_id") }

        var warnings: [String] = []
        event.title = cleanOptional(event.title, max: maxTitleLength)
        event.message = cleanOptional(event.message, max: maxMessageLength)

        if let cwd = cleanOptional(event.cwd, max: maxCwdLength) {
            if cwd.hasPrefix("/") { event.cwd = cwd } else { event.cwd = nil; warnings.append("cwd dropped: must be an absolute path") }
        } else {
            event.cwd = nil
        }

        if let raw = event.openURL {
            switch URLPolicy.evaluate(raw) {
            case .allowed(let url): event.openURL = url.absoluteString
            case .rejected(let why): event.openURL = nil; warnings.append("open_url dropped: \(why)")
            }
        }

        if let bundle = event.activateBundleID {
            if BundleIDPolicy.isValid(bundle) { event.activateBundleID = bundle } else {
                event.activateBundleID = nil; warnings.append("activate_bundle_id dropped: not a valid bundle identifier")
            }
        }

        if let usage = event.usage {
            let tokensOK = [usage.inputTokens, usage.outputTokens].allSatisfy { ($0 ?? 0) >= 0 && ($0 ?? 0) <= maxTokensPerEvent }
            let cost = usage.costUSD ?? 0
            let costOK = cost.isFinite && cost >= 0 && cost <= maxCostPerEvent
            if !(tokensOK && costOK) { event.usage = nil; warnings.append("usage dropped: values must be non-negative and within limits") }
        }

        event.activity = cleanOptional(event.activity, max: maxActivityLength)

        if var request = event.request {
            request.id = Sanitizer.clean(request.id, maxLength: maxIDLength)
            request.tool = cleanOptional(request.tool, max: maxToolLength)
            request.summary = cleanOptional(request.summary, max: maxMessageLength)
            request.detail = request.detail.map { Sanitizer.cleanMultiline($0, maxLength: maxDetailLength) }
                .flatMap { $0.isEmpty ? nil : $0 }
            if request.id.isEmpty {
                event.request = nil; warnings.append("request dropped: missing id")
            } else if event.event != .needsPermission {
                event.request = nil; warnings.append("request dropped: only valid with needs_permission")
            } else {
                event.request = request
            }
        }

        if let wait = event.awaitSeconds {
            if event.request == nil {
                event.awaitSeconds = nil; warnings.append("await_seconds dropped: needs needs_permission with a request")
            } else {
                event.awaitSeconds = min(max(wait, 1), maxAwaitSeconds)
            }
        }

        var date = now
        if let ts = event.timestamp {
            if let parsed = parseTimestamp(ts), abs(parsed.timeIntervalSince(now)) <= maxClockSkew {
                date = parsed
            } else {
                warnings.append("timestamp ignored: unparseable or more than 5 minutes off; using receive time")
            }
        }
        return DecodedEvent(event: event, date: date, warnings: warnings)
    }

    private static func cleanOptional(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        let cleaned = Sanitizer.clean(value, maxLength: max)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

public enum Sanitizer {
    /// Bidi override / isolate characters that can make text render misleadingly.
    private static let bidi: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F]

    /// Strips control and bidi characters, collapses whitespace, and truncates on
    /// grapheme-cluster boundaries (adding "…" when truncated).
    public static func clean(_ input: String, maxLength: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = false
        for s in input.unicodeScalars {
            if bidi.contains(s.value) { continue }
            if s.properties.isWhitespace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
                continue
            }
            let category = s.properties.generalCategory
            // Keep U+200D (zero-width joiner) so emoji sequences survive.
            if category == .control || (category == .format && s.value != 0x200D) { continue }
            scalars.append(s)
            lastWasSpace = false
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        guard cleaned.count > maxLength else { return cleaned }
        return String(cleaned.prefix(max(0, maxLength - 1))) + "…"
    }

    /// Like `clean`, but keeps line breaks (for commands and code shown on a permission card).
    public static func cleanMultiline(_ input: String, maxLength: Int, maxLines: Int = 40) -> String {
        var lines = input.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { clean(String($0), maxLength: maxLength) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        var truncated = false
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)); truncated = true }
        var joined = lines.joined(separator: "\n")
        if joined.count > maxLength { joined = String(joined.prefix(maxLength - 1)); truncated = true }
        return truncated ? joined + "…" : joined
    }
}
