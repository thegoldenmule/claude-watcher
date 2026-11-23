import Foundation
import SQLite3
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures

private let base: Double = 1_795_000_000

private func iso(_ seconds: Double) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date(timeIntervalSince1970: seconds))
}

private func window(_ percent: Double, minutes: Int?, resets: Double = base + 3600) -> String {
    let m = minutes.map { "\"window_minutes\":\($0)," } ?? ""
    return "{\"used_percent\":\(percent),\(m)\"resets_at\":\(Int(resets))}"
}

private func limits(id: String? = "codex", primary: String? = nil, secondary: String? = nil) -> String {
    let idJSON = id.map { "\"\($0)\"" } ?? "null"
    return "{\"limit_id\":\(idJSON),\"limit_name\":null,\"primary\":\(primary ?? "null"),"
        + "\"secondary\":\(secondary ?? "null"),\"credits\":{\"has_credits\":false,\"unlimited\":false,"
        + "\"balance\":null},\"individual_limit\":null,\"plan_type\":\"plus\",\"rate_limit_reached_type\":null}"
}

/// A `token_count` line; `rateLimits` nil omits the key. `padding` bloats `info`.
private func tokenLine(_ t: Double, rateLimits: String?, padding: Int = 0) -> String {
    let pad = padding > 0 ? ",\"pad\":\"\(String(repeating: "x", count: padding))\"" : ""
    let info = "{\"total_token_usage\":{\"total_tokens\":1000},\"last_token_usage\":{\"total_tokens\":500},"
        + "\"model_context_window\":258400\(pad)}"
    let rl = rateLimits.map { ",\"rate_limits\":\($0)" } ?? ""
    return "{\"timestamp\":\"\(iso(t))\",\"ordinal\":1,\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\","
        + "\"info\":\(info)\(rl)}}\n"
}

private func otherLine(_ t: Double, size: Int = 0) -> String {
    "{\"timestamp\":\"\(iso(t))\",\"ordinal\":2,\"type\":\"response_item\",\"payload\":{\"type\":\"message\","
        + "\"text\":\"\(String(repeating: "y", count: size))\"}}\n"
}

private func weekly(_ percent: Double, at t: Double) -> String {
    tokenLine(t, rateLimits: limits(primary: window(percent, minutes: 10080)))
}

/// A throwaway Codex home, removed on deinit.
private final class CodexHome {
    let url: URL
    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-codex-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: ProcessRules.realpath(raw.path) ?? raw.path, isDirectory: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.path
    }

    /// Sets the file's mtime (its last write, as far as the reader's bound is concerned).
    func touch(_ relative: String, at seconds: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)],
                                              ofItemAtPath: path(relative))
    }

    /// Replaces the file with a new one (new inode), like an atomic save.
    func replace(_ relative: String, _ text: String) throws {
        let temp = path(relative + ".tmp")
        try Data(text.utf8).write(to: URL(fileURLWithPath: temp))
        guard rename(temp, path(relative)) == 0 else { throw CodexUsageError("rename") }
    }

    /// Truncates and rewrites the file in place (same inode).
    func rewriteInPlace(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func inode(_ relative: String) -> UInt64 {
        var st = stat()
        return stat(path(relative), &st) == 0 ? UInt64(st.st_ino) : 0
    }

    func append(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// `state_5.sqlite` with one thread per rollout; `updated` in seconds, also set as the
    /// existing rollouts' mtime (Codex's last write).
    func database(_ threads: [(rollout: String, updated: Double)], legacy: Bool = false) throws {
        let file = path("state_5.sqlite")
        try? FileManager.default.removeItem(atPath: file)
        var db: OpaquePointer?
        guard sqlite3_open(file, &db) == SQLITE_OK else { throw CodexUsageError("open") }
        defer { sqlite3_close(db) }
        var sql = legacy
            ? "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL);"
            : "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL, updated_at_ms INTEGER);"
        for (i, t) in threads.enumerated() {
            let rollout = t.rollout.hasPrefix("/") ? t.rollout : path(t.rollout)
            sql += legacy
                ? "INSERT INTO threads VALUES ('t\(i)', '\(rollout)', \(Int(t.updated)));"
                : "INSERT INTO threads VALUES ('t\(i)', '\(rollout)', \(Int(t.updated)), \(Int(t.updated * 1000)));"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CodexUsageError("exec") }
        for t in threads where !t.rollout.hasPrefix("/") && FileManager.default.fileExists(atPath: path(t.rollout)) {
            try touch(t.rollout, at: t.updated)
        }
    }
}

private func parse(_ line: String) -> CodexRateLimitReading? {
    CodexRateLimitParser.reading(fromLine: Data(line.dropLast().utf8))
}

private let now = Date(timeIntervalSince1970: base + 60)

// MARK: - Parsing

@Test func codexUsagePrimaryWeeklyOnly() throws {
    let r = try #require(parse(tokenLine(base, rateLimits: limits(primary: window(96, minutes: 10080, resets: base + 9000)))))
    #expect(r.session == nil)
    #expect(r.weekly == UsageWindow(percent: 96, resetsAt: Date(timeIntervalSince1970: base + 9000)))
    #expect(r.timestamp == Date(timeIntervalSince1970: base))
}

@Test func codexUsagePrimarySessionSecondaryWeekly() throws {
    let r = try #require(parse(tokenLine(base, rateLimits: limits(
        primary: window(12.5, minutes: 300, resets: base + 100),
        secondary: window(40, minutes: 10080, resets: base + 200)))))
    #expect(r.session == UsageWindow(percent: 12.5, resetsAt: Date(timeIntervalSince1970: base + 100)))
    #expect(r.weekly == UsageWindow(percent: 40, resetsAt: Date(timeIntervalSince1970: base + 200)))
}

