import Foundation

/// One rate-limit window of an agent's plan. `percent` is 0...100 (may exceed 100).
public struct UsageWindow: Sendable, Equatable {
    public var percent: Double
    /// When the window resets; nil if the source didn't say.
    public var resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// True once `resetsAt` has passed: the usage counted here no longer applies,
    /// even if no newer reading has arrived yet (e.g. offline overnight).
    public func hasReset(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    /// The percentage to show at `now`: 0 once the window has reset.
    public func displayPercent(at now: Date) -> Double {
        hasReset(at: now) ? 0 : percent
    }
}

/// An agent's plan usage: the short (session, ~5 h) and weekly windows. Either may be
/// missing (e.g. a plan without a session limit).
public struct UsageSnapshot: Sendable, Equatable {
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    /// When this reading was taken (Claude: fetch time; Codex: the rollout event's timestamp).
    public var asOf: Date

    public init(session: UsageWindow?, weekly: UsageWindow?, asOf: Date) {
        self.session = session
        self.weekly = weekly
        self.asOf = asOf
    }
}

/// Severity bucket for a usage percentage (same thresholds as ClaudeTray).
public enum UsageLevel: Sendable, Equatable {
    case normal     // < 80%
    case warning    // >= 80%
    case critical   // >= 95%

    public init(percent: Double) {
        if percent >= 95 {
            self = .critical
        } else if percent >= 80 {
            self = .warning
        } else {
            self = .normal
        }
    }
}

/// The state of one agent's usage reading.
public enum UsageStatus: Sendable, Equatable {
    /// Nothing to show and nothing wrong: not logged in to Claude Code, Codex never used, ...
    /// The agent's meter is hidden.
    case unavailable
    /// Not polled yet.
    case loading
    /// The snapshot is current.
    case ok
    /// There is a snapshot, but the latest poll failed. User-facing message.
    case stale(String)
    /// No snapshot at all and the poll failed. User-facing message.
    case error(String)
}

/// One agent's usage as published to the UI.
public struct AgentUsage: Sendable, Equatable {
    public var agent: AgentKind
    public var snapshot: UsageSnapshot?
    public var status: UsageStatus

    public init(agent: AgentKind, snapshot: UsageSnapshot?, status: UsageStatus) {
        self.agent = agent
        self.snapshot = snapshot
        self.status = status
    }
}

/// The outcome of one poll of a `UsageSource`.
public struct UsagePollResult: Sendable, Equatable {
    public var usage: AgentUsage
    /// Seconds until the source wants to be polled again (backoff, rate limits, ...).
    public var nextPollIn: TimeInterval

    public init(usage: AgentUsage, nextPollIn: TimeInterval) {
        self.usage = usage
        self.nextPollIn = nextPollIn
    }
}

/// Produces one agent's usage. Each source keeps its own retry/backoff state; the caller
/// (`UsageStore`) polls it again after `nextPollIn`, never concurrently with itself.
public protocol UsageSource: Sendable {
    var agent: AgentKind { get }
    func poll(now: Date) async -> UsagePollResult
}
