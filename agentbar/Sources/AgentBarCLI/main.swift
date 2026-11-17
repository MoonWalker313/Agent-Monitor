import Foundation
import AgentBarCore

// agentbar: report agent activity to the AgentBar menu bar app.

/// The version of the AgentBar.app this command ships in (Contents/Helpers/agentbar → Contents/Info.plist).
let version: String = {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    if let dict = NSDictionary(contentsOf: plist), let v = dict["CFBundleShortVersionString"] as? String { return v }
    return "dev"
}()

let usage = """
usage:
  agentbar run [--agent NAME] [--title TEXT] -- COMMAND [ARGS...]
                                       run any command and show it in AgentBar (started, done or failed)
  agentbar status [--json]             show what AgentBar is showing
  agentbar connect|disconnect claude|cursor|gemini|antigravity [--approvals]
                                       add or remove AgentBar's hooks in that agent's settings
  agentbar emit --agent NAME --session ID --event KIND
               [--title TEXT] [--message TEXT] [--cwd PATH] [--open-url URL] [--strict] [--verbose]
  agentbar emit --json [--strict]      read one JSON event per line from stdin
  agentbar hook claude|cursor|gemini|antigravity [--wait SECONDS]
                                       agent hook adapters (read the hook's JSON on stdin)
  agentbar version

KIND: \(EventKind.allCases.map(\.rawValue).joined(separator: ", "))

Exit codes: emit: 0 ok (also when AgentBar isn't running, unless --strict),
                  1 usage or invalid event, 2 AgentBar not running (--strict only)
            run:  the command's own exit code (127 if it wasn't found)
            status: 0 ok, 2 AgentBar not running
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("agentbar: \(message)\n".utf8))
    exit(code)
}

func parseFlags(_ args: ArraySlice<String>) -> (values: [String: String], switches: Set<String>) {
    var values: [String: String] = [:]
    var switches: Set<String> = []
    var it = args.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--json", "--strict", "--verbose": switches.insert(arg)
        case "--agent", "--session", "--event", "--title", "--message", "--cwd", "--open-url":
            guard let value = it.next() else { fail("\(arg) needs a value\n\n\(usage)") }
            values[arg] = value
        case "-h", "--help": print(usage); exit(0)
        default: fail("unknown argument '\(arg)'\n\n\(usage)")
        }
    }
    return (values, switches)
}

/// Builds the wire lines to send. Returns instead of assigning to an outer `var` from
/// inside `do/catch` — that pattern came out empty in -O release builds (M0 finding).
func buildLines(_ values: [String: String], _ switches: Set<String>) -> [Data] {
    if switches.contains("--json") {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        return input.split(separator: 0x0A).map { Data($0) }.filter { !$0.isEmpty }
    }
    guard let agent = values["--agent"] else { fail("missing --agent\n\n\(usage)") }
    guard let session = values["--session"] else { fail("missing --session\n\n\(usage)") }
    guard let kindRaw = values["--event"] else { fail("missing --event\n\n\(usage)") }
    guard let kind = EventKind(rawValue: kindRaw) else {
        fail("unknown event '\(kindRaw)'. Use one of: \(EventKind.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    let event = AgentEvent(agent: agent, sessionID: session, event: kind,
                           title: values["--title"], message: values["--message"],
                           cwd: values["--cwd"], openURL: values["--open-url"])
    guard let line = try? EventCodec.encodeLine(event) else { fail("could not encode event") }
    return [line]
}

func emit(_ args: ArraySlice<String>) -> Never {
    let (values, switches) = parseFlags(args)
    let strict = switches.contains("--strict")
    let lines = buildLines(values, switches)
    guard !lines.isEmpty else { fail("no events to send") }

    do {
        let replies = try SocketClient.send(lines, to: Paths.socketPath)
        if switches.contains("--verbose") {
            FileHandle.standardError.write(Data("agentbar: socket \(Paths.socketPath)\n".utf8))
            for reply in replies {
                FileHandle.standardError.write(Data("agentbar: reply ok=\(reply.ok) running=\(reply.running ?? -1) waiting=\(reply.waiting ?? -1)\n".utf8))
            }
        }
        for warning in replies.flatMap({ $0.warnings ?? [] }) {
            FileHandle.standardError.write(Data("agentbar: warning: \(warning)\n".utf8))
        }
        var anyFailed = false
        for reply in replies where !reply.ok {
            anyFailed = true
            FileHandle.standardError.write(Data("agentbar: rejected: \(reply.error ?? "unknown error")\n".utf8))
        }
        if replies.count != lines.count { fail("expected \(lines.count) replies from AgentBar, got \(replies.count)") }
        exit(anyFailed ? 1 : 0)
    } catch SocketError.notRunning(let path) {
        // Never break an agent's hook just because the menu bar app is closed.
        FileHandle.standardError.write(Data("agentbar: warning: AgentBar is not running (\(path)); event dropped\n".utf8))
        exit(strict ? 2 : 0)
    } catch {
        fail("\(error)", code: strict ? 2 : 0)
    }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "emit": emit(args.dropFirst())
case "run": RunCommand.run(args.dropFirst())
case "connect", "disconnect": ConnectCommand.run(args.first!, args.dropFirst())
case "status": StatusCommand.run(args.dropFirst())
case "hook":
    switch args.dropFirst().first {
    case "claude": ClaudeHook.run(args.dropFirst(2))
    case let name? where ["cursor", "gemini", "antigravity"].contains(name): OtherHooks.run(name, args.dropFirst(2))
    default: fail("usage: agentbar hook claude|cursor|gemini|antigravity [--wait SECONDS]")
    }
case "version", "--version": print("agentbar \(version)")
case "-h", "--help", nil: print(usage)
default: fail("unknown command '\(args.first!)'\n\n\(usage)")
}
