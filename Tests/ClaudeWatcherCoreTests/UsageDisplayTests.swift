import Foundation
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures

/// Monday 2026-11-23 12:00 in New York.
private let noon = Date(timeIntervalSince1970: 1_795_453_200)

private func calendar(_ zone: String = "America/New_York") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let newYork = calendar()
private let enUS = Locale(identifier: "en_US")

/// Date formatting uses U+202F before AM/PM; compare with plain spaces.
private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
}

private func usage(_ agent: AgentKind = .claude, session: Double?, sessionReset: TimeInterval? = 3600,
                   weekly: Double?, weeklyReset: TimeInterval? = 3 * 86_400,
                   status: UsageStatus = .ok) -> AgentUsage {
    let snapshot = UsageSnapshot(
        session: session.map { UsageWindow(percent: $0, resetsAt: sessionReset.map(noon.addingTimeInterval)) },
        weekly: weekly.map { UsageWindow(percent: $0, resetsAt: weeklyReset.map(noon.addingTimeInterval)) },
        asOf: noon.addingTimeInterval(-300))
    return AgentUsage(agent: agent, snapshot: snapshot, status: status)
}

private func line(_ usage: AgentUsage, now: Date = noon) -> UsageLine? {
    UsageDisplay.line(for: usage, now: now, calendar: newYork, locale: enUS)
}

private func window(_ percent: Double, resetsIn: TimeInterval? = nil, kind: UsageWindowKind = .session)
    -> UsageWindowDisplay {
    UsageDisplay.windowDisplay(kind: kind, window: UsageWindow(percent: percent, resetsAt: resetsIn.map(noon.addingTimeInterval)),
                               now: noon, calendar: newYork, locale: enUS)
}

// MARK: - Line contents

@Test func usageLineShowsBothWindowsWithShortResets() throws {
    let both = try #require(line(usage(session: 42.4, sessionReset: 2 * 3600 + 10 * 60, weekly: 66.6,
                                       weeklyReset: 3 * 86_400 - 3 * 3600)))  // Thu 9:00
    #expect(both.agent == .claude)
    #expect(!both.isStale)
    #expect(both.message == nil)
    #expect(both.windows.map(\.kind) == [.session, .weekly])
    #expect(both.windows.map(\.percentText) == ["42%", "67%"])
    #expect(both.windows.map(\.resetText) == ["2h10m", "Thu"])
    #expect(both.windows.map(\.kind.shortLabel) == ["5h", "wk"])
    #expect(plain(both.help) == "Claude Code: 5h 42% (resets in 2h 10m) · wk 67% (resets Thu 9:00 AM)")
    #expect(both.accessibilityText
        == "Claude Code usage: session 42 percent, resets in 2 hours 10 minutes; weekly 67 percent, resets Thursday")
}

@Test func usageLinePicksTheMostConstrainingWindow() throws {
    #expect(line(usage(session: 42, weekly: 67))?.constraining?.kind == .weekly)
    #expect(line(usage(session: 85, weekly: 67))?.constraining?.kind == .session)
    // A tie goes to the session window.
    #expect(line(usage(session: 50, weekly: 50))?.constraining?.kind == .session)

    let critical = try #require(line(usage(.codex, session: 10, weekly: 96)))
    #expect(critical.agent == .codex)
    #expect(critical.constraining?.level == .critical)
    #expect(critical.constraining?.percent == 96)
    #expect(critical.accessibilityText.hasSuffix("weekly 96 percent, resets Thursday, critical"))
}

