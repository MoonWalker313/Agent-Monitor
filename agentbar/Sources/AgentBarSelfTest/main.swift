import Foundation
import AgentBarCore

// Minimal test runner (no XCTest / Swift Testing: those need full Xcode).
// Run: swift run agentbar-selftest            (add -c release to test optimized code)
//      AGENTBAR_CLI=path/to/agentbar ...      also runs the CLI end-to-end suite

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () throws -> Bool, _ name: String, line: Int = #line) {
    do {
        if try condition() { passed += 1; return }
        print("  ✗ \(name) (line \(line))")
    } catch {
        print("  ✗ \(name) threw \(error) (line \(line))")
    }
    failures += 1
}

func checkThrows<E: Error & Equatable>(_ expected: E, _ name: String, line: Int = #line, _ body: () throws -> Void) {
    do {
        try body()
        print("  ✗ \(name): did not throw (line \(line))"); failures += 1
    } catch let error as E where error == expected {
        passed += 1
    } catch {
        print("  ✗ \(name): threw \(error), expected \(expected) (line \(line))"); failures += 1
    }
}

func checkThrowsAny(_ name: String, line: Int = #line, _ body: () throws -> Void) {
    do { try body(); print("  ✗ \(name): did not throw (line \(line))"); failures += 1 } catch { passed += 1 }
}

func suite(_ name: String, _ body: () throws -> Void) {
    print("• \(name)")
    do { try body() } catch { print("  ✗ suite threw \(error)"); failures += 1 }
}

func decode(_ json: String, now: Date = Date()) throws -> DecodedEvent { try EventCodec.decode(Data(json.utf8), now: now) }

// Deterministic calendar for day/rollover tests.
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let t0 = ISO8601DateFormatter().date(from: "2026-11-16T10:00:00Z")!
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
func ev(_ kind: EventKind, _ session: String = "s1", agent: String = "a", usage: Usage? = nil, message: String? = nil) -> AgentEvent {
    AgentEvent(agent: agent, sessionID: session, event: kind, message: message, usage: usage)
}
func state(_ update: EngineUpdate) -> SessionState? { update.changes.last?.new }

