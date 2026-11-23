import Foundation
import Synchronization
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures

/// Monday 2026-11-23 12:00 in New York.
private let noon = Date(timeIntervalSince1970: 1_795_453_200)

private var newYork: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

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

// MARK: - Meter choice

@Test func usageMeterShowsTheHigherWindow() throws {
    let weeklyHigher = try #require(UsageDisplay.meter(for: usage(session: 42, weekly: 67), now: noon))
    #expect(weeklyHigher.kind == .weekly)
    #expect(weeklyHigher.percent == 67)
    #expect(weeklyHigher.level == .normal)
    #expect(!weeklyHigher.isStale)

    let sessionHigher = try #require(UsageDisplay.meter(for: usage(session: 85, weekly: 67), now: noon))
    #expect(sessionHigher.kind == .session)
    #expect(sessionHigher.level == .warning)

    // A tie goes to the session window.
    #expect(UsageDisplay.meter(for: usage(session: 50, weekly: 50), now: noon)?.kind == .session)

    let critical = try #require(UsageDisplay.meter(for: usage(.codex, session: 10, weekly: 96), now: noon))
    #expect(critical.agent == .codex)
    #expect(critical.level == .critical)
    #expect(critical.roundedPercent == 96)
    #expect(critical.accessibilityText == "Codex weekly usage 96 percent, critical")
}

@Test func usageMeterCountsResetWindowsAsZero() throws {
    // The session window (90%) reset a minute ago: the weekly 30% is now the constraint.
    let afterReset = try #require(UsageDisplay.meter(
        for: usage(session: 90, sessionReset: -60, weekly: 30), now: noon))
    #expect(afterReset.kind == .weekly)
    #expect(afterReset.percent == 30)

    // Both reset: 0%, session (tie).
    let bothReset = try #require(UsageDisplay.meter(
        for: usage(session: 90, sessionReset: -60, weekly: 99, weeklyReset: 0), now: noon))
    #expect(bothReset.kind == .session)
    #expect(bothReset.percent == 0)
    #expect(bothReset.level == .normal)

    // No reset time: never treated as reset.
    #expect(UsageDisplay.meter(for: usage(session: 70, sessionReset: nil, weekly: 10), now: noon)?.percent == 70)
}

@Test func usageMeterHandlesMissingWindows() throws {
    #expect(UsageDisplay.meter(for: usage(session: nil, weekly: 67), now: noon)?.kind == .weekly)
    #expect(UsageDisplay.meter(for: usage(session: 12, weekly: nil), now: noon)?.kind == .session)
    #expect(UsageDisplay.meter(for: usage(session: nil, weekly: nil), now: noon) == nil)
    #expect(UsageDisplay.menuLines(for: usage(session: nil, weekly: nil), now: noon).isEmpty)
}

// MARK: - Visibility and staleness

@Test func usageVisibilityFollowsStatus() throws {
    // Nothing to show: no meter, no menu line.
    let unavailable = AgentUsage(agent: .codex, snapshot: nil, status: .unavailable)
    #expect(UsageDisplay.meter(for: unavailable, now: noon) == nil)
    #expect(UsageDisplay.menuLines(for: unavailable, now: noon).isEmpty)
    // `.unavailable` hides even a leftover snapshot.
    #expect(UsageDisplay.meter(for: usage(session: 5, weekly: 5, status: .unavailable), now: noon) == nil)

    let loading = AgentUsage(agent: .claude, snapshot: nil, status: .loading)
    #expect(UsageDisplay.meter(for: loading, now: noon) == nil)
    #expect(UsageDisplay.menuLines(for: loading, now: noon).isEmpty)

    let okEmpty = AgentUsage(agent: .claude, snapshot: nil, status: .ok)
    #expect(UsageDisplay.meter(for: okEmpty, now: noon) == nil)
    #expect(UsageDisplay.menuLines(for: okEmpty, now: noon).isEmpty)

    // Error, no snapshot: no meter, only the error line.
    let error = AgentUsage(agent: .claude, snapshot: nil, status: .error("Couldn't read usage"))
    #expect(UsageDisplay.meter(for: error, now: noon) == nil)
    #expect(UsageDisplay.menuLines(for: error, now: noon) == ["Claude Code: Couldn't read usage"])

    // Stale: dimmed meter, usage line plus the error with the snapshot's time.
    let stale = usage(session: 42, weekly: 67, status: .stale("Offline"))
    let meter = try #require(UsageDisplay.meter(for: stale, now: noon))
    #expect(meter.isStale)
    #expect(meter.accessibilityText == "Claude Code weekly usage 67 percent, out of date")
    let lines = UsageDisplay.menuLines(for: stale, now: noon, calendar: newYork, locale: enUS).map(plain)
    #expect(lines.count == 2)
    #expect(lines.last == "Claude Code: Offline (as of 11:55 AM)")

    // Stale without a snapshot: just the error line.
    let staleEmpty = AgentUsage(agent: .codex, snapshot: nil, status: .stale("Offline"))
    #expect(UsageDisplay.meter(for: staleEmpty, now: noon) == nil)
    #expect(UsageDisplay.menuLines(for: staleEmpty, now: noon) == ["Codex: Offline"])
}

