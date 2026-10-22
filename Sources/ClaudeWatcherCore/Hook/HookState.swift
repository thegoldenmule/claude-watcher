import Foundation

/// Per-session record written by `hooks/claude-watcher-hook.sh` to
/// `<HookStateStore.defaultDirectory>/<session_id>.json`.
///
/// It carries what `~/.claude/sessions/<pid>.json` lacks for focusing a terminal:
/// the claude PID <-> session id link (confirmed from inside the process tree),
/// the controlling tty, `TERM_PROGRAM`, and the Ghostty terminal id once resolved.
public struct HookState: Codable, Sendable, Equatable {
    public var sessionID: String
    public var claudePID: Int32
    /// "/dev/ttys001"; nil when claude has no controlling terminal (e.g. `claude -p` from a pipe).
    public var tty: String?
    /// `TERM_PROGRAM` of the claude process, e.g. "ghostty", "Apple_Terminal".
    public var termProgram: String?
    public var cwd: String?
    public var transcriptPath: String?
    /// Hook event that last wrote the file: SessionStart, UserPromptSubmit, Stop, Notification.
    public var lastEvent: String
    /// Ghostty AppleScript terminal id, preserved across events once known.
    public var ghosttyTerminalID: String?
    /// Epoch milliseconds.
    public var updatedAtMillis: Int64

    public var updatedAt: Date { Date(timeIntervalSince1970: Double(updatedAtMillis) / 1000) }

    public init(
        sessionID: String,
        claudePID: Int32,
        tty: String? = nil,
        termProgram: String? = nil,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        lastEvent: String,
        ghosttyTerminalID: String? = nil,
        updatedAtMillis: Int64
    ) {
        self.sessionID = sessionID
        self.claudePID = claudePID
        self.tty = tty
        self.termProgram = termProgram
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.lastEvent = lastEvent
        self.ghosttyTerminalID = ghosttyTerminalID
        self.updatedAtMillis = updatedAtMillis
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case claudePID = "claude_pid"
        case tty
        case termProgram = "term_program"
        case cwd
        case transcriptPath = "transcript_path"
        case lastEvent = "last_event"
        case ghosttyTerminalID = "ghostty_terminal_id"
        case updatedAtMillis = "updated_at"
    }
}

/// Reads the hook state directory.
public enum HookStateStore {
    /// `~/Library/Application Support/ClaudeWatcher/hook-state`
    public static var defaultDirectory: URL {
        HookInstaller.defaultInstallDirectory.appendingPathComponent("hook-state", isDirectory: true)
    }

    /// All readable state files, keyed by session id. Unreadable/partial files are skipped.
    /// Does not check whether `claudePID` is still alive; callers join against live sessions.
    public static func loadAll(directory: URL = defaultDirectory) -> [String: HookState] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [:] }
        let decoder = JSONDecoder()
        var result: [String: HookState] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let state = try? decoder.decode(HookState.self, from: data) else { continue }
            if let existing = result[state.sessionID], existing.updatedAtMillis > state.updatedAtMillis { continue }
            result[state.sessionID] = state
        }
        return result
    }

    /// Convenience: the newest state per claude PID (a PID can host several session ids over
    /// its life via /clear or /resume; the newest one is current).
    public static func latestByPID(_ states: [String: HookState]) -> [Int32: HookState] {
        var byPID: [Int32: HookState] = [:]
        for state in states.values {
            if let existing = byPID[state.claudePID], existing.updatedAtMillis >= state.updatedAtMillis { continue }
            byPID[state.claudePID] = state
        }
        return byPID
    }
}
