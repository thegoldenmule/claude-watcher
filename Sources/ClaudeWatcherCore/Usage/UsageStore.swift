import Foundation
import Observation

/// Polls each agent's `UsageSource` and publishes its `AgentUsage` for the menu bar.
///
/// One independent loop per source: poll, publish, sleep `nextPollIn` (never below
/// `minimumInterval`), repeat. A source is never polled twice at once: a restarted loop first
/// waits for the previous one to finish, and the result of a poll whose loop was cancelled
/// (stop, suspend) is dropped. Each source's next poll is a wall-clock deadline, so restarts
/// (`resume`, `pollOverdue`) honour a source's backoff instead of polling early.
///
/// Sleep/wake is the caller's job (AppKit lives in the app): `suspend()` on will-sleep cancels
/// the loops; `resume()` on wake restarts them, each polling at its deadline but no sooner than
/// `wakeDelay` from now (the network is often not up yet right after wake).
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
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var loops: [AgentKind: Task<Void, Never>] = [:]
    /// When each source wants its next poll; absent = now.
    @ObservationIgnored private var deadlines: [AgentKind: Date] = [:]
    /// Sources with a poll in flight.
    @ObservationIgnored private var polling: Set<AgentKind> = []
    /// Bumped by every loop (re)start, so a superseded loop drops its result.
    @ObservationIgnored private var generations: [AgentKind: Int] = [:]
    @ObservationIgnored private var isSuspended = false

    /// - Parameters:
    ///   - sources: at most one per agent (a later duplicate is ignored).
    ///   - minimumInterval: floor for a source's `nextPollIn`, so a source can't spin.
    ///   - wakeDelay: seconds after `resume()` before any poll.
    ///   - now: the wall clock (injectable for tests).
    public init(sources: [any UsageSource], minimumInterval: TimeInterval = 5, wakeDelay: TimeInterval = 5,
                now: @escaping @Sendable () -> Date = { Date() }) {
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
        clock = now
    }

    /// Starts every source's loop (a source never polled yet polls right away). Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        isSuspended = false
        for agent in agents { restartLoop(agent, notBefore: nil) }
    }

    /// Cancels every loop; results of polls in flight are dropped. Idempotent.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        isSuspended = false
        cancelLoops()
    }

    /// System going to sleep: cancels the loops, keeping their deadlines. No-op unless running.
    public func suspend() {
        guard isRunning, !isSuspended else { return }
        isSuspended = true
        cancelLoops()
    }

    /// System woke: restarts the loops, none polling sooner than `wakeDelay` from now.
    /// No-op unless running. Also usable without a prior `suspend()` (e.g. a missed will-sleep).
    public func resume() {
        guard isRunning else { return }
        isSuspended = false
        let notBefore = clock().addingTimeInterval(wakeDelay)
        // A poll still in flight (cancelled by `suspend`) finishes first: the new loop waits for it.
        for agent in agents { restartLoop(agent, notBefore: notBefore) }
    }

    /// Polls now every source whose deadline passed more than `tolerance` ago and that isn't
    /// polling: catches up when a sleeping loop's timer was delayed (App Nap, a missed wake).
    public func pollOverdue(tolerance: TimeInterval = 2) {
        guard isRunning, !isSuspended else { return }
        let now = clock()
        for agent in agents where !polling.contains(agent) {
            guard let deadline = deadlines[agent], deadline.addingTimeInterval(tolerance) < now else { continue }
            restartLoop(agent, notBefore: nil)
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
                let result = await source.poll(now: self.clock())
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
        return due.timeIntervalSince(now)
    }

    private func publish(_ result: UsagePollResult, for agent: AgentKind) {
        var published = result.usage
        published.agent = agent
        if usage[agent] != published { usage[agent] = published }
        deadlines[agent] = clock().addingTimeInterval(max(result.nextPollIn, minimumInterval))
    }
}
