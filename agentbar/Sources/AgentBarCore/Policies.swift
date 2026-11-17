import Foundation

/// Which `open_url` values AgentBar will ever open (PRD D3).
/// Never file://, javascript:, data:, paths or commands.
public enum URLPolicy {
    public static let maxLength = 2048

    /// https plus known editor / terminal / desktop-app schemes.
    public static let allowedSchemes: Set<String> = [
        "https",
        "vscode", "vscode-insiders", "cursor", "windsurf", "zed", "jetbrains",
        "iterm2", "warp", "x-github-client",
    ]

    public enum Verdict: Equatable, Sendable {
        case allowed(URL)
        case rejected(String)
    }

    public static func evaluate(_ raw: String) -> Verdict {
        guard raw.utf8.count <= maxLength else { return .rejected("too long") }
        guard !raw.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) else {
            return .rejected("contains whitespace or control characters")
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return .rejected("not a valid URL")
        }
        guard allowedSchemes.contains(scheme) else { return .rejected("scheme '\(scheme)' is not allowed") }
        if url.user != nil || url.password != nil { return .rejected("credentials in URL are not allowed") }
        if scheme == "https", (url.host ?? "").isEmpty { return .rejected("https URL needs a host") }
        return .allowed(url)
    }
}

/// `activate_bundle_id` must look like a reverse-DNS bundle identifier. Whether the app is
/// actually installed is checked by the app (AppKit) at open time.
public enum BundleIDPolicy {
    public static func isValid(_ id: String) -> Bool {
        guard id.count <= 255 else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-"
            }
        }
    }
}

/// Per-key token bucket (plan §4.2: 20 events/s per session, extra events are refused).
/// Not thread-safe: the socket server uses it from its own serial queue.
public final class RateLimiter {
    public static let defaultRate = 20.0

    private struct Bucket { var tokens: Double; var last: Date }
    private var buckets: [String: Bucket] = [:]
    private let rate: Double
    private let burst: Double
    private let maxKeys: Int

    public init(rate: Double = RateLimiter.defaultRate, burst: Double = 40, maxKeys: Int = 2_000) {
        self.rate = rate
        self.burst = burst
        self.maxKeys = maxKeys
    }

    public func allow(_ key: String, now: Date = Date()) -> Bool {
        var bucket = buckets[key] ?? Bucket(tokens: burst, last: now)
        let elapsed = max(0, now.timeIntervalSince(bucket.last))
        bucket.tokens = min(burst, bucket.tokens + elapsed * rate)
        bucket.last = now
        let allowed = bucket.tokens >= 1
        if allowed { bucket.tokens -= 1 }
        buckets[key] = bucket
        if buckets.count > maxKeys { prune(now: now) }
        return allowed
    }

    /// Drops buckets that have fully refilled (idle long enough to be indistinguishable from new).
    private func prune(now: Date) {
        let idle = burst / rate
        buckets = buckets.filter { now.timeIntervalSince($0.value.last) < idle }
    }

    public var trackedKeys: Int { buckets.count }
}
