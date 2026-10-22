import Foundation
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures

private let sampleRecordJSON = """
{"pid":5004,"sessionId":"00000000-0000-4000-8000-000000000001","cwd":"/Users/me/projects/claude-watcher",\
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
    var argv: [Int32: [String]] = [:]
    func snapshot(pid: Int32) -> ProcessSnapshot? { table[pid] }
    func arguments(pid: Int32) -> [String]? { argv[pid] }
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
    #expect(record.sessionId == "00000000-0000-4000-8000-000000000001")
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

@Test func livenessAcceptsClaudeInstallKinds() {
    let start = Date(timeIntervalSince1970: 1792681136)
    let record = SessionRecord(pid: 42, sessionId: "s", cwd: "/", startedAt: 1792681139260,
                               procStart: procStartString(start))
    func live(_ path: String, argv: [String]? = nil) -> Bool {
        let snap = ProcessSnapshot(pid: 42, ppid: 1, startTime: start, executablePath: path)
        return ProcessRules.isLive(record, process: snap, arguments: { argv })
    }
    // What the kernel really reports for a global npm install: the `bin/claude` symlink.
    let npmArgv = ["node", "/opt/homebrew/bin/claude", "--resume"]

    // Native installer.
    #expect(live(claudeBinary))
    // Homebrew cask.
    #expect(live("/opt/homebrew/Caskroom/claude-code/2.1.306/claude"))
    // Any binary named claude (e.g. a symlinked or self-built install).
    #expect(live("/usr/local/bin/claude"))
    // npm, newer versions: a native binary inside the package (`bin/claude` -> `bin/claude.exe`).
    #expect(live("/Users/me/.nvm/versions/node/v24.13.0/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"))
    #expect(live("/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code-darwin-arm64/claude"))
    #expect(!live("/opt/homebrew/lib/node_modules/@anthropic-ai/sdk/bin/tool"))
    // npm: node running the claude-code package.
    #expect(live("/opt/homebrew/Cellar/node/24.1.0/bin/node", argv: npmArgv))
    #expect(live("/Users/me/.nvm/versions/node/v22.0.0/bin/node",
                 argv: ["node", "/Users/me/.nvm/versions/node/v22.0.0/bin/claude"]))
    // After `process.title = "claude"`, libuv rewrites argv.
    #expect(live("/opt/homebrew/bin/node", argv: ["claude", "--resume"]))
    // Explicit `node …/cli.js` still matches by package path.
    #expect(live("/opt/homebrew/bin/node",
                 argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
    // node's own options before the script are skipped; `--` ends them.
    #expect(live("/opt/homebrew/bin/node", argv: ["node", "--no-warnings", "/opt/homebrew/bin/claude"]))
    #expect(live("/opt/homebrew/bin/node",
                 argv: ["node", "--max-old-space-size=4096", "--enable-source-maps", "/usr/local/bin/claude", "-c"]))
    #expect(live("/opt/homebrew/bin/node", argv: ["node", "--", "/opt/homebrew/bin/claude"]))
    #expect(!live("/opt/homebrew/bin/node", argv: ["node", "--no-warnings", "server.js", "claude"]))
    #expect(!live("/opt/homebrew/bin/node", argv: ["node", "--", "--x", "/opt/homebrew/bin/claude"]))
    #expect(!live("/opt/homebrew/bin/node", argv: ["node", "--no-warnings"]))
    // Plain node, or node whose argv is unreadable: rejected.
    #expect(!live("/opt/homebrew/bin/node", argv: ["node", "server.js"]))
    #expect(!live("/opt/homebrew/bin/node", argv: nil))
    #expect(!live("/opt/homebrew/bin/node", argv: ["node"]))
    #expect(!live("/opt/homebrew/bin/node", argv: ["node", "/srv/app/server.js", "claude"]))
    // Unrelated binaries: rejected, and argv is never read for them.
    var argvRead = false
    let vim = ProcessSnapshot(pid: 42, ppid: 1, startTime: start, executablePath: "/usr/bin/vim")
    #expect(!ProcessRules.isLive(record, process: vim, arguments: { argvRead = true; return npmArgv }))
    #expect(!argvRead)
    #expect(!live("/Users/me/bin/claude-wrapper"))
    // Start-time guard still applies to non-native installs.
    let reused = ProcessSnapshot(pid: 42, ppid: 1, startTime: start.addingTimeInterval(3600),
                                 executablePath: "/opt/homebrew/bin/node")
    #expect(!ProcessRules.isLive(record, process: reused, arguments: { npmArgv }))
}

@Test func npmArgvResolvesRenamedSymlinkToPackage() throws {
    // bin/<anything> -> …/@anthropic-ai/claude-code/cli.js is accepted via realpath(3).
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cw-npm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pkg = root.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code")
    let other = root.appendingPathComponent("lib/node_modules/other")
    try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try Data("#!/usr/bin/env node\n".utf8).write(to: pkg.appendingPathComponent("cli.js"))
    try Data("#!/usr/bin/env node\n".utf8).write(to: other.appendingPathComponent("cli.js"))
    let cc = root.appendingPathComponent("bin/cc").path
    let tool = root.appendingPathComponent("bin/tool").path
    try FileManager.default.createSymbolicLink(atPath: cc, withDestinationPath: pkg.appendingPathComponent("cli.js").path)
    try FileManager.default.createSymbolicLink(atPath: tool, withDestinationPath: other.appendingPathComponent("cli.js").path)

    let node = "/opt/homebrew/bin/node"
    #expect(ProcessRules.isClaudeExecutable(node, arguments: { ["node", cc] }))
    #expect(!ProcessRules.isClaudeExecutable(node, arguments: { ["node", tool] }))
    #expect(!ProcessRules.isClaudeExecutable(node, arguments: { ["node", root.appendingPathComponent("bin/missing").path] }))
    // The script after node's options is resolved too.
    #expect(ProcessRules.isClaudeExecutable(node, arguments: { ["node", "--no-warnings", cc, "--resume"] }))
    #expect(!ProcessRules.isClaudeExecutable(node, arguments: { ["node", "--no-warnings", tool] }))
    // Relative script paths aren't resolved (they're relative to the target's cwd).
    var resolved = false
    #expect(!ProcessRules.isClaudeExecutable(
        node, arguments: { ["node", "bin/cc"] }, resolvePath: { resolved = true; return $0 }))
    #expect(!resolved)
}

@Test func parsesProcArgs2() {
    var bytes: [UInt8] = []
    withUnsafeBytes(of: Int32(3)) { bytes.append(contentsOf: $0) }
    bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0]
    for arg in ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js", "-c"] {
        bytes += Array(arg.utf8) + [0]
    }
    bytes += Array("HOME=/Users/me".utf8) + [0]
    #expect(SystemProcessInspector.parseProcArgs2(bytes[...])
            == ["node", "/x/node_modules/@anthropic-ai/claude-code/cli.js", "-c"])
    #expect(SystemProcessInspector.parseProcArgs2([1, 0][...]) == nil)
}

@Test func readsOwnArguments() {
    let args = SystemProcessInspector().arguments(pid: getpid())
    #expect(args?.isEmpty == false)
    #expect(SystemProcessInspector().arguments(pid: -1) == nil)
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

@Test func discoversCaskAndNpmInstalls() async throws {
    let home = try TempHome()
    let t0 = Date(timeIntervalSince1970: 1792681136)
    for pid: Int32 in [700, 800, 900, 1000] {
        try home.write("sessions/\(pid).json", recordJSON(
            pid: pid, sessionId: "s-\(pid)", cwd: "/p\(pid)",
            startedAt: t0.timeIntervalSince1970 * 1000 + Double(pid), procStart: procStartString(t0)))
    }
    let node = "/opt/homebrew/Cellar/node/24.1.0/bin/node"
    let inspector = FakeInspector(
        table: [
            700: ProcessSnapshot(pid: 700, ppid: 1, startTime: t0,
                                 executablePath: "/opt/homebrew/Caskroom/claude-code/2.1.306/claude"),
            800: ProcessSnapshot(pid: 800, ppid: 1, startTime: t0, executablePath: node),
            900: ProcessSnapshot(pid: 900, ppid: 1, startTime: t0, executablePath: node),
            1000: ProcessSnapshot(pid: 1000, ppid: 1, startTime: t0, executablePath: node),
        ],
        argv: [
            800: ["node", "/opt/homebrew/bin/claude"],
            900: ["node", "/srv/app/server.js"],
            1000: ["claude"],
        ])
    let sessions = await SessionDiscovery(claudeHome: home.url, inspector: inspector).scan()
    #expect(sessions.map(\.id) == ["s-700", "s-800", "s-1000"])
}

// MARK: - Claude home resolution

@Test func resolvesClaudeHome() {
    let home = "/Users/me"
    func resolve(env: [String: String] = [:], launchctl: String? = nil, shell: String? = nil) -> String {
        SessionDiscovery.resolveClaudeHome(
            env: env, launchctlValue: launchctl, shellValue: shell, home: home).path
    }
    // Nothing set: ~/.claude.
    #expect(resolve() == "/Users/me/.claude")
    #expect(resolve(env: ["CLAUDE_CONFIG_DIR": ""], launchctl: "", shell: " \n") == "/Users/me/.claude")
    // Precedence: process env, then launchctl, then the login shell.
    #expect(resolve(env: ["CLAUDE_CONFIG_DIR": "/opt/claude"], launchctl: "/Users/me/cfg", shell: "/x")
            == "/opt/claude")
    #expect(resolve(launchctl: "/opt/claude", shell: "/Users/me/cfg") == "/opt/claude")
    #expect(resolve(shell: "/Users/me/cfg") == "/Users/me/cfg")
    // Tilde expansion.
    #expect(resolve(shell: "~/cfg") == "/Users/me/cfg")
    #expect(resolve(launchctl: "~") == "/Users/me")
    #expect(resolve(env: ["CLAUDE_CONFIG_DIR": "~/cfg/"]) == "/Users/me/cfg")
    // A configured directory that doesn't exist yet is still honoured (watchers cope).
    #expect(resolve(env: ["CLAUDE_CONFIG_DIR": "/gone"], shell: "/Users/me/cfg") == "/gone")
    #expect(resolve(shell: "~/nope") == "/Users/me/nope")
    // Relative values can't be resolved: ~/.claude.
    #expect(resolve(shell: "cfg") == "/Users/me/.claude")
    #expect(resolve(env: ["CLAUDE_CONFIG_DIR": "cfg"], shell: "/Users/me/cfg") == "/Users/me/.claude")
}

@Test func claudeHomeProbesAreLazy() {
    var launchctlCalls = 0, shellCalls = 0
    func launchctl() -> String? { launchctlCalls += 1; return "/opt/claude" }
    func shell() -> String? { shellCalls += 1; return nil }
    _ = SessionDiscovery.resolveClaudeHome(
        env: ["CLAUDE_CONFIG_DIR": "/opt/claude"], launchctlValue: launchctl(), shellValue: shell(),
        home: "/Users/me")
    #expect(launchctlCalls == 0 && shellCalls == 0)
    _ = SessionDiscovery.resolveClaudeHome(
        env: [:], launchctlValue: launchctl(), shellValue: shell(),
        home: "/Users/me")
    #expect(launchctlCalls == 1 && shellCalls == 0)
}

@Test func claudeHomeShellOutputParsing() {
    let m = ClaudeHome.marker
    #expect(ClaudeHome.markedValue("motd junk\nmore\n\(m)/Users/me/cfg\nbye from zlogout\n") == "/Users/me/cfg")
    #expect(ClaudeHome.markedValue("junk without newline\(m)/a\n") == "/a")
    #expect(ClaudeHome.markedValue("\n\(m)\n") == "")
    #expect(ClaudeHome.markedValue("no marker at all\n") == nil)
    #expect(ClaudeHome.hasMarkedLine("junk\n\(m)/a\nbye"))
    #expect(ClaudeHome.hasMarkedLine("\(m)\n"))
    #expect(!ClaudeHome.hasMarkedLine("junk\n\(m)/a"))
    #expect(!ClaudeHome.hasMarkedLine("no marker\n"))
}

@Test func claudeHomeProbeRunnerIsBounded() async throws {
    // The probes block (~1 s in all), so they run on a dedicated thread, not the cooperative pool.
    struct Results: Sendable {
        var plain, stdin, timedOut, bgPlain, bgMarked, acceptedAtTimeout, partialAtTimeout, missing: String?
        var bgElapsed, totalElapsed: TimeInterval
    }
    let m = ClaudeHome.marker
    let r = try await onDedicatedThread { () -> Results in
        let plain = ClaudeHome.run("/bin/sh", ["-c", "echo junk >&2; printf 'a\\nb'"])
        // stdin is /dev/null, not our stdin.
        let stdin = ClaudeHome.run("/bin/sh", ["-c", "cat"])
        let start = Date()
        let timedOut = ClaudeHome.run("/bin/sh", ["-c", "printf x; sleep 30"], timeout: 0.3)
        // A backgrounded job inheriting stdout doesn't hold the probe until the timeout: once the
        // shell exits, what it printed is used (and the job is killed with the process group).
        // (A long timeout, so falling back to it would fail the elapsed-time check.)
        let bgStart = Date()
        let bgPlain = ClaudeHome.run("/bin/sh", ["-c", "sleep 10 & printf y"], timeout: 8)
        let bgMarked = ClaudeHome.run(
            "/bin/sh", ["-c", "echo motd; sleep 10 & printf '\\n%s%s\\n' '\(m)' /cfg"], timeout: 8)
        let bgElapsed = Date().timeIntervalSince(bgStart)
        // At the timeout, output already holding a complete marker line is accepted; else nil.
        let accepted = ClaudeHome.run("/bin/sh", ["-c", "printf '%s/cfg\\n' '\(m)'; sleep 30"], timeout: 0.3,
                                      acceptOnTimeout: ClaudeHome.hasMarkedLine)
        let partial = ClaudeHome.run("/bin/sh", ["-c", "printf '%s/cfg' '\(m)'; sleep 30"], timeout: 0.3,
                                     acceptOnTimeout: ClaudeHome.hasMarkedLine)
        let totalElapsed = Date().timeIntervalSince(start)
        let missing = ClaudeHome.run("/nonexistent/shell", [])
        return Results(plain: plain, stdin: stdin, timedOut: timedOut, bgPlain: bgPlain, bgMarked: bgMarked,
                       acceptedAtTimeout: accepted, partialAtTimeout: partial, missing: missing,
                       bgElapsed: bgElapsed, totalElapsed: totalElapsed)
    }
    #expect(r.plain == "a\nb")
    #expect(r.stdin == "")
    #expect(r.timedOut == nil)
    #expect(r.bgPlain == "y")
    #expect(r.bgMarked.flatMap(ClaudeHome.markedValue) == "/cfg")
    #expect(r.bgElapsed < 6)
    #expect(r.acceptedAtTimeout.flatMap(ClaudeHome.markedValue) == "/cfg")
    #expect(r.partialAtTimeout == nil)
    #expect(r.totalElapsed < 5)
    #expect(r.missing == nil)
}

@Test func asyncClaudeHomeMatchesCachedValue() async {
    SessionDiscovery.prewarmDefaultClaudeHome()
    let home = await SessionDiscovery.resolvedClaudeHome()
    #expect(home == SessionDiscovery.defaultClaudeHome)
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

@MainActor
@Test func storeWatcherPicksUpNewRegistryFiles() async throws {
    let home = try TempHome()
    let t0 = Date(timeIntervalSince1970: 1792681136)
    let inspector = FakeInspector(table: [
        100: ProcessSnapshot(pid: 100, ppid: 1, startTime: t0, executablePath: claudeBinary),
    ])
    // Long poll interval: only the directory watcher can deliver the update in time.
    let store = SessionStore(claudeHome: home.url, inspector: inspector, pollInterval: .seconds(60))
    store.start()
    defer { store.stop() }
    try await Task.sleep(for: .milliseconds(100))
    #expect(store.sessions.isEmpty)
    try home.write("sessions/100.json", recordJSON(
        pid: 100, sessionId: "s-100", cwd: "/x", startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0)))
    for _ in 0..<40 where store.sessions.isEmpty {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(store.sessions.map(\.id) == ["s-100"])
}

// MARK: - Live check (CW_LIVE=1 swift test --filter liveDiscovery)

@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE"] == "1"))
func liveDiscovery() async throws {
    // The probes block (up to ~4 s), so they run on a dedicated thread, not the cooperative pool.
    let (launchctl, shell, probeMs) = try await onDedicatedThread { () -> (String?, String?, Int) in
        let probeStart = Date()
        let launchctl = ClaudeHome.launchctlValue(), shell = ClaudeHome.shellValue()
        return (launchctl, shell, Int(Date().timeIntervalSince(probeStart) * 1000))
    }
    let claudeHome = await SessionDiscovery.resolvedClaudeHome()
    print("LIVE: launchctl=\(launchctl.debugDescription) shell=\(shell.debugDescription) "
          + "probes \(probeMs) ms; defaultClaudeHome=\(claudeHome.path)")
    let discovery = SessionDiscovery(
        claudeHome: claudeHome, hookStateDirectory: HookStateStore.defaultDirectory)
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
              tty=\(s.tty ?? "nil") terminal=\(s.terminal) ghosttyTerminalID=\(s.ghosttyTerminalID ?? "nil") cwd=\(s.cwd)
              startedAt=\(s.startedAt) updatedAt=\(s.updatedAt)
              lastPrompt=\((s.lastPrompt ?? "nil").prefix(80).debugDescription)
        """)
    }
    #expect(!sessions.isEmpty)
}