@Test func codexUsageWindowClassification() throws {
    // By length, not position: a weekly primary and a session secondary.
    let swapped = try #require(parse(tokenLine(base, rateLimits: limits(
        primary: window(50, minutes: 10080), secondary: window(5, minutes: 300)))))
    #expect(swapped.session?.percent == 5)
    #expect(swapped.weekly?.percent == 50)
    // In between: under 3 days is the session window, from 3 days on the weekly one.
    #expect(CodexRateLimitParser.isSession(minutes: 1440, isPrimary: false))
    #expect(CodexRateLimitParser.isSession(minutes: 2 * 1440, isPrimary: false))
    #expect(!CodexRateLimitParser.isSession(minutes: 4 * 1440, isPrimary: true))
    #expect(!CodexRateLimitParser.isSession(minutes: 8640, isPrimary: true))
    // No length: Codex's original layout.
    let unlabeled = try #require(parse(tokenLine(base, rateLimits: limits(
        primary: window(1, minutes: nil), secondary: window(2, minutes: nil)))))
    #expect(unlabeled.session?.percent == 1)
    #expect(unlabeled.weekly?.percent == 2)
    // Two windows of one kind: the fuller one.
    let two = try #require(parse(tokenLine(base, rateLimits: limits(
        primary: window(30, minutes: 10080), secondary: window(70, minutes: 20160)))))
    #expect(two.session == nil)
    #expect(two.weekly?.percent == 70)
}

@Test func codexUsageUnusableLines() {
    #expect(parse(tokenLine(base, rateLimits: nil)) == nil)
    #expect(parse(tokenLine(base, rateLimits: "null")) == nil)
    #expect(parse(tokenLine(base, rateLimits: limits())) == nil)  // no windows
    #expect(parse(tokenLine(base, rateLimits: limits(id: "codex_other", primary: window(1, minutes: 300)))) == nil)
    #expect(parse(tokenLine(base, rateLimits: limits(id: nil, primary: window(1, minutes: 300))))?.session?.percent == 1)
    #expect(parse(otherLine(base)) == nil)
    #expect(parse("{\"timestamp\":\"x\"") == nil)
    // Older CLIs: `resets_in_seconds`, relative to the event.
    let relative = "{\"used_percent\":3,\"window_minutes\":300,\"resets_in_seconds\":120}"
    #expect(parse(tokenLine(base, rateLimits: limits(primary: relative)))?.session?.resetsAt
            == Date(timeIntervalSince1970: base + 120))
}

// MARK: - Source

@Test func codexUsageSkipsBackToUsableEvent() async throws {
    let home = try CodexHome()
    try home.write("a.jsonl",
        weekly(20, at: base)
        + tokenLine(base + 1, rateLimits: limits(id: "other_limit", primary: window(99, minutes: 10080)))
        + tokenLine(base + 2, rateLimits: "null")
        + tokenLine(base + 3, rateLimits: nil)
        + otherLine(base + 4))
    try home.database([("a.jsonl", base)])
    let result = await CodexUsageSource(codexHome: home.url).poll(now: now)
    #expect(result.usage.agent == .codex)
    #expect(result.usage.status == .ok)
    #expect(result.usage.snapshot?.weekly?.percent == 20)
    #expect(result.usage.snapshot?.asOf == Date(timeIntervalSince1970: base))
    #expect(result.nextPollIn == 30)
}