@Test func usageMetersKeepAgentOrder() {
    let all: [AgentKind: AgentUsage] = [
        .claude: usage(.claude, session: 42, weekly: 67),
        .codex: usage(.codex, session: nil, weekly: 96),
    ]
    #expect(UsageDisplay.meters(all, agents: [.claude, .codex], now: noon).map(\.agent) == [.claude, .codex])
    #expect(UsageDisplay.meters(all, agents: [.codex, .claude], now: noon).map(\.agent) == [.codex, .claude])
    var codexGone = all
    codexGone[.codex] = AgentUsage(agent: .codex, snapshot: nil, status: .unavailable)
    #expect(UsageDisplay.meters(codexGone, agents: [.claude, .codex], now: noon).map(\.agent) == [.claude])
}

// MARK: - Menu text

@Test func usageMenuLineFormatsBothWindows() {
    let lines = UsageDisplay.menuLines(
        for: usage(session: 42.4, sessionReset: 2 * 3600 + 10 * 60, weekly: 66.6,
                   weeklyReset: 3 * 86_400 - 3 * 3600),  // Thu 9:00
        now: noon, calendar: newYork, locale: enUS).map(plain)
    #expect(lines == ["Claude Code: 5h 42% (resets in 2h 10m) · Week 67% (resets Thu 9:00 AM)"])
}

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
    #expect(text(UsageWindow(percent: 12.5, resetsAt: nil), .weekly) == "Week 13%")
    #expect(text(UsageWindow(percent: 104, resetsAt: nil)) == "5h 104%")
    #expect(text(UsageWindow(percent: -3, resetsAt: nil)) == "5h 0%")
    // A malformed server value must not trap the Int conversion.
    #expect(text(UsageWindow(percent: 1e19, resetsAt: nil)) == "5h 9999%")
    #expect(text(UsageWindow(percent: .infinity, resetsAt: nil)) == "5h 9999%")
    #expect(text(UsageWindow(percent: .nan, resetsAt: nil)) == "5h 0%")
}

@Test func usageWholePercentClamps() {
    #expect(UsageDisplay.wholePercent(42.5) == 43)
    #expect(UsageDisplay.wholePercent(-0.4) == 0)
    #expect(UsageDisplay.wholePercent(-1e300) == 0)
    #expect(UsageDisplay.wholePercent(1e19) == 9999)
    #expect(UsageDisplay.wholePercent(.infinity) == 9999)
    #expect(UsageDisplay.wholePercent(-.infinity) == 0)
    #expect(UsageDisplay.wholePercent(.nan) == 0)
    let huge = UsageMeter(agent: .claude, kind: .session, percent: 1e19, level: .critical, isStale: false)
    #expect(huge.roundedPercent == 9999)
    #expect(huge.fillFraction == 1)
}

@Test func usageMeterFillFollowsTheRoundedLabel() {
    func meter(_ percent: Double) -> UsageMeter {
        UsageMeter(agent: .claude, kind: .session, percent: percent, level: UsageLevel(percent: percent), isStale: false)
    }
    // Reads "0%": no fill (not a dot).
    #expect(meter(0.3).roundedPercent == 0)
    #expect(meter(0.3).fillFraction == 0)
    // Reads "1%": a fill, so the dot shows.
    #expect(meter(0.6).roundedPercent == 1)
    #expect(meter(0.6).fillFraction == 0.01)
    #expect(meter(42).fillFraction == 0.42)
    #expect(meter(-3).fillFraction == 0)
    #expect(meter(150).fillFraction == 1)
}

// MARK: - Store

