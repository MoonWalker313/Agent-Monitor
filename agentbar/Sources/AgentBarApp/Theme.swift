import SwiftUI
import AppKit
import AgentBarCore

/// "Standby, Go" — a stage manager's cue-light board, rendered with native macOS controls.
/// Every token has a light ("house lights") and dark ("blackout") value and follows the system appearance.
enum Theme {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                                                     .accessibilityHighContrastAqua])?.rawValue.lowercased().contains("dark") ?? false
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // Grounds
    static let panel = dynamic(light: 0xF2F1EE, dark: 0x161618)
    static let cue = dynamic(light: 0xFFFFFF, dark: 0x232326)
    static let cueHover = dynamic(light: 0xF7F6F3, dark: 0x2B2B2F)
    static let standby = dynamic(light: 0xFFF6E3, dark: 0x251E11)
    static let standbyEdge = dynamic(light: 0xE8B65A, dark: 0x7A5A1C)
    static let hairline = dynamic(light: 0xDEDBD4, dark: 0x343438)

    // Text (all ≥4.5:1 on their grounds)
    static let ink = dynamic(light: 0x1D1D1F, dark: 0xF2F2F7)
    static let inkSecondary = dynamic(light: 0x5F5E63, dark: 0xA8A8AD)
    static let inkTertiary = dynamic(light: 0x77767B, dark: 0x8E8E93)

    // Gaffer-tape label
    static let tape = dynamic(light: 0xE4E0D7, dark: 0x3A3A3D)
    static let tapeInk = dynamic(light: 0x47443D, dark: 0xD6D6DB)

    // Printed command block
    static let script = dynamic(light: 0xF8F3E7, dark: 0x0F0F10)
    static let scriptInk = dynamic(light: 0x4F3800, dark: 0xFFD58A)

    // Lamps (fills) and their readable text tints
    static let amber = dynamic(light: 0xF0A01C, dark: 0xFFB020)
    static let amberInk = dynamic(light: 0x8A5600, dark: 0xFFC14D)
    static let blue = dynamic(light: 0x0A7AFF, dark: 0x0A84FF)
    static let blueInk = dynamic(light: 0x0060CC, dark: 0x5EAEFF)
    static let green = dynamic(light: 0x2DB653, dark: 0x30D158)
    static let greenInk = dynamic(light: 0x1C7A37, dark: 0x5EDB7F)
    static let red = dynamic(light: 0xE5372B, dark: 0xFF453A)
    static let redInk = dynamic(light: 0xC0261B, dark: 0xFF7A70)
    static let unlit = dynamic(light: 0xB9B6AF, dark: 0x4A4A4E)

    /// The Go button.
    static let go = dynamic(light: 0x1F7A36, dark: 0x248A3D)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// How each session state reads: lamp colour, text tint, glyph and word.
/// Colour is never the only carrier: every state has its own glyph and word too.
struct CueStyle {
    let lamp: Color
    let ink: Color
    let symbol: String
    let word: String
    let lit: Bool

    static func of(_ session: Session) -> CueStyle {
        switch session.state {
        case .waiting:
            return session.pendingRequest != nil
                ? CueStyle(lamp: Theme.amber, ink: Theme.amberInk, symbol: "hand.raised.fill", word: "Standing by", lit: true)
                : CueStyle(lamp: Theme.amber, ink: Theme.amberInk, symbol: "bubble.left.fill", word: "Needs you", lit: true)
        case .running: return CueStyle(lamp: Theme.blue, ink: Theme.blueInk, symbol: "play.fill", word: "Running", lit: true)
        case .stale: return CueStyle(lamp: Theme.amber, ink: Theme.amberInk, symbol: "hourglass", word: "May be stuck", lit: false)
        case .finished: return CueStyle(lamp: Theme.green, ink: Theme.greenInk, symbol: "checkmark", word: "Done", lit: true)
        case .errored: return CueStyle(lamp: Theme.red, ink: Theme.redInk, symbol: "exclamationmark.triangle.fill", word: "Error", lit: true)
        case .stopped: return CueStyle(lamp: Theme.unlit, ink: Theme.inkTertiary, symbol: "stop.fill", word: "Stopped", lit: false)
        }
    }
}

/// The cue lamp: the board's signature. A lit lamp glows; a standing-by lamp breathes
/// (held steady when Reduce Motion is on). `flash` turns it green for the "Go" moment.
struct CueLamp: View {
    let color: Color
    var lit = true
    var breathing = false
    var flash = false
    var size: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The breath is computed from the clock, not a repeatForever animation: a forever
        // transaction also animates the lamp's (and its row's) position on every layout pass,
        // which made the whole panel drift. This only ever changes the glow; layout never moves.
        let animate = breathing && !reduceMotion && (lit || flash)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animate)) { context in
            let phase = animate ? (sin(context.date.timeIntervalSinceReferenceDate * .pi / 1.4) + 1) / 2 : 0
            lamp(glow: phase)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func lamp(glow: Double) -> some View {
        let fill = flash ? Theme.go : color
        let on = lit || flash
        return Circle()
            .fill(on ? fill : Theme.unlit)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: on ? fill.opacity(0.45 + 0.45 * glow) : .clear, radius: 3 + 2 * glow, y: 0.5)
    }
}

/// "just now", "4 min", "1 hr 5 min": coarse and stable. Refreshes every 30 s instead of every
/// second, so rows don't re-measure (and the menu bar window doesn't resize) on a ticking clock.
struct AgoText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(verbatim: Format.ago(date, now: context.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Gaffer-tape label: a small mono tag naming the project, as on a cue board.
struct TapeLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.tapeInk)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.tape))
    }
}

/// Glyph + word for a state, tinted for legibility.
struct StateTag: View {
    let style: CueStyle

    var body: some View {
        Label {
            Text(style.word)
        } icon: {
            Image(systemName: style.symbol).imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .foregroundStyle(style.ink)
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours) hr" : "\(hours) hr \(minutes % 60) min" }
        return "\(hours / 24) d"
    }

    /// Project name for a session: its title, else the cwd folder, else the agent.
    static func project(_ s: Session) -> String {
        s.title ?? s.cwd.map { ($0 as NSString).lastPathComponent } ?? s.agent
    }

    /// "Claude Code" for "claude-code".
    static func agentName(_ agent: String) -> String {
        Integration.allCases.first(where: { $0.agentID == agent })?.displayName
            ?? agent.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
