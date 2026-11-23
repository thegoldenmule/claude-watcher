import Foundation

/// Which rate-limit window a meter shows.
public enum UsageWindowKind: Sendable, Equatable {
    case session, weekly

    /// Short label for the sidebar header and tooltips ("5h", "wk").
    public var shortLabel: String {
        switch self {
        case .session: "5h"
        case .weekly: "wk"
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
    /// Product name for tooltips and accessibility ("Claude Code", "Codex").
    public var productName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One window of an agent's usage line, ready to draw.
public struct UsageWindowDisplay: Sendable, Equatable {
    public var kind: UsageWindowKind
    /// Whole percent (`UsageDisplay.wholePercent` of `displayPercent(at:)`): 0 once reset, may exceed 100.
    public var percent: Int
    /// From the rounded percent, so the color agrees with the label.
    public var level: UsageLevel
    /// "2h10m", "45m", "Thu", "Nov 30"; nil if the source gave no reset time or it has passed.
    public var resetText: String?
    /// "in 2 hours 10 minutes", "Thursday", "November 30"; nil like `resetText`.
    public var resetSpoken: String?

    public init(kind: UsageWindowKind, percent: Int, level: UsageLevel, resetText: String?, resetSpoken: String?) {
        self.kind = kind
        self.percent = percent
        self.level = level
        self.resetText = resetText
        self.resetSpoken = resetSpoken
    }

    /// "42%".
    public var percentText: String { "\(percent)%" }

    /// How much of the bar to fill, 0...1. Follows `percent`, so the bar and its label agree: a
    /// value that reads "0%" draws no fill (and any fill reads at least "1%").
    public var fillFraction: Double { min(Double(percent) / 100, 1) }

    /// "session 42 percent, resets in 2 hours 10 minutes", plus ", warning"/", critical".
    public var accessibilityText: String {
        var text = "\(kind.spokenName) \(percent) percent"
        if let resetSpoken { text += ", resets \(resetSpoken)" }
        switch level {
        case .normal: break
        case .warning: text += ", warning"
        case .critical: text += ", critical"
        }
        return text
    }
}

/// One agent's line in the sidebar header: its windows (`claude  5h ━━━░ 42% 2h10m  wk …`), or
/// only a message when there's no reading to show.
public struct UsageLine: Sendable, Equatable, Identifiable {
    public var agent: AgentKind
    /// Session first. Empty for a message-only line (`.error`, or `.stale` with no windows).
    public var windows: [UsageWindowDisplay]
    /// The most constraining window (higher display percent; session wins ties); nil iff
    /// `windows` is empty.
    public var constraining: UsageWindowDisplay?
    /// The latest poll failed but a reading is shown (`.stale`): drawn dimmed, never coloured.
    public var isStale: Bool
    /// The failure message for `.stale`/`.error`.
    public var message: String?
    /// Tooltip: the long form of every window, then the message with the reading's time.
    public var help: String
    /// One spoken summary for the whole line.
    public var accessibilityText: String

    public var id: AgentKind { agent }

    public init(agent: AgentKind, windows: [UsageWindowDisplay], constraining: UsageWindowDisplay?,
                isStale: Bool, message: String?, help: String, accessibilityText: String) {
        self.agent = agent
        self.windows = windows
        self.constraining = constraining
        self.isStale = isStale
        self.message = message
        self.help = help
        self.accessibilityText = accessibilityText
    }
}

/// Pure display rules for plan usage (the sidebar header's usage lines).
///
/// Visibility: an agent's windows show iff it has a snapshot with at least one window and its
/// status isn't `.unavailable` or `.error` (`.ok`, `.stale`, or `.loading` with a snapshot).
/// Otherwise `.error` and `.stale` show a message-only line, and `.unavailable` or `.loading`
/// with no snapshot show nothing at all.
public enum UsageDisplay {
    /// Largest whole percent shown; a bigger (malformed) value reads as this.
    public static let maxWholePercent = 9999

    /// `percent` rounded to a whole number for display, clamped to 0...`maxWholePercent`
    /// (NaN reads 0), so no server value can trap the `Int` conversion.
    public static func wholePercent(_ percent: Double) -> Int {
        guard !percent.isNaN else { return 0 }
        return Int(min(max(percent, 0), Double(maxWholePercent)).rounded())
    }

    /// The header lines to draw, in `agents` order (hidden agents left out).
    public static func lines(_ usage: [AgentKind: AgentUsage], agents: [AgentKind], now: Date,
                             calendar: Calendar = .current, locale: Locale = .current) -> [UsageLine] {
        agents.compactMap { agent in
            usage[agent].flatMap { line(for: $0, now: now, calendar: calendar, locale: locale) }
        }
    }

    /// The header line for `usage` at `now`, or nil if the agent is hidden.
    public static func line(for usage: AgentUsage, now: Date, calendar: Calendar = .current,
                            locale: Locale = .current) -> UsageLine? {
        let name = usage.agent.productName
        let message: String?
        switch usage.status {
        case .stale(let text), .error(let text): message = text
        case .unavailable, .loading, .ok: message = nil
        }

        guard isShown(usage.status), let windows = windows(usage) else {
            guard let message else { return nil }
            return UsageLine(agent: usage.agent, windows: [], constraining: nil, isStale: false, message: message,
                             help: "\(name): \(message)", accessibilityText: "\(name) usage unavailable: \(message)")
        }

        let displays = windows.map { kind, window in
            windowDisplay(kind: kind, window: window, now: now, calendar: calendar, locale: locale)
        }
        // Session first, and only a strictly higher weekly replaces it.
        let best = windows.indices.dropFirst().reduce(0) { best, next in
            windows[next].1.displayPercent(at: now) > windows[best].1.displayPercent(at: now) ? next : best
        }
        let stale = message != nil

        var help = "\(name): " + windows.map { kind, window in
            windowText(kind: kind, window: window, now: now, calendar: calendar, locale: locale)
        }.joined(separator: " · ")
        if let message {
            let asOf = usage.snapshot.map { clockText($0.asOf, now: now, calendar: calendar, locale: locale) }
            help += "\n\(message)" + (asOf.map { " (as of \($0))" } ?? "")
        }
        var spoken = "\(name) usage: " + displays.map(\.accessibilityText).joined(separator: "; ")
        if stale { spoken += "; out of date" }

        return UsageLine(agent: usage.agent, windows: displays, constraining: displays[best], isStale: stale,
                         message: message, help: help, accessibilityText: spoken)
    }

    /// One window's display data at `now`.
    public static func windowDisplay(kind: UsageWindowKind, window: UsageWindow, now: Date,
                                     calendar: Calendar = .current, locale: Locale = .current) -> UsageWindowDisplay {
        let percent = wholePercent(window.displayPercent(at: now))
        let reset = window.resetsAt.flatMap { resetMoment($0, now: now, calendar: calendar) }
        return UsageWindowDisplay(
            kind: kind, percent: percent, level: UsageLevel(percent: Double(percent)),
            resetText: reset.map { shortText($0, calendar: calendar, locale: locale) },
            resetSpoken: reset.map { spokenText($0, calendar: calendar, locale: locale) })
    }

    /// The header's short reset: "2h10m" / "2h" / "45m" under a day away (minutes rounded up,
    /// so never "0m"); else the weekday "Thu" within the next 6 calendar days (never today's
    /// weekday, which would be ambiguous); else the date "Nov 30". Nil once `date` has passed.
    public static func shortResetText(_ date: Date, now: Date, calendar: Calendar = .current,
                                      locale: Locale = .current) -> String? {
        resetMoment(date, now: now, calendar: calendar).map { shortText($0, calendar: calendar, locale: locale) }
    }

    /// "5h 42% (resets in 2h 10m)", "wk 67% (resets Thu 9:00 AM)", "5h 0% (reset)", "wk 12%":
    /// the tooltip's long form of one window.
    public static func windowText(kind: UsageWindowKind, window: UsageWindow, now: Date,
                                  calendar: Calendar = .current, locale: Locale = .current) -> String {
        let percent = wholePercent(window.displayPercent(at: now))
        let head = "\(kind.shortLabel) \(percent)%"
        guard let resetsAt = window.resetsAt else { return head }
        if window.hasReset(at: now) { return head + " (reset)" }
        return head + " (resets \(resetText(resetsAt, now: now, calendar: calendar, locale: locale)))"
    }

    /// The tooltip's long reset: "in 2h 10m" / "in 45m" under a day away (or later the same
    /// day, on a 25-hour DST day); else the clock time: "Thu 9:00 AM" within the next 6 days
    /// (never today's weekday, which would be ambiguous), "Dec 2, 9:00 AM" beyond.
    public static func resetText(_ date: Date, now: Date, calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch resetMoment(date, now: now, calendar: calendar) ?? .minutes(1) {
        case .minutes(let minutes):
            let hours = minutes / 60, rest = minutes % 60
            if hours == 0 { return "in \(rest)m" }
            return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
        case .weekday(let rounded):
            style = style.weekday(.abbreviated).hour().minute()
            return rounded.formatted(style)
        case .date(let rounded):
            style = style.month(.abbreviated).day().hour().minute()
            return rounded.formatted(style)
        }
    }

    // MARK: Rules

    /// How far away a reset is.
    private enum ResetMoment {
        /// Under a day away (or later today): whole minutes, rounded up (at least 1).
        case minutes(Int)
        /// 1...6 calendar days away (the date rounded to the minute).
        case weekday(Date)
        /// 7 or more calendar days away (rounded to the minute).
        case date(Date)
    }

    /// Nil once `date` has passed (as `UsageWindow.hasReset`).
    private static func resetMoment(_ date: Date, now: Date, calendar: Calendar) -> ResetMoment? {
        let remaining = date.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        // Reset timestamps drift by fractions of a second between readings: round to the minute.
        let rounded = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        // Start of day to start of day: DST-safe.
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: rounded)).day ?? 7
        if remaining < 24 * 3600 || days < 1 {
            return .minutes(max(1, Int((remaining / 60).rounded(.up))))
        }
        return days < 7 ? .weekday(rounded) : .date(rounded)
    }

    private static func shortText(_ moment: ResetMoment, calendar: Calendar, locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch moment {
        case .minutes(let minutes):
            let hours = minutes / 60, rest = minutes % 60
            if hours == 0 { return "\(rest)m" }
            return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
        case .weekday(let date):
            return date.formatted(style.weekday(.abbreviated))
        case .date(let date):
            return date.formatted(style.month(.abbreviated).day())
        }
    }

    private static func spokenText(_ moment: ResetMoment, calendar: Calendar, locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch moment {
        case .minutes(let minutes):
            let hours = minutes / 60, rest = minutes % 60
            func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
            let parts = [hours > 0 ? unit(hours, "hour") : nil, rest > 0 ? unit(rest, "minute") : nil]
            return "in " + parts.compactMap { $0 }.joined(separator: " ")
        case .weekday(let date):
            return date.formatted(style.weekday(.wide))
        case .date(let date):
            return date.formatted(style.month(.wide).day())
        }
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

    /// "3:05 PM" today, else "Nov 22, 3:05 PM".
    private static func clockText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = calendar.isDate(date, inSameDayAs: now)
            ? style.hour().minute()
            : style.month(.abbreviated).day().hour().minute()
        return date.formatted(style)
    }
}
