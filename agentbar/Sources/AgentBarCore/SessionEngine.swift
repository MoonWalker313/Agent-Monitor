import Foundation

public enum SessionState: String, Sendable, CaseIterable, Codable {
    case waiting, running, stale, finished, errored, stopped

    /// Panel order: Needs you → Running → Finished → Errored → Stale → Stopped.
    public var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .running: return 1
        case .finished: return 2
        case .errored: return 3
        case .stale: return 4
        case .stopped: return 5
        }
    }

    /// States that end a session's day: rolled into history at midnight.
    public var isTerminal: Bool { self == .finished || self == .errored || self == .stopped }
}

public struct UsageTotals: Equatable, Sendable, Codable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var costUSD = 0.0
    public init(inputTokens: Int = 0, outputTokens: Int = 0, costUSD: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
    public var totalTokens: Int { inputTokens + outputTokens }
    public mutating func add(_ u: Usage) {
        inputTokens += u.inputTokens ?? 0
        outputTokens += u.outputTokens ?? 0
        costUSD += u.costUSD ?? 0
    }
}

public struct ActivityItem: Codable, Equatable, Sendable {
    public var text: String
    public var at: Date
    public init(text: String, at: Date) { self.text = text; self.at = at }
}

public struct Session: Identifiable, Equatable, Sendable {
    public static let maxRecentActivity = 20

    public var id: String { Session.key(agent: agent, sessionID: sessionID) }
    public var agent: String
    public var sessionID: String
    public var title: String?
    public var message: String?
    public var cwd: String?
    public var openURL: String?
    public var activateBundleID: String?
    public var state: SessionState
    public var stateEnteredAt: Date
    public var startedAt: Date
    public var updatedAt: Date
    public var usage = UsageTotals()
    /// Total time this session spent waiting on the user (closed intervals only).
    public var waitingSeconds: Double = 0
    /// Local day ("yyyy-MM-dd") this session was last counted in DailyTotals.sessions.
    public var countedDay: String?
    /// Open permission request awaiting Allow/Deny (not persisted: it dies with the agent's connection).
    public var pendingRequest: PermissionRequestInfo?
    /// Newest last, at most `maxRecentActivity`.
    public var recentActivity: [ActivityItem] = []

    mutating func addActivity(_ text: String, at date: Date) {
        recentActivity.append(ActivityItem(text: text, at: date))
        if recentActivity.count > Self.maxRecentActivity {
            recentActivity.removeFirst(recentActivity.count - Self.maxRecentActivity)
        }
    }

    public static func key(agent: String, sessionID: String) -> String { "\(agent)/\(sessionID)" }

    public init(agent: String, sessionID: String, state: SessionState, at date: Date) {
        self.agent = agent
        self.sessionID = sessionID
        self.state = state
        self.stateEnteredAt = date
        self.startedAt = date
        self.updatedAt = date
    }
}

/// "Today" numbers for the panel header (PRD P0-2).
public struct DailyTotals: Equatable, Sendable {
    public var day: String
    public var sessions = 0
    public var finished = 0
    /// Closed waiting intervals that ended today. Use `SessionEngine.waitingSecondsToday(now:)` for a live value.
    public var waitingSeconds = 0.0
    public var usage = UsageTotals()
    public var costAlerted = false
    public var tokensAlerted = false
    public init(day: String) { self.day = day }
}

public struct Summary: Equatable, Sendable {
    public var running = 0
    public var waiting = 0
    public var stale = 0
    public var finished = 0
    public var errored = 0
    public init() {}
    /// Count for the menu bar badge: everything that needs a human.
    public var needsAttention: Int { waiting + errored + stale }
}

public enum OverallStatus: Equatable, Sendable {
    case idle, working, attention
}

public enum Threshold: Equatable, Sendable {
    case cost(limitUSD: Double, actualUSD: Double)
    case tokens(limit: Int, actual: Int)
}

