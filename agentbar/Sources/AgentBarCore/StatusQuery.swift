import Foundation

/// `{"query":"status"}` on the socket returns a snapshot for `agentbar status`.
/// Same-user only, like everything on the socket.
public struct StatusReport: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var agent: String
        public var sessionID: String
        public var project: String
        public var state: String
        public var message: String?
        public var lastTask: String?
        public var updatedAt: Date
        public var request: PermissionRequestInfo?

        enum CodingKeys: String, CodingKey {
            case agent, project, state, message, request
            case sessionID = "session_id"
            case lastTask = "last_task"
            case updatedAt = "updated_at"
        }
    }

    public var ok = true
    public var standingBy: Int
    public var needsYou: Int
    public var running: Int
    public var sessions: [Item]

    enum CodingKeys: String, CodingKey {
        case ok, running, sessions
        case standingBy = "standing_by"
        case needsYou = "needs_you"
    }

    public init(engine: SessionEngine) {
        let s = engine.summary
        standingBy = engine.pendingRequests.count
        needsYou = s.needsAttention - standingBy
        running = s.running
        // Same order as the panel: permission requests first, then everything else.
        let ordered = engine.pendingRequests + engine.sortedSessions.filter { $0.pendingRequest == nil }
        sessions = ordered.map { session in
            Item(agent: session.agent, sessionID: session.sessionID,
                 project: session.title ?? session.cwd.map { ($0 as NSString).lastPathComponent } ?? session.agent,
                 state: session.pendingRequest != nil ? "standing_by" : session.state.rawValue,
                 message: session.message, lastTask: session.recentActivity.last?.text,
                 updatedAt: session.updatedAt, request: session.pendingRequest)
        }
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum StatusQuery {
    public static let line = Data(#"{"query":"status"}"#.utf8)

    /// Returns the query name if this line is a query (`{"query": "..."}`), else nil.
    public static func queryName(_ line: Data) -> String? {
        guard line.count < 256, line.first == UInt8(ascii: "{"),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object.count == 1, let name = object["query"] as? String else { return nil }
        return name
    }

    /// Asks the running app for its status (used by `agentbar status`).
    public static func fetch(from path: String, timeout: TimeInterval = 2) throws -> StatusReport {
        let raw = try SocketClient.rawRequest(line, to: path, timeout: timeout)
        guard let report = try? StatusReport.decoder.decode(StatusReport.self, from: raw) else { throw SocketError.badReply }
        return report
    }
}
