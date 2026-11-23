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
/// Which rollouts: the state DB's threads ordered by `updated_at` (subagent and helper threads
/// too; a long-lived thread keeps writing to a rollout in an old date directory, so file paths
/// say nothing). The DB is opened read-only per pass and closed again: a pass every 30 s
/// doesn't justify holding the WAL open. Per rollout, the last `token_count` with usable
/// `rate_limits` is found by scanning backward from the end in chunks (bounded), cached by
/// (inode, size, mtime); a grown file only has its appended bytes scanned.
final class CodexUsageReader: @unchecked Sendable {
    /// Rollouts checked per pass (newest `updated_at` first)...
    static let rolloutsToCheck = 3
    /// ...or further down this many while none of them had a reading.
    static let maxRolloutsToCheck = 10

    let codexHome: URL
    let chunkSize: Int
    let maxScan: Int
    /// Rollout files opened (tests: an unchanged file must not be re-read).
    private(set) var fileReads = 0

    private struct Entry {
        var inode: UInt64
        var size: Int64
        var mtime: timespec
        /// End of the last complete line scanned; nil = rescan from the end next time.
        var completeEnd: Int64?
        var reading: CodexRateLimitReading?
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
        /// `reading` is the newest found (nil: none); `errors` lists rollouts that couldn't be read.
        case scanned(reading: CodexRateLimitReading?, errors: [String])
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
        let paths: [String]
        switch Self.recentRolloutPaths(dbFile: dbFile, limit: Self.maxRolloutsToCheck) {
        case .failure(let error): return .failed(error.message)
        case .success(let p): paths = p
        }
        var best: CodexRateLimitReading?
        var errors: [String] = []
        var checked = 0
        var seen: Set<String> = []
        for path in paths where seen.insert(path).inserted {
            if checked >= Self.rolloutsToCheck && best != nil { break }
            switch reading(at: path) {
            case .missing:
                continue
            case .failed(let message):
                errors.append(message)
            case .read(let reading):
                if let reading, best.map({ reading.timestamp > $0.timestamp }) ?? true { best = reading }
            }
            checked += 1
        }
        entries = entries.filter { seen.contains($0.key) }
        return .scanned(reading: best, errors: errors)
    }

    // MARK: - State DB

    static let recentQuery = """
        SELECT rollout_path FROM threads
        ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC LIMIT ?1
        """
    /// Older schemas without the `_ms` columns.
    static let legacyRecentQuery = "SELECT rollout_path FROM threads ORDER BY updated_at DESC LIMIT ?1"

    /// Rollout paths of the most recently updated threads (any kind, archived or not).
    static func recentRolloutPaths(dbFile: URL, limit: Int) -> Result<[String], CodexUsageError> {
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
            var paths: [String] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) {
                        let path = String(cString: c)
                        if !path.isEmpty { paths.append(path) }
                    }
                } else if rc == SQLITE_DONE {
                    return .success(paths)
                } else {
                    return .failure(CodexUsageError("state DB: \(String(cString: sqlite3_errmsg(db)))"))
                }
            }
        }
        return .failure(CodexUsageError("state DB: \(lastError)"))
    }

    // MARK: - Rollouts

    enum FileResult: Equatable {
        case missing
        case failed(String)
        case read(CodexRateLimitReading?)
    }

    /// The newest reading in the rollout at `path`.
    func reading(at path: String) -> FileResult {
        var st = stat()
        guard stat(path, &st) == 0 else {
            let code = errno
            entries[path] = nil
            if code == ENOENT || code == ENOTDIR { return .missing }
            return .failed("\((path as NSString).lastPathComponent): \(String(cString: strerror(code)))")
        }
        let inode = UInt64(st.st_ino)
        let size = Int64(st.st_size)
        let mtime = st.st_mtimespec
        let cached = entries[path]
        if let cached, cached.inode == inode, cached.size == size,
           cached.mtime.tv_sec == mtime.tv_sec, cached.mtime.tv_nsec == mtime.tv_nsec {
            return .read(cached.reading)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return .failed("\((path as NSString).lastPathComponent): can't open")
        }
        defer { try? handle.close() }
        fileReads += 1
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
            var entry = Entry(inode: inode, size: size, mtime: mtime, completeEnd: found.completeEnd, reading: found.value)
            if let cached, incremental != nil {
                if entry.reading == nil { entry.reading = cached.reading }
                if entry.completeEnd == nil { entry.completeEnd = cached.completeEnd }
            }
            entries[path] = entry
            return .read(entry.reading)
        } catch {
            entries[path] = nil
            return .failed("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Scans the complete lines in `floor..<end` newest first and returns the first that
    /// `parse` accepts, plus the end of the last complete line (nil if none). A trailing line
    /// without its newline is still being written and is skipped. Lines spanning chunks are
    /// carried over to the next (older) chunk; if `floor` isn't a line start, the partial line
    /// there is dropped.
    static func scanBackward<T>(
        handle: FileHandle, end: Int64, floor: Int64, floorIsLineStart: Bool, chunkSize: Int,
        parse: (Data) -> T?
    ) throws -> (value: T?, completeEnd: Int64?) {
        var position = end
        var carry = Data()  // start of a line that began in an older chunk
        var completeEnd: Int64?
        while position > floor {
            let start = max(floor, position - Int64(chunkSize))
            try handle.seek(toOffset: UInt64(start))
            let count = Int(position - start)
            guard var chunk = try handle.read(upToCount: count), chunk.count == count else {
                throw CodexUsageError("short read")
            }
            chunk.append(carry)
            carry = Data()
            position = start
            if completeEnd == nil {
                guard let nl = chunk.lastIndex(of: 0x0A) else { continue }  // all trailing partial line
                completeEnd = start + Int64(nl) + 1
                chunk = Data(chunk[..<nl])
            }
            if start > floor || !floorIsLineStart {
                guard let nl = chunk.firstIndex(of: 0x0A) else {
                    carry = chunk  // one line spans the whole chunk
                    continue
                }
                carry = Data(chunk[..<nl])
                chunk = Data(chunk[(nl + 1)...])
            }
            for line in chunk.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
                if let value = parse(Data(line)) { return (value, completeEnd) }
            }
        }
        return (nil, completeEnd)
    }
}

struct CodexUsageError: Error, Equatable, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
