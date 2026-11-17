import SwiftUI
import AppKit
import AgentBarCore

/// AgentBar's Settings window: a standard macOS grouped form.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var costText = ""
    @State private var tokenText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Permission requests", isOn: $settings.notifyPermission)
                Toggle("Questions and waiting for your next message", isOn: $settings.notifyNeedsInput)
                Toggle("Finished tasks", isOn: $settings.notifyFinished)
                Toggle("Errors and agents that may be stuck", isOn: $settings.notifyProblems)
                Toggle("Daily spending or token limit reached", isOn: $settings.notifyLimits)
                Toggle("Show a popup for permission requests", isOn: $settings.showPopup)
                LabeledContent("macOS notifications") {
                    HStack(spacing: 8) {
                        Text(model.notificationStatus).foregroundStyle(.secondary)
                        if model.notificationStatus != "allowed" && !model.notificationStatus.hasPrefix("unavailable") {
                            Button("Allow…") { model.requestNotifications() }
                        }
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Requests always appear in the menu bar, even with alerts off. Repeats from the same agent are grouped so you get at most one alert every 30 seconds.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mark as \u{201C}may be stuck\u{201D} after", selection: $settings.stuckMinutes) {
                    ForEach(AppSettings.stuckChoices, id: \.self) { Text(minutes($0)).tag($0) }
                }
                Picker("Stop showing silent agents after", selection: $settings.quietMinutes) {
                    ForEach(AppSettings.quietChoices, id: \.self) { Text(minutes($0)).tag($0) }
                }
            } header: {
                Text("Timing")
            } footer: {
                Text("A running agent that goes quiet for the first period is marked \u{201C}may be stuck\u{201D}. An agent that needs you but stays quiet for the second period is treated as closed and moves out of Needs you.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Spending per day") {
                    TextField("Spending per day", text: $costText, prompt: Text("No limit"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .onSubmit(commitLimits)
                }
                LabeledContent("Tokens per day") {
                    TextField("Tokens per day", text: $tokenText, prompt: Text("No limit"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .onSubmit(commitLimits)
                }
            } header: {
                Text("Daily limits")
            } footer: {
                Text("You're alerted once a day when an agent's reported usage passes a limit. Only agents that report usage count. Enter dollars (for example 5) or tokens (for example 2000000); leave empty for no limit.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open AgentBar at login", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
                Picker("Keep history for", selection: $settings.retentionDays) {
                    ForEach(AppSettings.retentionChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                if !settings.trustedSchemes.isEmpty {
                    LabeledContent("Links opened without asking") {
                        HStack {
                            Text(settings.trustedSchemes.sorted().joined(separator: ", ")).foregroundStyle(.secondary)
                            Button("Reset") { settings.trustedSchemes = [] }
                        }
                    }
                }
                LabeledContent("History") {
                    Button("Clear History…") { model.confirmClear() }
                }
            } header: {
                Text("General")
            }

            Section {
                AgentsSettings()
            } header: {
                Text("Agents")
            } footer: {
                Text("Connecting adds AgentBar to Claude Code's settings (~/.claude/settings.json). Your other settings are kept, and the previous file is saved as settings.json.agentbar-backup. For any other agent or script, run it with: agentbar run -- your-command")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear {
            costText = settings.dailyCostLimit > 0 ? String(format: "%g", settings.dailyCostLimit) : ""
            tokenText = settings.dailyTokenLimit > 0 ? String(settings.dailyTokenLimit) : ""
            model.refreshNotificationStatus()
            model.refreshClaudeStatus()
        }
        .onDisappear(perform: commitLimits)
    }

    private func minutes(_ m: Int) -> String {
        m < 60 ? "\(m) minutes" : (m % 60 == 0 ? "\(m / 60) hour\(m == 60 ? "" : "s")" : "\(m) minutes")
    }

    /// Accepts "5", "$5", "5.50"; "2000000", "2,000,000", "2m", "500k". Anything else clears the field.
    private func commitLimits() {
        let cost = Double(costText.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
        settings.dailyCostLimit = cost > 0 ? cost : 0
        costText = cost > 0 ? String(format: "%g", cost) : ""

        let raw = tokenText.lowercased().replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        var tokens = 0
        if raw.hasSuffix("m"), let v = Double(raw.dropLast()) { tokens = Int(v * 1_000_000) }
        else if raw.hasSuffix("k"), let v = Double(raw.dropLast()) { tokens = Int(v * 1_000) }
        else { tokens = Int(raw) ?? 0 }
        settings.dailyTokenLimit = max(0, tokens)
        tokenText = tokens > 0 ? String(tokens) : ""
    }
}

/// Owns the Settings window. A menu bar app has no main window or Settings menu item of its
/// own, so the window is opened from the panel's gear menu (⌘,).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: AppModel, settings: AppSettings) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model).environmentObject(settings))
            let window = NSWindow(contentViewController: host)
            window.title = "AgentBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Claude Code connection and the command-line tool, shared by Settings and the setup guide.
struct AgentsSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if model.claudeConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.greenInk)
                    Button("Disconnect") { model.disconnectClaude() }
                } else {
                    Button("Connect") { model.connectClaude() }
                        .help("Adds AgentBar's hooks to ~/.claude/settings.json")
                }
            }
        } label: {
            Text("Claude Code")
            Text("Shows every session, and lets you answer permission requests here.")
        }
        LabeledContent {
            if model.cliInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.greenInk)
            } else {
                Button("Install") { model.installCLI() }
                    .help("Links ~/.local/bin/agentbar to the command inside AgentBar")
            }
        } label: {
            Text("agentbar command")
            Text("For running other agents and scripts from Terminal.")
        }
        if let message = model.setupMessage {
            Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
