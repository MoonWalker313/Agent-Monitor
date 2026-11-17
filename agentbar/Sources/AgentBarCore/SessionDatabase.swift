import Foundation
import SQLite3

/// Local SQLite store (PRD P0-7). Uses the system SQLite directly — no third-party dependency.
/// Privacy: the `events` log stores only kind + time, never titles, messages or paths.
public final class SessionDatabase {
    public static let schemaVersion: Int32 = 2
    public let path: String
    private var db: OpaquePointer?

    public struct EventRecord: Equatable, Sendable {
        public var date: Date
        public var agent: String
        public var sessionID: String
        public var kind: EventKind
        public init(date: Date, agent: String, sessionID: String, kind: EventKind) {
            self.date = date; self.agent = agent; self.sessionID = sessionID; self.kind = kind
        }
    }

    public enum DBError: Error, CustomStringConvertible {
        case open(String), sql(String, String)
        public var description: String {
            switch self {
            case .open(let m): return "could not open database: \(m)"
            case .sql(let q, let m): return "SQL error (\(m)) in: \(q.prefix(80))"
            }
        }
    }

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw DBError.open(msg)
        }
        chmod(path, 0o600)
        sqlite3_busy_timeout(db, 2_000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: Schema

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version")
        if version < 1 {
            try exec("""
            BEGIN;
            CREATE TABLE IF NOT EXISTS sessions(
                id TEXT PRIMARY KEY,
                agent TEXT NOT NULL,
                session_id TEXT NOT NULL,
                title TEXT, message TEXT, cwd TEXT, open_url TEXT, activate_bundle_id TEXT,
                state TEXT NOT NULL,
                state_entered_at REAL NOT NULL,
                started_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cost_usd REAL NOT NULL DEFAULT 0,
                waiting_seconds REAL NOT NULL DEFAULT 0,
                counted_day TEXT
            );
            CREATE INDEX IF NOT EXISTS sessions_updated ON sessions(updated_at);
            CREATE TABLE IF NOT EXISTS events(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                agent TEXT NOT NULL,
                session_id TEXT NOT NULL,
                kind TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
            CREATE TABLE IF NOT EXISTS daily_totals(
                day TEXT PRIMARY KEY,
                sessions INTEGER NOT NULL,
                finished INTEGER NOT NULL,
                waiting_seconds REAL NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cost_usd REAL NOT NULL,
                cost_alerted INTEGER NOT NULL,
                tokens_alerted INTEGER NOT NULL
            );
            PRAGMA user_version = 1;
            COMMIT;
            """)
        }
        if version < 2 {
            try exec("BEGIN; ALTER TABLE sessions ADD COLUMN recent_activity TEXT; PRAGMA user_version = 2; COMMIT;")
        }
        // Future migrations: `if version < 3 { ... PRAGMA user_version = 3 }`
    }

    // MARK: Writes

    /// Writes a batch in one transaction (write-behind from EngineStore).
    public func save(sessions: [Session], totals: DailyTotals?, events: [EventRecord]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            if !sessions.isEmpty {
                let stmt = try prepare("""
                INSERT INTO sessions(id, agent, session_id, title, message, cwd, open_url, activate_bundle_id, state,
                    state_entered_at, started_at, updated_at, input_tokens, output_tokens, cost_usd, waiting_seconds, counted_day,
                    recent_activity)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET title=excluded.title, message=excluded.message, cwd=excluded.cwd,
                    open_url=excluded.open_url, activate_bundle_id=excluded.activate_bundle_id, state=excluded.state,
                    state_entered_at=excluded.state_entered_at, updated_at=excluded.updated_at,
                    input_tokens=excluded.input_tokens, output_tokens=excluded.output_tokens, cost_usd=excluded.cost_usd,
                    waiting_seconds=excluded.waiting_seconds, counted_day=excluded.counted_day,
                    recent_activity=excluded.recent_activity
                """)
                defer { sqlite3_finalize(stmt) }
                for s in sessions {
                    bind(stmt, 1, s.id); bind(stmt, 2, s.agent); bind(stmt, 3, s.sessionID)
                    bind(stmt, 4, s.title); bind(stmt, 5, s.message); bind(stmt, 6, s.cwd)
                    bind(stmt, 7, s.openURL); bind(stmt, 8, s.activateBundleID); bind(stmt, 9, s.state.rawValue)
                    bind(stmt, 10, s.stateEnteredAt); bind(stmt, 11, s.startedAt); bind(stmt, 12, s.updatedAt)
                    bind(stmt, 13, s.usage.inputTokens); bind(stmt, 14, s.usage.outputTokens); bind(stmt, 15, s.usage.costUSD)
                    bind(stmt, 16, s.waitingSeconds); bind(stmt, 17, s.countedDay)
                    bind(stmt, 18, Self.encodeActivity(s.recentActivity))
                    try step(stmt, "upsert session")
                }
            }
            if !events.isEmpty {
                let stmt = try prepare("INSERT INTO events(ts, agent, session_id, kind) VALUES(?,?,?,?)")
                defer { sqlite3_finalize(stmt) }
                for e in events {
                    bind(stmt, 1, e.date); bind(stmt, 2, e.agent); bind(stmt, 3, e.sessionID); bind(stmt, 4, e.kind.rawValue)
                    try step(stmt, "insert event")
                }
            }
            if let t = totals {
                let stmt = try prepare("""
                INSERT OR REPLACE INTO daily_totals(day, sessions, finished, waiting_seconds, input_tokens, output_tokens,
                    cost_usd, cost_alerted, tokens_alerted) VALUES(?,?,?,?,?,?,?,?,?)
                """)
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, t.day); bind(stmt, 2, t.sessions); bind(stmt, 3, t.finished); bind(stmt, 4, t.waitingSeconds)
                bind(stmt, 5, t.usage.inputTokens); bind(stmt, 6, t.usage.outputTokens); bind(stmt, 7, t.usage.costUSD)
                bind(stmt, 8, t.costAlerted ? 1 : 0); bind(stmt, 9, t.tokensAlerted ? 1 : 0)
                try step(stmt, "save totals")
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Retention (PRD P0-7, default 30 days).
    public func prune(before cutoff: Date, cutoffDay: String) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for (sql, label) in [("DELETE FROM events WHERE ts < ?", "prune events"),
                                 ("DELETE FROM sessions WHERE updated_at < ?", "prune sessions")] {
                let stmt = try prepare(sql)
                defer { sqlite3_finalize(stmt) }
                bind(stmt, 1, cutoff)
                try step(stmt, label)
            }
            let stmt = try prepare("DELETE FROM daily_totals WHERE day < ?")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, cutoffDay)
            try step(stmt, "prune totals")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// "Clear all data" (PRD P0-7).
    public func clearAll() throws {
        try exec("BEGIN IMMEDIATE; DELETE FROM sessions; DELETE FROM events; DELETE FROM daily_totals; COMMIT;")
        try exec("VACUUM")
    }

    // MARK: Reads

    /// Sessions that should be visible now: anything not finished/errored/stopped, plus anything touched since `since`.
    public func loadSessions(since: Date) throws -> [Session] {
        let stmt = try prepare("""
        SELECT agent, session_id, title, message, cwd, open_url, activate_bundle_id, state, state_entered_at, started_at,
               updated_at, input_tokens, output_tokens, cost_usd, waiting_seconds, counted_day, recent_activity
        FROM sessions WHERE state IN ('running','waiting','stale') OR updated_at >= ?
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, since)
        var result: [Session] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let state = SessionState(rawValue: text(stmt, 7) ?? "") else { continue }
            var s = Session(agent: text(stmt, 0) ?? "", sessionID: text(stmt, 1) ?? "", state: state, at: date(stmt, 9))
            s.title = text(stmt, 2); s.message = text(stmt, 3); s.cwd = text(stmt, 4)
            s.openURL = text(stmt, 5); s.activateBundleID = text(stmt, 6)
            s.stateEnteredAt = date(stmt, 8); s.updatedAt = date(stmt, 10)
            s.usage = UsageTotals(inputTokens: Int(sqlite3_column_int64(stmt, 11)), outputTokens: Int(sqlite3_column_int64(stmt, 12)),
                                  costUSD: sqlite3_column_double(stmt, 13))
            s.waitingSeconds = sqlite3_column_double(stmt, 14)
            s.countedDay = text(stmt, 15)
            s.recentActivity = Self.decodeActivity(text(stmt, 16))
            result.append(s)
        }
        return result
    }

    public func loadTotals(day: String) throws -> DailyTotals? {
        let stmt = try prepare("""
        SELECT sessions, finished, waiting_seconds, input_tokens, output_tokens, cost_usd, cost_alerted, tokens_alerted
        FROM daily_totals WHERE day = ?
        """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, day)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var t = DailyTotals(day: day)
        t.sessions = Int(sqlite3_column_int64(stmt, 0))
        t.finished = Int(sqlite3_column_int64(stmt, 1))
        t.waitingSeconds = sqlite3_column_double(stmt, 2)
        t.usage = UsageTotals(inputTokens: Int(sqlite3_column_int64(stmt, 3)), outputTokens: Int(sqlite3_column_int64(stmt, 4)),
                              costUSD: sqlite3_column_double(stmt, 5))
        t.costAlerted = sqlite3_column_int(stmt, 6) != 0
        t.tokensAlerted = sqlite3_column_int(stmt, 7) != 0
        return t
    }

    public func count(_ table: String) throws -> Int {
        precondition(["sessions", "events", "daily_totals"].contains(table))
        return try scalarInt("SELECT COUNT(*) FROM \(table)")
    }

    private static func encodeActivity(_ items: [ActivityItem]) -> String? {
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeActivity(_ text: String?) -> [ActivityItem] {
        guard let text, let items = try? JSONDecoder().decode([ActivityItem].self, from: Data(text.utf8)) else { return [] }
        return items
    }

    // MARK: SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.sql(sql, msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sql(sql, String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?, _ label: String) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.sql(label, String(cString: sqlite3_errmsg(db))) }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw DBError.sql(sql, String(cString: sqlite3_errmsg(db))) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(stmt, i, v, -1, Self.transient) } else { sqlite3_bind_null(stmt, i) }
    }
    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: Int) { sqlite3_bind_int64(stmt, i, Int64(v)) }
    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: Double) { sqlite3_bind_double(stmt, i, v) }
    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: Date) { sqlite3_bind_double(stmt, i, v.timeIntervalSince1970) }

    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_text(stmt, i).map { String(cString: $0) }
    }
    private func date(_ stmt: OpaquePointer?, _ i: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
    }
}
