import Foundation
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures

private let sampleRecordJSON = """
{"pid":5004,"sessionId":"7b25c51d-d0b9-4471-81ec-ae45057b535d","cwd":"/Users/me/projects/claude-watcher",\
"startedAt":1792681139260,"procStart":"Thu Oct 22 14:58:56 2026","version":"2.1.306","peerProtocol":1,\
"peerFeatures":["notify_idle"],"kind":"interactive","entrypoint":"cli","pidDomain":"darwin",\
"messagingSocketPath":"/tmp/cc-socks/5004.sock","name":"claude-watcher-6d","nameSource":"derived",\
"nameSince":1792681139260,"status":"waiting","waitingFor":"input needed","updatedAt":1792681935295,\
"statusUpdatedAt":1792681935295}
"""

private func recordJSON(
    pid: Int32, sessionId: String, cwd: String, kind: String = "interactive",
    startedAt: Double, procStart: String, name: String = "derived-name",
    nameSource: String = "derived", status: String = "idle"
) -> String {
    """
    {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"\(cwd)","startedAt":\(Int64(startedAt)),\
    "procStart":"\(procStart)","version":"2.1.306","kind":"\(kind)","entrypoint":"cli",\
    "name":"\(name)","nameSource":"\(nameSource)","status":"\(status)","updatedAt":\(Int64(startedAt) + 500)}
    """
}

/// procStart string for a UTC date, matching the CLI's format.
private func procStartString(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return f.string(from: date)
}

/// Fake process table.
private struct FakeInspector: ProcessInspecting {
    var table: [Int32: ProcessSnapshot]
    func snapshot(pid: Int32) -> ProcessSnapshot? { table[pid] }
}

private final class TempHome {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relative: String, _ text: String) throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func append(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

private let claudeBinary = "/Users/me/.local/share/claude/versions/2.1.306"
private let ghosttyBinary = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
private let terminalBinary = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"

// MARK: - Registry records

@Test func parsesSessionRecordSample() throws {
    let record = try #require(SessionRecord.parse(Data(sampleRecordJSON.utf8)))
    #expect(record.pid == 5004)
    #expect(record.sessionId == "7b25c51d-d0b9-4471-81ec-ae45057b535d")
    #expect(record.cwd == "/Users/me/projects/claude-watcher")
    #expect(record.kind == "interactive")
    #expect(record.isInteractive)
    #expect(record.name == "claude-watcher-6d")
    #expect(record.nameSource == "derived")
    #expect(record.sessionStatus == .waiting)
    #expect(record.waitingFor == "input needed")
    #expect(record.startedAtDate == Date(timeIntervalSince1970: 1792681139.260))
    #expect(record.updatedAtDate == Date(timeIntervalSince1970: 1792681935.295))
    // procStart is UTC.
    #expect(record.procStartDate == Date(timeIntervalSince1970: 1792681136))
}

@Test func rejectsMalformedOrPartialRecords() {
    #expect(SessionRecord.parse(Data()) == nil)
    #expect(SessionRecord.parse(Data(sampleRecordJSON.prefix(80).utf8)) == nil)
    #expect(SessionRecord.parse(Data("{\"pid\":1}".utf8)) == nil)
    #expect(SessionRecord.parse(Data("[]".utf8)) == nil)
}

@Test func mapsStatuses() {
    func status(_ s: String?) -> SessionStatus {
        SessionRecord(pid: 1, sessionId: "x", cwd: "/", status: s).sessionStatus
    }
    #expect(status("busy") == .busy)
    #expect(status("idle") == .idle)
    #expect(status("waiting") == .waiting)
    #expect(status("weird") == .unknown)
    #expect(status(nil) == .unknown)
}

@Test func parsesProcStartWithPaddedDay() {
    let a = SessionRecord.parseProcStart("Fri Oct  2 09:05:01 2026")
    let b = SessionRecord.parseProcStart("Fri Oct 2 09:05:01 2026")
    #expect(a != nil)
    #expect(a == b)
    #expect(SessionRecord.parseProcStart("garbage") == nil)
}

@Test func filtersNonInteractiveKinds() {
    for kind in ["background", "sdk", "worker"] {
        #expect(!SessionRecord(pid: 1, sessionId: "x", cwd: "/", kind: kind).isInteractive)
    }
    #expect(SessionRecord(pid: 1, sessionId: "x", cwd: "/", kind: "interactive").isInteractive)
    #expect(SessionRecord(pid: 1, sessionId: "x", cwd: "/", kind: nil).isInteractive)
}

@Test func onlyReadsRegistryJSONNeverKeyFiles() {
    #expect(SessionDiscovery.isRegistryFileName("5004.json"))
    #expect(!SessionDiscovery.isRegistryFileName("5004.abcdef.key"))
    #expect(!SessionDiscovery.isRegistryFileName("5004.abcdef.json"))
    #expect(!SessionDiscovery.isRegistryFileName(".json"))
    #expect(!SessionDiscovery.isRegistryFileName("tmp.json"))
}

@Test func projectSlugReplacesNonAlphanumerics() {
    #expect(SessionDiscovery.projectSlug(for: "/Users/me/projects/claude-watcher")
            == "-Users-me-projects-claude-watcher")
    #expect(SessionDiscovery.projectSlug(for: "/a/b.c_d e") == "-a-b-c-d-e")
}