func tempDir() -> String {
    let dir = "/tmp/agentbar-test-\(getpid())-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
func cleanup(_ dir: String) { try? FileManager.default.removeItem(atPath: dir) }

// MARK: - Codec & policies

suite("codec") {
    let e = try decode(#"{"v":1,"agent":"claude-code","session_id":"abc","event":"needs_permission","message":"Run npm install?"}"#)
    check(e.event.agent == "claude-code" && e.event.sessionID == "abc", "decodes ids")
    check(e.event.event == .needsPermission && e.event.message == "Run npm install?", "decodes kind + message")
    check(e.warnings.isEmpty, "no warnings for a clean event")
    check(try decode(#"{"agent":"a","session_id":"s","event":"started","future_field":42,"reply_channel":"x"}"#).event.event == .started,
          "ignores unknown/reserved fields, v optional")

    for bad in [#"not json"#, #"{"agent":"a","event":"started"}"#,
                #"{"agent":"a","session_id":"s","event":"exploded"}"#, #"{"agent":"   ","session_id":"s","event":"started"}"#,
                #"{"agent":"a","session_id":"s","event":"started","usage":"lots"}"#] {
        checkThrowsAny("rejects \(bad)") { _ = try decode(bad) }
    }
    checkThrows(EventValidationError.unsupportedVersion(2), "rejects v2") {
        _ = try decode(#"{"v":2,"agent":"a","session_id":"s","event":"started"}"#)
    }
    let big = String(repeating: "x", count: EventCodec.maxLineBytes)
    checkThrows(EventValidationError.tooLarge, "rejects >16KB") {
        _ = try decode(#"{"agent":"a","session_id":"s","event":"started","message":"\#(big)"}"#)
    }
}

suite("codec: optional fields are dropped with warnings, not rejected") {
    let now = t0
    let good = try decode(#"{"agent":"a","session_id":"s","event":"working","timestamp":"2026-11-16T09:58:00Z","cwd":"/Users/me/code","open_url":"vscode://file/Users/me/code","activate_bundle_id":"com.googlecode.iterm2","usage":{"input_tokens":10,"output_tokens":5,"cost_usd":0.01}}"#, now: now)
    check(good.warnings.isEmpty, "all valid optionals accepted (got \(good.warnings))")
    check(good.date == at(-120), "in-range timestamp is used")
    check(good.event.cwd == "/Users/me/code" && good.event.activateBundleID == "com.googlecode.iterm2", "cwd + bundle id kept")
    check(good.event.usage == Usage(inputTokens: 10, outputTokens: 5, costUSD: 0.01), "usage kept")

    let frac = try decode(#"{"agent":"a","session_id":"s","event":"working","timestamp":"2026-11-16T10:00:01.500Z"}"#, now: now)
    check(frac.date == at(1.5) && frac.warnings.isEmpty, "fractional-second timestamp")

    let off = try decode(#"{"agent":"a","session_id":"s","event":"working","timestamp":"2020-01-01T00:00:00Z"}"#, now: now)
    check(off.date == now && off.warnings.count == 1, "far-off timestamp → receive time + warning")

    let bad = try decode(#"{"agent":"a","session_id":"s","event":"working","cwd":"relative/path","open_url":"file:///etc/passwd","activate_bundle_id":"not a bundle","usage":{"input_tokens":-5}}"#, now: now)
    check(bad.event.cwd == nil && bad.event.openURL == nil && bad.event.activateBundleID == nil && bad.event.usage == nil,
          "invalid optionals dropped")
    check(bad.warnings.count == 4, "one warning per dropped field (got \(bad.warnings.count))")
    check(bad.event.event == .working, "event itself still accepted")
}

suite("URL policy") {
    let allowed = ["https://github.com/org/repo/pull/1", "vscode://file/Users/me/x", "cursor://file/x", "iterm2://open?x=1",
                   "HTTPS://example.com", "x-github-client://openRepo/https://github.com/a/b"]
    for u in allowed {
        if case .allowed = URLPolicy.evaluate(u) { passed += 1 } else { print("  ✗ should allow \(u)"); failures += 1 }
    }
    let rejected = ["file:///Applications/Calculator.app", "javascript:alert(1)", "data:text/html,hi", "http://example.com",
                    "/usr/bin/open", "ssh://host", "https://user:pw@example.com", "https:///nohost", "vscode://x y",
                    "https://example.com/\u{0007}", "smb://server/share", String(repeating: "a", count: 3000)]
    for u in rejected {
        if case .rejected = URLPolicy.evaluate(u) { passed += 1 } else { print("  ✗ should reject \(u.prefix(60))"); failures += 1 }
    }
}

suite("bundle id policy") {
    check(BundleIDPolicy.isValid("com.googlecode.iterm2"), "iterm2")
    check(BundleIDPolicy.isValid("com.microsoft.VSCode"), "vscode")
    check(BundleIDPolicy.isValid("dev.warp.Warp-Stable"), "hyphen allowed")
    for bad in ["iterm2", "com..x", ".com.x", "com.x.", "com.x/../y", "com.x;rm", "com.ex ample", "com.exämple"] {
        check(!BundleIDPolicy.isValid(bad), "rejects \(bad)")
    }
}

suite("sanitizer") {
    check(Sanitizer.clean("ok\u{202E}gnp.exe\u{0007}\n\tdone", maxLength: 80) == "okgnp.exe done", "strips bidi/control, collapses whitespace")
    let s = Sanitizer.clean(String(repeating: "👩‍💻", count: 10), maxLength: 5)
    check(s.count == 5 && s.hasSuffix("…"), "truncates on grapheme boundaries")
    let long = try decode(#"{"agent":"a","session_id":"s","event":"started","title":"\#(String(repeating: "t", count: 200))"}"#)
    check(long.event.title?.count == EventCodec.maxTitleLength, "title capped at 80")
}

suite("rate limiter") {
    let limiter = RateLimiter(rate: 20, burst: 40)
    let allowedBurst = (0..<50).filter { _ in limiter.allow("k", now: t0) }.count
    check(allowedBurst == 40, "burst of 40 allowed, rest refused (got \(allowedBurst))")
    let afterHalfSecond = (0..<50).filter { _ in limiter.allow("k", now: at(0.5)) }.count
    check(afterHalfSecond == 10, "refills at 20/s (got \(afterHalfSecond))")
    check(limiter.allow("other", now: t0), "keys are independent")
    let small = RateLimiter(rate: 20, burst: 40, maxKeys: 10)
    for i in 0..<10 { _ = small.allow("k\(i)", now: t0) }
    _ = small.allow("late", now: at(10))
    check(small.trackedKeys < 11, "idle keys pruned (\(small.trackedKeys))")
}

// MARK: - Engine

suite("engine: lifecycle") {
    var engine = SessionEngine(config: EngineConfig(calendar: utc), now: t0)
    check(engine.overall == .idle, "starts idle")
    check(state(engine.apply(ev(.started), now: at(0))) == .running, "started → running")
    check(engine.overall == .working, "overall working")
    check(engine.apply(ev(.needsInput, message: "Which branch?"), now: at(10)).changes[0].enteredAttentionState, "needs_input alerts")
    check(engine.overall == .attention && engine.summary.waiting == 1, "overall attention")
    check(state(engine.apply(ev(.heartbeat), now: at(20))) == .waiting, "heartbeat keeps needs-you")
    check(engine.sessions["a/s1"]?.message == "Which branch?", "heartbeat keeps message")
    check(!engine.apply(ev(.needsPermission), now: at(25)).changes[0].enteredAttentionState, "no re-alert while waiting")
    check(state(engine.apply(ev(.working), now: at(70))) == .running, "working clears waiting")
    check(engine.sessions["a/s1"]?.message == nil, "new state without message clears old text")
    check(engine.sessions["a/s1"]?.waitingSeconds == 60, "waiting time accounted (\(engine.sessions["a/s1"]?.waitingSeconds ?? -1))")
    check(engine.apply(ev(.finished), now: at(80)).changes[0].enteredAttentionState, "finished alerts")
    check(state(engine.apply(ev(.stopped), now: at(90))) == .stopped && engine.overall == .idle, "stopped → idle")
}

suite("engine: stale sweep") {
    var cfg = EngineConfig(staleAfter: 600, calendar: utc)
    cfg.staleAfterByAgent = ["slow-builder": 3600]
    var engine = SessionEngine(config: cfg, now: t0)
    engine.apply(ev(.working, "run"), now: at(0))
    engine.apply(ev(.working, "build", agent: "slow-builder"), now: at(0))
    engine.apply(ev(.needsInput, "wait"), now: at(0))
    check(engine.sweep(now: at(599)).changes.isEmpty, "nothing stale before timeout")
    let swept = engine.sweep(now: at(600))
    check(swept.changes.map(\.session.sessionID) == ["run"] && swept.changes[0].enteredAttentionState, "running → stale at timeout, alerts")
    check(engine.sessions["slow-builder/build"]?.state == .running, "per-agent timeout respected")
    check(engine.sessions["a/wait"]?.state == .waiting, "waiting sessions never go stale")
    check(engine.summary.needsAttention == 2 && engine.overall == .attention, "stale counts as needing attention")
    check(engine.sweep(now: at(700)).changes.isEmpty, "stale doesn't re-alert")
    check(state(engine.apply(ev(.heartbeat, "run"), now: at(800))) == .running, "heartbeat revives stale")
    let hour = engine.sweep(now: at(3600))
    check(hour.changes.first(where: { $0.session.agent == "slow-builder" })?.new == .stale, "slow agent stale after its own timeout")
    check(hour.changes.first(where: { $0.session.sessionID == "wait" })?.new == .stopped, "a waiting session silent for 1 hr retires")
}

suite("engine: quiet sessions retire, dismiss") {
    var engine = SessionEngine(config: EngineConfig(staleAfter: 600, calendar: utc), now: t0)
    engine.apply(ev(.needsInput, "ask"), now: at(0))
    engine.apply(ev(.working, "run"), now: at(0))
    engine.apply(ev(.error, "err"), now: at(0))
    engine.apply(ev(.working, "busy"), now: at(0))
    engine.sweep(now: at(600))
    check(engine.sessions["a/run"]?.state == .stale, "running goes stale first")
    check(engine.apply(ev(.heartbeat, "busy"), now: at(3200)).changes.first?.new == .running, "a live agent keeps working")
    let retired = engine.sweep(now: at(3600))
    check(Set(retired.changes.map(\.session.sessionID)) == ["ask", "run", "err"], "silent needs-you sessions retire after 1 hr (\(retired.changes.map(\.session.sessionID)))")
    check(retired.changes.allSatisfy { $0.new == .stopped && !$0.enteredAttentionState }, "retiring never alerts")
    check(engine.sessions["a/busy"]?.state == .running, "active session untouched")
    check(engine.summary.needsAttention == 0 && engine.overall == .working, "nothing needs you any more")
    check(engine.sessions["a/ask"]?.message?.contains("No activity for 1 hr") == true, "retired message explains why")
    check(engine.totals.waitingSeconds == 3600, "the hour waiting is still counted")

    engine.apply(ev(.needsInput, "ask2"), now: at(4000))
    let dismissed = engine.dismiss(sessionKey: "a/ask2", now: at(4010))
    check(dismissed.changes.first?.new == .stopped && engine.sessions["a/ask2"]?.recentActivity.last?.text == "You dismissed this",
          "dismiss stops it and records it")
    check(engine.dismiss(sessionKey: "a/ask2", now: at(4020)).isEmpty, "dismissing twice is a no-op")
    check(engine.dismiss(sessionKey: "a/missing", now: at(4020)).isEmpty, "unknown session is a no-op")
}

suite("engine: daily totals + thresholds") {
    var engine = SessionEngine(config: EngineConfig(dailyCostLimitUSD: 1.0, dailyTokenLimit: 1000, calendar: utc), now: t0)
    engine.apply(ev(.started, "x"), now: at(0))
    engine.apply(ev(.working, "x"), now: at(1))
    engine.apply(ev(.started, "y"), now: at(2))
    check(engine.totals.sessions == 2, "each session counted once per day")
    engine.apply(ev(.needsInput, "y"), now: at(10))
    check(engine.waitingSecondsToday(now: at(40)) == 30, "live waiting includes open waits")
    engine.apply(ev(.working, "y"), now: at(70))
    check(engine.totals.waitingSeconds == 60, "closed wait added to totals")
    engine.apply(ev(.finished, "x"), now: at(80))
    engine.apply(ev(.finished, "x"), now: at(81))
    check(engine.totals.finished == 1, "duplicate finished counted once")

    let first = engine.apply(ev(.working, "x", usage: Usage(inputTokens: 400, outputTokens: 100, costUSD: 0.6)), now: at(90))
    check(first.thresholds.isEmpty, "below thresholds")
    let cross = engine.apply(ev(.working, "y", usage: Usage(inputTokens: 400, outputTokens: 200, costUSD: 0.5)), now: at(91))
    check(cross.thresholds.count == 2, "cost and token thresholds cross (\(cross.thresholds))")
    let again = engine.apply(ev(.working, "y", usage: Usage(costUSD: 5)), now: at(92))
    check(again.thresholds.isEmpty, "each threshold alerts once per day")
    check(engine.totals.usage.totalTokens == 1100 && abs(engine.totals.usage.costUSD - 6.1) < 1e-9, "usage summed")
    check(engine.sessions["a/y"]?.usage.costUSD == 5.5, "per-session usage summed")
}

suite("engine: midnight rollover") {
    var engine = SessionEngine(config: EngineConfig(dailyCostLimitUSD: 1, calendar: utc), now: t0)
    engine.apply(ev(.working, "run"), now: at(0))
    engine.apply(ev(.finished, "done"), now: at(0))
    engine.apply(ev(.error, "err"), now: at(0))
    engine.apply(ev(.working, "x", usage: Usage(costUSD: 2)), now: at(0))
    let midnight = ISO8601DateFormatter().date(from: "2026-11-17T00:00:05Z")!
    let update = engine.sweep(now: midnight)
    check(Set(update.rolledOver) == ["a/done", "a/err"], "finished/errored rolled into history (\(update.rolledOver))")
    check(engine.totals.day == "2026-11-17" && engine.totals.sessions == 0 && engine.totals.usage.costUSD == 0, "totals reset")
    check(engine.sessions["a/run"] != nil, "live sessions carry over")
    engine.apply(ev(.working, "run"), now: midnight)
    check(engine.totals.sessions == 1, "carried-over session counted on its first event of the new day")
    check(engine.apply(ev(.working, "x", usage: Usage(costUSD: 2)), now: midnight).thresholds.count == 1, "threshold re-arms each day")
}

suite("engine: restore") {
    let old = at(-30 * 3600)
    var running = Session(agent: "a", sessionID: "old-run", state: .running, at: old)
    running.updatedAt = old
    var doneYesterday = Session(agent: "a", sessionID: "old-done", state: .finished, at: old)
    doneYesterday.updatedAt = old
    let fresh = Session(agent: "a", sessionID: "fresh", state: .waiting, at: at(-60))
    var totals = DailyTotals(day: "2026-11-16"); totals.sessions = 7
    let engine = SessionEngine(config: EngineConfig(calendar: utc), restoring: [running, doneYesterday, fresh], totals: totals, now: t0)
    check(engine.sessions["a/old-run"]?.state == .stale, "running untouched >24h restores as stale")
    check(engine.sessions["a/old-done"] == nil, "yesterday's finished session not restored")
    check(engine.sessions["a/fresh"]?.state == .waiting, "recent waiting session restored as is")
    check(engine.totals.sessions == 7, "today's totals restored")
    let stale = SessionEngine(config: EngineConfig(calendar: utc), restoring: [], totals: DailyTotals(day: "2026-11-15"), now: t0)
    check(stale.totals.day == "2026-11-16" && stale.totals.sessions == 0, "yesterday's totals ignored")
}

// MARK: - Database

suite("database") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sqlite"
    let db = try SessionDatabase(path: path)
    check((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600, "db file is 0600")

    var s = Session(agent: "claude-code", sessionID: "1", state: .waiting, at: t0)
    s.title = "repo"; s.message = "Run tests?"; s.cwd = "/x"; s.openURL = "vscode://file/x"; s.activateBundleID = "com.a.b"
    s.usage = UsageTotals(inputTokens: 5, outputTokens: 6, costUSD: 0.25); s.waitingSeconds = 12; s.countedDay = "2026-11-16"
    var totals = DailyTotals(day: "2026-11-16"); totals.sessions = 3; totals.finished = 1; totals.waitingSeconds = 42
    totals.usage = UsageTotals(inputTokens: 1, outputTokens: 2, costUSD: 3); totals.costAlerted = true
    try db.save(sessions: [s], totals: totals, events: [.init(date: t0, agent: "claude-code", sessionID: "1", kind: .needsInput)])

    let loaded = try db.loadSessions(since: t0)
    check(loaded == [s], "session round-trips exactly")
    check(try db.loadTotals(day: "2026-11-16") == totals, "totals round-trip")
    check(try db.loadTotals(day: "2026-11-15") == nil, "missing day → nil")
    check(try db.count("events") == 1, "event logged")

    s.state = .running; s.message = nil
    try db.save(sessions: [s], totals: nil, events: [])
    check(try db.loadSessions(since: t0).first?.state == .running && db.loadSessions(since: t0).first?.message == nil, "upsert updates")
    check(try db.count("sessions") == 1, "upsert doesn't duplicate")

    var oldDone = Session(agent: "a", sessionID: "old", state: .finished, at: at(-40 * 86400))
    oldDone.updatedAt = at(-40 * 86400)
    var oldTotals = DailyTotals(day: "2026-10-01"); oldTotals.sessions = 1
    try db.save(sessions: [oldDone], totals: oldTotals, events: [.init(date: at(-40 * 86400), agent: "a", sessionID: "old", kind: .finished)])
    check(try db.loadSessions(since: t0).count == 1, "old finished session not loaded as visible")
    try db.prune(before: at(-30 * 86400), cutoffDay: "2026-10-17")
    check(try db.count("sessions") == 1 && db.count("events") == 1 && db.count("daily_totals") == 1, "retention prunes >30 days")

    let reopened = try SessionDatabase(path: path)
    check(try reopened.count("sessions") == 1, "reopen keeps data (migrations are idempotent)")
    try reopened.clearAll()
    check(try reopened.count("sessions") == 0 && reopened.count("events") == 0 && reopened.count("daily_totals") == 0, "clear all")
}

suite("engine store: write-behind + restart") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sqlite"
    let cfg = EngineConfig(calendar: utc)
    do {
        let store = try EngineStore(config: cfg, databasePath: path, clock: { t0 })
        store.apply(ev(.started, "a"))
        store.apply(ev(.needsPermission, "b", usage: Usage(inputTokens: 100, costUSD: 0.5), message: "Deploy?"))
        store.apply(ev(.finished, "c"))
        store.flush()
        check(store.lastPersistenceError == nil, "no persistence error")
        check(try store.databaseForTesting?.count("events") == 3, "events persisted after flush")
    }
    let restarted = try EngineStore(config: cfg, databasePath: path, clock: { at(60) })
    let snap = restarted.snapshot()
    check(snap.sessions.count == 3, "sessions restored after restart")
    check(snap.sessions["a/b"]?.state == .waiting && snap.sessions["a/b"]?.message == "Deploy?", "state + message restored")
    check(snap.totals.sessions == 3 && snap.totals.finished == 1 && snap.totals.usage.costUSD == 0.5, "totals restored")
    try restarted.removeAll()
    check(try restarted.snapshot().sessions.isEmpty && restarted.databaseForTesting?.count("sessions") == 0, "removeAll clears db too")
}

suite("engine store: changing history length prunes right away") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sqlite"
    do {
        let old = try EngineStore(config: EngineConfig(calendar: utc), databasePath: path, clock: { at(-10 * 86400) })
        old.apply(ev(.finished, "old"))
        old.flush()
    }
    let store = try EngineStore(config: EngineConfig(calendar: utc), databasePath: path, clock: { t0 })
    store.flush()
    Thread.sleep(forTimeInterval: 0.2)
    check(try store.databaseForTesting?.count("events") == 1, "10-day-old event kept under 30-day retention")
    store.setRetention(7 * 86400)
    store.flush()
    Thread.sleep(forTimeInterval: 0.2)
    check(try store.databaseForTesting?.count("events") == 0, "switching to 7 days prunes it")
}

suite("engine store: onUpdate + sweep") {
    final class Box: @unchecked Sendable { var updates: [EngineUpdate] = []; let lock = NSLock() }
    final class Clock: @unchecked Sendable { var now = t0 }
    let box = Box(), clock = Clock()
    let store = try EngineStore(config: EngineConfig(staleAfter: 60, calendar: utc), clock: { clock.now })
    store.onUpdate = { u in box.lock.lock(); box.updates.append(u); box.lock.unlock() }
    store.apply(ev(.working))
    clock.now = at(61)
    let swept = store.sweep()
    check(swept.changes.first?.new == .stale, "store sweep marks stale")
    check(box.updates.count == 2, "onUpdate fired for apply and sweep (\(box.updates.count))")
    check(store.sweep().isEmpty && box.updates.count == 2, "empty sweep doesn't notify")
}

// MARK: - Socket

suite("socket: round trip, permissions, warnings") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/run/agentbar.sock"
    let store = try EngineStore()
    let server = SocketServer(path: path) { d in
        let (_, s) = store.apply(d.event, at: d.date)
        return ServerReply(ok: true, running: s.running, waiting: s.waiting)
    }
    try server.start()
    defer { server.stop() }

    let fm = FileManager.default
    check((try fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600, "socket is 0600")
    check((try fm.attributesOfItem(atPath: dir + "/run")[.posixPermissions] as? Int) == 0o700, "dir is 0700")

    let replies = try SocketClient.send([
        EventCodec.encodeLine(AgentEvent(agent: "a", sessionID: "1", event: .working)),
        EventCodec.encodeLine(AgentEvent(agent: "a", sessionID: "2", event: .needsInput, openURL: "file:///etc/passwd")),
        Data(#"{"garbage":true}"#.utf8),
    ], to: path)
    check(replies.count == 3, "one reply per line")
    guard replies.count == 3 else { return }
    check(replies[0].ok && replies[1].ok, "valid events accepted")
    check(replies[1].running == 1 && replies[1].waiting == 1, "reply carries counts")
    check(replies[1].warnings?.first?.hasPrefix("open_url dropped") == true, "warning returned for dropped open_url")
    check(store.snapshot().sessions["a/2"]?.openURL == nil, "disallowed URL never stored")
    check(!replies[2].ok, "invalid event rejected")
    check(server.rejectedPeers == 0, "same-UID peer accepted")
}

suite("socket: abuse + rate limit") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sock"
    let server = SocketServer(path: path) { _ in ServerReply(ok: true) }
    try server.start()
    defer { server.stop() }

    let huge = Data(repeating: 0x41, count: EventCodec.maxLineBytes * 2)
    check((try? SocketClient.send([huge], to: path))?.first?.ok == false, "oversized line rejected")
    let ok = try SocketClient.send([EventCodec.encodeLine(ev(.started))], to: path)
    check(ok.first?.ok == true, "still serving after abuse")

    let flood = try (0..<100).map { _ in try EventCodec.encodeLine(ev(.heartbeat, "flood")) }
    let floodReplies = try SocketClient.send(flood, to: path)
    let refused = floodReplies.filter { !$0.ok }.count
    check(floodReplies.count == 100 && refused >= 50, "single-session flood is rate limited (\(refused)/100 refused)")
    check(server.rateLimitedEvents == refused, "rate-limited events counted")
    check(try SocketClient.send([EventCodec.encodeLine(ev(.working, "other"))], to: path).first?.ok == true, "other sessions unaffected")

    let second = SocketServer(path: path) { _ in ServerReply(ok: true) }
    checkThrows(SocketError.alreadyRunning(path), "refuses to steal a live socket") { try second.start() }
}

suite("socket: client when app not running") {
    let path = tempDir() + "/missing.sock"
    checkThrows(SocketError.notRunning(path), "reports notRunning") { _ = try SocketClient.send([Data("{}".utf8)], to: path) }
}


// MARK: - Permission requests (Allow / Deny)

func permissionEvent(_ session: String = "s1", id: String = "r1", wait: Int? = nil) -> AgentEvent {
    AgentEvent(agent: "a", sessionID: session, event: .needsPermission,
               request: PermissionRequestInfo(id: id, tool: "Bash", summary: "Run: install deps", detail: "npm install\nnpm test"),
               awaitSeconds: wait)
}

suite("codec: permission request fields") {
    let e = try decode(#"{"agent":"a","session_id":"s","event":"needs_permission","await_seconds":9999,"activity":"Edited x","request":{"id":"r1","tool":"Bash","summary":"Run tests","detail":"line1\nline2\u202e evil"}}"#)
    check(e.event.request?.detail == "line1\nline2 evil", "detail keeps newlines, strips bidi (\(e.event.request?.detail ?? "nil"))")
    check(e.event.awaitSeconds == EventCodec.maxAwaitSeconds, "await_seconds clamped to 600")
    check(e.event.activity == "Edited x", "activity kept")
    let wrongKind = try decode(#"{"agent":"a","session_id":"s","event":"working","await_seconds":5,"request":{"id":"r1"}}"#)
    check(wrongKind.event.request == nil && wrongKind.event.awaitSeconds == nil && wrongKind.warnings.count == 2,
          "request/await only allowed with needs_permission")
    let noID = try decode(#"{"agent":"a","session_id":"s","event":"needs_permission","request":{"id":"  "}}"#)
    check(noID.event.request == nil && noID.warnings.first?.contains("missing id") == true, "request without id dropped")
    let long = Sanitizer.cleanMultiline(String(repeating: "x\n", count: 100), maxLength: 2000)
    check(long.split(separator: "\n").count == 40 && long.hasSuffix("…"), "multiline capped at 40 lines")
}

suite("engine: permission request lifecycle") {
    var engine = SessionEngine(config: EngineConfig(calendar: utc), now: t0)
    engine.apply(AgentEvent(agent: "a", sessionID: "s1", event: .working, activity: "Edited a.swift"), now: at(0))
    for i in 1...(Session.maxRecentActivity + 1) { engine.apply(AgentEvent(agent: "a", sessionID: "s1", event: .heartbeat, activity: "step \(i)"), now: at(Double(i) / 100)) }
    let kept = engine.sessions["a/s1"]?.recentActivity.map(\.text) ?? []
    check(kept.count == Session.maxRecentActivity && kept.first == "step 2" && kept.last == "step \(Session.maxRecentActivity + 1)",
          "keeps the last \(Session.maxRecentActivity) tasks, oldest dropped")

    engine.apply(permissionEvent(), now: at(10))
    let s = engine.sessions["a/s1"]
    check(s?.state == .waiting && s?.pendingRequest?.id == "r1", "request pending, session waiting")
    check(s?.message == "Run: install deps", "message falls back to request summary")
    check(engine.pendingRequests.map(\.id) == ["a/s1"], "listed in pendingRequests")
    check(engine.apply(AgentEvent(agent: "a", sessionID: "s1", event: .heartbeat), now: at(11)).changes[0].session.pendingRequest != nil,
          "heartbeat keeps the request")

    check(engine.resolveRequest(sessionKey: "a/s1", requestID: "other", decision: .allow, now: at(20)).isEmpty, "wrong id is a no-op")
    let allowed = engine.resolveRequest(sessionKey: "a/s1", requestID: "r1", decision: .allow, now: at(40))
    let after = allowed.changes.first?.session
    check(after?.state == .running && after?.pendingRequest == nil, "allow → running, card gone")
    check(after?.recentActivity.last?.text == "You allowed: Run: install deps", "allow recorded in activity")
    check(after?.waitingSeconds == 30, "waiting time accounted (\(after?.waitingSeconds ?? -1))")

    engine.apply(permissionEvent(id: "r2"), now: at(50))
    engine.resolveRequest(sessionKey: "a/s1", requestID: "r2", decision: .deny, now: at(51))
    check(engine.sessions["a/s1"]?.message?.hasPrefix("Denied:") == true && engine.sessions["a/s1"]?.state == .running, "deny → running")

    engine.apply(permissionEvent(id: "r3"), now: at(60))
    engine.resolveRequest(sessionKey: "a/s1", requestID: "r3", decision: .deferred, now: at(61))
    check(engine.sessions["a/s1"]?.state == .waiting && engine.sessions["a/s1"]?.pendingRequest == nil, "defer → card gone, still needs you")

    engine.apply(permissionEvent(id: "r4"), now: at(70))
    engine.apply(AgentEvent(agent: "a", sessionID: "s1", event: .working), now: at(71))
    check(engine.sessions["a/s1"]?.pendingRequest == nil, "agent moving on clears the request")

    engine.apply(permissionEvent(id: "r5"), now: at(80))
    let restored = SessionEngine(config: EngineConfig(calendar: utc), restoring: Array(engine.sessions.values), totals: nil, now: at(90))
    check(restored.sessions["a/s1"]?.pendingRequest == nil, "pending requests aren't restored after restart")
}

suite("database: activity + migration from v1") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/v1.sqlite"
    // Build a v1 database by hand (as M1 shipped it), then open it with the current code.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [path, """
    CREATE TABLE sessions(id TEXT PRIMARY KEY, agent TEXT NOT NULL, session_id TEXT NOT NULL, title TEXT, message TEXT, cwd TEXT,
      open_url TEXT, activate_bundle_id TEXT, state TEXT NOT NULL, state_entered_at REAL NOT NULL, started_at REAL NOT NULL,
      updated_at REAL NOT NULL, input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
      cost_usd REAL NOT NULL DEFAULT 0, waiting_seconds REAL NOT NULL DEFAULT 0, counted_day TEXT);
    CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, agent TEXT NOT NULL, session_id TEXT NOT NULL, kind TEXT NOT NULL);
    CREATE TABLE daily_totals(day TEXT PRIMARY KEY, sessions INTEGER NOT NULL, finished INTEGER NOT NULL, waiting_seconds REAL NOT NULL,
      input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, cost_usd REAL NOT NULL, cost_alerted INTEGER NOT NULL, tokens_alerted INTEGER NOT NULL);
    INSERT INTO sessions(id, agent, session_id, state, state_entered_at, started_at, updated_at) VALUES('a/old','a','old','running',\(t0.timeIntervalSince1970),\(t0.timeIntervalSince1970),\(t0.timeIntervalSince1970));
    PRAGMA user_version = 1;
    """]
    try p.run(); p.waitUntilExit()
    check(p.terminationStatus == 0, "built v1 fixture")

    let db = try SessionDatabase(path: path)
    let migrated = try db.loadSessions(since: t0)
    check(migrated.map(\.id) == ["a/old"] && migrated[0].recentActivity.isEmpty, "v1 data survives migration to v2")
    var s = migrated[0]
    s.recentActivity = [ActivityItem(text: "Ran tests", at: t0), ActivityItem(text: "Edited x", at: at(1))]
    s.pendingRequest = PermissionRequestInfo(id: "r")
    try db.save(sessions: [s], totals: nil, events: [])
    let reloaded = try db.loadSessions(since: t0)[0]
    check(reloaded.recentActivity == s.recentActivity, "recent activity round-trips")
    check(reloaded.pendingRequest == nil, "pending request is never persisted")
}

suite("socket: awaited permission requests") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sock"
    final class Ends: @unchecked Sendable { var list: [(SocketServer.AwaitInfo, SocketServer.AwaitEnd)] = []; let lock = NSLock() }
    let ends = Ends()
    let store = try EngineStore()
    let server = SocketServer(path: path) { d in
        let (_, s) = store.apply(d.event, at: d.date)
        return ServerReply(ok: true, running: s.running, waiting: s.waiting)
    }
    server.onAwaitEnded = { info, end in ends.lock.lock(); ends.list.append((info, end)); ends.lock.unlock() }
    try server.start()
    defer { server.stop() }

    func asyncRequest(_ event: AgentEvent, timeout: TimeInterval = 10) -> () -> ServerReply? {
        final class Box: @unchecked Sendable { var reply: ServerReply?; let done = DispatchSemaphore(value: 0) }
        let box = Box()
        let line = try! EventCodec.encodeLine(event)
        DispatchQueue.global().async { box.reply = try? SocketClient.request(line, to: path, timeout: timeout); box.done.signal() }
        return { box.done.wait(); return box.reply }
    }
    func waitUntil(_ cond: () -> Bool) { for _ in 0..<200 where !cond() { usleep(10_000) } }
    let info = SocketServer.AwaitInfo(sessionKey: "a/s1", requestID: "r1")

    // Allow, delivered after the 5 s idle timeout would have closed a normal connection.
    let allowReply = asyncRequest(permissionEvent(wait: 30))
    waitUntil { server.awaitingRequests == [info] }
    check(store.snapshot().sessions["a/s1"]?.pendingRequest?.id == "r1", "request shown while agent waits")
    Thread.sleep(forTimeInterval: SocketServer.clientTimeout + 0.5)
    check(server.awaitingRequests == [info], "waiting connection survives the idle timeout")
    check(server.resolve(info, decision: .allow), "resolve delivered")
    let r1 = allowReply()
    check(r1?.ok == true && r1?.decision == .allow, "agent receives allow")
    check(!server.resolve(info, decision: .deny), "second resolve is a no-op")

    // Deny with message.
    let denyReply = asyncRequest(permissionEvent(id: "r2", wait: 30))
    let info2 = SocketServer.AwaitInfo(sessionKey: "a/s1", requestID: "r2")
    waitUntil { server.awaitingRequests == [info2] }
    server.resolve(info2, decision: .deny, message: "nope")
    let r2 = denyReply()
    check(r2?.decision == .deny && r2?.decisionMessage == "nope", "agent receives deny + message")

    // Expiry → defer, and the app is told.
    let expiring = asyncRequest(permissionEvent(id: "r3", wait: 1))
    check(expiring()?.decision == .deferred, "no answer within await_seconds → defer")
    waitUntil { !ends.list.isEmpty }
    check(ends.list.first?.1 == .expired && ends.list.first?.0.requestID == "r3", "onAwaitEnded(.expired)")

    // Agent goes away (e.g. Claude Code cancelled the hook) → app is told.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { src in withUnsafeMutableBytes(of: &addr.sun_path) { strncpy($0.baseAddress!.assumingMemoryBound(to: CChar.self), src, 103) } }
    let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    let line = try EventCodec.encodeLine(permissionEvent(id: "r4", wait: 30))
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    let info4 = SocketServer.AwaitInfo(sessionKey: "a/s1", requestID: "r4")
    waitUntil { server.awaitingRequests.contains(info4) }
    close(fd)
    waitUntil { ends.list.count >= 2 }
    check(connected == 0 && ends.list.last?.1 == .agentGone && ends.list.last?.0 == info4, "onAwaitEnded(.agentGone) when agent disconnects")
    check(!server.resolve(info4, decision: .allow), "can't answer an agent that left")

    // Quitting AgentBar releases waiting agents with defer.
    let atQuit = asyncRequest(permissionEvent(id: "r5", wait: 30))
    waitUntil { !server.awaitingRequests.isEmpty }
    server.stop()
    check(atQuit()?.decision == .deferred, "stop() tells waiting agents to ask in their own UI")
}

// MARK: - M4: Claude setup, status, run

suite("Claude Code setup: connect / disconnect keep everything else") {
    let mine: [String: Any] = [
        "enabledPlugins": ["x@y": true],
        "hooks": ["PostToolUse": [["matcher": "Edit", "hooks": [["type": "command", "command": "/usr/local/bin/lint"]]]]],
    ]
    let cli = "/Applications/Agent Bar.app/Contents/Helpers/agentbar"
    let connected = ClaudeSetup.connect(mine, cli: cli)
    check(ClaudeSetup.isConnected(connected), "connected")
    let hooks = connected["hooks"] as? [String: Any] ?? [:]
    check(Set(hooks.keys) == Set(ClaudeSetup.events), "all 8 events hooked")
    let post = hooks["PostToolUse"] as? [[String: Any]] ?? []
    check(post.count == 2 && (post[0]["matcher"] as? String) == "Edit", "user's own hook kept, ours added after it")
    let permission = ((hooks["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first
    check((permission?["command"] as? String) == "'\(cli)' hook claude --wait 300" && (permission?["timeout"] as? Int) == 310,
          "path with spaces quoted; permission waits 300 s with a 310 s timeout")
    check((connected["enabledPlugins"] as? [String: Bool]) == ["x@y": true], "unrelated settings untouched")

    let twice = ClaudeSetup.connect(connected, cli: "/new/agentbar")
    let post2 = (twice["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]] ?? []
    check(post2.count == 2, "connecting again replaces ours instead of duplicating")

    let removed = ClaudeSetup.disconnect(twice)
    check(!ClaudeSetup.isConnected(removed), "disconnected")
    let left = removed["hooks"] as? [String: Any] ?? [:]
    check(Array(left.keys) == ["PostToolUse"] && (left["PostToolUse"] as? [Any])?.count == 1, "only the user's hook remains")
    check(ClaudeSetup.disconnect([:]).isEmpty, "disconnecting empty settings is a no-op")

    // File round trip with backup, in a temp folder.
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/settings.json"
    try Data(#"{"enabledPlugins":{"x@y":true}}"#.utf8).write(to: URL(fileURLWithPath: path))
    try ClaudeSetup.connectFile(cli: "/Applications/AgentBar.app/Contents/Helpers/agentbar", path: path)
    check(try ClaudeSetup.isConnected(ClaudeSetup.read(path)), "file connected")
    check(FileManager.default.fileExists(atPath: path + ".agentbar-backup"), "backup written")
    check(try String(contentsOfFile: path + ".agentbar-backup", encoding: .utf8).contains("enabledPlugins"), "backup is the original")
    try ClaudeSetup.disconnectFile(path: path)
    let after = try ClaudeSetup.read(path)
    check(after["hooks"] == nil && after["enabledPlugins"] != nil, "file disconnected, plugins kept")
    try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
    checkThrowsAny("refuses to rewrite a broken settings file") { try ClaudeSetup.connectFile(cli: "/x", path: path) }
    check(try String(contentsOfFile: path, encoding: .utf8) == "not json", "broken file left as it was")
}

suite("status query") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sock"
    let store = try EngineStore()
    let server = SocketServer(path: path) { d in
        let (_, s) = store.apply(d.event, at: d.date)
        return ServerReply(ok: true, running: s.running, waiting: s.waiting)
    }
    server.onQuery = { name in name == "status" ? try? StatusReport.encoder.encode(StatusReport(engine: store.snapshot())) : nil }
    try server.start()
    defer { server.stop() }
    store.apply(ev(.working, "r"))
    store.apply(permissionEvent("p"))
    store.apply(ev(.needsInput, "q", message: "Which branch?"))
    for i in 0..<60 { store.apply(AgentEvent(agent: "bulk", sessionID: "b\(i)", event: .finished, message: String(repeating: "m", count: 250))) }
    let report = try StatusQuery.fetch(from: path)
    check(report.standingBy == 1 && report.needsYou == 1 && report.running == 1, "counts (\(report.standingBy)/\(report.needsYou)/\(report.running))")
    check(report.sessions.first?.state == "standing_by" && report.sessions.first?.request?.id == "r1", "standing-by request first")
    check(report.sessions.count == 63, "large status (~20 KB) arrives whole")
    let unknown = try SocketClient.send([Data(#"{"query":"nope"}"#.utf8)], to: path)
    check(unknown.first?.ok == false, "unknown query refused")
    checkThrows(SocketError.notRunning(dir + "/none.sock"), "status when not running") { _ = try StatusQuery.fetch(from: dir + "/none.sock") }
}

// MARK: - Security regressions

suite("security: requests can't be swapped or hijacked") {
    // A request without await_seconds never becomes an Allow/Deny card.
    let noWait = try decode(#"{"agent":"a","session_id":"s","event":"needs_permission","request":{"id":"r","summary":"Run: ls","detail":"ls"}}"#)
    check(noWait.event.request == nil && noWait.event.message == "Run: ls" && !noWait.warnings.isEmpty, "unawaited request shown as a message only")

    // The engine keeps the first content for an open request id.
    var engine = SessionEngine(config: EngineConfig(calendar: utc), now: t0)
    engine.apply(AgentEvent(agent: "a", sessionID: "s", event: .needsPermission,
                            request: PermissionRequestInfo(id: "r1", summary: "Run: delete everything", detail: "rm -rf ~")), now: at(0))
    engine.apply(AgentEvent(agent: "a", sessionID: "s", event: .needsPermission,
                            request: PermissionRequestInfo(id: "r1", summary: "Run: list files", detail: "ls")), now: at(1))
    check(engine.sessions["a/s"]?.pendingRequest?.detail == "rm -rf ~", "same id can't rewrite what the card says")

    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sock"
    let store = try EngineStore()
    let server = SocketServer(path: path) { d in
        let (_, s) = store.apply(d.event, at: d.date)
        return ServerReply(ok: true, running: s.running, waiting: s.waiting)
    }
    try server.start()
    defer { server.stop() }

    final class Box: @unchecked Sendable { var reply: ServerReply?; let done = DispatchSemaphore(value: 0) }
    let real = Box()
    let realEvent = AgentEvent(agent: "a", sessionID: "s", event: .needsPermission,
                               request: PermissionRequestInfo(id: "r1", tool: "Bash", summary: "Run: delete", detail: "rm -rf ~"),
                               awaitSeconds: 20)
    DispatchQueue.global().async {
        real.reply = try? SocketClient.request(EventCodec.encodeLine(realEvent), to: path, timeout: 25); real.done.signal()
    }
    let info = SocketServer.AwaitInfo(sessionKey: "a/s", requestID: "r1")
    for _ in 0..<200 where server.awaitingRequests.isEmpty { usleep(10_000) }

    // A second connection claiming the same id is refused and can't change the card.
    var impostor = realEvent
    impostor.request = PermissionRequestInfo(id: "r1", tool: "Bash", summary: "Run: list files", detail: "ls")
    let refused = try SocketClient.request(EventCodec.encodeLine(impostor), to: path, timeout: 3)
    check(refused.ok == false, "second waiter for the same request id is refused")
    check(store.snapshot().sessions["a/s"]?.pendingRequest?.detail == "rm -rf ~", "card still shows the real request")
    check(server.awaitingRequests == [info], "the real agent is still the one waiting")

    // Answering a different version of the request than the agent sent is refused.
    let tampered = PermissionRequestInfo(id: "r1", tool: "Bash", summary: "Run: list files", detail: "ls")
    check(!server.resolve(info, decision: .allow, shown: tampered), "resolve refuses when what was shown doesn't match")
    check(server.resolve(info, decision: .deny, shown: realEvent.request), "resolve works for exactly what was shown")
    real.done.wait()
    check(real.reply?.decision == .deny, "the real agent got the user's answer")
}

suite("security: Claude settings keep permissions and symlinks") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let realFile = dir + "/dotfiles-settings.json"
    let link = dir + "/settings.json"
    try Data(#"{"env":{"ANTHROPIC_API_KEY":"secret"}}"#.utf8).write(to: URL(fileURLWithPath: realFile))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: realFile)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realFile)
    try ClaudeSetup.connectFile(cli: "/Applications/AgentBar.app/Contents/Helpers/agentbar", path: link)
    check((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == realFile, "symlink kept (dotfiles still linked)")
    check(try ClaudeSetup.isConnected(ClaudeSetup.read(realFile)), "the linked file was updated")
    check((try FileManager.default.attributesOfItem(atPath: realFile)[.posixPermissions] as? Int) == 0o600, "private file stays 0600")
    check((try FileManager.default.attributesOfItem(atPath: link + ".agentbar-backup")[.posixPermissions] as? Int) == 0o600, "backup is private (0600)")
}

// MARK: - Load test (plan M1 exit criteria: 1,000 events/s across 50 sessions)

suite("load: 1,000 events across 50 sessions through socket + engine + SQLite") {
    let dir = tempDir()
    defer { cleanup(dir) }
    let path = dir + "/agentbar.sock"
    let store = try EngineStore(databasePath: dir + "/agentbar.sqlite")
    let server = SocketServer(path: path) { d in
        let (_, s) = store.apply(d.event, at: d.date)
        return ServerReply(ok: true, running: s.running, waiting: s.waiting)
    }
    try server.start()
    defer { server.stop() }

    let lock = NSLock()
    var okCount = 0, errors = 0
    let start = Date()
    DispatchQueue.concurrentPerform(iterations: 50) { i in
        // 20 events per session in one connection = the per-session rate limit's burst budget.
        let lines = (0..<20).map { j -> Data in
            let kind: EventKind = j == 19 ? .finished : (j % 5 == 0 ? .needsInput : .working)
            return try! EventCodec.encodeLine(AgentEvent(agent: "load", sessionID: "s\(i)", event: kind,
                                                        usage: Usage(inputTokens: 10, outputTokens: 5, costUSD: 0.001)))
        }
        let replies = (try? SocketClient.send(lines, to: path, timeout: 10)) ?? []
        lock.lock()
        okCount += replies.filter(\.ok).count
        errors += 20 - replies.filter(\.ok).count
        lock.unlock()
    }
    let elapsed = Date().timeIntervalSince(start)
    store.flush()
    let snap = store.snapshot()
    check(okCount == 1000 && errors == 0, "all 1,000 events accepted (ok \(okCount), errors \(errors))")
    check(snap.sessions.count == 50 && snap.totals.finished == 50, "50 sessions, all finished")
    check(snap.totals.usage.totalTokens == 15_000, "usage totals exact (\(snap.totals.usage.totalTokens))")
    check(try store.databaseForTesting?.count("events") == 1000, "all 1,000 events persisted")
    check(store.lastPersistenceError == nil, "no persistence errors")
    check(elapsed < 1.0, String(format: "throughput ≥ 1,000 events/s (took %.3fs)", elapsed))
    print(String(format: "  … 1,000 events in %.0f ms (%.0f events/s)", elapsed * 1000, 1000 / elapsed))
}

// MARK: - CLI end-to-end (set AGENTBAR_CLI)

if let cli = ProcessInfo.processInfo.environment["AGENTBAR_CLI"] {
    suite("CLI binary end-to-end (\((cli as NSString).lastPathComponent))") {
        let dir = tempDir()
        defer { cleanup(dir) }
        let path = dir + "/agentbar.sock"
        let store = try EngineStore()
        let server = SocketServer(path: path) { d in
            let (_, s) = store.apply(d.event, at: d.date)
            return ServerReply(ok: true, running: s.running, waiting: s.waiting)
        }
        try server.start()
        defer { server.stop() }

        final class Out: @unchecked Sendable { var text = "" }
        let lastOut = Out()
        func run(_ args: [String], stdin: String? = nil, socket: String? = nil) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["AGENTBAR_SOCKET"] = socket ?? path
            p.environment = env
            p.standardError = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            if let stdin {
                let pipe = Pipe()
                p.standardInput = pipe
                try p.run()
                pipe.fileHandleForWriting.write(Data(stdin.utf8))
                try pipe.fileHandleForWriting.close()
            } else {
                try p.run()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            lastOut.text = String(decoding: data, as: UTF8.self)
            return p.terminationStatus
        }

        check(try run(["emit", "--agent", "cli", "--session", "1", "--event", "needs_input", "--message", "hi",
                       "--cwd", "/tmp", "--open-url", "vscode://file/tmp"]) == 0, "emit exits 0")
        let s1 = store.snapshot().sessions["cli/1"]
        check(s1?.state == .waiting && s1?.cwd == "/tmp" && s1?.openURL == "vscode://file/tmp", "emitted event + optionals reached the server")
        check(try run(["emit", "--json"], stdin: #"{"agent":"cli","session_id":"2","event":"working"}"# + "\n") == 0, "emit --json exits 0")
        check(store.snapshot().summary.running == 1, "--json event reached the server")
        check(try run(["emit", "--agent", "cli", "--session", "3", "--event", "working", "--open-url", "file:///x"]) == 0,
              "dropped optional field is a warning, not a failure")
        check(try run(["emit", "--agent", "cli", "--session", "3", "--event", "bogus"]) == 1, "bad kind exits 1")
        let missing = dir + "/missing.sock"
        check(try run(["emit", "--agent", "a", "--session", "1", "--event", "started"], socket: missing) == 0, "not running → 0")
        check(try run(["emit", "--agent", "a", "--session", "1", "--event", "started", "--strict"], socket: missing) == 2, "not running + --strict → 2")

        // --- agentbar hook claude ---
        func hook(_ json: String, socket: String? = nil) throws -> Int32 { try run(["hook", "claude", "--wait", "20"], stdin: json, socket: socket) }
        let cwd = "/Users/me/code/shop"
        check(try hook(#"{"hook_event_name":"SessionStart","session_id":"cc1","cwd":"\#(cwd)","source":"startup"}"#) == 0, "SessionStart exits 0")
        check(store.snapshot().sessions["claude-code/cc1"]?.title == "shop", "title from cwd folder")
        _ = try hook(#"{"hook_event_name":"UserPromptSubmit","session_id":"cc1","cwd":"\#(cwd)","prompt":"Add a checkout page\nwith tests"}"#)
        check(store.snapshot().sessions["claude-code/cc1"]?.message == "Working on: Add a checkout page", "prompt → working message (first line)")
        _ = try hook(#"{"hook_event_name":"PostToolUse","session_id":"cc1","cwd":"\#(cwd)","tool_name":"Edit","tool_input":{"file_path":"/Users/me/code/shop/Checkout.swift"}}"#)
        _ = try hook(#"{"hook_event_name":"PostToolUse","session_id":"cc1","cwd":"\#(cwd)","tool_name":"Bash","tool_input":{"command":"swift build"}}"#)
        check(store.snapshot().sessions["claude-code/cc1"]?.recentActivity.suffix(2).map(\.text) == ["Edited Checkout.swift", "Ran swift build"],
              "tool use → recent activity")

        // PermissionRequest: allow from AgentBar → Claude Code decision JSON on stdout.
        func permission(_ id: String, decide: Decision?) throws -> (Int32, String) {
            if let decide {
                DispatchQueue.global().async {
                    for _ in 0..<300 {
                        if store.snapshot().sessions["claude-code/cc1"]?.pendingRequest?.id == id { break }
                        usleep(10_000)
                    }
                    // Same two steps as AppModel.decide: answer the agent, then update the session.
                    if server.resolve(SocketServer.AwaitInfo(sessionKey: "claude-code/cc1", requestID: id), decision: decide) {
                        store.resolveRequest(sessionKey: "claude-code/cc1", requestID: id, decision: decide)
                    }
                }
            }
            let code = try hook(#"{"hook_event_name":"PermissionRequest","session_id":"cc1","cwd":"\#(cwd)","tool_name":"Bash","tool_use_id":"\#(id)","tool_input":{"command":"rm -rf node_modules","description":"Remove node_modules directory"}}"#)
            return (code, lastOut.text)
        }
        let (allowCode, allowOut) = try permission("tu1", decide: .allow)
        let allowJSON = (try? JSONSerialization.jsonObject(with: Data(allowOut.utf8))) as? [String: Any]
        let allowDecision = (allowJSON?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        check(allowCode == 0 && allowDecision?["behavior"] as? String == "allow", "Allow → {behavior: allow} (\(allowOut))")
        check(((allowJSON?["hookSpecificOutput"] as? [String: Any])?["hookEventName"] as? String) == "PermissionRequest", "hookEventName set")
        check(store.snapshot().sessions["claude-code/cc1"]?.recentActivity.last?.text == "You allowed: Run: Remove node_modules directory",
              "card showed the request summary")

        let (_, denyOut) = try permission("tu2", decide: .deny)
        check(denyOut.contains(#""behavior":"deny""#) && denyOut.contains("denied this from AgentBar"), "Deny → behavior deny + message")

        let (_, deferOut) = try permission("tu3", decide: .deferred)
        check(deferOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Answer in terminal → no output (Claude asks normally)")

        let missingCode = try hook(#"{"hook_event_name":"PermissionRequest","session_id":"cc1","tool_name":"Bash","tool_input":{"command":"ls"}}"#, socket: missing)
        check(missingCode == 0 && lastOut.text.isEmpty, "AgentBar not running → exit 0, no decision")

        _ = try hook(#"{"hook_event_name":"Notification","session_id":"cc1","cwd":"\#(cwd)","notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#)
        check(store.snapshot().sessions["claude-code/cc1"]?.state == .waiting, "idle notification → needs you")
        _ = try hook(#"{"hook_event_name":"Stop","session_id":"cc1","cwd":"\#(cwd)"}"#)
        check(store.snapshot().sessions["claude-code/cc1"]?.state == .finished, "Stop → finished")
        check(try hook("not json") == 0, "garbage stdin never fails the hook")

        // --- agentbar run ---
        check(try run(["run", "--agent", "builder", "--session", "job1", "--", "/bin/sh", "-c", "echo building; exit 0"]) == 0, "run: exit 0 passes through")
        check(lastOut.text.contains("building"), "run: the command's output is untouched")
        let job1 = store.snapshot().sessions["builder/job1"]
        check(job1?.state == .finished && job1?.message?.hasPrefix("Finished in") == true, "run: finished reported (\(job1?.message ?? "nil"))")
        check(try run(["run", "--agent", "builder", "--session", "job2", "--", "/bin/sh", "-c", "exit 3"]) == 3, "run: exit code 3 passes through")
        check(store.snapshot().sessions["builder/job2"]?.message == "Exited with code 3 after 0 s", "run: failure reported with code")
        check(try run(["run", "--session", "job3", "--", "no-such-command-xyz"]) == 127, "run: missing command exits 127")
        check(store.snapshot().sessions["no-such-command-xyz/job3"]?.state == .errored, "run: missing command reported as error")
        check(try run(["run", "--", "/bin/sh", "-c", "exit 0"], socket: missing) == 0, "run: works when AgentBar isn't running")
        check(try run(["run"]) == 1, "run: no command is a usage error")

        // --- agentbar status ---
        server.onQuery = { name in name == "status" ? try? StatusReport.encoder.encode(StatusReport(engine: store.snapshot())) : nil }
        check(try run(["status"]) == 0 && lastOut.text.contains("STATE") && lastOut.text.contains("Builder"), "status: table printed")
        check(try run(["status", "--json"]) == 0 && lastOut.text.contains("\"sessions\""), "status --json")
        check(try run(["status"], socket: missing) == 2 && lastOut.text.contains("not running"), "status: not running exits 2")
        check(try hook(#"{"hook_event_name":"SomethingNew","session_id":"cc1"}"#) == 0, "unknown hook ignored")
    }
}

print(failures == 0 ? "\nALL PASSED (\(passed) checks)" : "\n\(failures) FAILED, \(passed) passed")
exit(failures == 0 ? 0 : 1)