@Test func usageLineCountsResetWindowsAsZero() throws {
    // The session window (90%) reset a minute ago: 0%, no reset text; the weekly 30% constrains.
    let afterReset = try #require(line(usage(session: 90, sessionReset: -60, weekly: 30)))
    #expect(afterReset.windows[0].percent == 0)
    #expect(afterReset.windows[0].resetText == nil)
    #expect(afterReset.windows[0].resetSpoken == nil)
    #expect(afterReset.windows[0].fillFraction == 0)
    #expect(afterReset.constraining?.kind == .weekly)
    #expect(afterReset.constraining?.percent == 30)
    #expect(afterReset.help.hasPrefix("Claude Code: 5h 0% (reset) · wk 30%"))

    // Both reset (one exactly now): 0%, session (tie), normal.
    let bothReset = try #require(line(usage(session: 90, sessionReset: -60, weekly: 99, weeklyReset: 0)))
    #expect(bothReset.constraining?.kind == .session)
    #expect(bothReset.windows.map(\.percent) == [0, 0])
    #expect(bothReset.windows.map(\.resetText) == [nil, nil])
    #expect(bothReset.constraining?.level == .normal)

    // No reset time: never treated as reset, and no reset text.
    let noReset = try #require(line(usage(session: 70, sessionReset: nil, weekly: 10)))
    #expect(noReset.windows[0].percent == 70)
    #expect(noReset.windows[0].resetText == nil)
}

@Test func usageLineHandlesMissingWindows() throws {
    let weeklyOnly = try #require(line(usage(.codex, session: nil, weekly: 96)))
    #expect(weeklyOnly.windows.map(\.kind) == [.weekly])
    #expect(weeklyOnly.constraining?.kind == .weekly)
    #expect(line(usage(session: 12, weekly: nil))?.windows.map(\.kind) == [.session])
    #expect(line(usage(session: nil, weekly: nil)) == nil)
}

// MARK: - Visibility and staleness

@Test func usageLineVisibilityFollowsStatus() throws {
    // Nothing to show and nothing wrong: no line.
    #expect(line(AgentUsage(agent: .codex, snapshot: nil, status: .unavailable)) == nil)
    // `.unavailable` hides even a leftover snapshot.
    #expect(line(usage(session: 5, weekly: 5, status: .unavailable)) == nil)
    #expect(line(AgentUsage(agent: .claude, snapshot: nil, status: .loading)) == nil)
    #expect(line(AgentUsage(agent: .claude, snapshot: nil, status: .ok)) == nil)
    // Loading with a snapshot (e.g. a restarted store) still shows it.
    #expect(line(usage(session: 5, weekly: 5, status: .loading))?.windows.count == 2)

    // Error, no snapshot: a message-only line.
    let error = try #require(line(AgentUsage(agent: .claude, snapshot: nil, status: .error("Couldn't read usage"))))
    #expect(error.windows.isEmpty)
    #expect(error.constraining == nil)
    #expect(!error.isStale)
    #expect(error.message == "Couldn't read usage")
    #expect(error.help == "Claude Code: Couldn't read usage")
    #expect(error.accessibilityText == "Claude Code usage unavailable: Couldn't read usage")
    // Error with a leftover snapshot: still only the message.
    #expect(line(usage(session: 5, weekly: 5, status: .error("Nope")))?.windows.isEmpty == true)

    // Stale: the windows, dimmed, with the message and the reading's time in the tooltip.
    let stale = try #require(line(usage(session: 42, weekly: 67, status: .stale("Offline"))))
    #expect(stale.isStale)
    #expect(stale.windows.count == 2)
    #expect(stale.message == "Offline")
    #expect(plain(stale.help).hasSuffix("\nOffline (as of 11:55 AM)"))
    #expect(stale.accessibilityText.hasSuffix("; out of date"))

    // Stale without a snapshot: message-only.
    let staleEmpty = try #require(line(AgentUsage(agent: .codex, snapshot: nil, status: .stale("Offline"))))
    #expect(staleEmpty.windows.isEmpty)
    #expect(!staleEmpty.isStale)
    #expect(staleEmpty.help == "Codex: Offline")
}

