import SwiftUI
import AppKit
import AgentBarCore

/// A standing-by cue: an agent asking permission.
/// Reading order is the product principle "understand before deciding":
/// who is asking → what it wants, in plain words → the exact command → what it did before → decide.
/// All agent-provided text is rendered verbatim (never as markdown).
struct CueCard: View {
    let session: Session
    let request: PermissionRequestInfo
    let onDecide: (Decision) -> Void

    @State private var going = false
    @State private var copied = false
    /// Allow is ignored for a moment after the card appears, so a click meant for something
    /// else can't land on it as the popup slides in.
    @State private var armed = Snapshot.directory != nil // screenshots skip the delay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(verbatim: headline)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let detail = request.detail { script(detail) }
            if !session.recentActivity.isEmpty { before }
            actions
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.standby))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.standbyEdge, lineWidth: 1))
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { armed = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Format.agentName(session.agent)) in \(Format.project(session)) is asking: \(headline)")
    }

    private var headline: String {
        if let summary = request.summary {
            // Adapters write "Run: <what the command does>"; read it as a plain sentence.
            if summary.hasPrefix("Run: ") { return "Wants to run a command to \(summary.dropFirst(5).prefix(1).lowercased())\(summary.dropFirst(6))" }
            return "Wants to \(summary.prefix(1).lowercased())\(summary.dropFirst())"
        }
        return "Wants to use \(request.tool ?? "a tool")"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            CueLamp(color: Theme.amber, breathing: !going, flash: going)
            TapeLabel(text: Format.project(session))
            Text(verbatim: Format.agentName(session.agent))
                .font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            Spacer(minLength: 6)
            Text(going ? "Go" : "Standing by")
                .font(.caption.weight(.semibold))
                .foregroundStyle(going ? Theme.greenInk : Theme.amberInk)
            AgoText(date: session.stateEnteredAt)
        }
    }

    private func script(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(request.tool.map { $0 == "Bash" ? "Exact command" : "Exactly what (\($0))" } ?? "Exactly what")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.inkSecondary)
                .help("Copy the exact command")
            }
            ScrollView {
                Text(verbatim: detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.scriptInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.script))
            .accessibilityLabel("Exact command: \(detail)")
        }
    }

    private var before: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Before this").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
            ForEach(Array(session.recentActivity.suffix(3).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(Theme.inkTertiary).frame(width: 3, height: 3).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text(verbatim: item.text).font(.caption).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    AgoText(date: item.at)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Answer in terminal") { onDecide(.deferred) }
                .buttonStyle(.link)
                .font(.caption)
                .help("Don't decide here. The agent will ask in its own window.")
            Spacer()
            Button(role: .destructive) { onDecide(.deny) } label: {
                Text("Deny").frame(minWidth: 56)
            }
            .buttonStyle(GoButtonStyle(kind: .hold))
            .help("Refuse. The agent is told you said no.")
            Button {
                going = true
                // Let the lamp flash green before the cue folds away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDecide(.allow) }
            } label: {
                Text("Allow").fontWeight(.semibold).frame(minWidth: 56)
            }
            .buttonStyle(GoButtonStyle())
            .disabled(going || !armed)
            .help("Let the agent do exactly this, once.")
        }
    }
}

/// Floating, non-activating popup listing every standing-by cue. It appears on top of other
/// windows without stealing keyboard focus from what you're typing.
@MainActor
final class RequestPopupController {
    private var panel: NSPanel?

    func update(model: AppModel, show: Bool) {
        if model.pendingRequests.isEmpty {
            close()
            return
        }
        guard show || panel?.isVisible == true else { return }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = "AgentBar"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor(Theme.panel)
        let host = NSHostingView(rootView: RequestPopupView(onClose: { [weak panel] in panel?.orderOut(nil) })
            .environmentObject(model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    /// Top-right of the screen with the mouse, just under the menu bar.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.layoutIfNeeded()
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8))
    }
}

struct RequestPopupView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("AgentBar").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(model.pendingRequests.count == 1 ? "1 agent standing by" : "\(model.pendingRequests.count) agents standing by")
                    .font(.caption).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button("Later") { onClose() }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(Theme.inkSecondary)
                    .help("Hide this. The requests stay in the menu bar.")
            }
            ScrollView {
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
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 30) // the transparent title bar's close button sits here
        .padding(.bottom, 14)
        .frame(width: 400)
        .background(Theme.panel)
    }
}

/// The Go button. Stays green even in the non-activating popup, where a stock prominent
/// button would turn grey because its window is never key.
struct GoButtonStyle: ButtonStyle {
    enum Kind { case go, hold }
    var kind: Kind = .go
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .go ? .semibold : .regular))
            .foregroundStyle(kind == .go ? Color.white : Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(kind == .go ? Theme.go : Theme.cue)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
