import SwiftUI
import AppKit
import AgentBarCore

/// The menu bar panel: a cue board. Standing-by cues lead as full cards; everything else
/// is a compact cue row grouped by what it needs from you.
struct PanelView: View {
    @EnvironmentObject private var model: AppModel
    /// Rows the user has opened to see their tasks.
    @State private var expanded: Set<String>
    @State private var showAllDone = false

    init(expanded: Set<String> = []) { _expanded = State(initialValue: expanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            notices
            Divider().overlay(Theme.hairline)
            if model.sessions.isEmpty {
                EmptyBoard(sendTest: model.sendTestEvents)
            } else {
                board
            }
            Divider().overlay(Theme.hairline)
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 400)
        .background(Theme.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("AgentBar").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(verbatim: headline).font(.caption).foregroundStyle(Theme.inkSecondary)
            Spacer()
            SettingsMenu()
        }
    }

    private var headline: String {
        let s = model.summary
        var parts: [String] = []
        if model.pendingRequests.count > 0 { parts.append("\(model.pendingRequests.count) standing by") }
        let otherNeeds = s.needsAttention - model.pendingRequests.count
        if otherNeeds > 0 { parts.append("\(otherNeeds) need\(otherNeeds == 1 ? "s" : "") you") }
        if s.running > 0 { parts.append("\(s.running) running") }
        return parts.isEmpty ? (model.sessions.isEmpty ? "" : "All quiet") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var notices: some View {
        ForEach(Array([model.serverError.map { "AgentBar can't hear agents: \($0)" },
                       model.storageError, model.decisionNote].compactMap { $0 }.enumerated()), id: \.offset) { _, text in
            Label { Text(verbatim: text) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.caption)
                .foregroundStyle(Theme.amberInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
    }

    // MARK: Board

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.pendingRequests.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(model.pendingRequests) { session in
                            if let request = session.pendingRequest {
                                CueCard(session: session, request: request) { decision in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        model.decide(sessionKey: session.id, requestID: request.id, decision: decision)
                                    }
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                            }
                        }
                    }
                }
                group("Needs you", sessions(where: { $0.pendingRequest == nil && ($0.state == .waiting || $0.state == .stale || $0.state == .errored) }))
                group("Running", sessions(where: { $0.state == .running }))
                doneGroup
            }
            .padding(14)
        }
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Done today" shows the 5 most recent; the rest fold behind "Show all".
    @ViewBuilder
    private var doneGroup: some View {
        let done = sessions(where: { $0.state == .finished || $0.state == .stopped })
        group("Done today", showAllDone ? done : Array(done.prefix(5)))
        if done.count > 5 {
            Button(showAllDone ? "Show fewer" : "Show all \(done.count) done") { showAllDone.toggle() }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.leading, 4)
                .padding(.top, -8)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func sessions(where predicate: (Session) -> Bool) -> [Session] {
        model.sessions.filter(predicate)
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Session]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 30) }
                        CueRow(session: session,
                               expanded: expanded.contains(session.id),
                               toggle: { toggle(session.id) },
                               open: { model.open(session) },
                               revealFolder: { model.revealFolder(session) },
                               dismiss: { model.dismiss(session) })
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cue))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let t = model.totals
            VStack(alignment: .leading, spacing: 2) {
                if t.sessions == 0 {
                    Text("Nothing yet today")
                } else {
                    Text(verbatim: countsLine(t))
                    Text(verbatim: "Agents waited on you for \(Format.duration(model.waitingSecondsToday())) today")
                }
            }
            .font(.caption2)
            .foregroundStyle(Theme.inkTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func countsLine(_ t: DailyTotals) -> String {
        var parts = ["Today: \(t.sessions) session\(t.sessions == 1 ? "" : "s")", "\(t.finished) done"]
        if t.usage.totalTokens > 0 { parts.append("\(Format.compact(t.usage.totalTokens)) tokens") }
        if t.usage.costUSD > 0 { parts.append(String(format: "$%.2f", t.usage.costUSD)) }
        return parts.joined(separator: " · ")
    }
}

/// One cue on the board. Click it to open it and see its tasks (what the agent did, newest
/// first) plus its details; click again to close.
struct CueRow: View {
    let session: Session
    let expanded: Bool
    let toggle: () -> Void
    let open: () -> Void
    let revealFolder: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if expanded {
                SessionDetail(session: session, open: canOpen ? open : nil,
                              revealFolder: session.cwd != nil ? revealFolder : nil,
                              dismiss: needsYou ? dismiss : nil)
                    .padding(.leading, 30)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(expanded ? Theme.cueHover.opacity(0.6) : .clear)
    }