/// A source with scripted results that records its polls. `pollDuration` makes each poll take
/// that long, ignoring cancellation (like a request that can't be interrupted).
private actor FakeSource: UsageSource {
    nonisolated let agent: AgentKind
    private let nextPollIn: TimeInterval
    private let pollDuration: Duration
    private(set) var polls = 0
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    /// While set, polls wait (ignoring cancellation) until `openGate()`.
    private var gated: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ agent: AgentKind, nextPollIn: TimeInterval, pollDuration: Duration = .zero, gated: Bool = false) {
        self.agent = agent
        self.nextPollIn = nextPollIn
        self.pollDuration = pollDuration
        self.gated = gated
    }

    func openGate() {
        gated = false
        for waiter in gateWaiters { waiter.resume() }
        gateWaiters = []
    }

    func poll(now: Date) async -> UsagePollResult {
        polls += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        let number = polls
        if gated { await withCheckedContinuation { gateWaiters.append($0) } }
        if pollDuration > .zero {
            // An unstructured task doesn't inherit our cancellation: the "request" always runs out.
            let duration = pollDuration
            await Task { try? await Task.sleep(for: duration) }.value
        }
        inFlight -= 1
        let snapshot = UsageSnapshot(session: UsageWindow(percent: Double(number), resetsAt: nil), weekly: nil, asOf: now)
        return UsagePollResult(usage: AgentUsage(agent: agent, snapshot: snapshot, status: .ok), nextPollIn: nextPollIn)
    }
}

/// Polls `condition` every 10 ms for up to `timeout`.
@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A wall clock the test can move forward.
private final class TestClock: Sendable {
    private let offset = Mutex<TimeInterval>(0)
    func advance(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }
    var now: @Sendable () -> Date { { [self] in Date().addingTimeInterval(offset.withLock { $0 }) } }
}

@MainActor @Test func usageStorePublishesResults() async {
    let claude = FakeSource(.claude, nextPollIn: 60)
    let codex = FakeSource(.codex, nextPollIn: 60)
    let store = UsageStore(sources: [claude, codex], minimumInterval: 0)
    defer { store.stop() }
    #expect(store.agents == [.claude, .codex])
    #expect(store.usage[.claude]?.status == .loading)
    #expect(store.usage[.codex]?.status == .loading)
    store.start()
    store.start()  // idempotent
    #expect(await waitUntil { store.usage[.claude]?.status == .ok && store.usage[.codex]?.status == .ok })
    #expect(store.usage[.codex]?.agent == .codex)
    #expect(store.usage[.claude]?.snapshot?.session?.percent == 1)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await claude.polls == 1)
    #expect(await codex.polls == 1)
}

@MainActor @Test func usageStoreHonoursEachSourcesInterval() async {
    let fast = FakeSource(.claude, nextPollIn: 0.05)
    let slow = FakeSource(.codex, nextPollIn: 60)
    let store = UsageStore(sources: [fast, slow], minimumInterval: 0)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await fast.polls >= 4 })
    #expect(await slow.polls == 1)
    #expect(await fast.maxInFlight == 1)
    // The published value follows the latest poll.
    #expect(await waitUntil { (store.usage[.claude]?.snapshot?.session?.percent ?? 0) >= 4 })
}

@MainActor @Test func usageStoreMinimumIntervalFloorsTheSchedule() async {
    let spinning = FakeSource(.claude, nextPollIn: 0)
    let store = UsageStore(sources: [spinning], minimumInterval: 60)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await spinning.polls == 1 })
    try? await Task.sleep(for: .milliseconds(150))
    #expect(await spinning.polls == 1)
}

@MainActor @Test func usageStoreStopCancelsAndDropsInFlightResults() async {
    let source = FakeSource(.claude, nextPollIn: 0, gated: true)
    let store = UsageStore(sources: [source], minimumInterval: 0)
    store.start()
    #expect(await waitUntil { await source.inFlight == 1 })
    store.stop()
    store.stop()  // idempotent
    await source.openGate()
    #expect(await waitUntil { await source.inFlight == 0 })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.polls == 1)
    #expect(store.usage[.claude]?.status == .loading)  // the cancelled poll's result was dropped
    #expect(!store.isRunning)
}

@MainActor @Test func usageStoreNeverOverlapsPollsOfOneSource() async {
    let source = FakeSource(.claude, nextPollIn: 0, pollDuration: .milliseconds(80))
    let store = UsageStore(sources: [source], minimumInterval: 0, wakeDelay: 0)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.inFlight == 1 })
    // Restart while the first poll is still running, several ways.
    store.stop()
    store.start()
    store.resume()
    store.pollOverdue(tolerance: 0)
    #expect(await waitUntil { await source.polls >= 3 })
    #expect(await source.maxInFlight == 1)
}

