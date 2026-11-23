import Foundation
import SQLite3

/// One plan-limit reading from a rollout's `token_count` event (`payload.rate_limits`).
struct CodexRateLimitReading: Equatable, Sendable {
    /// The event's `timestamp`.
    var timestamp: Date
    var session: UsageWindow?
    var weekly: UsageWindow?

    var snapshot: UsageSnapshot { UsageSnapshot(session: session, weekly: weekly, asOf: timestamp) }
}

/// Parses `rate_limits` out of rollout lines. Shape (CLI 0.169):
/// `"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":96.0,
/// "window_minutes":10080,"resets_at":1795533518},"secondary":null,"credits":{...},"plan_type":...}`.
/// `rate_limits` follows `info`, so the line is decoded whole (~900 bytes), but only after the
/// 512-byte prefix says it's a `token_count` and the line mentions `"rate_limits":`.
enum CodexRateLimitParser {
    /// Windows shorter than this are the session (~5 h) window, longer ones the weekly window.
    /// Codex has sent 300 and 10080 minutes; the cut sits well between them.
    static let sessionWindowLimitMinutes: Double = 3 * 24 * 60

    private static let rateLimitsMarker = Data("\"rate_limits\":".utf8)

    /// The reading in `line`, or nil if it isn't a `token_count` event with usable limits.
    static func reading(fromLine line: Data) -> CodexRateLimitReading? {
        let prefix = String(decoding: line.prefix(CodexRolloutParser.prefixLength), as: UTF8.self)
        guard prefix.hasPrefix("{"),
              CodexRolloutParser.stringValue(after: "\"payload\":{\"type\":\"", in: prefix) == "token_count",
              line.range(of: rateLimitsMarker) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let stamp = object["timestamp"] as? String, let timestamp = CodexRolloutParser.parseDate(stamp),
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }
        return reading(fromRateLimits: limits, timestamp: timestamp)
    }

    /// Only the `codex` limit (or an unnamed one) is Codex's plan limit; other `limit_id`s
    /// (per-model or add-on limits) are ignored. nil if no window could be read.
    static func reading(fromRateLimits limits: [String: Any], timestamp: Date) -> CodexRateLimitReading? {
        switch limits["limit_id"] {
        case nil, is NSNull: break
        case let id as String where id == "codex" || id.isEmpty: break
        default: return nil
        }
        var result = CodexRateLimitReading(timestamp: timestamp)
        let windows = [(limits["primary"], true), (limits["secondary"], false)]
        for (raw, isPrimary) in windows {
            guard let dict = raw as? [String: Any], let (window, minutes) = window(dict, timestamp: timestamp)
            else { continue }
            if isSession(minutes: minutes, isPrimary: isPrimary) {
                result.session = higher(result.session, window)
            } else {
                result.weekly = higher(result.weekly, window)
            }
        }
        return result.session == nil && result.weekly == nil ? nil : result
    }

    /// Classifies by length, not position (Codex has sent the weekly window as `primary` with no
    /// `secondary`). Without a length, Codex's original layout: primary = session, secondary = weekly.
    static func isSession(minutes: Double?, isPrimary: Bool) -> Bool {
        guard let minutes, minutes > 0 else { return isPrimary }
        return minutes < sessionWindowLimitMinutes
    }

    /// Two windows of the same kind: the fuller one is the binding limit.
    private static func higher(_ a: UsageWindow?, _ b: UsageWindow) -> UsageWindow {
        guard let a else { return b }
        return b.percent > a.percent ? b : a
    }

    private static func window(_ dict: [String: Any], timestamp: Date) -> (UsageWindow, Double?)? {
        guard let percent = (dict["used_percent"] as? NSNumber)?.doubleValue, percent.isFinite, percent >= 0
        else { return nil }
        let minutes = (dict["window_minutes"] as? NSNumber)?.doubleValue
        var resetsAt: Date?
        if let at = (dict["resets_at"] as? NSNumber)?.doubleValue, at > 0 {
            resetsAt = Date(timeIntervalSince1970: at)
        } else if let inSeconds = (dict["resets_in_seconds"] as? NSNumber)?.doubleValue, inSeconds >= 0 {
            // Older CLIs: relative to the event.
            resetsAt = timestamp.addingTimeInterval(inSeconds)
        }
        return (UsageWindow(percent: percent, resetsAt: resetsAt), minutes)
    }
}