// MARK: - Hook state join

private func hookStateJSON(
    sessionID: String, pid: Int32, tty: String?, ghosttyID: String?, updatedAt: Date
) -> String {
    let ttyJSON = tty.map { "\"\($0)\"" } ?? "null"
    let idJSON = ghosttyID.map { "\"\($0)\"" } ?? "null"
    return """
    {"session_id":"\(sessionID)","claude_pid":\(pid),"tty":\(ttyJSON),"term_program":"ghostty",\
    "cwd":"/x","transcript_path":null,"last_event":"Stop","ghostty_terminal_id":\(idJSON),\
    "updated_at":\(Int64(updatedAt.timeIntervalSince1970 * 1000))}
    """
}

@Test func hookStateMatchRules() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let later = start.addingTimeInterval(60)
    func state(_ id: String, pid: Int32 = 10, tty: String? = "/dev/ttys001", at: Date = later) -> HookState {
        HookState(sessionID: id, claudePID: pid, tty: tty, lastEvent: "Stop", ghosttyTerminalID: "G-\(id)",
                  updatedAtMillis: Int64(at.timeIntervalSince1970 * 1000))
    }
    func match(_ states: [HookState], id: String = "s", pid: Int32 = 10, tty: String? = "/dev/ttys001") -> String? {
        let byID = Dictionary(states.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        return HookStateStore.match(
            sessionID: id, pid: pid, tty: tty, processStart: start,
            states: byID, byPID: HookStateStore.latestByPID(byID))?.sessionID
    }

    #expect(match([state("s")]) == "s")                                   // by session id
    #expect(match([state("other")]) == "other")                           // pid fallback (/clear lag)
    #expect(match([state("s", tty: "/dev/ttys009")]) == nil)              // tty disagrees
    #expect(match([state("s", tty: nil)]) == "s")                         // unknown tty is fine
    #expect(match([state("s")], tty: nil) == "s")
    #expect(match([state("s", pid: 11)]) == nil)                          // same id, other process (resumed elsewhere)
    #expect(match([state("s", at: start.addingTimeInterval(-3600))]) == nil)  // dead process with a reused pid
    // Session id match wins over a newer state for the same pid.
    #expect(match([state("s"), state("newer", at: later.addingTimeInterval(5))]) == "s")
}

