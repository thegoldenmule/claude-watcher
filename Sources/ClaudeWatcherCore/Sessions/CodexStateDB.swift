import Foundation
import SQLite3

/// A row of Codex's `threads` table (`$CODEX_HOME/state_<n>.sqlite`).
public struct CodexThreadRow: Equatable, Sendable {
    public var id: String
    public var rolloutPath: String
    public var createdAtMillis: Int64
    public var updatedAtMillis: Int64
    public var cwd: String
    /// Thread name: auto-generated (~1 s after the first prompt) or set with `/rename`.
    public var name: String?
    /// First user message (Codex's fallback title).
    public var title: String?
    /// Branch when the thread started.
    public var gitBranch: String?
    /// Subagents only.
    public var parentID: String?
    public var agentNickname: String?
    public var agentRole: String?
    public var agentPath: String?
    public var depth: Int

    public init(
        id: String, rolloutPath: String, createdAtMillis: Int64, updatedAtMillis: Int64, cwd: String,
        name: String? = nil, title: String? = nil, gitBranch: String? = nil, parentID: String? = nil,
        agentNickname: String? = nil, agentRole: String? = nil, agentPath: String? = nil, depth: Int = 0
    ) {
        self.id = id
        self.rolloutPath = rolloutPath
        self.createdAtMillis = createdAtMillis
        self.updatedAtMillis = updatedAtMillis
        self.cwd = cwd
        self.name = name
        self.title = title
        self.gitBranch = gitBranch
        self.parentID = parentID
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
        self.depth = depth
    }

    public var createdAt: Date { Date(timeIntervalSince1970: Double(createdAtMillis) / 1000) }
    public var updatedAt: Date { Date(timeIntervalSince1970: Double(updatedAtMillis) / 1000) }
    /// The later of created/updated: a thread is "in use" by a TUI started before this.
    public var activeAtMillis: Int64 { max(createdAtMillis, updatedAtMillis) }
}

/// Where thread rows come from; abstracted so discovery can be tested without sqlite.
public protocol CodexThreadSource: AnyObject {
    /// Interactive root threads (not subagents, `codex exec`, or Codex's internal helper
    /// threads) not archived and active at or after `sinceMillis`. nil when unavailable.
    func rootThreads(sinceMillis: Int64) -> [CodexThreadRow]?
    /// Subagent threads under `rootID` (nested ones too, `depth` 0 = direct child), active at
    /// or after `sinceMillis`.
    func subagentThreads(rootID: String, sinceMillis: Int64) -> [CodexThreadRow]
    /// Releases the database (no Codex sessions left to watch).
    func close()
}

/// Read-only access to Codex's state database. The newest `state_<n>.sqlite` in the Codex home
/// is opened `SQLITE_OPEN_READONLY` (the database is in WAL mode; a read-only connection still
/// sees committed writes and never checkpoints), kept open between scans, and reopened when a
/// newer schema file appears. Queries are statement-scoped, so no read transaction is held.
/// Not thread-safe: owned by `CodexDiscovery`'s actor.
public final class CodexStateDB: CodexThreadSource {
    public let codexHome: URL
    private var db: OpaquePointer?
    private var openPath: String?
    private var lastPathCheck = Date.distantPast

    public init(codexHome: URL) {
        self.codexHome = codexHome
    }

    deinit { close() }