/// Finds the newest plan-limit reading in the Codex home. Not thread-safe: used only on
/// `CodexUsageSource`'s queue.
///
/// Which rollouts: the state DB's most recently updated threads (subagent and helper threads
/// too; a long-lived thread keeps writing to a rollout in an old date directory, so file paths
/// say nothing), newest possible event first, down to the first one last written no later than
/// the best reading found: a rollout can't hold an event newer than its last write, which is
/// the later of the thread's `updated_at` and the file's mtime (Codex doesn't bump `updated_at`
/// on every write). At most `maxRolloutsToCheck` threads. The DB is opened read-only per pass
/// and closed again: a pass every 30 s doesn't justify holding the WAL open. Per rollout, the
/// last `token_count` with usable `rate_limits` is found by scanning backward from the end in
/// chunks (bounded), cached by (inode, size, mtime) of the descriptor actually read; a grown
/// file only has its appended bytes scanned.
final class CodexUsageReader: @unchecked Sendable {
    /// Threads considered per pass (newest `updated_at` first), a cost cap.
    static let maxRolloutsToCheck = 10

    let codexHome: URL
    let chunkSize: Int
    let maxScan: Int
    /// Rollout files read (tests: an unchanged file must not be re-read).
    private(set) var fileReads = 0

    private struct Entry {
        var inode: UInt64
        var size: Int64
        var mtime: timespec
        /// End of the last complete line scanned; nil = rescan from the end next time.
        var completeEnd: Int64?
        var reading: CodexRateLimitReading?

        func matches(_ st: stat) -> Bool {
            inode == UInt64(st.st_ino) && size == Int64(st.st_size)
                && mtime.tv_sec == st.st_mtimespec.tv_sec && mtime.tv_nsec == st.st_mtimespec.tv_nsec
        }
    }

    private var entries: [String: Entry] = [:]

    init(codexHome: URL, chunkSize: Int = 64 * 1024, maxScan: Int = 8 * 1024 * 1024) {
        self.codexHome = codexHome
        self.chunkSize = chunkSize
        self.maxScan = maxScan
    }

    enum Outcome: Equatable, Sendable {
        /// No Codex home or no state DB: Codex isn't in use.
        case unavailable
        /// The DB couldn't be read.
        case failed(String)
        /// `reading` is the newest found (nil: none); `errors` lists rollouts that couldn't be
        /// read although they may hold a newer reading.
        case scanned(reading: CodexRateLimitReading?, errors: [String])
    }

    private struct Candidate {
        var path: String
        /// The rollout's stat, or why it failed.
        var info: Result<stat, CodexUsageError>
        /// Its last write (nil: unknown); no event in it is newer.
        var lastWrite: Date?
        var order: Int
    }

