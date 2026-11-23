import Foundation
import Observation

/// Polls each agent's `UsageSource` and publishes its `AgentUsage` for the sidebar header.
///
/// One independent loop per source: poll, publish, sleep `nextPollIn` (never below
/// `minimumInterval`), repeat. A source is never polled twice at once: a restarted loop first
/// waits for the previous one to finish, and the result of a poll whose loop was cancelled
/// (stop, suspend) is dropped; the poll itself isn't cancelled. Running loops retain the store
/// until `stop()`. Each source's next poll is a wall-clock deadline, so restarts
/// (`resume`, `pollOverdue`) honour a source's backoff instead of polling early.
///
/// Sleep/wake is the caller's job (AppKit lives in the app): `suspend()` on will-sleep cancels
/// the loops; `resume()` on wake restarts them, each polling at its deadline but no sooner than
/// `wakeDelay` from now (the network is often not up yet right after wake). That wake hold also
/// binds `pollOverdue()` until it passes. A suspension that lasted more than `maxSuspension` of
/// awake time (a did-wake that never came) is ended by the next `pollOverdue()`; it is measured
/// on `uptime`, which stops while the system sleeps, and also requires `isFullWake` (the app:
/// the display is awake): dark wakes (Power Nap) add up to awake time over a night, so uptime
/// alone would end a real sleep's suspension during one.
///
/// A loop never sleeps longer than `maxWait` at a time before polling, so a backward wall-clock
/// jump (deadline suddenly hours away) can't stall a source; sources guard their own backoff.
@MainActor
@Observable
public final class UsageStore {
    /// One entry per source's agent; `.loading` until that source's first result.
    public private(set) var usage: [AgentKind: AgentUsage]
    /// The sources' agents, in the order given.
    public let agents: [AgentKind]

    public private(set) var isRunning = false

    @ObservationIgnored private let sources: [AgentKind: any UsageSource]
    @ObservationIgnored private let minimumInterval: TimeInterval
    @ObservationIgnored private let wakeDelay: TimeInterval
    @ObservationIgnored private let maxWait: TimeInterval
    @ObservationIgnored private let maxSuspension: TimeInterval
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private let isFullWake: @Sendable () -> Bool
    @ObservationIgnored private var loops: [AgentKind: Task<Void, Never>] = [:]
    /// When each source wants its next poll; absent = now.
    @ObservationIgnored private var deadlines: [AgentKind: Date] = [:]
    /// Sources with a poll in flight.
    @ObservationIgnored private var polling: Set<AgentKind> = []
    /// Bumped by every loop (re)start, so a superseded loop drops its result.
    @ObservationIgnored private var generations: [AgentKind: Int] = [:]
    @ObservationIgnored private var isSuspended = false
    /// `uptime()` when `suspend()` ran; nil unless suspended.
    @ObservationIgnored private var suspendedAt: TimeInterval?
    /// No poll before this after a `resume()` (the network may still be down); cleared by
    /// `start`/`stop`.
    @ObservationIgnored private var wakeHoldUntil: Date?

    /// - Parameters:
    ///   - sources: at most one per agent (a later duplicate is ignored).
    ///   - minimumInterval: floor for a source's `nextPollIn`, so a source can't spin.
    ///   - wakeDelay: seconds after `resume()` before any poll.
    ///   - maxWait: longest a loop sleeps before polling (caps a backward wall-clock jump).
    ///   - maxSuspension: a suspension longer than this (awake time) is ended by `pollOverdue()`.
    ///   - now: the wall clock (injectable for tests).
    ///   - uptime: seconds of awake time, stopping during system sleep (injectable for tests).
    ///   - isFullWake: false during a dark wake; gates ending a stuck suspension.
    public init(sources: [any UsageSource], minimumInterval: TimeInterval = 5, wakeDelay: TimeInterval = 5,
                maxWait: TimeInterval = 3600, maxSuspension: TimeInterval = 300,
                now: @escaping @Sendable () -> Date = { Date() },
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                isFullWake: @escaping @Sendable () -> Bool = { true }) {
        var byAgent: [AgentKind: any UsageSource] = [:]
        var order: [AgentKind] = []
        for source in sources where byAgent[source.agent] == nil {
            byAgent[source.agent] = source
            order.append(source.agent)
        }
        self.sources = byAgent
        agents = order
        usage = Dictionary(uniqueKeysWithValues: order.map {
            ($0, AgentUsage(agent: $0, snapshot: nil, status: .loading))
        })
        self.minimumInterval = minimumInterval
        self.wakeDelay = wakeDelay
        self.maxWait = maxWait
        self.maxSuspension = maxSuspension
        clock = now
        self.uptime = uptime
        self.isFullWake = isFullWake
    }

