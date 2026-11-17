import SwiftUI
import AppKit
import AgentBarCore

/// Design QA: `AgentBar --snapshot <dir>` starts against a throwaway data folder, feeds sample
/// (synthetic) agent events through the real socket, renders the real views in light and dark
/// to PNGs, and quits. Never touches the user's real AgentBar data.
enum Snapshot {
    static var directory: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    /// Call from App.init, before AppModel exists, so Paths resolve to a temp folder.
    static func prepareEnvironment() {
        guard directory != nil else { return }
        let home = NSTemporaryDirectory() + "agentbar-snapshot-\(getpid())"
        setenv("AGENTBAR_HOME", home, 1) // socket and database live in this private temp folder
    }

    @MainActor
    static func run(model: AppModel, into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Empty state first.
        render(PanelView().environmentObject(model), name: "empty", dir: dir)
        feedSampleEvents(path: model.socketPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            render(PanelView().environmentObject(model), name: "panel", dir: dir)
            render(PanelView(expanded: ["codex/s2", "claude-code/s5"]).environmentObject(model), name: "panel-expanded", dir: dir)
            render(RequestPopupView(onClose: {}).environmentObject(model), name: "popup", dir: dir)
            render(SettingsView().environmentObject(model).environmentObject(model.settings), name: "settings", dir: dir)
            render(SetupGuideView(done: {}).environmentObject(model).environmentObject(model.settings), name: "setup", dir: dir)
            NSApp.terminate(nil)
        }
    }

    private static func feedSampleEvents(path: String) {
        func line(_ e: AgentEvent) -> Data { try! EventCodec.encodeLine(e) }
        let base = [
            AgentEvent(agent: "claude-code", sessionID: "s1", event: .working, title: "shop", cwd: "/Users/demo/code/shop",
                       activity: "You asked: Clean up dependencies and rebuild"),
            AgentEvent(agent: "claude-code", sessionID: "s1", event: .heartbeat, activity: "Read package.json"),
            AgentEvent(agent: "claude-code", sessionID: "s1", event: .heartbeat, activity: "Edited package.json"),
            AgentEvent(agent: "codex", sessionID: "s2", event: .working, title: "api-server", activity: "Read routes/orders.ts"),
            AgentEvent(agent: "codex", sessionID: "s2", event: .heartbeat, activity: "Edited routes/orders.ts"),
            AgentEvent(agent: "codex", sessionID: "s2", event: .heartbeat, activity: "Ran npm run lint"),
            AgentEvent(agent: "codex", sessionID: "s2", event: .working, title: "api-server",
                       usage: Usage(inputTokens: 12_400, outputTokens: 3_100, costUSD: 0.21), activity: "Ran npm test"),
            AgentEvent(agent: "claude-code", sessionID: "s3", event: .needsInput, title: "launch-post",
                       message: "Which tone do you want for the intro: playful or formal?"),
            AgentEvent(agent: "research-bot", sessionID: "s4", event: .working, title: "market scan", activity: "Fetched 14 pages"),
            AgentEvent(agent: "claude-code", sessionID: "s5", event: .finished, title: "docs", message: "Finished. Ready for your review.",
                       activity: "Edited README.md"),
        ]
        _ = try? SocketClient.send(base.map(line), to: path)
        let request = AgentEvent(agent: "claude-code", sessionID: "s1", event: .needsPermission, title: "shop",
                                 request: PermissionRequestInfo(id: "r1", tool: "Bash", summary: "Run: Reinstall dependencies",
                                                                detail: "rm -rf node_modules && npm install"),
                                 awaitSeconds: 60)
        DispatchQueue.global().async { _ = try? SocketClient.request(line(request), to: path, timeout: 30) }
    }

    @MainActor
    private static func render<V: View>(_ view: V, name: String, dir: String) {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 900),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(suffix).png"))
            }
            window.orderOut(nil)
        }
    }
}
