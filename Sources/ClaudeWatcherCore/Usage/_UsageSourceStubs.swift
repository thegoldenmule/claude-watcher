import Foundation

// Temporary stand-ins for the real sources (written in parallel); deleted at merge.

public actor ClaudeUsageSource: UsageSource {
    public nonisolated let agent: AgentKind = .claude

    public init() {}

    public func poll(now: Date) async -> UsagePollResult {
        UsagePollResult(usage: AgentUsage(agent: agent, snapshot: nil, status: .unavailable), nextPollIn: 300)
    }
}

public actor CodexUsageSource: UsageSource {
    public nonisolated let agent: AgentKind = .codex

    public init() {}

    public func poll(now: Date) async -> UsagePollResult {
        UsagePollResult(usage: AgentUsage(agent: agent, snapshot: nil, status: .unavailable), nextPollIn: 300)
    }
}
