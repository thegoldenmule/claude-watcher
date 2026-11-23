import Foundation

/// Which rate-limit window a meter shows.
public enum UsageWindowKind: Sendable, Equatable {
    case session, weekly

    /// Short label for the menu ("5h", "Week").
    public var shortLabel: String {
        switch self {
        case .session: "5h"
        case .weekly: "Week"
        }
    }

    /// Spoken name, for accessibility ("session", "weekly").
    public var spokenName: String {
        switch self {
        case .session: "session"
        case .weekly: "weekly"
        }
    }
}

extension AgentKind {
    /// Product name for the menu ("Claude Code", "Codex").
    public var productName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Two-letter caption for the menu bar meter ("CC", "CX").
    public var meterCaption: String {
        switch self {
        case .claude: "CC"
        case .codex: "CX"
        }
    }
}

/// What one agent's menu bar meter shows: its most constraining window.
public struct UsageMeter: Sendable, Equatable {
    public var agent: AgentKind
    public var kind: UsageWindowKind
    /// 0 once the window has reset; may exceed 100.
    public var percent: Double
    public var level: UsageLevel
    /// The latest poll failed (`.stale`): drawn dimmed, never coloured.
    public var isStale: Bool

    public init(agent: AgentKind, kind: UsageWindowKind, percent: Double, level: UsageLevel, isStale: Bool) {
        self.agent = agent
        self.kind = kind
        self.percent = percent
        self.level = level
        self.isStale = isStale
    }

    /// Whole percent for display, as the menu shows it (`UsageDisplay.wholePercent`).
    public var roundedPercent: Int { UsageDisplay.wholePercent(percent) }

    /// How much of the bar to fill, 0...1. Follows `roundedPercent`, so the bar and its label
    /// agree: a value that reads "0%" draws no fill (and any fill reads at least "1%").
    public var fillFraction: Double { min(Double(roundedPercent) / 100, 1) }

    /// "Claude Code session usage 42 percent", plus ", warning"/", critical" and ", out of date".
    public var accessibilityText: String {
        var text = "\(agent.productName) \(kind.spokenName) usage \(roundedPercent) percent"
        switch level {
        case .normal: break
        case .warning: text += ", warning"
        case .critical: text += ", critical"
        }
        if isStale { text += ", out of date" }
        return text
    }
}

/// Pure display rules for plan usage (menu bar meters and menu lines).
///
/// Visibility: an agent's meter shows iff it has a snapshot with at least one window and its
/// status isn't `.unavailable` or `.error` (`.ok`, `.stale`, or `.loading` with a snapshot).
/// Its menu lines show iff the meter does (plus an error line for `.stale`), or the status is
/// `.error`/`.stale` (the error line only). So `.unavailable`, and `.loading` with no snapshot,
/// show nothing anywhere.
public enum UsageDisplay {
    /// Largest whole percent shown; a bigger (malformed) value reads as this.
    public static let maxWholePercent = 9999

    /// `percent` rounded to a whole number for display, clamped to 0...`maxWholePercent`
    /// (NaN reads 0), so no server value can trap the `Int` conversion.
    public static func wholePercent(_ percent: Double) -> Int {
        guard !percent.isNaN else { return 0 }
        return Int(min(max(percent, 0), Double(maxWholePercent)).rounded())
    }

    /// The meter for `usage` at `now`, or nil if hidden. Shows whichever window has the higher
    /// `displayPercent(at:)` (a reset window counts 0); the session window wins a tie.
    public static func meter(for usage: AgentUsage, now: Date) -> UsageMeter? {
        guard let (kind, window) = mostConstraining(usage, now: now) else { return nil }
        let percent = window.displayPercent(at: now)
        return UsageMeter(agent: usage.agent, kind: kind, percent: percent,
                          level: UsageLevel(percent: percent), isStale: isStale(usage.status))
    }

    /// The meters to draw, in `agents` order.
    public static func meters(_ usage: [AgentKind: AgentUsage], agents: [AgentKind], now: Date) -> [UsageMeter] {
        agents.compactMap { agent in usage[agent].flatMap { meter(for: $0, now: now) } }
    }