    /// Starts every source's loop (a source never polled yet polls right away). Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isSuspended = false
        suspendedAt = nil
        wakeHoldUntil = nil
        for agent in agents { restartLoop(agent, notBefore: nil) }
    }

    /// Cancels every loop; results of polls in flight are dropped. Idempotent.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        isSuspended = false
        suspendedAt = nil
        wakeHoldUntil = nil
        cancelLoops()
    }

    /// System going to sleep: cancels the loops, keeping their deadlines. No-op unless running.
    public func suspend() {
        guard isRunning, !isSuspended else { return }
        isSuspended = true
        suspendedAt = uptime()
        cancelLoops()
    }

    /// System woke: restarts the loops, none polling sooner than `wakeDelay` from now.
    /// No-op unless running. Also usable without a prior `suspend()` (e.g. a missed will-sleep).
    public func resume() {
        guard isRunning else { return }
        isSuspended = false
        suspendedAt = nil
        let notBefore = clock().addingTimeInterval(wakeDelay)
        wakeHoldUntil = notBefore
        // A poll still in flight (cancelled by `suspend`) finishes first: the new loop waits for it.
        for agent in agents { restartLoop(agent, notBefore: notBefore) }
    }

    /// Polls now every source whose deadline (or the wake hold, if later) passed more than
    /// `tolerance` ago and that isn't polling: catches up when a sleeping loop's timer was
    /// delayed (App Nap, a missed wake). While suspended it does nothing, unless the suspension
    /// is older than `maxSuspension` (will-sleep without a did-wake): then it `resume()`s.
    public func pollOverdue(tolerance: TimeInterval = 2) {
        guard isRunning else { return }
        let now = clock()
        if isSuspended {
            if let suspendedAt, uptime() - suspendedAt > maxSuspension, isFullWake() { resume() }
            return
        }
        // Drop a passed hold; clamp one a backward clock jump left far ahead to a full wake delay
        // from now, so it can neither hold back the catch-up for long nor be skipped.
        if let hold = wakeHoldUntil {
            if hold <= now {
                wakeHoldUntil = nil
            } else if hold.timeIntervalSince(now) > wakeDelay {
                wakeHoldUntil = now.addingTimeInterval(wakeDelay)
            }
        }
        for agent in agents where !polling.contains(agent) {
            guard var due = deadlines[agent] else { continue }
            if let wakeHoldUntil, wakeHoldUntil > due { due = wakeHoldUntil }
            guard due.addingTimeInterval(tolerance) < now else { continue }
            restartLoop(agent, notBefore: wakeHoldUntil)
        }
    }

    private func cancelLoops() {
        for (agent, loop) in loops {
            generations[agent, default: 0] += 1
            loop.cancel()
        }
    }

    /// Replaces `agent`'s loop. The new loop waits for the old one to finish (it may be mid-poll),
    /// then sleeps until the source's deadline (and `notBefore`), then polls.
    private func restartLoop(_ agent: AgentKind, notBefore: Date?) {
        guard let source = sources[agent] else { return }
        let previous = loops[agent]
        previous?.cancel()
        generations[agent, default: 0] += 1
        let generation = generations[agent, default: 0]
        loops[agent] = Task { [weak self] in
            await previous?.value
            var notBefore = notBefore
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.secondsUntilDue(agent, notBefore: notBefore)
                notBefore = nil
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    if Task.isCancelled { return }
                }
                guard self.generations[agent] == generation else { return }
                self.polling.insert(agent)
                // Unstructured, so `stop`/`suspend` don't cancel the request under the source
                // (which would count it as a failure); its result is just dropped.
                let now = self.clock()
                let result = await Task { await source.poll(now: now) }.value
                self.polling.remove(agent)
                guard !Task.isCancelled, self.generations[agent] == generation else { return }
                self.publish(result, for: agent)
            }
        }
    }

    private func secondsUntilDue(_ agent: AgentKind, notBefore: Date?) -> TimeInterval {
        let now = clock()
        var due = deadlines[agent] ?? now
        if let notBefore, notBefore > due { due = notBefore }
        return min(due.timeIntervalSince(now), maxWait)
    }

    private func publish(_ result: UsagePollResult, for agent: AgentKind) {
        var published = result.usage
        published.agent = agent
        if usage[agent] != published { usage[agent] = published }
        deadlines[agent] = clock().addingTimeInterval(max(result.nextPollIn, minimumInterval))
    }
}