@Test func hookStateCacheRereadsOnlyChangedFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hookcache-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let t = Date(timeIntervalSince1970: 1_000_000)
    var cache = HookStateCache()
    #expect(cache.load(directory: dir).isEmpty)

    try Data(hookStateJSON(sessionID: "a", pid: 1, tty: nil, ghosttyID: nil, updatedAt: t).utf8)
        .write(to: dir.appendingPathComponent("a.json"), options: .atomic)
    #expect(cache.load(directory: dir)["a"]?.ghosttyTerminalID == nil)

    // The probe patches the id in (temp + rename, like the hook).
    try Data(hookStateJSON(sessionID: "a", pid: 1, tty: nil, ghosttyID: "GID-1", updatedAt: t).utf8)
        .write(to: dir.appendingPathComponent("a.json"), options: .atomic)
    #expect(cache.load(directory: dir)["a"]?.ghosttyTerminalID == "GID-1")

    try FileManager.default.moveItem(at: dir.appendingPathComponent("a.json"), to: dir.appendingPathComponent("a.ended"))
    #expect(cache.load(directory: dir).isEmpty)
}

@Test func discoveryJoinsHookTerminalIDs() async throws {
    let home = try TempHome()
    let hookDir = home.url.appendingPathComponent("hook-state", isDirectory: true)
    let t0 = Date(timeIntervalSince1970: 1792681136)
    try home.write("sessions/100.json", recordJSON(
        pid: 100, sessionId: "s-100", cwd: "/x", startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0)))
    try home.write("sessions/200.json", recordJSON(
        pid: 200, sessionId: "s-200", cwd: "/y", startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0)))
    try home.write("hook-state/s-100.json", hookStateJSON(
        sessionID: "s-100", pid: 100, tty: "/dev/ttys001", ghosttyID: "GID-100", updatedAt: t0.addingTimeInterval(5)))
    // Terminal.app session: a Ghostty id must never be attached.
    try home.write("hook-state/s-200.json", hookStateJSON(
        sessionID: "s-200", pid: 200, tty: "/dev/ttys004", ghosttyID: "GID-200", updatedAt: t0.addingTimeInterval(5)))
    let inspector = FakeInspector(table: [
        100: ProcessSnapshot(pid: 100, ppid: 103, startTime: t0, tty: "/dev/ttys001", executablePath: claudeBinary),
        103: ProcessSnapshot(pid: 103, ppid: 1, startTime: t0, executablePath: ghosttyBinary),
        200: ProcessSnapshot(pid: 200, ppid: 202, startTime: t0, tty: "/dev/ttys004", executablePath: claudeBinary),
        202: ProcessSnapshot(pid: 202, ppid: 1, startTime: t0, executablePath: terminalBinary),
    ])
    let discovery = SessionDiscovery(claudeHome: home.url, hookStateDirectory: hookDir, inspector: inspector)
    let sessions = await discovery.scan()
    #expect(sessions.first { $0.id == "s-100" }?.ghosttyTerminalID == "GID-100")
    #expect(sessions.first { $0.id == "s-200" }?.ghosttyTerminalID == nil)

    // Without a hook directory the join is off.
    let plain = SessionDiscovery(claudeHome: home.url, inspector: inspector)
    #expect(await plain.scan().allSatisfy { $0.ghosttyTerminalID == nil })
}