    /// `state_<n>.sqlite` with the largest n, or nil.
    static func newestStateFile(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let best = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            guard let n = Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (n, name)
        }.max { $0.0 < $1.0 }
        return best.map { directory.appendingPathComponent($0.1) }
    }

    private func connection() -> OpaquePointer? {
        let now = Date()
        if db != nil, now.timeIntervalSince(lastPathCheck) < 30 { return db }
        lastPathCheck = now
        guard let file = Self.newestStateFile(in: codexHome) else {
            close()
            return nil
        }
        if db != nil, openPath == file.path { return db }
        close()
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(file.path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
        db = handle
        openPath = file.path
        return db
    }

    public func close() {
        if let db { sqlite3_close(db) }
        db = nil
        openPath = nil
    }

    /// `created_at`/`updated_at` are seconds; the `_ms` columns were added later (filled by
    /// triggers on insert/update).
    static let createdMs = "COALESCE(t.created_at_ms, t.created_at * 1000)"
    static let updatedMs = "COALESCE(t.updated_at_ms, t.updated_at * 1000)"

    /// Interactive roots: `thread_source` 'user' (NULL on older rows); `source` is "cli" (an
    /// embedded TUI) or "vscode" (the app-server default, which TUI threads served by the shared
    /// daemon get); `exec`/`mcp` are headless and a subagent's source is a JSON object. Other
    /// clients of the same daemon (the IDE extension, the desktop app) are excluded by
    /// `originator`: the TUI is "codex-tui" through the daemon, "codex_cli_rs" embedded.
    static let rootQuery = """
        SELECT t.id, t.rollout_path, \(createdMs), \(updatedMs), t.cwd, t.name, t.title, t.git_branch
        FROM threads t
        WHERE t.archived = 0
          AND max(\(createdMs), \(updatedMs)) >= ?1
          AND (t.thread_source IS NULL OR t.thread_source = 'user')
          AND t.source NOT IN ('exec', 'mcp') AND t.source NOT LIKE '{%'
          AND (t.originator IS NULL OR t.originator IN ('codex-tui', 'codex_cli_rs'))
        ORDER BY \(updatedMs) DESC
        LIMIT 200
        """

    /// Older schemas without `name`/`thread_source`/`_ms` columns.
    static let legacyRootQuery = """
        SELECT t.id, t.rollout_path, t.created_at * 1000, t.updated_at * 1000, t.cwd, NULL, t.title, t.git_branch
        FROM threads t
        WHERE t.archived = 0
          AND max(t.created_at, t.updated_at) * 1000 >= ?1
          AND t.source NOT IN ('exec', 'mcp') AND t.source NOT LIKE '{%'
        ORDER BY t.updated_at DESC
        LIMIT 200
        """

    static let subagentQuery = """
        WITH RECURSIVE tree(id, parent, depth) AS (
          SELECT child_thread_id, parent_thread_id, 0 FROM thread_spawn_edges WHERE parent_thread_id = ?1
          UNION ALL
          SELECT e.child_thread_id, e.parent_thread_id, tree.depth + 1
          FROM thread_spawn_edges e JOIN tree ON e.parent_thread_id = tree.id
          WHERE tree.depth < 8
        )
        SELECT t.id, t.rollout_path, \(createdMs), \(updatedMs), t.cwd, t.agent_nickname, t.agent_role,
               t.agent_path, tree.parent, tree.depth
        FROM tree JOIN threads t ON t.id = tree.id
        WHERE max(\(createdMs), \(updatedMs)) >= ?2
        ORDER BY \(createdMs)
        """

    public func rootThreads(sinceMillis: Int64) -> [CodexThreadRow]? {
        guard let db = connection() else { return nil }
        let rows = query(db, Self.rootQuery, bind: { stmt in sqlite3_bind_int64(stmt, 1, sinceMillis) })
            ?? query(db, Self.legacyRootQuery, bind: { stmt in sqlite3_bind_int64(stmt, 1, sinceMillis) })
        guard let rows else { return nil }
        return rows.compactMap { row -> CodexThreadRow? in
            guard let id = row.text(0), let rollout = row.text(1), let cwd = row.text(4) else { return nil }
            return CodexThreadRow(
                id: id, rolloutPath: rollout, createdAtMillis: row.int(2), updatedAtMillis: row.int(3),
                cwd: cwd, name: row.text(5), title: row.text(6), gitBranch: row.text(7))
        }
    }

    public func subagentThreads(rootID: String, sinceMillis: Int64) -> [CodexThreadRow] {
        guard let db = connection() else { return [] }
        let rows = query(db, Self.subagentQuery, bind: { stmt in
            sqlite3_bind_text(stmt, 1, rootID, -1, Self.transient)
            sqlite3_bind_int64(stmt, 2, sinceMillis)
        }) ?? []
        return rows.compactMap { row -> CodexThreadRow? in
            guard let id = row.text(0), let rollout = row.text(1) else { return nil }
            return CodexThreadRow(
                id: id, rolloutPath: rollout, createdAtMillis: row.int(2), updatedAtMillis: row.int(3),
                cwd: row.text(4) ?? "", parentID: row.text(8),
                agentNickname: row.text(5), agentRole: row.text(6), agentPath: row.text(7),
                depth: Int(row.int(9)))
        }
    }

    /// Runs `sql` and copies out every result row, or nil if the statement doesn't prepare
    /// (schema mismatch) or fails.
    private func query(
        _ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void
    ) -> [Row]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(Row(stmt))
            } else if rc == SQLITE_DONE {
                return rows
            } else {
                return nil
            }
        }
    }

    /// A copied result row (column values read while the statement is positioned on it).
    private struct Row {
        var values: [Value]
        enum Value { case int(Int64), text(String), null }
        func int(_ i: Int) -> Int64 {
            guard i < values.count, case let .int(v) = values[i] else { return 0 }
            return v
        }
        /// Non-empty text, else nil.
        func text(_ i: Int) -> String? {
            guard i < values.count, case let .text(s) = values[i], !s.isEmpty else { return nil }
            return s
        }
        init(_ stmt: OpaquePointer) {
            values = (0..<sqlite3_column_count(stmt)).map { i in
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL: return .null
                case SQLITE_INTEGER, SQLITE_FLOAT: return .int(sqlite3_column_int64(stmt, i))
                default:
                    guard let c = sqlite3_column_text(stmt, i) else { return .null }
                    return .text(String(cString: c))
                }
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