@MainActor @Test func usageStoreSuspendsAndResumesAfterWakeDelay() async {
    let source = FakeSource(.claude, nextPollIn: 0.03)
    let store = UsageStore(sources: [source], minimumInterval: 0, wakeDelay: 0.2)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.polls >= 2 })
    store.suspend()
    try? await Task.sleep(for: .milliseconds(50))
    let atSuspend = await source.polls
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.polls == atSuspend)
    // Overdue catch-up is off while suspended.
    store.pollOverdue(tolerance: 0)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await source.polls == atSuspend)

    let resumed = ContinuousClock.now
    store.resume()
    #expect(await waitUntil { await source.polls > atSuspend })
    #expect(ContinuousClock.now - resumed >= .milliseconds(190))
}

@MainActor @Test func usageStoreResumeKeepsALaterDeadline() async {
    let source = FakeSource(.claude, nextPollIn: 60)
    let store = UsageStore(sources: [source], minimumInterval: 0, wakeDelay: 0)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.polls == 1 })
    store.suspend()
    store.resume()  // a short sleep: the source asked for 60 s, so no poll on wake
    try? await Task.sleep(for: .milliseconds(150))
    #expect(await source.polls == 1)
}

@MainActor @Test func usageStorePollsOverdueSourcesNow() async {
    let clock = TestClock()
    let source = FakeSource(.claude, nextPollIn: 100)
    let store = UsageStore(sources: [source], minimumInterval: 0, now: clock.now)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.polls == 1 })
    store.pollOverdue()  // not due yet
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await source.polls == 1)
    // The wall clock jumped past the deadline but the loop's timer hasn't fired (App Nap).
    clock.advance(200)
    store.pollOverdue()
    #expect(await waitUntil { await source.polls == 2 })
}

@MainActor @Test func usageStorePollOverdueHonoursTheWakeHold() async {
    let clock = TestClock()
    let source = FakeSource(.claude, nextPollIn: 100)
    let store = UsageStore(sources: [source], minimumInterval: 0, wakeDelay: 0.4, now: clock.now)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.polls == 1 })
    store.suspend()
    clock.advance(200)  // slept past the deadline
    let resumed = ContinuousClock.now
    store.resume()
    // A menu open / minute tick right after wake: the deadline is long past, but the wake
    // hold isn't, so no poll yet.
    store.pollOverdue(tolerance: 0)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(await source.polls == 1)
    store.pollOverdue(tolerance: 0)
    #expect(await waitUntil { await source.polls == 2 })
    #expect(ContinuousClock.now - resumed >= .milliseconds(390))
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.polls == 2)
}

@MainActor @Test func usageStoreCapsTheWaitAfterABackwardClockJump() async {
    let clock = TestClock()
    let source = FakeSource(.claude, nextPollIn: 100)
    let store = UsageStore(sources: [source], minimumInterval: 0, maxWait: 0.2, now: clock.now)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.polls == 1 })
    // The wall clock went back two hours: the deadline is now ~2 h away, but the loop polls
    // after at most `maxWait`.
    clock.advance(-7200)
    #expect(await waitUntil { await source.polls == 2 })
}

@MainActor @Test func usageStoreEndsASuspensionWithoutAWake() async {
    let clock = TestClock()
    let source = FakeSource(.claude, nextPollIn: 100)
    let store = UsageStore(sources: [source], minimumInterval: 0, wakeDelay: 0, maxSuspension: 300,
                           now: clock.now)
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.polls == 1 })
    store.suspend()
    clock.advance(200)  // past the deadline, but a recent suspension: still asleep
    store.pollOverdue()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.polls == 1)
    // Suspended for more than `maxSuspension` with no did-wake: the tick resumes polling.
    clock.advance(200)
    store.pollOverdue()
    #expect(await waitUntil { await source.polls == 2 })
}

@MainActor @Test func usageStoreIgnoresDuplicateAgents() async {
    let first = FakeSource(.claude, nextPollIn: 60)
    let second = FakeSource(.claude, nextPollIn: 60)
    let store = UsageStore(sources: [first, second], minimumInterval: 0)
    defer { store.stop() }
    #expect(store.agents == [.claude])
    store.start()
    #expect(await waitUntil { await first.polls == 1 })
    #expect(await second.polls == 0)
}
