import Foundation
import AgentBarCore

// `agentbar run -- <command>`: report any command-line agent or long script to AgentBar.
// `agentbar status`: print what AgentBar is showing.

enum RunCommand {
    static func run(_ args: ArraySlice<String>) -> Never {
        var agent: String?
        var title: String?
        var session: String?
        var command: [String] = []
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg == "--" { while let rest = it.next() { command.append(rest) }; break }
            switch arg {
            case "--agent": agent = it.next()
            case "--title": title = it.next()
            case "--session": session = it.next()
            case "-h", "--help": print(usage); exit(0)
            default:
                if arg.hasPrefix("-") { fail("unknown option '\(arg)' for run\n\n\(usage)") }
                // Allow `agentbar run cmd args` without `--`.
                command.append(arg)
                while let rest = it.next() { command.append(rest) }
            }
        }
        guard let program = command.first else { fail("run: missing the command to run\n\n\(usage)") }

        let name = agent ?? (program as NSString).lastPathComponent
        let cwd = FileManager.default.currentDirectoryPath
        let sessionID = session ?? "run-\(getpid())-\(UUID().uuidString.prefix(6))"
        let label = title ?? (cwd as NSString).lastPathComponent
        let shown = command.joined(separator: " ")
        let host = ClaudeHook.hostAppBundleID()
        let path = Paths.socketPath

        // Reporting is best-effort and quick: the command runs whether or not AgentBar is open.
        func report(_ kind: EventKind, message: String? = nil, activity: String? = nil) {
            let event = AgentEvent(agent: name, sessionID: sessionID, event: kind, title: label, message: message,
                                   cwd: cwd, activateBundleID: host, activity: activity)
            if let line = try? EventCodec.encodeLine(event) { _ = try? SocketClient.send([line], to: path, timeout: 1) }
        }

        report(.started, message: "Running: \(ClaudeHook.truncate(shown, 120))", activity: "Started \(ClaudeHook.truncate(shown, 80))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env") // resolves the command on PATH
        process.arguments = command
        // stdin/stdout/stderr are inherited, so the command behaves exactly as if run directly.
        let started = Date()
        do {
            try process.run()
        } catch {
            report(.error, message: "Couldn't start: \(error.localizedDescription)")
            fail("couldn't start \(program): \(error.localizedDescription)", code: 127)
        }

        // Only now ignore signals in this process, so the child doesn't inherit "ignore".
        // Ctrl-C reaches the child through the terminal; TERM/HUP sent to us are forwarded.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                if sig != SIGINT && process.isRunning { kill(process.processIdentifier, sig) }
            }
            source.resume()
            sources.append(source)
        }

        // A heartbeat every minute keeps a long, quiet job from being marked "may be stuck".
        let heartbeat = DispatchSource.makeTimerSource(queue: .global())
        heartbeat.schedule(deadline: .now() + 60, repeating: 60)
        heartbeat.setEventHandler { report(.heartbeat) }
        heartbeat.resume()

        process.waitUntilExit()
        heartbeat.cancel()
        sources.forEach { $0.cancel() }

        let took = Format.elapsed(Date().timeIntervalSince(started))
        let status = process.terminationStatus
        if process.terminationReason == .uncaughtSignal {
            report(.error, message: "Stopped by signal \(status) after \(took)", activity: "Stopped by signal \(status)")
            exit(128 + status)
        }
        switch status {
        case 0:
            report(.finished, message: "Finished in \(took)", activity: "Finished: \(ClaudeHook.truncate(shown, 80))")
        case 127:
            report(.error, message: "Command not found: \(program)", activity: "Command not found")
        default:
            report(.error, message: "Exited with code \(status) after \(took)", activity: "Failed with code \(status)")
        }
        exit(status)
    }

    enum Format {
        static func elapsed(_ s: TimeInterval) -> String {
            if s < 60 { return "\(Int(s.rounded())) s" }
            let m = Int(s / 60)
            if m < 60 { return "\(m) min \(Int(s) % 60) s" }
            return "\(m / 60) hr \(m % 60) min"
        }
    }
}

enum StatusCommand {
    static func run(_ args: ArraySlice<String>) -> Never {
        let json = args.contains("--json")
        let report: StatusReport
        do {
            report = try StatusQuery.fetch(from: Paths.socketPath)
        } catch SocketError.notRunning {
            if json { print(#"{"ok":false,"error":"AgentBar is not running"}"#) } else { print("AgentBar is not running.") }
            exit(2)
        } catch {
            fail("couldn't read status: \(error)", code: 1)
        }

        if json {
            if let data = try? StatusReport.encoder.encode(report), let text = String(data: data, encoding: .utf8) { print(text) }
            exit(0)
        }

        var head: [String] = []
        if report.standingBy > 0 { head.append("\(report.standingBy) standing by") }
        if report.needsYou > 0 { head.append("\(report.needsYou) need\(report.needsYou == 1 ? "s" : "") you") }
        if report.running > 0 { head.append("\(report.running) running") }
        print("AgentBar: " + (head.isEmpty ? (report.sessions.isEmpty ? "no agents yet" : "all quiet") : head.joined(separator: " · ")))
        guard !report.sessions.isEmpty else { exit(0) }
        print("")

        let rows = report.sessions.map { item -> [String] in
            [word(item.state), item.project, agentName(item.agent), ago(item.updatedAt),
             item.request.map { "Wants to: \($0.summary ?? $0.tool ?? "permission")" } ?? item.message ?? item.lastTask ?? ""]
        }
        let headers = ["STATE", "PROJECT", "AGENT", "UPDATED", "DETAIL"]
        var widths = headers.map(\.count)
        for row in rows { for (i, cell) in row.enumerated() where i < 4 { widths[i] = min(max(widths[i], cell.count), 24) } }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in
                i < 4 ? ClaudeHook.truncate(cell, widths[i]).padding(toLength: widths[i], withPad: " ", startingAt: 0) : ClaudeHook.truncate(cell, 60)
            }.joined(separator: "  ")
        }
        print(line(headers))
        rows.forEach { print(line($0)) }
        exit(0)
    }

    static func word(_ state: String) -> String {
        switch state {
        case "standing_by": return "Standing by"
        case "waiting": return "Needs you"
        case "running": return "Running"
        case "stale": return "May be stuck"
        case "finished": return "Done"
        case "errored": return "Error"
        case "stopped": return "Stopped"
        default: return state
        }
    }

    static func agentName(_ agent: String) -> String {
        agent.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func ago(_ date: Date) -> String {
        let s = max(0, Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        let m = Int(s / 60)
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min"
    }
}
