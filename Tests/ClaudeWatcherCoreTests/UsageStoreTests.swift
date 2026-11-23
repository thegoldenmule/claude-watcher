import Foundation
import Synchronization
import Testing
@testable import ClaudeWatcherCore

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

@MainActor @Test func usageStoreWakeHoldSurvivesABackwardClockJump() async {
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
    // An NTP step back right after wake leaves the hold further ahead than the wake delay: it's
    // clamped, not dropped, so the overdue catch-up still can't poll inside the wake delay.
    clock.advance(-1)
    store.pollOverdue(tolerance: 0)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(await source.polls == 1)
    // The clamped hold releases at the wake delay: the catch-up polls then, well before the
    // resumed loop's own (stepped-back, ~1.4 s) wait would.
    try? await Task.sleep(for: .milliseconds(300))
    store.pollOverdue(tolerance: 0)
    #expect(await waitUntil { await source.polls == 2 })
    #expect(ContinuousClock.now - resumed >= .milliseconds(390))
    #expect(ContinuousClock.now - resumed < .milliseconds(1200))
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
    let awake = TestClock()  // awake time: only what `uptime` sees
    let fullWake = Mutex(true)
    let source = FakeSource(.claude, nextPollIn: 100)
    let store = UsageStore(sources: [source], minimumInterval: 0, wakeDelay: 0, maxSuspension: 300,
                           now: clock.now, uptime: { awake.now().timeIntervalSince1970 },
                           isFullWake: { fullWake.withLock { $0 } })
    defer { store.stop() }
    store.start()
    #expect(await waitUntil { await source.polls == 1 })
    store.suspend()
    // A real overnight sleep with a dark wake: the wall clock moved hours, awake time didn't.
    clock.advance(8 * 3600)
    store.pollOverdue()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.polls == 1)
    // Awake but suspended, under `maxSuspension`: still waiting for did-wake.
    awake.advance(200)
    store.pollOverdue()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.polls == 1)
    // Dark wakes add up to more than `maxSuspension` of awake time: still asleep (display off).
    awake.advance(200)
    fullWake.withLock { $0 = false }
    store.pollOverdue()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.polls == 1)
    // Fully awake and suspended for more than `maxSuspension` with no did-wake: the tick resumes.
    fullWake.withLock { $0 = true }
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
