import Foundation

public enum Paths {
    /// `~/Library/Application Support/AgentBar` (override with AGENTBAR_HOME, used by tests).
    public static var supportDirectory: String {
        if let override = ProcessInfo.processInfo.environment["AGENTBAR_HOME"], !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Library/Application Support/AgentBar")
    }

    /// Socket path (override with AGENTBAR_SOCKET).
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["AGENTBAR_SOCKET"], !override.isEmpty {
            return override
        }
        return (supportDirectory as NSString).appendingPathComponent("agentbar.sock")
    }

    /// SQLite database (override with AGENTBAR_DB).
    public static var databasePath: String {
        if let override = ProcessInfo.processInfo.environment["AGENTBAR_DB"], !override.isEmpty {
            return override
        }
        return (supportDirectory as NSString).appendingPathComponent("agentbar.sqlite")
    }
}
