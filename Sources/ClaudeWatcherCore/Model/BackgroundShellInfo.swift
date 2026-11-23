import Foundation

/// A shell command the session's main conversation runs in the background (Bash with
/// `run_in_background`, or a foreground command that timed out or was backgrounded), read from
/// the session transcript. Claude Code re-invokes the session when it ends, so the session is
/// still at work while one runs, even with its prompt idle.
public struct BackgroundShellInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String            // Claude Code's background task id (`backgroundTaskId`)
    public var label: String         // the Bash call's description, else its command's first line
    /// The command's first line, when `label` is the description; nil otherwise.
    public var command: String?
    public var startedAt: Date

    public init(id: String, label: String, command: String? = nil, startedAt: Date) {
        self.id = id
        self.label = label
        self.command = command
        self.startedAt = startedAt
    }
}