@Test func usageLinesKeepAgentOrder() {
    let all: [AgentKind: AgentUsage] = [
        .claude: usage(.claude, session: 42, weekly: 67),
        .codex: usage(.codex, session: nil, weekly: 96),
    ]
    func agents(_ usage: [AgentKind: AgentUsage], _ order: [AgentKind]) -> [AgentKind] {
        UsageDisplay.lines(usage, agents: order, now: noon, calendar: newYork, locale: enUS).map(\.agent)
    }
    #expect(agents(all, [.claude, .codex]) == [.claude, .codex])
    #expect(agents(all, [.codex, .claude]) == [.codex, .claude])
    var codexGone = all
    codexGone[.codex] = AgentUsage(agent: .codex, snapshot: nil, status: .unavailable)
    #expect(agents(codexGone, [.claude, .codex]) == [.claude])
    #expect(agents([:], [.claude, .codex]).isEmpty)
}

// MARK: - Percent, fill and level

@Test func usageWindowDisplayClampsPercents() {
    let over = window(104)
    #expect(over.percentText == "104%")
    #expect(over.fillFraction == 1)
    #expect(over.level == .critical)
    #expect(window(-3).percentText == "0%")
    // A malformed server value must not trap the Int conversion.
    #expect(window(1e19).percent == 9999)
    #expect(window(1e19).fillFraction == 1)
    #expect(window(.infinity).percent == 9999)
    #expect(window(.nan).percent == 0)
    #expect(window(.nan).fillFraction == 0)
    #expect(window(.nan).level == .normal)
}

@Test func usageWholePercentClamps() {
    #expect(UsageDisplay.wholePercent(42.5) == 43)
    #expect(UsageDisplay.wholePercent(-0.4) == 0)
    #expect(UsageDisplay.wholePercent(-1e300) == 0)
    #expect(UsageDisplay.wholePercent(1e19) == 9999)
    #expect(UsageDisplay.wholePercent(.infinity) == 9999)
    #expect(UsageDisplay.wholePercent(-.infinity) == 0)
    #expect(UsageDisplay.wholePercent(.nan) == 0)
}

@Test func usageFillAndLevelFollowTheRoundedLabel() {
    // Reads "0%": no fill (not a sliver).
    #expect(window(0.3).percent == 0)
    #expect(window(0.3).fillFraction == 0)
    // Reads "1%": a fill.
    #expect(window(0.6).fillFraction == 0.01)
    #expect(window(42).fillFraction == 0.42)
    #expect(window(79.4).level == .normal)
    #expect(window(79.6).level == .warning)   // reads "80%"
    #expect(window(94.7).level == .critical)  // reads "95%"
    #expect(window(85).accessibilityText == "session 85 percent, warning")
}

// MARK: - Short reset text

@Test func usageShortResetTextRules() {
    func text(_ seconds: TimeInterval, calendar: Calendar = newYork) -> String? {
        UsageDisplay.shortResetText(noon.addingTimeInterval(seconds), now: noon, calendar: calendar, locale: enUS)
    }
    #expect(text(45 * 60) == "45m")
    #expect(text(20) == "1m")              // rounded up: never "0m"
    #expect(text(2 * 3600) == "2h")
    #expect(text(2 * 3600 + 30) == "2h1m")
    #expect(text(2 * 3600 + 10 * 60) == "2h10m")
    #expect(text(23 * 3600 + 59 * 60) == "23h59m")
    #expect(text(86_400) == "Tue")
    #expect(text(6 * 86_400) == "Sun")
    // Next Monday is today's weekday: the date instead.
    #expect(text(7 * 86_400 - 3600) == "Nov 30")
    #expect(text(30 * 86_400) == "Dec 23")
    // Passed (or exactly now): nothing.
    #expect(text(0) == nil)
    #expect(text(-60) == nil)
    // The weekday is the calendar's: noon Monday in New York is 2:00 Tuesday in Tokyo.
    #expect(text(86_400, calendar: calendar("Asia/Tokyo")) == "Wed")
}