public struct EngineConfig: Equatable, Sendable {
    public var staleAfter: TimeInterval = 10 * 60
    public var staleAfterByAgent: [String: TimeInterval] = [:]
    /// A session that needs you (waiting, may be stuck, error) but has sent nothing for this long
    /// is treated as gone (the agent quit without saying so) and moves out of "Needs you".
    public var quietAfter: TimeInterval = 60 * 60
    public var dailyCostLimitUSD: Double?
    public var dailyTokenLimit: Int?
    public var calendar = Calendar.current

    public init(staleAfter: TimeInterval = 10 * 60, staleAfterByAgent: [String: TimeInterval] = [:],
                dailyCostLimitUSD: Double? = nil, dailyTokenLimit: Int? = nil, calendar: Calendar = .current) {
        self.staleAfter = staleAfter
        self.staleAfterByAgent = staleAfterByAgent
        self.dailyCostLimitUSD = dailyCostLimitUSD
        self.dailyTokenLimit = dailyTokenLimit
        self.calendar = calendar
    }

    public func staleTimeout(for agent: String) -> TimeInterval { staleAfterByAgent[agent] ?? staleAfter }

    public func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

public struct StateChange: Equatable, Sendable {
    public var session: Session
    public var old: SessionState?
    public var new: SessionState { session.state }
    public var stateChanged: Bool { old != new }
    /// True when the session just entered a state that should alert the user.
    public var enteredAttentionState: Bool {
        stateChanged && (new == .waiting || new == .finished || new == .errored || new == .stale)
    }
}

public struct EngineUpdate: Equatable, Sendable {
    /// Every session touched (including ones whose state didn't change).
    public var changes: [StateChange] = []
    public var thresholds: [Threshold] = []
    /// Session keys removed from the live view by a midnight rollover (they remain in history).
    public var rolledOver: [String] = []
    public var totalsChanged = false
    public init() {}
    public var isEmpty: Bool { changes.isEmpty && thresholds.isEmpty && rolledOver.isEmpty && !totalsChanged }
}

/// Pure, deterministic state machine (PRD P0-6, plan §4.4). Time is always passed in.
public struct SessionEngine: Sendable {
    public private(set) var sessions: [String: Session] = [:]
    public private(set) var totals: DailyTotals
    public var config: EngineConfig

    public init(config: EngineConfig = EngineConfig(), now: Date = Date()) {
        self.config = config
        self.totals = DailyTotals(day: config.dayString(now))
    }