// MARK: - Title precedence

@Test func titlePrecedence() {
    let cwd = "/Users/me/proj"
    // User-set name wins over everything.
    #expect(SessionTitle.resolve(name: "mine", nameSource: "user", customTitle: "custom",
                                 aiTitle: "ai", cwd: cwd) == "mine")
    // Custom title beats AI title and a derived name.
    #expect(SessionTitle.resolve(name: "proj-6d", nameSource: "derived", customTitle: "custom",
                                 aiTitle: "ai", cwd: cwd) == "custom")
    // AI title beats a derived/auto/collision name.
    for source in ["derived", "auto", "collision"] {
        #expect(SessionTitle.resolve(name: "proj-6d", nameSource: source, customTitle: nil,
                                     aiTitle: "ai", cwd: cwd) == "ai")
    }
    // Falls back to name, then cwd basename.
    #expect(SessionTitle.resolve(name: "proj-6d", nameSource: "derived", customTitle: nil,
                                 aiTitle: nil, cwd: cwd) == "proj-6d")
    #expect(SessionTitle.resolve(name: nil, nameSource: nil, customTitle: nil,
                                 aiTitle: "  ", cwd: cwd) == "proj")
    // An empty user name doesn't win.
    #expect(SessionTitle.resolve(name: "", nameSource: "user", customTitle: nil,
                                 aiTitle: "ai", cwd: cwd) == "ai")
}

// MARK: - Transcript parsing

private let transcriptSample = """
{"type":"user","cwd":"/Users/me/proj","gitBranch":"main","timestamp":"2026-10-22T14:00:00.000Z","message":{}}
{"type":"last-prompt","lastPrompt":"first prompt","sessionId":"s1"}
{"type":"ai-title","aiTitle":"Early title","sessionId":"s1"}
{"type":"pr-link","sessionId":"s1","prNumber":4,"prUrl":"https://github.com/o/r/pull/4"}
{"type":"assistant","cwd":"/Users/me/proj","gitBranch":"feature/x","timestamp":"2026-10-22T14:01:00.000Z"}
{"type":"mode","mode":"normal","sessionId":"s1"}
{not json at all
{"type":"ai-title","aiTitle":"Later title","sessionId":"s1"}
{"type":"last-prompt","lastPrompt":"second prompt","sessionId":"s1"}
{"type":"system","cwd":"/Users/me/proj","gitBranch":"","timestamp":"2026-10-22T14:02:00.000Z"}
{"type":"agent-name","agentName":"Later title","sessionId":"s1"}

"""

@Test func transcriptLastWins() {
    let info = TranscriptParser.parse(transcriptSample)
    #expect(info.aiTitle == "Later title")
    #expect(info.lastPrompt == "second prompt")
    #expect(info.gitBranch == "feature/x")  // empty gitBranch doesn't clobber
    #expect(info.cwd == "/Users/me/proj")
    #expect(info.prURL == "https://github.com/o/r/pull/4")
    #expect(info.prNumber == 4)
    #expect(info.agentName == "Later title")
    #expect(info.customTitle == nil)
}

