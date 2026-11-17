import SwiftUI
import AppKit
import AgentBarCore

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() { Snapshot.prepareEnvironment() }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            StatusLabel(status: model.overall, waiting: model.summary.needsAttention)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only, even when launched outside a bundle with LSUIElement (e.g. `swift run`).
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.installDelegate()
        if Snapshot.directory == nil {
            // First launch: show the setup guide once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let model = AppModel.current, !model.settings.onboarded { model.showSetupGuide() }
            }
        }
        if let dir = Snapshot.directory {
            // Give the App a moment to create its model, then render.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let model = AppModel.current { Snapshot.run(model: model, into: dir) }
            }
        }
    }
}

/// The menu bar lamp. Template images, so macOS tints them for the menu bar;
/// shape (not colour) carries the state, and the count says how many need you.
struct StatusLabel: View {
    let status: OverallStatus
    let waiting: Int

    var body: some View {
        switch status {
        case .idle:
            Image(systemName: "circle")
                .accessibilityLabel("AgentBar: no agents running")
        case .working:
            Image(systemName: "circle.inset.filled")
                .accessibilityLabel("AgentBar: agents running")
        case .attention:
            HStack(spacing: 3) {
                Image(systemName: "circle.fill")
                Text("\(waiting)").monospacedDigit()
            }
            .accessibilityLabel("AgentBar: \(waiting) need\(waiting == 1 ? "s" : "") you")
        }
    }
}
