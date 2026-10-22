import Foundation

public enum SessionStatus: String, Sendable, Codable {
    case busy, waiting, idle, unknown
}

public enum TerminalKind: Sendable, Equatable, Hashable {
    case ghostty, appleTerminal, other(String)
}

public struct ClaudeSession: Identifiable, Equatable, Hashable, Sendable {
    public var id: String            // Claude sessionId
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

    public init(
        id: String,
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
        updatedAt: Date
    ) {
        self.id = id
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
    }
}