@Test func codexUsageNewestAcrossRollouts() async throws {
    let home = try CodexHome()
    // DB order (updated desc): a, b, c, d. b holds the newest event; d was last written before
    // it (its event, out of line with that, shows it's never read).
    try home.write("sessions/2026/11/01/a.jsonl", weekly(10, at: base + 10))
    try home.write("sessions/2026/10/01/b.jsonl", weekly(30, at: base + 30))
    try home.write("sessions/2026/11/02/c.jsonl", weekly(20, at: base + 20))
    try home.write("d.jsonl", weekly(99, at: base + 99))
    try home.database([
        ("sessions/2026/11/01/a.jsonl", base + 500), ("sessions/2026/10/01/b.jsonl", base + 400),
        ("sessions/2026/11/02/c.jsonl", base + 300), ("d.jsonl", base + 25),
    ])
    let source = CodexUsageSource(codexHome: home.url)
    let result = await source.poll(now: now)
    #expect(result.usage.snapshot?.weekly?.percent == 30)
    #expect(await source.fileReads == 3)
}

@Test func codexUsageLooksFurtherWhileNoReading() async throws {
    let home = try CodexHome()
    // The first four rollouts read have no reading; the 5th does. f was last written before it.
    try home.write("a.jsonl", otherLine(base))
    try home.write("b.jsonl", tokenLine(base, rateLimits: "null"))
    try home.write("c.jsonl", tokenLine(base, rateLimits: nil))
    try home.write("d.jsonl", otherLine(base) + tokenLine(base, rateLimits: limits()))
    try home.write("e.jsonl", weekly(42, at: base + 1))
    try home.write("f.jsonl", weekly(99, at: base + 99))
    try home.database([
        ("a.jsonl", base + 9), ("b.jsonl", base + 8), ("missing.jsonl", base + 7), ("c.jsonl", base + 6),
        ("d.jsonl", base + 5), ("e.jsonl", base + 4), ("f.jsonl", base),
    ])
    let source = CodexUsageSource(codexHome: home.url)
    let result = await source.poll(now: now)
    #expect(result.usage.status == .ok)
    #expect(result.usage.snapshot?.weekly?.percent == 42)
    #expect(await source.fileReads == 5)
}

@Test func codexUsageKeepsLookingWhileLastWriteIsNewer() async throws {
    let home = try CodexHome()
    // Ranked by last write, not by last reading: the newest reading is in the 4th thread, which
    // was written after the readings above it; e was last written before that reading.
    try home.write("a.jsonl", weekly(10, at: base + 10) + otherLine(base + 500))
    try home.write("b.jsonl", otherLine(base + 400))
    try home.write("c.jsonl", weekly(20, at: base + 20) + otherLine(base + 300))
    try home.write("d.jsonl", weekly(77, at: base + 100) + otherLine(base + 200))
    try home.write("e.jsonl", weekly(99, at: base + 999))  // out of line with its last write: never read
    try home.database([("a.jsonl", base + 500), ("b.jsonl", base + 400), ("c.jsonl", base + 300),
                       ("d.jsonl", base + 200), ("e.jsonl", base + 90)])
    let source = CodexUsageSource(codexHome: home.url)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 77)
    #expect(await source.fileReads == 4)
}

@Test func codexUsageLastWriteIncludesMtime() async throws {
    let home = try CodexHome()
    // Codex doesn't bump `updated_at` on every write: b's DB row is old, its file isn't.
    try home.write("a.jsonl", weekly(10, at: base + 10) + otherLine(base + 500))
    try home.write("b.jsonl", weekly(55, at: base + 550))
    try home.database([("a.jsonl", base + 500), ("b.jsonl", base + 100)])
    try home.touch("b.jsonl", at: base + 600)
    let source = CodexUsageSource(codexHome: home.url)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 55)
    #expect(await source.fileReads == 1)  // b first; a was last written before its reading
}

@Test func codexUsageLegacySchema() async throws {
    let home = try CodexHome()
    try home.write("a.jsonl", weekly(7, at: base))
    try home.database([("a.jsonl", base)], legacy: true)
    #expect(await CodexUsageSource(codexHome: home.url).poll(now: now).usage.snapshot?.weekly?.percent == 7)
}

