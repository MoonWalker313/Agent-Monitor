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
                Toggle("Show a popup when an agent needs a decision", isOn: $settings.showPopup)
                Toggle("Post a banner instead when the popup is off", isOn: $settings.notifyPermission)
                    .disabled(settings.showPopup)
                Toggle("Only ask about commands that change things", isOn: $settings.autoAllowReadOnly)
            } header: {
                Text("Decisions")
            } footer: {
                Text("A popup appears only when an agent needs you to decide: a permission, a question with options, or a plan to approve. Cursor and Antigravity check every terminal command with AgentBar; with the last option on, read-only ones such as ls, cat or git status run without asking and are listed as activity.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Waiting for your next message", isOn: $settings.notifyNeedsInput)
                Toggle("Finished tasks", isOn: $settings.notifyFinished)
                Toggle("Errors and agents that may be stuck", isOn: $settings.notifyProblems)
                Toggle("Daily spending or token limit reached", isOn: $settings.notifyLimits)
                LabeledContent("macOS notifications") {
                    HStack(spacing: 8) {
                        Text(model.notificationStatus).foregroundStyle(.secondary)
                        if model.notificationStatus != "allowed" && !model.notificationStatus.hasPrefix("unavailable") {
                            Button("Allow…") { model.requestNotifications() }
                        }
                    }
                }
            } header: {
                Text("Other banners")
            } footer: {
                Text("Everything agents do is tracked in the menu bar either way. Turn these on to also get a macOS banner (at most one per agent every 30 seconds).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Text("Connecting adds AgentBar's hooks to that agent's settings file in your home folder. Your other settings are kept, and the previous file is saved next to it with .agentbar-backup on the end.")
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

/// Agent connections and the command-line tool, shared by Settings and the setup guide.
struct AgentsSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ForEach(Integration.allCases) { integration in
            AgentRow(integration: integration)
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
            Text("For any other agent or script: agentbar run -- your-command")
        }
        if let message = model.setupMessage {
            Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AgentRow: View {
    @EnvironmentObject private var model: AppModel
    let integration: Integration

    private var isConnected: Bool { model.connected[integration] ?? false }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.greenInk)
                    Button("Disconnect") { model.disconnect(integration) }
                } else {
                    Button("Connect") { model.connect(integration) }
                        .help("Adds AgentBar's hooks to \(integration.displayPath)")
                }
            }
        } label: {
            Text(integration.displayName)
            Text(caption)
        }
        if isConnected && integration.approvalsAreOptional {
            Toggle(isOn: Binding(get: { model.approvals[integration] ?? false },
                                 set: { model.setApprovals(integration, $0) })) {
                Text("Answer \(integration.displayName)'s terminal commands here")
                Text("Each terminal command waits for Allow or Deny in AgentBar for up to \(Integration.ideWait) seconds, then \(integration.displayName) asks as usual.")
            }
            .padding(.leading, 16)
        }
    }

    private var caption: String {
        switch integration {
        case .claude: return "Sessions, tasks, and permission requests you can Allow or Deny here."
        case .cursor: return "Sessions, edits and commands. Can also answer its terminal commands."
        case .gemini: return "Sessions, tasks, and an alert when it's waiting for your permission (you answer in Gemini)."
        case .antigravity: return "Sessions, edits and commands. Can also answer its terminal commands."
        }
    }
}
