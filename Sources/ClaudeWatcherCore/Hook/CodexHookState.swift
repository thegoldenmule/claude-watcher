import Foundation

/// Per-session record written by `hooks/codex-watcher-hook.sh` to
/// `<CodexHookStateStore.defaultDirectory>/<session_id>.json` (temp file + rename).
///
/// Codex runs hooks inside its shared app-server daemon, in a new session with no controlling
/// tty, so unlike the Claude hook this one can't record a pid or tty: it is joined to a live
/// Codex TUI by thread id only, after discovery matched the TUI to its thread. Its job is the
/// one signal Codex never persists to its rollout: `PermissionRequest` ("waiting").
public struct CodexHookState: Codable, Sendable, Equatable {
    /// The root thread id (Codex's `session_id`; a subagent's events carry its root's id).
    public var sessionID: String
    /// SessionStart, UserPromptSubmit, PermissionRequest, Stop, Interrupt, SessionEnd.
    public var lastEvent: String
    public var turnID: String?
    /// Set when the event came from a subagent thread (its thread id).
    public var agentID: String?
    public var cwd: String?
    /// Epoch milliseconds.
    public var updatedAtMillis: Int64

    public var updatedAt: Date { Date(timeIntervalSince1970: Double(updatedAtMillis) / 1000) }

    public init(
        sessionID: String,
        lastEvent: String,
        turnID: String? = nil,
        agentID: String? = nil,
        cwd: String? = nil,
        updatedAtMillis: Int64
    ) {
        self.sessionID = sessionID
        self.lastEvent = lastEvent
        self.turnID = turnID
        self.agentID = agentID
        self.cwd = cwd
        self.updatedAtMillis = updatedAtMillis
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case lastEvent = "last_event"
        case turnID = "turn_id"
        case agentID = "agent_id"
        case cwd
        case updatedAtMillis = "updated_at"
    }

    /// Whether the last event says the session is blocked on an approval.
    public var isPermissionRequest: Bool { lastEvent == "PermissionRequest" }
}

public enum CodexHookStateStore {
    /// `~/Library/Application Support/ClaudeWatcher/codex-hook-state`: separate from the Claude
    /// hook's directory, whose GC deletes state files whose pid isn't a live Claude process.
    public static var defaultDirectory: URL {
        HookInstaller.defaultInstallDirectory.appendingPathComponent("codex-hook-state", isDirectory: true)
    }
}

/// Incremental reader for the Codex hook-state directory (re-reads only files whose size or
/// mtime changed). Keyed by session id; dot-files (temp files) are skipped.
public struct CodexHookStateCache: Sendable {
    private struct Entry: Sendable {
        var mtime: Date
        var size: Int
        var state: CodexHookState?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func load(directory: URL) -> [String: CodexHookState] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            entries = [:]
            return [:]
        }
        let decoder = JSONDecoder()
        var result: [String: CodexHookState] = [:]
        var next: [String: Entry] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let path = directory.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.intValue
            else { continue }
            let entry: Entry
            if let cached = entries[name], cached.mtime == mtime, cached.size == size {
                entry = cached
            } else {
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
                entry = Entry(mtime: mtime, size: size,
                              state: data.flatMap { try? decoder.decode(CodexHookState.self, from: $0) })
            }
            next[name] = entry
            if let state = entry.state {
                if let existing = result[state.sessionID], existing.updatedAtMillis > state.updatedAtMillis { continue }
                result[state.sessionID] = state
            }
        }
        entries = next
        return result
    }
}
