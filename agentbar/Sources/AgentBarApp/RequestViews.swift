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
    /// The decision, plus the chosen answers for a question (question text → labels joined with ", ").
    let onDecide: (Decision, [String: String]?) -> Void

    init(session: Session, request: PermissionRequestInfo, onDecide: @escaping (Decision, [String: String]?) -> Void) {
        self.session = session
        self.request = request
        self.onDecide = onDecide
    }

    @State private var going = false
    /// Picked option labels per question (index → labels, in option order).
    @State private var picked: [Int: Set<String>] = [:]
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
            if let questions = request.questions, !questions.isEmpty {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    questionView(question, index: index, numbered: questions.count > 1)
                }
            } else if let detail = request.detail {
                script(detail)
            }
            if !session.recentActivity.isEmpty { before }
            if request.isQuestion { questionActions } else { actions }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.standby))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.standbyEdge, lineWidth: 1))
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { armed = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Format.agentName(session.agent)) in \(Format.project(session)) is asking: \(headline)")
    }

    /// Claude Code asks in the terminal; IDE agents ask in their own window.
    private var answerElsewhere: String {
        ["claude-code", "codex", "gemini-cli"].contains(session.agent) ? "Answer in terminal" : "Answer in \(Format.agentName(session.agent))"
    }

    private var isPlan: Bool { request.tool == "ExitPlanMode" }

    private var headline: String {
        if request.isQuestion { return (request.questions?.count ?? 0) > 1 ? "Has \(request.questions!.count) questions for you" : "Has a question for you" }
        if isPlan { return "Has a plan ready and wants to start working" }
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
                Text(isPlan ? "The plan" : request.tool.map { $0 == "Bash" || $0 == "Terminal" ? "Exact command" : "Exactly what (\($0))" } ?? "Exactly what")
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
                .help(isPlan ? "Copy the plan" : "Copy the exact command")
            }
            ScrollView {
                Text(verbatim: detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.scriptInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: isPlan ? 220 : 110)
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
            terminalLink
            Spacer()
            Button(role: .destructive) { onDecide(.deny, nil) } label: {
                Text(isPlan ? "Keep planning" : "Deny").frame(minWidth: 56)
            }
            .buttonStyle(GoButtonStyle(kind: .hold))
            .help(isPlan ? "Don't start yet. The agent is asked to revise the plan." : "Refuse. The agent is told you said no.")
            Button {
                go(.allow, nil)
            } label: {
                Text(isPlan ? "Approve plan" : "Allow").fontWeight(.semibold).frame(minWidth: 56)
            }
            .buttonStyle(GoButtonStyle())
            .disabled(going || !armed)
            .help(isPlan ? "Approve the plan. The agent starts working on it." : "Let the agent do exactly this, once.")
        }
    }

    private var terminalLink: some View {
        Button(answerElsewhere) { onDecide(.deferred, nil) }
            .buttonStyle(.link)
            .font(.caption)
            .help("Don't decide here. The agent will ask in its own window.")
    }

    private func go(_ decision: Decision, _ answers: [String: String]?) {
        going = true
        // Let the lamp flash green before the cue folds away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDecide(decision, answers) }
    }

    // MARK: Questions

    private func questionView(_ question: Question, index: Int, numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let header = question.header { TapeLabel(text: header) }
                if question.allowsMany {
                    Text("Pick any").font(.caption2).foregroundStyle(Theme.inkSecondary)
                }
            }
            Text(verbatim: numbered ? "\(index + 1). \(question.question)" : question.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(question.options, id: \.label) { option in
                    optionRow(option, selected: picked[index]?.contains(option.label) == true, many: question.allowsMany) {
                        toggle(option.label, in: index, many: question.allowsMany)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func optionRow(_ option: Question.Option, selected: Bool, many: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: many ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Theme.go : Theme.inkTertiary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: option.label).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(Theme.ink)
                    if let description = option.description {
                        Text(verbatim: description).font(.caption).foregroundStyle(Theme.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.go.opacity(0.12) : Theme.script.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Theme.go.opacity(0.6) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(going)
        .accessibilityLabel(option.description.map { "\(option.label). \($0)" } ?? option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func toggle(_ label: String, in index: Int, many: Bool) {
        var set = picked[index] ?? []
        if many {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        picked[index] = set
    }

    /// question text → chosen labels (in the order offered), once every question has an answer.
    private var answers: [String: String]? {
        guard let questions = request.questions, !questions.isEmpty else { return nil }
        var result: [String: String] = [:]
        for (i, q) in questions.enumerated() {
            let chosen = q.options.map(\.label).filter { picked[i]?.contains($0) == true }
            guard !chosen.isEmpty else { return nil }
            result[q.question] = chosen.joined(separator: ", ")
        }
        return result
    }

    private var questionActions: some View {
        HStack(spacing: 8) {
            terminalLink
            Spacer()
            Button {
                if let answers { go(.allow, answers) }
            } label: {
                Text((request.questions?.count ?? 0) > 1 ? "Send answers" : "Send answer").fontWeight(.semibold).frame(minWidth: 56)
            }
            .buttonStyle(GoButtonStyle())
            .disabled(going || !armed || answers == nil)
            .help("Send your choice to the agent. It carries on from there.")
        }
    }
}

/// Floating, non-activating popup listing every standing-by cue. It appears on top of other
/// windows without stealing keyboard focus from what you're typing.
@MainActor
final class RequestPopupController {
    private var panel: NSPanel?
    private var host: NSView?

    func update(model: AppModel, show: Bool) {
        if model.pendingRequests.isEmpty {
            close()
            return
        }
        guard show || panel?.isVisible == true else { return }
        let panel = self.panel ?? makePanel(model: model)
        self.panel = panel
        fit(panel)
        panel.orderFrontRegardless()
        // SwiftUI applies the model change on the next pass; fit again once it has.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            self.fit(panel)
        }
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
        // No traffic lights: "Later" hides the popup, and it can't be minimised or zoomed.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let host = NSHostingView(rootView: RequestPopupView(onClose: { [weak panel] in panel?.orderOut(nil) })
            .environmentObject(model))
        panel.contentView = host
        self.host = host
        return panel
    }

    /// Sizes the window to its content (never taller than the screen) and pins it to the
    /// top-right of the screen with the mouse, just under the menu bar.
    private func fit(_ panel: NSPanel) {
        guard let host else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        host.layoutSubtreeIfNeeded()
        let content = host.fittingSize
        let height = min(content.height, visible.height - 24)
        let frame = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: content.width, height: height))
        panel.setFrame(NSRect(x: visible.maxX - frame.width - 12, y: visible.maxY - frame.height - 8,
                              width: frame.width, height: frame.height), display: true)
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
                            CueCard(session: session, request: request) { decision, answers in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    model.decide(sessionKey: session.id, requestID: request.id, decision: decision, answers: answers)
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
        .padding(.top, 18)
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