@Test func transcriptCustomTitle() {
    let info = TranscriptParser.parse("""
    {"type":"ai-title","aiTitle":"ai"}
    {"type":"custom-title","customTitle":"Renamed","sessionId":"s1"}
    """)
    #expect(info.customTitle == "Renamed")
    #expect(info.aiTitle == "ai")
}

@Test func transcriptReaderTailsIncrementallyAndScansBackForTitle() throws {
    let home = try TempHome()
    let rel = "projects/p/s1.jsonl"
    // Title far from the end, then lots of filler lines.
    var text = "{\"type\":\"ai-title\",\"aiTitle\":\"Old title\"}\n"
    let filler = "{\"type\":\"assistant\",\"gitBranch\":\"main\",\"pad\":\"\(String(repeating: "x", count: 200))\"}\n"
    for _ in 0..<100 { text += filler }
    text += "{\"type\":\"last-prompt\",\"lastPrompt\":\"hi\"}\n"
    text += "{\"type\":\"assistant\",\"gitBranch\":\"ma"  // partial trailing line (mid-write)
    try home.write(rel, text)

    let reader = TranscriptReader(tailBytes: 1024)
    let url = home.url.appendingPathComponent(rel)
    let first = try #require(reader.info(at: url))
    #expect(first.aiTitle == "Old title")  // found by backward scan
    #expect(first.lastPrompt == "hi")
    #expect(first.gitBranch == "main")

    // Finish the partial line and append new metadata; only the delta is parsed.
    try home.append(rel, "in-2\"}\n{\"type\":\"ai-title\",\"aiTitle\":\"New title\"}\n")
    let second = try #require(reader.info(at: url))
    #expect(second.aiTitle == "New title")
    #expect(second.gitBranch == "main-2")
    #expect(second.lastPrompt == "hi")
}

@Test func historyIndexSkipsSlashCommands() {
    let data = Data("""
    {"display":"fix the bug","project":"/p","sessionId":"a","timestamp":1}
    {"display":"/clear","project":"/p","sessionId":"a","timestamp":2}
    {"display":"other","project":"/p","sessionId":"b","timestamp":3}
    garbage
    """.utf8)
    let map = HistoryIndex.parse(data)
    #expect(map["a"] == "fix the bug")
    #expect(map["b"] == "other")
}

@Test func parsesGitHead() {
    #expect(SessionDiscovery.parseGitHead("ref: refs/heads/main\n") == "main")
    #expect(SessionDiscovery.parseGitHead("ref: refs/heads/feature/x") == "feature/x")
    #expect(SessionDiscovery.parseGitHead("3f2a9c0d1e\n") == nil)
}

// MARK: - Process rules

@Test func livenessChecks() {
    let start = Date(timeIntervalSince1970: 1792681136)
    let record = SessionRecord(pid: 42, sessionId: "s", cwd: "/", startedAt: 1792681139260,
                               procStart: procStartString(start))
    let good = ProcessSnapshot(pid: 42, ppid: 1, startTime: start.addingTimeInterval(0.4),
                               executablePath: claudeBinary)
    #expect(ProcessRules.isLive(record, process: good))
    #expect(!ProcessRules.isLive(record, process: nil))
    // pid reused by a later process
    var reused = good
    reused.startTime = start.addingTimeInterval(3600)
    #expect(!ProcessRules.isLive(record, process: reused))
    // pid reused by a non-claude binary
    var other = good
    other.executablePath = "/bin/sleep"
    #expect(!ProcessRules.isLive(record, process: other))
}