@Test func usageShortResetTextIsDSTSafe() {
    // Sat 2026-10-31 23:30 EDT; clocks fall back on Sun Nov 1.
    let saturdayNight = Date(timeIntervalSince1970: 1_793_503_800)
    // Sat Nov 7 00:30 EST: 6 days 2 hours of elapsed time, but 7 calendar days away, so the
    // date (not "Sat", today's weekday).
    let nextSaturday = Date(timeIntervalSince1970: 1_794_029_400)
    #expect(UsageDisplay.shortResetText(nextSaturday, now: saturdayNight, calendar: newYork, locale: enUS) == "Nov 7")
    #expect(UsageDisplay.shortResetText(nextSaturday.addingTimeInterval(-3600), now: saturdayNight,
                                        calendar: newYork, locale: enUS) == "Fri")

    // Sun Nov 1 00:10 EDT is a 25-hour day: 24 h 30 m later is still Sunday (23:40 EST), so it
    // stays relative instead of naming today's weekday.
    let sundayMorning = Date(timeIntervalSince1970: 1_793_506_200)
    let laterSunday = sundayMorning.addingTimeInterval(24 * 3600 + 30 * 60)
    #expect(UsageDisplay.shortResetText(laterSunday, now: sundayMorning, calendar: newYork, locale: enUS) == "24h30m")
    #expect(UsageDisplay.resetText(laterSunday, now: sundayMorning, calendar: newYork, locale: enUS) == "in 24h 30m")
}

@Test func usageResetSpokenText() {
    #expect(window(1, resetsIn: 3600).resetSpoken == "in 1 hour")
    #expect(window(1, resetsIn: 61 * 60).resetSpoken == "in 1 hour 1 minute")
    #expect(window(1, resetsIn: 45 * 60).resetSpoken == "in 45 minutes")
    #expect(window(1, resetsIn: 2 * 86_400).resetSpoken == "Wednesday")
    #expect(window(1, resetsIn: 10 * 86_400).resetSpoken == "December 3")
}

// MARK: - Tooltip text

@Test func usageResetTextRules() {
    func text(_ seconds: TimeInterval) -> String {
        plain(UsageDisplay.resetText(noon.addingTimeInterval(seconds), now: noon, calendar: newYork, locale: enUS))
    }
    #expect(text(45 * 60) == "in 45m")
    #expect(text(20) == "in 1m")            // rounded up: never "in 0m"
    #expect(text(2 * 3600) == "in 2h")
    #expect(text(2 * 3600 + 30) == "in 2h 1m")
    #expect(text(23 * 3600 + 59 * 60) == "in 23h 59m")
    #expect(text(86_400) == "Tue 12:00 PM")
    #expect(text(6 * 86_400) == "Sun 12:00 PM")
    // Next Monday is today's weekday: a date instead.
    #expect(text(7 * 86_400 - 3600).hasPrefix("Nov 30"))
    #expect(text(7 * 86_400 - 3600).hasSuffix("11:00 AM"))
}

@Test func usageWindowTextEdgeCases() {
    func text(_ window: UsageWindow, _ kind: UsageWindowKind = .session) -> String {
        plain(UsageDisplay.windowText(kind: kind, window: window, now: noon, calendar: newYork, locale: enUS))
    }
    #expect(text(UsageWindow(percent: 88, resetsAt: noon.addingTimeInterval(-1))) == "5h 0% (reset)")
    #expect(text(UsageWindow(percent: 12.5, resetsAt: nil), .weekly) == "wk 13%")
    #expect(text(UsageWindow(percent: 104, resetsAt: nil)) == "5h 104%")
    #expect(text(UsageWindow(percent: -3, resetsAt: nil)) == "5h 0%")
    #expect(text(UsageWindow(percent: 1e19, resetsAt: nil)) == "5h 9999%")
    #expect(text(UsageWindow(percent: .infinity, resetsAt: nil)) == "5h 9999%")
    #expect(text(UsageWindow(percent: .nan, resetsAt: nil)) == "5h 0%")
}
