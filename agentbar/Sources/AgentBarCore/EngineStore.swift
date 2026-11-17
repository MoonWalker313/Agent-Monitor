import Foundation

/// Thread-safe owner of the engine + database.
/// - The socket queue applies events and gets a reply synchronously.
/// - Changes are persisted write-behind (batched every `flushInterval`) so a burst of
///   events costs one SQLite transaction, not one per event.
/// - A sweep timer marks silent sessions stale and handles midnight rollover.
public final class EngineStore: @unchecked Sendable {
    public static let defaultRetention: TimeInterval = 30 * 24 * 3600

    private var engine: SessionEngine
    private let lock = NSLock()
    private let database: SessionDatabase?
    private let dbQueue = DispatchQueue(label: "dev.agentbar.db")
    private let timerQueue = DispatchQueue(label: "dev.agentbar.sweep")
    private let flushInterval: TimeInterval
    private var retention: TimeInterval
    private let clock: @Sendable () -> Date

    private var dirtySessions: [String: Session] = [:]
    private var pendingEvents: [SessionDatabase.EventRecord] = []
    private var totalsDirty = false
    private var flushScheduled = false
    private var sweepTimer: DispatchSourceTimer?
    private var _lastPersistenceError: String?

    /// Called (off the main thread) after every apply/sweep that changed something.
    public var onUpdate: (@Sendable (EngineUpdate) -> Void)?

    /// - Parameter databasePath: nil keeps everything in memory (tests, or if the DB can't be opened).
    public init(config: EngineConfig = EngineConfig(), databasePath: String? = nil,
                retention: TimeInterval = EngineStore.defaultRetention, flushInterval: TimeInterval = 0.5,
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        self.flushInterval = flushInterval
        self.retention = retention
        self.clock = clock
        let now = clock()
        if let databasePath {
            let db = try SessionDatabase(path: databasePath)
            let startOfDay = config.calendar.startOfDay(for: now)
            let restored = try db.loadSessions(since: startOfDay)
            let totals = try db.loadTotals(day: config.dayString(now))
            self.engine = SessionEngine(config: config, restoring: restored, totals: totals, now: now)
            self.database = db
            pruneOldData(now: now)
        } else {
            self.engine = SessionEngine(config: config, now: now)
            self.database = nil
        }
    }

    deinit { sweepTimer?.cancel() }

    // MARK: Events

    @discardableResult
    public func apply(_ event: AgentEvent, at date: Date? = nil) -> (EngineUpdate, Summary) {
        let now = date ?? clock()
        lock.lock()
        let update = engine.apply(event, now: now)
        let summary = engine.summary
        record(update)
        pendingEvents.append(.init(date: now, agent: event.agent, sessionID: event.sessionID, kind: event.event))
        lock.unlock()
        scheduleFlush()
        if !update.isEmpty { onUpdate?(update) }
        return (update, summary)
    }

    @discardableResult
    public func resolveRequest(sessionKey: String, requestID: String, decision: Decision) -> EngineUpdate {
        lock.lock()
        let update = engine.resolveRequest(sessionKey: sessionKey, requestID: requestID, decision: decision, now: clock())
        record(update)
        lock.unlock()
        if !update.isEmpty {
            scheduleFlush()
            onUpdate?(update)
        }
        return update
    }

    @discardableResult
    public func dismiss(sessionKey: String) -> EngineUpdate {
        lock.lock()
        let update = engine.dismiss(sessionKey: sessionKey, now: clock())
        record(update)
        lock.unlock()
        if !update.isEmpty {
            scheduleFlush()
            onUpdate?(update)
        }
        return update
    }

    @discardableResult
    public func sweep() -> EngineUpdate {
        lock.lock()
        let update = engine.sweep(now: clock())
        record(update)
        lock.unlock()
        if !update.isEmpty {
            scheduleFlush()
            onUpdate?(update)
        }
        return update
    }

    /// Runs `sweep()` every `interval` seconds (default 30 s, plan §4.4). Call `sweep()`
    /// directly on wake from sleep.
    public func startSweeping(interval: TimeInterval = 30) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.sweep() }
        sweepTimer?.cancel()
        sweepTimer = timer
        timer.resume()
    }

    /// Changes how long history is kept and prunes anything older right away.
    public func setRetention(_ seconds: TimeInterval) {
        lock.lock(); retention = seconds; lock.unlock()
        pruneOldData(now: clock())
    }

    public func updateConfig(_ config: EngineConfig) {
        lock.lock(); engine.config = config; lock.unlock()
    }

    public func snapshot() -> SessionEngine {
        lock.lock(); defer { lock.unlock() }
        return engine
    }

    /// "Clear all data": live view and database.
    public func removeAll() throws {
        lock.lock()
        engine.removeAll(now: clock())
        dirtySessions.removeAll()
        pendingEvents.removeAll()
        totalsDirty = false
        lock.unlock()
        var thrown: Error?
        dbQueue.sync {
            do { try database?.clearAll() } catch { thrown = error }
        }
        if let thrown { throw thrown }
        var update = EngineUpdate()
        update.totalsChanged = true
        onUpdate?(update)
    }

    // MARK: Persistence

    public var lastPersistenceError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastPersistenceError
    }

    public var databaseForTesting: SessionDatabase? { database }

    /// Must be called with `lock` held.
    private func record(_ update: EngineUpdate) {
        guard database != nil else { return }
        for change in update.changes { dirtySessions[change.session.id] = change.session }
        if update.totalsChanged || !update.thresholds.isEmpty { totalsDirty = true }
    }

    private func scheduleFlush() {
        guard database != nil else { return }
        lock.lock()
        let shouldSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        dbQueue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in self?.flushOnQueue() }
    }

    /// Writes everything pending now (call on quit, and from tests).
    public func flush() {
        dbQueue.sync { flushOnQueue() }
    }

    private func flushOnQueue() {
        guard let database else { return }
        lock.lock()
        let sessions = Array(dirtySessions.values)
        let events = pendingEvents
        let totals = totalsDirty ? engine.totals : nil
        dirtySessions.removeAll()
        pendingEvents.removeAll()
        totalsDirty = false
        flushScheduled = false
        lock.unlock()
        guard !sessions.isEmpty || !events.isEmpty || totals != nil else { return }
        do {
            try database.save(sessions: sessions, totals: totals, events: events)
            lock.lock(); _lastPersistenceError = nil; lock.unlock()
        } catch {
            lock.lock(); _lastPersistenceError = "\(error)"; lock.unlock()
        }
    }

    private func pruneOldData(now: Date) {
        guard let database else { return }
        lock.lock()
        let cutoff = now.addingTimeInterval(-retention)
        let cutoffDay = engine.config.dayString(cutoff)
        lock.unlock()
        dbQueue.async { [weak self] in
            do { try database.prune(before: cutoff, cutoffDay: cutoffDay) } catch {
                guard let self else { return }
                self.lock.lock(); self._lastPersistenceError = "\(error)"; self.lock.unlock()
            }
        }
    }
}
