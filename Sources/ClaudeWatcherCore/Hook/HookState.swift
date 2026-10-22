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
        var cache = HookStateCache()
        return cache.load(directory: directory)
    }

    /// State files are `<session_id>.json`; dot-files are temp files / stamps.
    static func isStateFileName(_ name: String) -> Bool {
        name.hasSuffix(".json") && !name.hasPrefix(".")
    }

    /// Keeps the newer of two states for the same session id.
    static func insertNewest(_ state: HookState, into result: inout [String: HookState]) {
        if let existing = result[state.sessionID], existing.updatedAtMillis > state.updatedAtMillis { return }
        result[state.sessionID] = state
    }

    /// The hook state describing a live session, or nil.
    ///
    /// Looks up `sessionID` first, then the newest state for `pid` (covers a registry entry
    /// whose session id lags a `/clear` or `/resume` in the same process). Either candidate must
    /// belong to `pid`, agree on the tty when both are known, and have been written after the
    /// process started (so a dead process's state can't attach to a reused pid).
    public static func match(
        sessionID: String,
        pid: Int32,
        tty: String?,
        processStart: Date,
        states: [String: HookState],
        byPID: [Int32: HookState]
    ) -> HookState? {
        func plausible(_ s: HookState) -> Bool {
            guard s.claudePID == pid else { return false }
            if let a = s.tty, let b = tty, a != b { return false }
            return s.updatedAt >= processStart.addingTimeInterval(-ProcessRules.startTolerance)
        }
        if let s = states[sessionID], plausible(s) { return s }
        if let s = byPID[pid], plausible(s) { return s }
        return nil
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

/// Incremental reader for the hook-state directory: only files whose size or modification
/// time changed since the last `load` are re-read and decoded. The hook writes atomically
/// (temp file + rename), so a changed file is always a new inode with a fresh mtime.
public struct HookStateCache: Sendable {
    private struct Entry: Sendable {
        var mtime: Date
        var size: Int
        var state: HookState?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// All readable state files in `directory`, keyed by session id (newest wins).
    public mutating func load(directory: URL) -> [String: HookState] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            entries = [:]
            return [:]
        }
        let decoder = JSONDecoder()
        var result: [String: HookState] = [:]
        var next: [String: Entry] = [:]
        for name in names where HookStateStore.isStateFileName(name) {
            let path = directory.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.intValue
            else { continue }
            let entry: Entry
            if let cached = entries[name], cached.mtime == mtime, cached.size == size {
                entry = cached
            } else {
                let state = (try? Data(contentsOf: URL(fileURLWithPath: path)))
                    .flatMap { try? decoder.decode(HookState.self, from: $0) }
                entry = Entry(mtime: mtime, size: size, state: state)
            }
            next[name] = entry
            if let state = entry.state { HookStateStore.insertNewest(state, into: &result) }
        }
        entries = next
        return result
    }
}