/// Rewrites a file in place (same inode), the way Claude Code updates `sessions/<pid>.json`.
private func rewriteInPlace(_ url: URL, _ text: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
}

@MainActor
@Test func storePicksUpInPlaceStatusRewritesAndHookUpdatesQuickly() async throws {
    let home = try TempHome()
    let hookDir = home.url.appendingPathComponent("hook-state", isDirectory: true)
    try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
    let t0 = Date(timeIntervalSince1970: 1792681136)
    let registry = home.url.appendingPathComponent("sessions/100.json")
    try home.write("sessions/100.json", recordJSON(
        pid: 100, sessionId: "s-100", cwd: "/x", startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0), status: "idle"))
    let inspector = FakeInspector(table: [
        100: ProcessSnapshot(pid: 100, ppid: 103, startTime: t0, tty: "/dev/ttys001", executablePath: claudeBinary),
        103: ProcessSnapshot(pid: 103, ppid: 1, startTime: t0, executablePath: ghosttyBinary),
    ])
    // Long poll interval: only the vnode sources can deliver updates in time.
    let store = SessionStore(
        claudeHome: home.url, hookStateDirectory: hookDir, inspector: inspector, pollInterval: .seconds(60))
    store.start()
    defer { store.stop() }
    for _ in 0..<40 where store.sessions.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
    #expect(store.sessions.first?.status == .idle)
    let inode = try FileManager.default.attributesOfItem(atPath: registry.path)[.systemFileNumber] as? Int

    try rewriteInPlace(registry, recordJSON(
        pid: 100, sessionId: "s-100", cwd: "/x", startedAt: t0.timeIntervalSince1970 * 1000,
        procStart: procStartString(t0), status: "busy"))
    #expect(try FileManager.default.attributesOfItem(atPath: registry.path)[.systemFileNumber] as? Int == inode)
    for _ in 0..<40 where store.sessions.first?.status != .busy { try await Task.sleep(for: .milliseconds(25)) }
    #expect(store.sessions.first?.status == .busy)

    try Data(hookStateJSON(
        sessionID: "s-100", pid: 100, tty: "/dev/ttys001", ghosttyID: "GID-100", updatedAt: t0.addingTimeInterval(5)
    ).utf8).write(to: hookDir.appendingPathComponent("s-100.json"), options: .atomic)
    for _ in 0..<40 where store.sessions.first?.ghosttyTerminalID == nil {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(store.sessions.first?.ghosttyTerminalID == "GID-100")
}
