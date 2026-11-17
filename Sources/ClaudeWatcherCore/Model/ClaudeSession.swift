import Foundation

public enum SessionStatus: String, Sendable, Codable {
    case busy, waiting, idle, unknown
}

public enum TerminalKind: Sendable, Equatable, Hashable {
    case ghostty, appleTerminal, other(String)
}

/// Which coding agent CLI a session runs.
public enum AgentKind: String, Sendable, Codable, Hashable, CaseIterable {
    case claude, codex

    /// Short lowercase name for the UI ("claude", "codex").
    public var label: String { rawValue }
}

public struct ClaudeSession: Identifiable, Equatable, Hashable, Sendable {
    public var id: String            // Claude sessionId / Codex thread id (or `codex-pid-…`)
    public var agent: AgentKind
    public var pid: Int32
    public var cwd: String
    public var title: String         // best display title (custom title > ai-title > derived name)
    public var branch: String?
    public var lastPrompt: String?
    public var status: SessionStatus
    public var waitingFor: String?   // e.g. "input needed"
    public var tty: String?          // "/dev/ttys001"
    public var terminal: TerminalKind
    public var ghosttyTerminalID: String?  // Ghostty AppleScript terminal UUID, if known
    public var startedAt: Date
    public var updatedAt: Date
    public var subagents: [SubagentInfo]  // running subagents, pre-order (children follow their parent)
    public var contextTokens: Int?        // main conversation's context size at its last reply
    public var contextWindow: Int?        // nil = the agent's default (`ContextUsage.window`)

    public init(
        id: String,
        agent: AgentKind = .claude,
        pid: Int32,
        cwd: String,
        title: String,
        branch: String? = nil,
        lastPrompt: String? = nil,
        status: SessionStatus = .unknown,
        waitingFor: String? = nil,
        tty: String? = nil,
        terminal: TerminalKind = .other("unknown"),
        ghosttyTerminalID: String? = nil,
        startedAt: Date,
        updatedAt: Date,
        subagents: [SubagentInfo] = [],
        contextTokens: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.title = title
        self.branch = branch
        self.lastPrompt = lastPrompt
        self.status = status
        self.waitingFor = waitingFor
        self.tty = tty
        self.terminal = terminal
        self.ghosttyTerminalID = ghosttyTerminalID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.subagents = subagents
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
    }

    /// The context window to measure `contextTokens` against.
    public var effectiveContextWindow: Int { contextWindow ?? ContextUsage.window }
}