    /// Restores persisted state. Running/waiting sessions untouched for 24h come back as stale.
    public init(config: EngineConfig, restoring restored: [Session], totals: DailyTotals?, now: Date) {
        self.init(config: config, now: now)
        let today = config.dayString(now)
        if let totals, totals.day == today { self.totals = totals }
        for var s in restored {
            s.pendingRequest = nil // the agent's waiting connection didn't survive the restart
            if !s.state.isTerminal && s.state != .stale && now.timeIntervalSince(s.updatedAt) > 24 * 3600 {
                s.state = .stale
                s.stateEnteredAt = now
            }
            if s.state.isTerminal && config.dayString(s.updatedAt) != today { continue }
            sessions[s.id] = s
        }
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent, now: Date = Date()) -> EngineUpdate {
        var update = rollover(now: now)
        let key = Session.key(agent: event.agent, sessionID: event.sessionID)
        let existing = sessions[key]

        let newState: SessionState
        switch event.event {
        case .started, .working: newState = .running
        // A heartbeat proves the agent is alive. It revives a stale session but
        // never clears "needs you".
        case .heartbeat: newState = existing?.state == .waiting ? .waiting : .running
        case .needsInput, .needsPermission: newState = .waiting
        case .finished: newState = .finished
        case .error: newState = .errored
        case .stopped: newState = .stopped
        }

        var session = existing ?? Session(agent: event.agent, sessionID: event.sessionID, state: newState, at: now)
        let today = totals.day
        if session.countedDay != today {
            session.countedDay = today
            totals.sessions += 1
        }
        if let old = existing?.state, old != newState {
            if old == .waiting {
                let waited = max(0, now.timeIntervalSince(session.stateEnteredAt))
                session.waitingSeconds += waited
                totals.waitingSeconds += waited
            }
            session.stateEnteredAt = now
        }
        if newState == .finished && existing?.state != .finished { totals.finished += 1 }

        if let title = event.title { session.title = title }
        if let message = event.message {
            session.message = message
        } else if let summary = event.request?.summary {
            session.message = summary
        } else if event.event != .heartbeat && existing?.state != newState {
            session.message = nil // a new state without a message shouldn't keep the old state's text
        }
        if let activity = event.activity { session.addActivity(activity, at: now) }
        if let request = event.request {
            session.pendingRequest = request
        } else if newState != .waiting {
            session.pendingRequest = nil
        }
        if let cwd = event.cwd { session.cwd = cwd }
        if let url = event.openURL { session.openURL = url }
        if let bundle = event.activateBundleID { session.activateBundleID = bundle }
        if let usage = event.usage {
            session.usage.add(usage)
            totals.usage.add(usage)
            update.thresholds = checkThresholds()
        }
        session.state = newState
        session.updatedAt = max(session.updatedAt, now)
        sessions[key] = session
        update.changes.append(StateChange(session: session, old: existing?.state))
        update.totalsChanged = true
        return update
    }

    /// Records the user's answer to a pending permission request.
    /// - allow/deny: the agent continues, so the session goes back to running.
    /// - deferred (or the agent stopped waiting): the request card goes away but the session
    ///   stays waiting, because the agent will now ask in its own window.
    @discardableResult
    public mutating func resolveRequest(sessionKey: String, requestID: String, decision: Decision,
                                        now: Date = Date()) -> EngineUpdate {
        var update = EngineUpdate()
        guard var session = sessions[sessionKey], let request = session.pendingRequest, request.id == requestID else {
            return update
        }
        let old = session.state
        session.pendingRequest = nil
        let what = request.summary ?? request.tool ?? "request"
        switch decision {
        case .allow, .deny:
            if old == .waiting {
                let waited = max(0, now.timeIntervalSince(session.stateEnteredAt))
                session.waitingSeconds += waited
                totals.waitingSeconds += waited
                session.stateEnteredAt = now
            }
            session.state = .running
            session.message = decision == .allow ? "Allowed: \(what)" : "Denied: \(what)"
            session.addActivity(decision == .allow ? "You allowed: \(what)" : "You denied: \(what)", at: now)
            update.totalsChanged = true
        case .deferred:
            session.message = "Waiting for you in the agent's window: \(what)"
        }
        session.updatedAt = max(session.updatedAt, now)
        sessions[sessionKey] = session
        update.changes.append(StateChange(session: session, old: old))
        return update
    }

    /// Sessions with an open permission request, oldest first.
    public var pendingRequests: [Session] {
        sessions.values.filter { $0.pendingRequest != nil }.sorted { ($0.stateEnteredAt, $0.id) < ($1.stateEnteredAt, $1.id) }
    }

    /// Marks running sessions with no events for their stale timeout as stale (PRD P0-6), and
    /// retires sessions that have needed you but stayed silent for `quietAfter` (the agent most
    /// likely quit without saying so), so they stop asking for attention.
    @discardableResult
    public mutating func sweep(now: Date = Date()) -> EngineUpdate {
        var update = rollover(now: now)
        for (key, var session) in sessions where session.state == .running {
            if now.timeIntervalSince(session.updatedAt) >= config.staleTimeout(for: session.agent) {
                session.state = .stale
                session.stateEnteredAt = now
                sessions[key] = session
                update.changes.append(StateChange(session: session, old: .running))
            }
        }
        for (key, session) in sessions where [.waiting, .stale, .errored].contains(session.state) {
            if now.timeIntervalSince(session.updatedAt) >= config.quietAfter {
                let minutes = Int(config.quietAfter / 60)
                let quiet = minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes) min"
                update.changes.append(retire(key, message: "No activity for \(quiet), so it no longer needs you", now: now))
            }
        }
        return update
    }

