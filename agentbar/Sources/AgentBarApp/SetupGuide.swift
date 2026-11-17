import SwiftUI
import AppKit
import AgentBarCore

/// First-run guide: four short steps, each doable right here. Shown once on first launch,
/// and any time from the gear menu (Setup Guide…).
struct SetupGuideView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                CueLamp(color: Theme.amber, breathing: true, size: 14)
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to AgentBar").font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("See what your AI agents are doing, and answer them when they need you, from the menu bar.")
                        .font(.callout).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Form {
                Section {
                    LabeledContent {
                        if model.notificationStatus == "allowed" {
                            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.greenInk)
                        } else {
                            Button("Allow Alerts") { model.requestNotifications() }
                        }
                    } label: {
                        Text("Get alerts")
                        Text("So you hear about requests while you're working in other apps.")
                    }
                } header: { Text("1. Alerts") }

                Section {
                    Toggle(isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) })) {
                        Text("Open AgentBar at login")
                        Text("Agents can only reach AgentBar while it's running.")
                    }
                } header: { Text("2. Always on") }

                Section {
                    AgentsSettings()
                } header: { Text("3. Connect your agents") }

                Section {
                    LabeledContent {
                        Button("Send a Sample Request") { model.sendTestEvents() }
                    } label: {
                        Text("See a request")
                        Text(model.lastTestResult ?? "A sample agent asks permission. Answer it with Allow or Deny. Nothing runs.")
                    }
                } header: { Text("4. Try it") }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Text("You can change all of this later in Settings (⌘,).").font(.caption).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 680)
        .background(Theme.panel)
        .onAppear {
            model.refreshNotificationStatus()
            model.refreshClaudeStatus()
        }
    }
}

@MainActor
final class SetupGuideController {
    private var window: NSWindow?

    func show(model: AppModel, settings: AppSettings) {
        if window == nil {
            let view = SetupGuideView(done: { [weak self] in
                settings.onboarded = true
                self?.window?.close()
            })
            .environmentObject(model)
            .environmentObject(settings)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Set Up AgentBar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