    private var summary: some View {
        let style = CueStyle.of(session)
        return Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                CueLamp(color: style.lamp, lit: style.lit, breathing: session.state == .waiting)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: Format.project(session))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(verbatim: Format.agentName(session.agent))
                            .font(.caption).foregroundStyle(Theme.inkTertiary).lineLimit(1)
                        Spacer(minLength: 6)
                        AgoText(date: session.updatedAt)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.inkTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.easeOut(duration: 0.15), value: expanded)
                            .frame(width: 12)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StateTag(style: style)
                        if !expanded, let line = detailLine {
                            Text(verbatim: line).font(.caption).foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovering && !expanded ? Theme.cueHover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "Hide tasks" : "Show tasks")
        .accessibilityElement(children: .combine)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded ? "Hides this agent's tasks" : "Shows this agent's tasks")
    }

    private var canOpen: Bool { session.openURL != nil || session.activateBundleID != nil }
    private var needsYou: Bool { [.waiting, .stale, .errored].contains(session.state) }

    /// The message for states that need you; otherwise the last thing the agent did.
    private var detailLine: String? {
        switch session.state {
        case .waiting, .errored: return session.message ?? session.recentActivity.last?.text
        default: return session.recentActivity.last?.text ?? session.message
        }
    }
}

/// What opens under a row: the current status in full, the task list, and details.
struct SessionDetail: View {
    let session: Session
    let open: (() -> Void)?
    let revealFolder: (() -> Void)?
    let dismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = session.message {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(session.recentActivity.isEmpty ? "Tasks" : "Tasks (\(session.recentActivity.count), newest first)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                if session.recentActivity.isEmpty {
                    Text("No tasks reported yet. Tasks appear as the agent edits files, runs commands and finishes steps.")
                        .font(.caption).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(session.recentActivity.reversed().enumerated()), id: \.offset) { index, item in
                        TaskLine(item: item, isLatest: index == 0)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                detailRow("Agent", Format.agentName(session.agent))
                if let cwd = session.cwd { detailRow("Folder", abbreviate(cwd)) }
                detailRow("Started", session.startedAt.formatted(date: .omitted, time: .shortened))
                if session.waitingSeconds > 0 { detailRow("Waited on you", Format.duration(session.waitingSeconds)) }
                if session.usage.totalTokens > 0 || session.usage.costUSD > 0 {
                    detailRow("Usage", usageText)
                }
            }

            if open != nil || revealFolder != nil || dismiss != nil {
                HStack(spacing: 12) {
                    if let open {
                        Button("Show agent", action: open).buttonStyle(.link).font(.caption)
                    }
                    if let revealFolder {
                        Button("Show folder in Finder", action: revealFolder).buttonStyle(.link).font(.caption)
                    }
                    Spacer()
                    if let dismiss {
                        Button("Dismiss", action: dismiss)
                            .buttonStyle(.link).font(.caption)
                            .help("This doesn't need you. Move it out of Needs you.")
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var usageText: String {
        var parts: [String] = []
        if session.usage.totalTokens > 0 { parts.append("\(Format.compact(session.usage.totalTokens)) tokens") }
        if session.usage.costUSD > 0 { parts.append(String(format: "$%.2f", session.usage.costUSD)) }
        return parts.joined(separator: " · ")
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(Theme.inkTertiary).frame(width: 84, alignment: .leading)
            Text(verbatim: value).font(.caption2).foregroundStyle(Theme.inkSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// One task in a session's list: a small mark, what happened, and when.
struct TaskLine: View {
    let item: ActivityItem
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isLatest ? Theme.ink : Theme.inkTertiary)
                .frame(width: 12)
            Text(verbatim: item.text)
                .font(.caption)
                .foregroundStyle(isLatest ? Theme.ink : Theme.inkSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            AgoText(date: item.at)
        }
    }

    /// A glyph from the task's own verb, so the list scans at a glance.
    private var symbol: String {
        let t = item.text
        if t.hasPrefix("You allowed") { return "checkmark.circle" }
        if t.hasPrefix("You denied") { return "xmark.circle" }
        if t.hasPrefix("You asked") { return "person.fill" }
        if t.hasPrefix("Failed") { return "exclamationmark.triangle" }
        if t.hasPrefix("Edited") || t.hasPrefix("Wrote") { return "pencil" }
        if t.hasPrefix("Ran") { return "terminal" }
        if t.hasPrefix("Read") { return "doc.text" }
        if t.hasPrefix("Fetched") || t.hasPrefix("Searched") { return "magnifyingglass" }
        return "circle.fill"
    }
}

struct EmptyBoard: View {
    let sendTest: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            CueLamp(color: Theme.unlit, lit: false, size: 16)
                .padding(.bottom, 2)
            Text("No agents on stage").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("When an agent starts work, it shows up here. If it asks permission, you'll see exactly what it wants to do, with Allow and Deny.")
                .font(.caption).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try a sample request", action: sendTest)
                .controlSize(.regular)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}

/// Everything that isn't the board: settings, test tools and quit, in one native menu.
struct SettingsMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",")
            Button("Setup Guide…") { model.showSetupGuide() }
            Button("Try a sample request") { model.sendTestEvents() }
            Divider()
            Section("Notifications: \(model.notificationStatus)") {
                Button("Allow notifications…") { model.requestNotifications() }
                Button("Send a test notification") {
                    Notifier.shared.post(id: "test", title: "AgentBar", body: "Notifications are working.")
                }
            }
            Toggle("Open at login", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
            Divider()
            Button("Clear history…") { model.confirmClear() }
            Divider()
            Button("Quit AgentBar") {
                model.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityLabel("Settings")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { model.refreshNotificationStatus() }
    }
}
