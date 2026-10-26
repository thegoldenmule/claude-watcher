import Foundation

/// How full a session's context window is. Claude Code's window is 1M tokens; transcripts don't
/// record it, so it's assumed.
public enum ContextUsage {
    public static let window = 1_000_000

    public enum Level: Sendable, Equatable {
        case normal, warning, critical
    }

    /// `tokens / window`, clamped to 0...1.
    public static func fraction(_ tokens: Int, window: Int = window) -> Double {
        guard window > 0 else { return 0 }
        return min(1, max(0, Double(tokens) / Double(window)))
    }

    /// Below 50%: normal; 50% up to 75%: warning (yellow); 75% and up: critical (red).
    public static func level(_ fraction: Double) -> Level {
        if fraction >= 0.75 { return .critical }
        if fraction >= 0.5 { return .warning }
        return .normal
    }

    /// "245k", "1.0M", "850".
    public static func shortTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(tokens / 1_000)k" }
        return "\(max(0, tokens))"
    }

    /// Whole percent used, 0...100, rounded down (in integers, so 290k is 29%) so it agrees
    /// with `level`: 749,999 tokens read 74%, still a warning.
    public static func percent(_ tokens: Int, window: Int = window) -> Int {
        guard window > 0 else { return 0 }
        return min(100, max(0, tokens) * 100 / window)
    }

    /// "245k / 1M · 25%". A round window drops the decimal ("1M", not "1.0M").
    public static func label(_ tokens: Int, window: Int = window) -> String {
        let size = window > 0 && window % 1_000_000 == 0 ? "\(window / 1_000_000)M" : shortTokens(window)
        return "\(shortTokens(tokens)) / \(size) · \(percent(tokens, window: window))%"
    }
}