    /// One pass. Blocking (sqlite + file reads).
    func scan() -> Outcome {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexHome.path, isDirectory: &isDir), isDir.boolValue,
              let dbFile = CodexStateDB.newestStateFile(in: codexHome)
        else {
            entries = [:]
            return .unavailable
        }
        let threads: [RecentThread]
        switch Self.recentThreads(dbFile: dbFile, limit: Self.maxRolloutsToCheck) {
        case .failure(let error): return .failed(error.message)
        case .success(let t): threads = t
        }
        var seen: Set<String> = []
        var candidates: [Candidate] = []
        for thread in threads where seen.insert(thread.path).inserted {
            var st = stat()
            if stat(thread.path, &st) == 0 {
                let mtime = Self.date(st.st_mtimespec)
                candidates.append(Candidate(path: thread.path, info: .success(st),
                                            lastWrite: max(thread.updatedAt ?? mtime, mtime), order: candidates.count))
            } else {
                let code = errno
                entries[thread.path] = nil
                if code == ENOENT || code == ENOTDIR { continue }
                candidates.append(Candidate(path: thread.path, info: .failure(Self.error(thread.path, code)),
                                            lastWrite: thread.updatedAt, order: candidates.count))
            }
        }
        // Newest possible event first (unknown first), DB order among equals.
        candidates.sort {
            let a = $0.lastWrite ?? .distantFuture, b = $1.lastWrite ?? .distantFuture
            return a != b ? a > b : $0.order < $1.order
        }
        var best: CodexRateLimitReading?
        var errors: [String] = []
        for candidate in candidates {
            if let best, let lastWrite = candidate.lastWrite, lastWrite <= best.timestamp { break }
            do {
                let reading = try reading(at: candidate.path, stat: candidate.info.get())
                if let reading, best.map({ reading.timestamp > $0.timestamp }) ?? true { best = reading }
            } catch {
                errors.append((error as? CodexUsageError)?.message ?? error.localizedDescription)
            }
        }
        entries = entries.filter { seen.contains($0.key) }
        return .scanned(reading: best, errors: errors)
    }

    private static func date(_ t: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }

    private static func error(_ path: String, _ code: Int32) -> CodexUsageError {
        CodexUsageError("\((path as NSString).lastPathComponent): \(String(cString: strerror(code)))")
    }

    // MARK: - State DB

    struct RecentThread: Equatable {
        var path: String
        /// `updated_at_ms` (else `updated_at`); nil if neither is a number.
        var updatedAt: Date?
    }

    static let recentQuery = """
        SELECT rollout_path, COALESCE(updated_at_ms, updated_at * 1000) AS updated FROM threads
        ORDER BY updated DESC LIMIT ?1
        """
    /// Older schemas without the `_ms` columns.
    static let legacyRecentQuery = "SELECT rollout_path, updated_at * 1000 FROM threads ORDER BY updated_at DESC LIMIT ?1"

    /// The most recently updated threads (any kind, archived or not).
    static func recentThreads(dbFile: URL, limit: Int) -> Result<[RecentThread], CodexUsageError> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbFile.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return .failure(CodexUsageError("state DB: \(message)"))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var lastError = "no threads table"
        for sql in [recentQuery, legacyRecentQuery] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                lastError = String(cString: sqlite3_errmsg(db))
                sqlite3_finalize(stmt)
                continue
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))
            var threads: [RecentThread] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    guard let c = sqlite3_column_text(stmt, 0) else { continue }
                    let path = String(cString: c)
                    guard !path.isEmpty else { continue }
                    var updatedAt: Date?
                    let type = sqlite3_column_type(stmt, 1)
                    if type == SQLITE_INTEGER || type == SQLITE_FLOAT {
                        var value = sqlite3_column_double(stmt, 1)
                        if value < 1e11 { value *= 1000 }  // seconds in an `_ms` column
                        updatedAt = Date(timeIntervalSince1970: value / 1000)
                    }
                    threads.append(RecentThread(path: path, updatedAt: updatedAt))
                } else if rc == SQLITE_DONE {
                    return .success(threads)
                } else {
                    return .failure(CodexUsageError("state DB: \(String(cString: sqlite3_errmsg(db)))"))
                }
            }
        }
        return .failure(CodexUsageError("state DB: \(lastError)"))
    }

    // MARK: - Rollouts

    /// The newest reading in the rollout at `path`, whose stat by path was `st`. Throws a
    /// `CodexUsageError` naming the file. A file gone since `st` has no reading.
    func reading(at path: String, stat st: stat) throws -> CodexRateLimitReading? {
        let cached = entries[path]
        if let cached, cached.matches(st) { return cached.reading }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            entries[path] = nil
            if code == ENOENT || code == ENOTDIR { return nil }
            throw Self.error(path, code)
        }
        defer { Darwin.close(fd) }
        // Keyed on the file actually opened: it may have been replaced since `st`.
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            let code = errno
            entries[path] = nil
            throw Self.error(path, code)
        }
        if let cached, cached.matches(opened) { return cached.reading }
        fileReads += 1
        let inode = UInt64(opened.st_ino)
        let size = Int64(opened.st_size)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        // Grown (append-only while its thread is loaded): scan only the new bytes.
        let incremental = cached.flatMap { c -> Int64? in
            guard c.inode == inode, let end = c.completeEnd, size >= end else { return nil }
            return end
        }
        let lowest = incremental ?? 0
        let floor = max(lowest, size - Int64(maxScan))
        do {
            let found = try Self.scanBackward(
                handle: handle, end: size, floor: floor, floorIsLineStart: floor == lowest,
                chunkSize: chunkSize, parse: CodexRateLimitParser.reading(fromLine:))
            var entry = Entry(inode: inode, size: size, mtime: opened.st_mtimespec,
                              completeEnd: found.completeEnd, reading: found.value)
            if let cached, incremental != nil {
                if entry.reading == nil { entry.reading = cached.reading }
                if entry.completeEnd == nil { entry.completeEnd = cached.completeEnd }
            }
            entries[path] = entry
            return entry.reading
        } catch {
            entries[path] = nil
            throw CodexUsageError("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Scans the complete lines in `floor..<end` newest first and returns the first that
    /// `parse` accepts, plus the end of the last complete line (nil if none). A trailing line
    /// without its newline is still being written and is skipped. A line spanning chunks is
    /// assembled once, when its start is found (its newer pieces are kept, not re-copied per
    /// chunk); if `floor` isn't a line start, the partial line there is dropped.
    static func scanBackward<T>(
        handle: FileHandle, end: Int64, floor: Int64, floorIsLineStart: Bool, chunkSize: Int,
        parse: (Data) -> T?
    ) throws -> (value: T?, completeEnd: Int64?) {
        var position = end
        var tail: [Data] = []  // newer pieces of a line that began in an older chunk, newest first
        var completeEnd: Int64?
        while position > floor {
            let start = max(floor, position - Int64(chunkSize))
            try handle.seek(toOffset: UInt64(start))
            let count = Int(position - start)
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                throw CodexUsageError("short read")
            }
            position = start
            var body = chunk[...]
            if completeEnd == nil {
                guard let nl = chunk.lastIndex(of: 0x0A) else { continue }  // all trailing partial line
                completeEnd = start + Int64(nl - chunk.startIndex) + 1
                body = chunk[..<nl]
            }
            // `head`: the part of a line that began in an older chunk (nil: `body` starts a line).
            var head: Data.SubSequence?
            if start > floor || !floorIsLineStart {
                guard let nl = body.firstIndex(of: 0x0A) else {
                    tail.append(Data(body))  // one line spans the whole chunk
                    continue
                }
                head = body[..<nl]
                body = body[(nl + 1)...]
            }
            if !tail.isEmpty {
                // `body`'s last line continues in `tail`.
                let lineStart = body.lastIndex(of: 0x0A).map { $0 + 1 } ?? body.startIndex
                var line = Data(body[lineStart...])
                for piece in tail.reversed() { line.append(piece) }
                tail = []
                body = body[..<lineStart]
                if !line.isEmpty, let value = parse(line) { return (value, completeEnd) }
            }
            for line in body.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                if let value = parse(Data(line)) { return (value, completeEnd) }
            }
            if let head { tail = [Data(head)] }
        }
        return (nil, completeEnd)
    }
}

struct CodexUsageError: Error, Equatable, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