@Test func codexUsageCachesUnchangedFiles() async throws {
    let home = try CodexHome()
    try home.write("a.jsonl", weekly(10, at: base) + otherLine(base + 1))
    try home.database([("a.jsonl", base)])
    let source = CodexUsageSource(codexHome: home.url)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 10)
    #expect(await source.fileReads == 1)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 10)
    #expect(await source.fileReads == 1)

    // Appended lines without a reading: the old one stays.
    try home.append("a.jsonl", otherLine(base + 2) + tokenLine(base + 3, rateLimits: "null"))
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 10)
    #expect(await source.fileReads == 2)
    // A partial line still being written is ignored until complete.
    let line = weekly(55, at: base + 4)
    try home.append("a.jsonl", String(line.prefix(80)))
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 10)
    try home.append("a.jsonl", String(line.dropFirst(80)))
    let result = await source.poll(now: now)
    #expect(result.usage.snapshot?.weekly?.percent == 55)
    #expect(result.usage.snapshot?.asOf == Date(timeIntervalSince1970: base + 4))
}

@Test func codexUsageUnavailable() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("cw-none-\(UUID().uuidString)")
    let none = await CodexUsageSource(codexHome: missing).poll(now: now)
    #expect(none.usage.status == .unavailable)
    #expect(none.usage.snapshot == nil)
    #expect(none.nextPollIn == 300)

    let home = try CodexHome()
    #expect(await CodexUsageSource(codexHome: home.url).poll(now: now).usage.status == .unavailable)  // no DB

    try home.write("a.jsonl", otherLine(base) + tokenLine(base, rateLimits: nil))
    try home.database([("a.jsonl", base)])
    let empty = await CodexUsageSource(codexHome: home.url).poll(now: now)
    #expect(empty.usage.status == .unavailable)
    #expect(empty.usage.snapshot == nil)
}

@Test func codexUsageStaleOnReadError() async throws {
    let home = try CodexHome()
    try home.write("a.jsonl", weekly(10, at: base))
    try home.database([("a.jsonl", base)])
    let source = CodexUsageSource(codexHome: home.url)
    #expect(await source.poll(now: now).usage.status == .ok)

    // The rollout grows but can't be opened.
    try home.append("a.jsonl", weekly(20, at: base + 1))
    #expect(chmod(home.path("a.jsonl"), 0) == 0)
    defer { chmod(home.path("a.jsonl"), 0o644) }
    let stale = await source.poll(now: now)
    guard case .stale(let message) = stale.usage.status else {
        Issue.record("expected stale, got \(stale.usage.status)")
        return
    }
    #expect(message.contains("a.jsonl"))
    #expect(stale.usage.snapshot?.weekly?.percent == 10)

    // The DB is unreadable.
    chmod(home.path("a.jsonl"), 0o644)
    try home.write("state_5.sqlite", "not a database, just some text that is long enough to not be empty")
    let dbStale = await source.poll(now: now)
    guard case .stale = dbStale.usage.status else {
        Issue.record("expected stale, got \(dbStale.usage.status)")
        return
    }
    #expect(dbStale.usage.snapshot?.weekly?.percent == 10)

    // Without an earlier reading, a DB error just hides the meter.
    let fresh = await CodexUsageSource(codexHome: home.url).poll(now: now)
    #expect(fresh.usage.status == .unavailable)
}

