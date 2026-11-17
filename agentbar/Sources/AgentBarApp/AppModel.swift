import Foundation
import AppKit
import AgentBarCore
import ServiceManagement
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var summary = Summary()
    @Published private(set) var totals = DailyTotals(day: "")
    @Published private(set) var overall: OverallStatus = .idle
    @Published private(set) var serverError: String?
    @Published private(set) var storageError: String?
    @Published private(set) var loginItemStatus = ""
    @Published private(set) var loginItemError: String?
    @Published private(set) var lastTestResult: String?
    /// Sessions with an open permission request, oldest first.
    @Published private(set) var pendingRequests: [Session] = []
    /// Shown briefly when a decision couldn't be delivered.
    @Published private(set) var decisionNote: String?
    @Published private(set) var notificationStatus = "checking…"
    @Published private(set) var claudeConnected = false

    let settings = AppSettings()

    let socketPath = Paths.socketPath
    private let store: EngineStore
    private var server: SocketServer?
    private let popup = RequestPopupController()
    private var announcedRequests: Set<String> = []
    private let settingsWindow = SettingsWindowController()
    private var settingsObserver: AnyCancellable?
    private var appliedRetentionDays = 0
    /// Updates waiting to be shown; drained at most 10 times a second (plan M2 2.1).
    private var queuedUpdates: [EngineUpdate] = []
    private var drainScheduled = false
    /// Last alert per session and kind, to group repeats (at most one per 30 s).
    private var lastAlert: [String: Date] = [:]

    /// The running model (for the --snapshot design-QA mode).
    static weak var current: AppModel?

    init() {
        // Fall back to in-memory if the database can't be opened, so the app still works.
        do {
            store = try EngineStore(databasePath: Paths.databasePath)
        } catch {
            store = try! EngineStore()
            storageError = "History not saved: \(error)"
        }
        store.onUpdate = { [weak self] update in
            Task { @MainActor in self?.enqueue(update) }
        }
        applySettings()
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value lands; apply on the next turn.
            DispatchQueue.main.async { self?.applySettings() }
        }
        store.startSweeping()
        Notifier.shared.onPermissionAction = { [weak self] sessionKey, requestID, action in
            Task { @MainActor in self?.handleNotificationAction(sessionKey: sessionKey, requestID: requestID, action: action) }
        }
        refresh()
        startServer()
        AppModel.current = self
        refreshLoginItem()
        // Any quit path (menu, Dock, logout, AppleScript) must flush pending writes and remove the socket.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        // After sleep: catch up on stuck/silent agents and make sure agents can still reach us.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        refreshClaudeStatus()
    }

    private func applySettings() {
        store.updateConfig(settings.engineConfig)
        if settings.retentionDays != appliedRetentionDays {
            appliedRetentionDays = settings.retentionDays
            store.setRetention(settings.retention)
        }
        if !settings.showPopup { popup.close() }
    }

    func didWake() {
        store.sweep()
        if !FileManager.default.fileExists(atPath: socketPath) {
            server?.stop()
            server = nil
            startServer()
        }
    }

    // MARK: Event ingestion

    private func startServer() {
        let store = self.store
        let server = SocketServer(path: socketPath) { decoded in
            let (_, summary) = store.apply(decoded.event, at: decoded.date)
            return ServerReply(ok: true, running: summary.running, waiting: summary.waiting)
        }
        server.log = { NSLog("AgentBar socket: %@", $0) }
        // `agentbar status`
        server.onQuery = { name in
            guard name == "status" else { return nil }
            return try? StatusReport.encoder.encode(StatusReport(engine: store.snapshot()))
        }
        // The agent stopped waiting (timed out, or it was cancelled): drop the card, keep "needs you".
        server.onAwaitEnded = { info, _ in
            store.resolveRequest(sessionKey: info.sessionKey, requestID: info.requestID, decision: .deferred)
        }
        do {
            try server.start()
            self.server = server
            serverError = nil
        } catch {
            serverError = "\(error)"
        }
    }

    /// Batches bursts of updates so the panel redraws at most 10 times a second.
    private func enqueue(_ update: EngineUpdate) {
        queuedUpdates.append(update)
        guard !drainScheduled else { return }
        drainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let batch = self.queuedUpdates
            self.queuedUpdates.removeAll()
            self.drainScheduled = false
            self.handle(batch)
        }
    }

    private func handle(_ batch: [EngineUpdate]) {
        refresh()
        var update = EngineUpdate()
        for u in batch {
            update.changes += u.changes
            update.thresholds += u.thresholds
        }
        var newRequest = false
        for change in update.changes {
            if let request = change.session.pendingRequest {
                let key = "\(change.session.id)#\(request.id)"
                if !announcedRequests.contains(key) {
                    announcedRequests.insert(key)
                    newRequest = true
                    if settings.notifyPermission {
                        Notifier.shared.postPermission(sessionKey: change.session.id, request: request,
                                                       title: "\(Format.project(change.session)) needs your permission")
                    }
                }
            } else if change.enteredAttentionState {
                notify(change)
            }
        }
        // Forget answered requests; withdraw their notifications.
        let open = Set(pendingRequests.compactMap { s in s.pendingRequest.map { "\(s.id)#\($0.id)" } })
        for gone in announcedRequests.subtracting(open) {
            Notifier.shared.withdraw(id: Notifier.permissionID(gone))
        }
        announcedRequests.formIntersection(open)
        popup.update(model: self, show: newRequest && settings.showPopup)
        for threshold in update.thresholds where settings.notifyLimits {
            switch threshold {
            case .cost(let limit, let actual):
                Notifier.shared.post(id: "threshold-cost", title: "Daily AI spend limit reached",
                                     body: String(format: "$%.2f today (limit $%.2f)", actual, limit))
            case .tokens(let limit, let actual):
                Notifier.shared.post(id: "threshold-tokens", title: "Daily token limit reached",
                                     body: "\(actual.formatted()) tokens today (limit \(limit.formatted()))")
            }
        }
    }

    private func notify(_ change: StateChange) {
        let name = Format.project(change.session)
        let enabled: Bool
        switch change.new {
        case .waiting: enabled = settings.notifyNeedsInput
        case .finished: enabled = settings.notifyFinished
        case .errored, .stale: enabled = settings.notifyProblems
        default: enabled = false
        }
        guard enabled else { return }
        // Group repeats: one alert per session and kind every 30 s at most.
        let key = "\(change.session.id)|\(change.new.rawValue)"
        if let last = lastAlert[key], Date().timeIntervalSince(last) < 30 { return }
        lastAlert[key] = Date()
        if lastAlert.count > 500 { lastAlert = lastAlert.filter { Date().timeIntervalSince($0.value) < 30 } }
        switch change.new {
        case .waiting:
            Notifier.shared.post(id: change.session.id, title: "\(name) needs you",
                                 body: change.session.message ?? "Waiting for your input")
        case .finished:
            Notifier.shared.post(id: change.session.id, title: "\(name) finished",
                                 body: change.session.message ?? "Ready for review")
        case .errored:
            Notifier.shared.post(id: change.session.id, title: "\(name) hit an error",
                                 body: change.session.message ?? "The agent reported an error")
        case .stale:
            Notifier.shared.post(id: change.session.id, title: "\(name) may be stuck",
                                 body: "No activity for \(Int(store.snapshot().config.staleTimeout(for: change.session.agent) / 60)) minutes")
        default: break
        }
    }

    private func refresh() {
        let snapshot = store.snapshot()
        sessions = snapshot.sortedSessions
        summary = snapshot.summary
        totals = snapshot.totals
        overall = snapshot.overall
        pendingRequests = snapshot.pendingRequests
        if let error = store.lastPersistenceError { storageError = "Couldn't save history: \(error)" }
    }

    func waitingSecondsToday() -> Double { store.snapshot().waitingSecondsToday() }

    // MARK: Permission decisions

    /// Allow / Deny / Answer-in-terminal from the panel, the popup, or a notification.
    func decide(sessionKey: String, requestID: String, decision: Decision) {
        let info = SocketServer.AwaitInfo(sessionKey: sessionKey, requestID: requestID)
        let delivered = server?.resolve(info, decision: decision,
                                        message: decision == .deny ? "The user denied this from AgentBar." : nil) ?? false
        if delivered {
            store.resolveRequest(sessionKey: sessionKey, requestID: requestID, decision: decision)
            decisionNote = nil
        } else {
            // The agent already stopped waiting (e.g. timed out and is asking in its own window).
            store.resolveRequest(sessionKey: sessionKey, requestID: requestID, decision: .deferred)
            decisionNote = "That agent stopped waiting. Answer it in its own window."
        }
    }

    func dismissPopup() { popup.close() }

    // MARK: Panel actions

    /// Brings the agent's window forward: its link if it sent one (already allow-listed by
    /// URLPolicy), otherwise the app it runs in.
    func open(_ session: Session) {
        if let raw = session.openURL, case .allowed(let url) = URLPolicy.evaluate(raw) {
            if confirmScheme(url, for: session) { NSWorkspace.shared.open(url) }
        } else if let bundle = session.activateBundleID,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Links that open another app (anything but https) ask once per scheme (PRD P0-3).
    private func confirmScheme(_ url: URL, for session: Session) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme != "https", !settings.trustedSchemes.contains(scheme) else { return true }
        let appName = NSWorkspace.shared.urlForApplication(toOpen: url).map { $0.deletingPathExtension().lastPathComponent }
        let alert = NSAlert()
        alert.messageText = "Open this link in \(appName ?? "another app")?"
        alert.informativeText = "\(Format.agentName(session.agent)) (\(Format.project(session))) asked AgentBar to open:\n\(url.absoluteString)"
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Always Open \(scheme): Links")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn:
            settings.trustedSchemes.append(scheme)
            return true
        default: return false
        }
    }

    // MARK: Settings

    func showSettings() { settingsWindow.show(model: self, settings: settings) }

    private let setupGuide = SetupGuideController()
    func showSetupGuide() { setupGuide.show(model: self, settings: settings) }

    /// Claude Code is connected when its user settings run `agentbar hook claude`.
    func refreshClaudeStatus() {
        claudeConnected = (try? ClaudeSetup.isConnected(ClaudeSetup.read())) ?? false
    }

    /// The agentbar command inside this app.
    var bundledCLI: String { Bundle.main.bundlePath + "/Contents/Helpers/agentbar" }

    @Published private(set) var setupMessage: String?

    /// Adds AgentBar's hooks to ~/.claude/settings.json (backup kept; other settings untouched).
    func connectClaude() {
        do {
            try ClaudeSetup.connectFile(cli: bundledCLI)
            setupMessage = "Connected. New Claude Code sessions will show up here. Sessions already open need a restart."
        } catch {
            setupMessage = "\(error)"
        }
        refreshClaudeStatus()
    }

    func disconnectClaude() {
        do {
            try ClaudeSetup.disconnectFile()
            setupMessage = "Disconnected. Claude Code no longer reports to AgentBar."
        } catch {
            setupMessage = "\(error)"
        }
        refreshClaudeStatus()
    }

    // MARK: Command-line tool

    static let cliLink = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agentbar").path

    var cliInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: Self.cliLink)) == bundledCLI
    }

    /// Links ~/.local/bin/agentbar to the agentbar command in this app (no admin password needed).
    func installCLI() {
        let fm = FileManager.default
        let link = Self.cliLink
        do {
            try fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
                guard existing != bundledCLI else { setupMessage = "The agentbar command is already installed."; return }
                try fm.removeItem(atPath: link)
            } else if fm.fileExists(atPath: link) {
                setupMessage = "~/.local/bin/agentbar already exists and isn't AgentBar's, so it was left alone."
                return
            }
            try fm.createSymbolicLink(atPath: link, withDestinationPath: bundledCLI)
            setupMessage = "Installed. Open a new terminal and run: agentbar status"
        } catch {
            setupMessage = "Couldn't install the agentbar command: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    /// Copies the Claude Code hooks, pointing at this copy of the agentbar command.
    func copyClaudeSetup() {
        let snippet = ClaudeSetup.connect([:], cli: bundledCLI)
        guard let data = try? JSONSerialization.data(withJSONObject: snippet, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    func dismiss(_ session: Session) {
        store.dismiss(sessionKey: session.id)
    }

    func revealFolder(_ session: Session) {
        guard let cwd = session.cwd else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            decisionNote = "That folder no longer exists."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear AgentBar's history?"
        alert.informativeText = "This removes every session and today's totals from this Mac. Agents that are still running will reappear when they next report."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { clearSessions() }
    }

    func refreshNotificationStatus() {
        Notifier.shared.status { status in Task { @MainActor in self.notificationStatus = status } }
    }

    func requestNotifications() {
        Notifier.shared.requestAuthorization { _ in Task { @MainActor in self.refreshNotificationStatus() } }
    }
    func showPopup() { popup.update(model: self, show: true) }

    private func handleNotificationAction(sessionKey: String, requestID: String, action: Notifier.PermissionAction) {
        switch action {
        case .allow: decide(sessionKey: sessionKey, requestID: requestID, decision: .allow)
        case .deny: decide(sessionKey: sessionKey, requestID: requestID, decision: .deny)
        case .review: showPopup()
        }
    }

    func clearSessions() {
        do {
            try store.removeAll()
        } catch {
            storageError = "Couldn't clear history: \(error)"
        }
        refresh()
    }

    /// Sends demo events through the real socket path, exactly like the CLI does.
    func sendTestEvents() {
        let path = socketPath
        let run = Int.random(in: 100...999)
        Task.detached {
            let session = "sample-\(run)"
            let setup = [
                AgentEvent(agent: "sample", sessionID: session, event: .working, title: "sample project", activity: "Edited Package.swift"),
                AgentEvent(agent: "sample", sessionID: session, event: .heartbeat, activity: "Ran swift build"),
            ]
            let request = AgentEvent(agent: "sample", sessionID: session, event: .needsPermission, title: "sample project",
                                     request: PermissionRequestInfo(id: "req-\(run)", tool: "Bash",
                                                                    summary: "Run: install dependencies",
                                                                    detail: "npm install --save-dev typescript"),
                                     awaitSeconds: 120)
            do {
                _ = try SocketClient.send(try setup.map { try EventCodec.encodeLine($0) }, to: path)
                await MainActor.run { self.lastTestResult = "Waiting for your answer…" }
                let reply = try SocketClient.request(try EventCodec.encodeLine(request), to: path, timeout: 125)
                let result = "The sample agent got: \(reply.decision?.rawValue ?? "no decision")"
                // A sample never lingers: it ends as soon as you've answered (or it timed out).
                let end = AgentEvent(agent: "sample", sessionID: session, event: .stopped,
                                     message: "Sample finished. You answered: \(reply.decision?.rawValue ?? "nothing")")
                _ = try? SocketClient.send([try EventCodec.encodeLine(end)], to: path)
                await MainActor.run { self.lastTestResult = result }
            } catch {
                let result = "Failed: \(error)"
                await MainActor.run { self.lastTestResult = result }
            }
        }
    }

    // MARK: Launch at login (M0 risk test)

    func refreshLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled: loginItemStatus = "enabled"
        case .notRegistered: loginItemStatus = "off"
        case .requiresApproval: loginItemStatus = "needs approval in System Settings › Login Items"
        case .notFound: loginItemStatus = "not found (run from the .app bundle)"
        @unknown default: loginItemStatus = "unknown"
        }
    }

    var loginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    func stop() {
        server?.stop()
        store.flush()
    }
}