@Test func classifiesTerminals() {
    #expect(ProcessRules.terminalKind(ancestorPaths: ["/bin/zsh", "/usr/bin/login", ghosttyBinary]) == .ghostty)
    #expect(ProcessRules.terminalKind(ancestorPaths: ["/bin/zsh", "/usr/bin/login", terminalBinary]) == .appleTerminal)
    #expect(ProcessRules.terminalKind(ancestorPaths: ["/bin/zsh", "/Applications/iTerm.app/Contents/MacOS/iTerm2"])
            == .other("iTerm"))
    #expect(ProcessRules.terminalKind(ancestorPaths: ["/bin/zsh", "/opt/homebrew/bin/tmux"]) == .other("tmux"))
    #expect(ProcessRules.terminalKind(ancestorPaths: []) == .other("unknown"))
}

// MARK: - End-to-end discovery against a fake claudeHome

@Test func discoversLiveInteractiveSessions() async throws {
    let home = try TempHome()
    let t0 = Date(timeIntervalSince1970: 1792681136)
    let t1 = t0.addingTimeInterval(600)
    let cwd = "/Users/me/projects/claude-watcher"
    let slug = SessionDiscovery.projectSlug(for: cwd)

    // 100: live, Ghostty, with transcript under the slug dir.
    try home.write("sessions/100.json", recordJSON(
        pid: 100, sessionId: "s-100", cwd: cwd, startedAt: t1.timeIntervalSince1970 * 1000 + 2000,
        procStart: procStartString(t1), status: "busy"))
    try home.write("projects/\(slug)/s-100.jsonl", transcriptSample)
    // 200: live, Terminal.app, started earlier, transcript in another project dir (cwd changed).
    try home.write("sessions/200.json", recordJSON(
        pid: 200, sessionId: "s-200", cwd: "/somewhere/else", startedAt: t0.timeIntervalSince1970 * 1000 + 2000,
        procStart: procStartString(t0), name: "my name", nameSource: "user"))
    try home.write("projects/-old-cwd/s-200.jsonl", "{\"type\":\"ai-title\",\"aiTitle\":\"ignored\"}\n")
    // 300: background kind -> filtered.
    try home.write("sessions/300.json", recordJSON(
        pid: 300, sessionId: "s-300", cwd: cwd, kind: "background",
        startedAt: t0.timeIntervalSince1970 * 1000, procStart: procStartString(t0)))
    // 400: stale (no such process).
    try home.write("sessions/400.json", recordJSON(
        pid: 400, sessionId: "s-400", cwd: cwd, startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0)))
    // 500: pid reused by another process.
    try home.write("sessions/500.json", recordJSON(
        pid: 500, sessionId: "s-500", cwd: cwd, startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0)))
    // Garbage files that must be ignored.
    try home.write("sessions/600.json", "{\"pid\":600,\"sessionId\":")
    try home.write("sessions/100.deadbeef.key", "SECRET")

    let inspector = FakeInspector(table: [
        100: ProcessSnapshot(pid: 100, ppid: 101, startTime: t1, tty: "/dev/ttys001", executablePath: claudeBinary),
        101: ProcessSnapshot(pid: 101, ppid: 102, startTime: t1, executablePath: "/bin/zsh"),
        102: ProcessSnapshot(pid: 102, ppid: 103, startTime: t1, executablePath: "/usr/bin/login"),
        103: ProcessSnapshot(pid: 103, ppid: 1, startTime: t0, executablePath: ghosttyBinary),
        200: ProcessSnapshot(pid: 200, ppid: 201, startTime: t0, tty: "/dev/ttys004", executablePath: claudeBinary),
        201: ProcessSnapshot(pid: 201, ppid: 202, startTime: t0, executablePath: "/bin/zsh"),
        202: ProcessSnapshot(pid: 202, ppid: 1, startTime: t0, executablePath: terminalBinary),
        300: ProcessSnapshot(pid: 300, ppid: 1, startTime: t0, executablePath: claudeBinary),
        500: ProcessSnapshot(pid: 500, ppid: 1, startTime: t1, executablePath: "/usr/bin/vim"),
    ])

    let discovery = SessionDiscovery(claudeHome: home.url, inspector: inspector)
    let sessions = await discovery.scan()

    #expect(sessions.map(\.id) == ["s-200", "s-100"])  // sorted by startedAt
    let a = try #require(sessions.first { $0.id == "s-100" })
    #expect(a.pid == 100)
    #expect(a.title == "Later title")
    #expect(a.branch == "feature/x")
    #expect(a.lastPrompt == "second prompt")
    #expect(a.status == .busy)
    #expect(a.tty == "/dev/ttys001")
    #expect(a.terminal == .ghostty)
    #expect(a.ghosttyTerminalID == nil)
    #expect(a.startedAt == Date(timeIntervalSince1970: t1.timeIntervalSince1970 + 2))

    let b = try #require(sessions.first { $0.id == "s-200" })
    #expect(b.title == "my name")  // user-set name wins over ai-title
    #expect(b.terminal == .appleTerminal)
    #expect(b.tty == "/dev/ttys004")
    #expect(b.branch == nil)

    // A registry file mid-rewrite keeps the last good copy.
    try home.write("sessions/100.json", "{\"pid\":100,")
    let again = await discovery.scan()
    #expect(again.map(\.id) == ["s-200", "s-100"])

    // Process exit removes the session.
    var gone = inspector
    gone.table[100] = nil
    let discovery2 = SessionDiscovery(claudeHome: home.url, inspector: gone)
    #expect(await discovery2.scan().map(\.id) == ["s-200"])
}