    /// The user's "Dismiss": this session no longer needs them. Moves it to stopped without alerting.
    @discardableResult
    public mutating func dismiss(sessionKey: String, now: Date = Date()) -> EngineUpdate {
        var update = EngineUpdate()
        guard let s = sessions[sessionKey], s.state != .stopped else { return update }
        update.changes.append(retire(sessionKey, message: "Dismissed by you", activity: "You dismissed this", now: now))
        update.totalsChanged = true
        return update
    }

    private mutating func retire(_ key: String, message: String, activity: String? = nil, now: Date) -> StateChange {
        var session = sessions[key]!
        let old = session.state
        if old == .waiting {
            let waited = max(0, now.timeIntervalSince(session.stateEnteredAt))
            session.waitingSeconds += waited
            totals.waitingSeconds += waited
        }
        session.state = .stopped
        session.stateEnteredAt = now
        session.pendingRequest = nil
        session.message = message
        if let activity { session.addActivity(activity, at: now) }
        sessions[key] = session
        return StateChange(session: session, old: old)
    }

    /// At local midnight: reset totals and drop finished/errored/stopped sessions from the live view.
    private mutating func rollover(now: Date) -> EngineUpdate {
        var update = EngineUpdate()
        let today = config.dayString(now)
        guard today != totals.day else { return update }
        totals = DailyTotals(day: today)
        update.totalsChanged = true
        for (key, session) in sessions where session.state.isTerminal {
            sessions[key] = nil
            update.rolledOver.append(key)
        }
        return update
    }

    private mutating func checkThresholds() -> [Threshold] {
        var crossed: [Threshold] = []
        if let limit = config.dailyCostLimitUSD, !totals.costAlerted, totals.usage.costUSD >= limit {
            totals.costAlerted = true
            crossed.append(.cost(limitUSD: limit, actualUSD: totals.usage.costUSD))
        }
        if let limit = config.dailyTokenLimit, !totals.tokensAlerted, totals.usage.totalTokens >= limit {
            totals.tokensAlerted = true
            crossed.append(.tokens(limit: limit, actual: totals.usage.totalTokens))
        }
        return crossed
    }

    public mutating func removeAll(now: Date = Date()) {
        sessions.removeAll()
        totals = DailyTotals(day: config.dayString(now))
    }

    // MARK: Read-only views

    public var sortedSessions: [Session] {
        sessions.values.sorted { ($0.state.sortRank, $1.updatedAt, $0.id) < ($1.state.sortRank, $0.updatedAt, $1.id) }
    }

    public var summary: Summary {
        var s = Summary()
        for session in sessions.values {
            switch session.state {
            case .running: s.running += 1
            case .waiting: s.waiting += 1
            case .stale: s.stale += 1
            case .finished: s.finished += 1
            case .errored: s.errored += 1
            case .stopped: break
            }
        }
        return s
    }

    public var overall: OverallStatus {
        let s = summary
        if s.needsAttention > 0 { return .attention }
        if s.running > 0 { return .working }
        return .idle
    }

    /// Closed waits today plus the part of currently-open waits that falls today.
    public func waitingSecondsToday(now: Date = Date()) -> Double {
        let startOfDay = config.calendar.startOfDay(for: now)
        let open = sessions.values.filter { $0.state == .waiting }
            .reduce(0.0) { $0 + max(0, now.timeIntervalSince(max($1.stateEnteredAt, startOfDay))) }
        return totals.waitingSeconds + open
    }
}
