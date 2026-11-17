import Foundation
import AgentBarCore

/// User preferences, saved in UserDefaults. Every change is applied immediately.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    // Alerts
    @Published var notifyPermission: Bool { didSet { save("notifyPermission", notifyPermission) } }
    @Published var notifyNeedsInput: Bool { didSet { save("notifyNeedsInput", notifyNeedsInput) } }
    @Published var notifyFinished: Bool { didSet { save("notifyFinished", notifyFinished) } }
    @Published var notifyProblems: Bool { didSet { save("notifyProblems", notifyProblems) } }
    @Published var notifyLimits: Bool { didSet { save("notifyLimits", notifyLimits) } }
    @Published var showPopup: Bool { didSet { save("showPopup", showPopup) } }
    /// Cursor and Antigravity ask before every command; let read-only ones (ls, git status…) through
    /// without a popup. Read by the `agentbar` hooks too (CommandPolicy.autoAllowEnabled).
    @Published var autoAllowReadOnly: Bool { didSet { save(CommandPolicy.preferenceKey, autoAllowReadOnly) } }

    // Timing (minutes)
    @Published var stuckMinutes: Int { didSet { save("stuckMinutes", stuckMinutes) } }
    @Published var quietMinutes: Int { didSet { save("quietMinutes", quietMinutes) } }

    // Daily limits (0 = off)
    @Published var dailyCostLimit: Double { didSet { save("dailyCostLimit", dailyCostLimit) } }
    @Published var dailyTokenLimit: Int { didSet { save("dailyTokenLimit", dailyTokenLimit) } }

    // History
    @Published var retentionDays: Int { didSet { save("retentionDays", retentionDays) } }

    /// The setup guide has been completed (or dismissed with Done).
    @Published var onboarded: Bool { didSet { save("onboarded", onboarded) } }

    /// Link schemes (other than https) the user has agreed AgentBar may open without asking.
    @Published var trustedSchemes: [String] { didSet { save("trustedSchemes", trustedSchemes) } }

    static let stuckChoices = [5, 10, 15, 30, 60]
    static let quietChoices = [30, 60, 120, 240, 480]
    static let retentionChoices = [7, 30, 90]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
        notifyPermission = bool("notifyPermission", true)
        // Popups and banners are for decisions. Status changes are tracked in the menu bar; these
        // banners are opt-in (Settings › Alerts).
        notifyNeedsInput = bool("notifyNeedsInput", false)
        notifyFinished = bool("notifyFinished", false)
        notifyProblems = bool("notifyProblems", false)
        notifyLimits = bool("notifyLimits", true)
        showPopup = bool("showPopup", true)
        autoAllowReadOnly = bool(CommandPolicy.preferenceKey, true)
        stuckMinutes = int("stuckMinutes", 10)
        quietMinutes = int("quietMinutes", 60)
        dailyCostLimit = defaults.object(forKey: "dailyCostLimit") as? Double ?? 0
        dailyTokenLimit = int("dailyTokenLimit", 0)
        retentionDays = int("retentionDays", 30)
        trustedSchemes = defaults.stringArray(forKey: "trustedSchemes") ?? []
        onboarded = bool("onboarded", false)
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }

    /// The engine configuration these settings describe.
    var engineConfig: EngineConfig {
        var config = EngineConfig(staleAfter: TimeInterval(stuckMinutes * 60),
                                  dailyCostLimitUSD: dailyCostLimit > 0 ? dailyCostLimit : nil,
                                  dailyTokenLimit: dailyTokenLimit > 0 ? dailyTokenLimit : nil)
        config.quietAfter = TimeInterval(max(quietMinutes, stuckMinutes + 5) * 60)
        return config
    }

    var retention: TimeInterval { TimeInterval(retentionDays) * 24 * 3600 }
}