@Test func codexUsageStaleWhileNewerRolloutUnreadable() async throws {
    let home = try CodexHome()
    try home.write("a.jsonl", weekly(50, at: base + 100))
    try home.write("b.jsonl", weekly(10, at: base + 10))
    try home.database([("a.jsonl", base + 100), ("b.jsonl", base + 50)])
    let source = CodexUsageSource(codexHome: home.url)
    #expect(await source.poll(now: now).usage.status == .ok)

    // The active thread's rollout grows but can't be read; only an older reading is found.
    try home.append("a.jsonl", weekly(60, at: base + 200))
    #expect(chmod(home.path("a.jsonl"), 0) == 0)
    defer { chmod(home.path("a.jsonl"), 0o644) }
    try home.database([("a.jsonl", base + 200), ("b.jsonl", base + 50)])
    try home.touch("a.jsonl", at: base + 200)
    let frozen = await source.poll(now: now)
    guard case .stale(let message) = frozen.usage.status else {
        Issue.record("expected stale, got \(frozen.usage.status)")
        return
    }
    #expect(message.contains("a.jsonl"))
    #expect(frozen.usage.snapshot?.weekly?.percent == 50)

    // A newer reading elsewhere is shown, still stale while a may hold an even newer one.
    try home.append("b.jsonl", weekly(70, at: base + 150))
    try home.database([("a.jsonl", base + 200), ("b.jsonl", base + 150)])
    try home.touch("a.jsonl", at: base + 200)
    try home.touch("b.jsonl", at: base + 150)
    let advanced = await source.poll(now: now)
    guard case .stale = advanced.usage.status else {
        Issue.record("expected stale, got \(advanced.usage.status)")
        return
    }
    #expect(advanced.usage.snapshot?.weekly?.percent == 70)

    // Readable again: its reading wins, ok.
    chmod(home.path("a.jsonl"), 0o644)
    let ok = await source.poll(now: now)
    #expect(ok.usage.status == .ok)
    #expect(ok.usage.snapshot?.weekly?.percent == 60)
}

@Test func codexUsageNeverRollsBack() async throws {
    let home = try CodexHome()
    try home.write("new.jsonl", weekly(50, at: base + 100))
    try home.write("old.jsonl", weekly(5, at: base))
    try home.database([("new.jsonl", base + 100)])
    let source = CodexUsageSource(codexHome: home.url)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 50)
    // An old thread resumed: it tops the DB, but its last reading is older.
    try home.database([("old.jsonl", base + 300)])
    let result = await source.poll(now: now)
    #expect(result.usage.status == .ok)
    #expect(result.usage.snapshot?.weekly?.percent == 50)
}

// MARK: - Backward scan

@Test func codexUsageHugeLinesAcrossChunks() async throws {
    let home = try CodexHome()
    // The newest reading sits behind a line several chunks long, and is itself longer than a chunk.
    try home.write("a.jsonl",
        weekly(1, at: base)
        + tokenLine(base + 1, rateLimits: limits(primary: window(77, minutes: 10080)), padding: 3000)
        + otherLine(base + 2, size: 10_000)
        + tokenLine(base + 3, rateLimits: nil, padding: 2500))
    try home.database([("a.jsonl", base)])
    let source = CodexUsageSource(codexHome: home.url, chunkSize: 1024)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 77)

    // Bounded: a reading further back than `maxScan` isn't found.
    let far = try CodexHome()
    try far.write("a.jsonl", weekly(9, at: base) + otherLine(base + 1, size: 20_000))
    try far.database([("a.jsonl", base)])
    let bounded = CodexUsageSource(codexHome: far.url, chunkSize: 1024, maxScan: 8 * 1024)
    #expect(await bounded.poll(now: now).usage.status == .unavailable)
    #expect(await CodexUsageSource(codexHome: far.url, chunkSize: 1024).poll(now: now).usage.snapshot?.weekly?.percent == 9)
}

@Test func codexUsageIncrementalGrowthBeyondMaxScan() async throws {
    let home = try CodexHome()
    try home.write("a.jsonl", weekly(10, at: base))
    try home.database([("a.jsonl", base)])
    let source = CodexUsageSource(codexHome: home.url, chunkSize: 1024, maxScan: 8 * 1024)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 10)

    // Grown by more than `maxScan`, its reading further back than that: not found, the old
    // reading stays (bounded like a first scan).
    try home.append("a.jsonl", weekly(20, at: base + 1) + otherLine(base + 2, size: 10_000))
    let bounded = await source.poll(now: now)
    #expect(bounded.usage.status == .ok)
    #expect(bounded.usage.snapshot?.weekly?.percent == 10)
    // Grown by more than `maxScan` again, the reading within it (the line cut at the floor is dropped).
    try home.append("a.jsonl", otherLine(base + 3, size: 10_000) + weekly(40, at: base + 4))
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 40)
    // Later small growth: incremental from the new end.
    try home.append("a.jsonl", weekly(45, at: base + 5) + otherLine(base + 6))
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 45)
    #expect(await source.fileReads == 4)
}