@Test func missingClaudeHomeYieldsNoSessions() async {
    let discovery = SessionDiscovery(
        claudeHome: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
        inspector: FakeInspector(table: [:]))
    #expect(await discovery.scan().isEmpty)
}

@Test func finalizeDedupesAndSortsStably() {
    let t = Date(timeIntervalSince1970: 1000)
    func s(_ id: String, _ pid: Int32, _ start: Double, _ upd: Double) -> ClaudeSession {
        ClaudeSession(id: id, pid: pid, cwd: "/", title: id,
                      startedAt: t.addingTimeInterval(start), updatedAt: t.addingTimeInterval(upd))
    }
    let out = SessionDiscovery.finalize([s("b", 2, 5, 5), s("a", 1, 5, 5), s("c", 3, 0, 0), s("a", 9, 7, 9)])
    #expect(out.map(\.id) == ["c", "b", "a"])
    #expect(out.last?.pid == 9)
}

@MainActor
@Test func storePublishesOnReload() async throws {
    let home = try TempHome()
    let t0 = Date(timeIntervalSince1970: 1792681136)
    try home.write("sessions/100.json", recordJSON(
        pid: 100, sessionId: "s-100", cwd: "/x", startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0)))
    let inspector = FakeInspector(table: [
        100: ProcessSnapshot(pid: 100, ppid: 1, startTime: t0, executablePath: claudeBinary),
    ])
    let store = SessionStore(claudeHome: home.url, inspector: inspector)
    #expect(store.sessions.isEmpty)
    await store.reload()
    #expect(store.sessions.map(\.id) == ["s-100"])
    #expect(store.sessions.first?.title == "derived-name")
}

// MARK: - Live check (CW_LIVE=1 swift test --filter liveDiscovery)

@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE"] == "1"))
func liveDiscovery() async {
    let discovery = SessionDiscovery(claudeHome: SessionDiscovery.defaultClaudeHome)
    let start = Date()
    let sessions = await discovery.scan()
    let firstMs = Date().timeIntervalSince(start) * 1000
    let start2 = Date()
    _ = await discovery.scan()
    let secondMs = Date().timeIntervalSince(start2) * 1000
    print("LIVE: \(sessions.count) session(s); first scan \(Int(firstMs)) ms, cached rescan \(Int(secondMs)) ms")
    for s in sessions {
        print("""
        LIVE: pid=\(s.pid) id=\(s.id)
              title=\(s.title.debugDescription) branch=\(s.branch ?? "nil") status=\(s.status) \
        waitingFor=\(s.waitingFor ?? "nil")
              tty=\(s.tty ?? "nil") terminal=\(s.terminal) cwd=\(s.cwd)
              startedAt=\(s.startedAt) updatedAt=\(s.updatedAt)
              lastPrompt=\((s.lastPrompt ?? "nil").prefix(80).debugDescription)
        """)
    }
    #expect(!sessions.isEmpty)
}