    /// The menu's disabled info lines for one agent: the usage line, plus an error line when the
    /// latest poll failed. Empty when the agent is hidden.
    ///
    /// `Claude Code: 5h 42% (resets in 2h 10m) · Week 67% (resets Thu 9:00 AM)`
    /// `Claude Code: Couldn't reach the usage server (as of 3:05 PM)` (stale)
    /// `Codex: Couldn't read usage` (error, no snapshot)
    public static func menuLines(for usage: AgentUsage, now: Date, calendar: Calendar = .current,
                                 locale: Locale = .current) -> [String] {
        let name = usage.agent.productName
        var lines: [String] = []
        if let windows = windows(usage), isShown(usage.status) {
            let parts = windows.map { kind, window in
                windowText(kind: kind, window: window, now: now, calendar: calendar, locale: locale)
            }
            lines.append("\(name): " + parts.joined(separator: " · "))
        }
        switch usage.status {
        case .stale(let message) where !lines.isEmpty:
            let asOf = usage.snapshot.map { clockText($0.asOf, now: now, calendar: calendar, locale: locale) }
            lines.append("\(name): \(message)" + (asOf.map { " (as of \($0))" } ?? ""))
        case .error(let message), .stale(let message):
            lines.append("\(name): \(message)")
        case .unavailable, .loading, .ok:
            break
        }
        return lines
    }

    /// "5h 42% (resets in 2h 10m)", "Week 67% (resets Thu 9:00 AM)", "5h 0% (reset)", "Week 12%".
    public static func windowText(kind: UsageWindowKind, window: UsageWindow, now: Date,
                                  calendar: Calendar = .current, locale: Locale = .current) -> String {
        let percent = wholePercent(window.displayPercent(at: now))
        let head = "\(kind.shortLabel) \(percent)%"
        guard let resetsAt = window.resetsAt else { return head }
        if window.hasReset(at: now) { return head + " (reset)" }
        return head + " (resets \(resetText(resetsAt, now: now, calendar: calendar, locale: locale)))"
    }

    /// Under a day away: "in 2h 10m" / "in 45m" (minutes rounded up, so never "in 0m");
    /// else the clock time: "Thu 9:00 AM" within the next 6 days (never today's weekday, which
    /// would be ambiguous), "Dec 2, 9:00 AM" beyond.
    public static func resetText(_ date: Date, now: Date, calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        let remaining = date.timeIntervalSince(now)
        if remaining < 24 * 3600 {
            let minutes = max(1, Int((remaining / 60).rounded(.up)))
            let hours = minutes / 60, rest = minutes % 60
            if hours == 0 { return "in \(rest)m" }
            return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
        }
        // Reset timestamps drift by fractions of a second between readings: round to the minute.
        let rounded = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: rounded)).day ?? 7
        style = days < 7
            ? style.weekday(.abbreviated).hour().minute()
            : style.month(.abbreviated).day().hour().minute()
        return rounded.formatted(style)
    }

    // MARK: Rules

    private static func isStale(_ status: UsageStatus) -> Bool {
        if case .stale = status { true } else { false }
    }

    /// Statuses whose snapshot (if any) is shown.
    private static func isShown(_ status: UsageStatus) -> Bool {
        switch status {
        case .ok, .stale, .loading: true
        case .unavailable, .error: false
        }
    }

    /// The snapshot's windows, session first; nil if there are none.
    private static func windows(_ usage: AgentUsage) -> [(UsageWindowKind, UsageWindow)]? {
        guard let snapshot = usage.snapshot else { return nil }
        let windows = [(UsageWindowKind.session, snapshot.session), (.weekly, snapshot.weekly)]
            .compactMap { kind, window in window.map { (kind, $0) } }
        return windows.isEmpty ? nil : windows
    }

    private static func mostConstraining(_ usage: AgentUsage, now: Date) -> (UsageWindowKind, UsageWindow)? {
        guard isShown(usage.status), let windows = windows(usage) else { return nil }
        // Session first, and only a strictly higher weekly replaces it.
        return windows.dropFirst().reduce(windows[0]) { best, next in
            next.1.displayPercent(at: now) > best.1.displayPercent(at: now) ? next : best
        }
    }

    /// "3:05 PM" today, else "Nov 22, 3:05 PM".
    private static func clockText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = calendar.isDate(date, inSameDayAs: now)
            ? style.hour().minute()
            : style.month(.abbreviated).day().hour().minute()
        return date.formatted(style)
    }
}