@Test func codexUsageReplacedOrTruncatedRescans() async throws {
    let home = try CodexHome()
    try home.write("a.jsonl", weekly(50, at: base + 5) + otherLine(base + 6))
    try home.database([("a.jsonl", base + 6)])
    let source = CodexUsageSource(codexHome: home.url)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 50)

    // Replaced by a longer file (new inode): its bytes past the old end hold no reading, so
    // only a full rescan finds the one at its start.
    let before = home.inode("a.jsonl")
    try home.replace("a.jsonl", weekly(60, at: base + 7) + otherLine(base + 8, size: 400))
    #expect(home.inode("a.jsonl") != before)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 60)

    // Truncated in place (same inode, shorter): rescanned from the start.
    let inode = home.inode("a.jsonl")
    try home.rewriteInPlace("a.jsonl", weekly(70, at: base + 9))
    #expect(home.inode("a.jsonl") == inode)
    #expect(await source.poll(now: now).usage.snapshot?.weekly?.percent == 70)
    #expect(await source.fileReads == 3)
}

@Test func codexUsageScanBackwardFloorAndSpanningLines() throws {
    let home = try CodexHome()
    // Empty lines, a line many chunks long, a floor inside a line.
    let lines = ["first", "", "second", String(repeating: "L", count: 700), "", "", "third-" + String(repeating: "m", count: 90), "x"]
    let text = lines.joined(separator: "\n") + "\ntrailing-partial"
    let path = try home.write("lines.txt", text)
    let handle = try #require(FileHandle(forReadingAtPath: path))
    defer { try? handle.close() }
    let bytes = Array(text.utf8)
    let size = Int64(bytes.count)
    let completeEnd = size - Int64("trailing-partial".utf8.count)
    for floor in [0, 3, 6, 20, 500] {
        // Not a line start: everything up to the first newline at or after `floor` is dropped.
        let window = bytes[floor..<Int(completeEnd - 1)]
        let afterCut = window.firstIndex(of: 0x0A).map { Array(window[($0 + 1)...]) } ?? []
        let expected = afterCut.split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }.reversed() as [String]
        for chunk in [1, 2, 7, 64, 100_000] {
            var seen: [String] = []
            let result = try CodexUsageReader.scanBackward(
                handle: handle, end: size, floor: Int64(floor), floorIsLineStart: false, chunkSize: chunk
            ) { (line: Data) -> Int? in
                seen.append(String(decoding: line, as: UTF8.self))
                return nil
            }
            #expect(seen == expected, "floor \(floor) chunk \(chunk)")
            #expect(result.completeEnd == completeEnd)
        }
    }
}

@Test func codexUsageScanBackwardLines() throws {
    let home = try CodexHome()
    let lines = (0..<50).map { "line-\($0)-" + String(repeating: "z", count: $0 * 7) }
    let path = try home.write("lines.txt", lines.joined(separator: "\n") + "\npartial")
    let handle = try #require(FileHandle(forReadingAtPath: path))
    defer { try? handle.close() }
    let size = Int64((lines.joined(separator: "\n") + "\npartial").utf8.count)
    for chunk in [7, 64, 333, 100_000] {
        var seen: [String] = []
        let result = try CodexUsageReader.scanBackward(
            handle: handle, end: size, floor: 0, floorIsLineStart: true, chunkSize: chunk
        ) { (line: Data) -> Int? in
            seen.append(String(decoding: line, as: UTF8.self))
            return nil
        }
        #expect(seen == lines.reversed(), "chunk \(chunk)")
        #expect(result.completeEnd == size - Int64("partial".utf8.count))
    }
}

// MARK: - Live

/// `CW_LIVE=1 swift test --filter liveCodexUsage`: one real poll (read-only).
@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE"] == "1"))
func liveCodexUsage() async throws {
    let source = CodexUsageSource()
    let start = Date()
    let result = await source.poll(now: Date())
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    func describe(_ w: UsageWindow?) -> String {
        guard let w else { return "none" }
        return "\(w.percent)% resets \(w.resetsAt.map { "\($0)" } ?? "?") (now \(w.displayPercent(at: Date()))%)"
    }
    let s = result.usage.snapshot
    print("LIVE codex usage: status=\(result.usage.status) asOf=\(s.map { "\($0.asOf)" } ?? "-") "
          + "session=\(describe(s?.session)) weekly=\(describe(s?.weekly)) next=\(Int(result.nextPollIn))s in \(ms) ms")
    let again = Date()
    _ = await source.poll(now: Date())
    print("LIVE codex usage: second poll \(Int(Date().timeIntervalSince(again) * 1000)) ms, files read \(await source.fileReads)")
}
