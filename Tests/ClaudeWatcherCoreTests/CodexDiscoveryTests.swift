import Foundation
import SQLite3
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures

/// Rollout lines in Codex's shape (`{"timestamp","ordinal","type","payload"}`).
private enum Rollout {
    static func ts(_ seconds: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: seconds))
    }

    static func meta(_ t: Double, id: String = "t1") -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":0,"type":"session_meta","payload":{"id":"\#(id)","cwd":"/x","base_instructions":{"text":"\#(String(repeating: "x", count: 600))"}}}"#
    }

    static func taskStarted(_ t: Double, window: Int = 475_000) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_id":"u1","turn_trigger":"user"},"turn_id":"u1","started_at":\#(Int(t)),"model_context_window":\#(window),"collaboration_mode_kind":"default"}}"#
    }

    static func taskComplete(_ t: Double) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":9,"type":"event_msg","payload":{"type":"task_complete","turn_id":"u1","last_agent_message":"done","completed_at":\#(Int(t)),"duration_ms":1000}}"#
    }

    static func turnAborted(_ t: Double) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":9,"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"u1","reason":"interrupted"}}"#
    }

    static func tokenCount(_ t: Double, total: Int, window: Int = 475_000) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":5,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999,"total_tokens":999999},"last_token_usage":{"input_tokens":\#(total - 100),"cached_input_tokens":10,"output_tokens":100,"reasoning_output_tokens":0,"total_tokens":\#(total)},"model_context_window":\#(window)},"rate_limits":null}}"#
    }

    static func userMessage(_ t: Double, _ text: String) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":3,"type":"event_msg","payload":{"type":"item_completed","thread_id":"t1","turn_id":"u1","item":{"type":"UserMessage","id":"m1","content":[{"type":"text","text":"\#(text)","text_elements":[]}]}}}"#
    }

    static func environmentContext(_ t: Double) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":2,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n</environment_context>"}]}}"#
    }

    static func toolCall(_ t: Double, name: String) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":4,"type":"response_item","payload":{"type":"function_call","status":"completed","id":"fc_1","name":"\#(name)","arguments":"{}"}}"#
    }

    static func output(_ t: Double, bytes: Int) -> String {
        #"{"timestamp":"\#(ts(t))","ordinal":6,"type":"response_item","payload":{"type":"function_call_output","call_id":"c","output":"\#(String(repeating: "o", count: bytes))"}}"#
    }

    static func lines(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }
}

private func parse(_ text: String) -> CodexRolloutInfo {
    var info = CodexRolloutInfo()
    CodexRolloutParser.apply(data: Data(text.utf8), to: &info)
    return info
}

/// A throwaway directory, removed on deinit.
private final class TempDir {
    let url: URL
    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        url = URL(fileURLWithPath: ProcessRules.realpath(raw.path) ?? raw.path, isDirectory: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func append(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

private let codexBinary = "/Users/me/.codex/packages/standalone/releases/0.169.0-aarch64-apple-darwin/bin/codex"
private let daemonBinary = "/Users/me/.codex/packages/app-server-daemon/releases/0.169.0-aarch64-apple-darwin/bin/codex"
private let ghosttyBinary = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
private let terminalBinary = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"

private struct FakeInspector: ProcessInspecting {
    var table: [Int32: ProcessSnapshot]
    var argv: [Int32: [String]] = [:]
    var cwd: [Int32: String] = [:]
    func snapshot(pid: Int32) -> ProcessSnapshot? { table[pid] }
    func arguments(pid: Int32) -> [String]? { argv[pid] }
    func allPIDs() -> [Int32] { Array(table.keys) }
    func currentDirectory(pid: Int32) -> String? { cwd[pid] }
}

private final class FakeThreads: CodexThreadSource, @unchecked Sendable {
    var roots: [CodexThreadRow]
    var children: [String: [CodexThreadRow]]
    private(set) var closed = 0
    init(roots: [CodexThreadRow], children: [String: [CodexThreadRow]] = [:]) {
        self.roots = roots
        self.children = children
    }
    func rootThreads(sinceMillis: Int64) -> [CodexThreadRow]? { roots.filter { $0.activeAtMillis >= sinceMillis } }
    func subagentThreads(rootID: String, sinceMillis: Int64) -> [CodexThreadRow] {
        (children[rootID] ?? []).filter { $0.activeAtMillis >= sinceMillis }
    }
    func close() { closed += 1 }
}

private struct FakeTitles: TerminalTitleReading {
    var titles: [String: String]?
    func ghosttyTitlesByTTY() async -> [String: String]? { titles }
}

private func ms(_ seconds: Double) -> Int64 { Int64(seconds * 1000) }

private func row(_ id: String, cwd: String = "/p", created: Double, active: Double? = nil,
                 name: String? = nil, rollout: String = "/nonexistent.jsonl") -> CodexThreadRow {
    CodexThreadRow(id: id, rolloutPath: rollout, createdAtMillis: ms(created),
                   updatedAtMillis: ms(active ?? created), cwd: cwd, name: name)
}

private func proc(_ pid: Int32, start: Double, cwd: String = "/p", tty: String? = nil,
                  terminal: TerminalKind = .appleTerminal, resumes: Bool = false) -> CodexProcess {
    CodexProcess(pid: pid, startTime: Date(timeIntervalSince1970: start), tty: tty ?? "/dev/ttys\(pid)",
                 cwd: cwd, terminal: terminal, resumes: resumes)
}

// MARK: - Process rules

@Test func codexTUIRecognisesInstallKindsAndRejectsHelpers() {
    #expect(ProcessRules.isCodexTUI(codexBinary, arguments: { ["codex"] }))
    #expect(ProcessRules.isCodexTUI("/opt/homebrew/Caskroom/codex/0.169.0/bin/codex", arguments: { ["codex", "fix the bug"] }))
    #expect(ProcessRules.isCodexTUI(
        "/opt/homebrew/lib/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
        arguments: { ["codex", "-m", "gpt-6.1", "resume"] }))
    #expect(ProcessRules.isCodexTUI(codexBinary, arguments: { ["codex", "resume", "--last"] }))
    #expect(ProcessRules.isCodexTUI(codexBinary, arguments: { nil }))
    #expect(!ProcessRules.isCodexTUI(daemonBinary, arguments: {
        ["codex", "app-server", "--listen", "unix://", "--managed-daemon"] }))
    #expect(!ProcessRules.isCodexTUI(codexBinary, arguments: { ["codex", "exec", "do it"] }))
    #expect(!ProcessRules.isCodexTUI(codexBinary, arguments: { ["codex", "--full-auto", "e", "x"] }))
    #expect(!ProcessRules.isCodexTUI("/usr/local/bin/node", arguments: { ["node", "/usr/local/bin/codex"] }))
    #expect(!ProcessRules.isCodexTUI("/x/bin/codex-code-mode-host", arguments: { ["codex-code-mode-host"] }))
    #expect(!ProcessRules.isCodexTUI(nil, arguments: { nil }))
}

@Test func systemInspectorReadsOwnCwdAndListsItself() {
    let inspector = SystemProcessInspector()
    let me = getpid()
    #expect(inspector.allPIDs().contains(me))
    #expect(inspector.currentDirectory(pid: me) == ProcessRules.realpath(FileManager.default.currentDirectoryPath))
    #expect(inspector.processName(pid: me)?.isEmpty == false)
}

// MARK: - Rollout parsing

@Test func rolloutTurnStateFollowsTheLastTurnEvent() {
    let open = parse(Rollout.lines(Rollout.meta(100), Rollout.taskStarted(101), Rollout.toolCall(102, name: "exec")))
    #expect(open.turnActive == true)
    #expect(open.lastTool == "exec")
    #expect(open.contextWindow == 475_000)
    #expect(open.lastTurnEventAt == Date(timeIntervalSince1970: 101))
    #expect(open.lastRecordAt == Date(timeIntervalSince1970: 102))

    let done = parse(Rollout.lines(Rollout.taskStarted(101), Rollout.taskComplete(110)))
    #expect(done.turnActive == false)
    #expect(done.lastTurnEventAt == Date(timeIntervalSince1970: 110))

    let aborted = parse(Rollout.lines(Rollout.taskStarted(101), Rollout.turnAborted(103)))
    #expect(aborted.turnActive == false)

    #expect(parse(Rollout.lines(Rollout.meta(100))).turnActive == nil)
}

@Test func rolloutContextAndPromptUseTheLatestRecords() {
    let info = parse(Rollout.lines(
        Rollout.taskStarted(100, window: 258_400),
        Rollout.environmentContext(100.1),
        Rollout.userMessage(100.2, "first prompt"),
        Rollout.tokenCount(101, total: 20_000),
        Rollout.userMessage(105, "second prompt"),
        Rollout.tokenCount(106, total: 41_980, window: 475_000)))
    // last_token_usage.total_tokens, never the cumulative total_token_usage.
    #expect(info.contextTokens == 41_980)
    #expect(info.contextWindow == 475_000)
    #expect(info.lastPrompt == "second prompt")
}

@Test func rolloutPromptIsFlattenedAndGarbageIsIgnored() {
    let info = parse(Rollout.lines(
        "not json", "{\"truncated\":", "",
        Rollout.userMessage(1, "line one\\n  line two")))
    #expect(info.lastPrompt == "line one line two")
}

@Test func rolloutReaderParsesAppendsIncrementally() throws {
    let dir = try TempDir()
    let file = try dir.write("r.jsonl", Rollout.lines(Rollout.meta(100), Rollout.taskStarted(101)))
    let reader = CodexRolloutReader()
    #expect(reader.info(at: file)?.turnActive == true)
    // A partial line isn't consumed until it's complete.
    try dir.append("r.jsonl", String(Rollout.taskComplete(110).dropLast(10)))
    #expect(reader.info(at: file)?.turnActive == true)
    try dir.append("r.jsonl", String(Rollout.taskComplete(110).suffix(10)) + "\n")
    #expect(reader.info(at: file)?.turnActive == false)
    try dir.append("r.jsonl", Rollout.lines(Rollout.taskStarted(120), Rollout.tokenCount(121, total: 5_000)))
    let info = try #require(reader.info(at: file))
    #expect(info.turnActive == true)
    #expect(info.contextTokens == 5_000)
    // Replaced file (new inode): read from scratch.
    try FileManager.default.removeItem(at: file)
    try dir.write("r.jsonl", Rollout.lines(Rollout.taskStarted(1), Rollout.taskComplete(2)))
    #expect(reader.info(at: file)?.turnActive == false)
    #expect(reader.info(at: dir.url.appendingPathComponent("missing.jsonl")) == nil)
}

@Test func rolloutReaderScansBackPastAHugeTail() throws {
    let dir = try TempDir()
    // The turn started, then >256 KB of tool output followed: the tail alone has no turn event.
    var text = Rollout.lines(Rollout.meta(100), Rollout.userMessage(100.5, "do the big thing"),
                             Rollout.taskStarted(101), Rollout.tokenCount(102, total: 77_000))
    for i in 0..<12 { text += Rollout.output(103 + Double(i), bytes: 40_000) + "\n" }
    let file = try dir.write("big.jsonl", text)
    let info = try #require(CodexRolloutReader().info(at: file))
    #expect(info.turnActive == true)
    #expect(info.contextTokens == 77_000)
    #expect(info.lastPrompt == "do the big thing")
    #expect(info.lastRecordAt == Date(timeIntervalSince1970: 114))
}

// MARK: - Matching

@Test func singleTUITakesItsMostRecentlyActiveThread() {
    let p = proc(1, start: 1000)
    let a = CodexMatcher.match(processes: [p], roots: [
        row("old", created: 500, active: 900),       // finished before the TUI started
        row("a1", created: 1010, active: 1100),
        row("a2", created: 1200, active: 1300),       // after /new
        row("other", cwd: "/q", created: 1250),
    ], titles: nil)
    #expect(a.threads[1]?.id == "a2")
    #expect(a.ambiguous.isEmpty)

    // Nothing yet (no prompt sent): no thread, not ambiguous.
    let fresh = CodexMatcher.match(processes: [p], roots: [row("old", created: 500, active: 900)], titles: nil)
    #expect(fresh.threads[1] == nil)
    #expect(fresh.ambiguous.isEmpty)
}

@Test func resumeMayOwnAnOlderThread() {
    let resumed = row("r", created: 100, active: 1500)
    #expect(CodexMatcher.match(processes: [proc(1, start: 1000)], roots: [resumed], titles: nil).threads[1] == nil)
    #expect(CodexMatcher.match(processes: [proc(1, start: 1000, resumes: true)], roots: [resumed], titles: nil)
        .threads[1]?.id == "r")
}

@Test func sharedDirectoryIsDeducedFromThreadTimelines() {
    let a = proc(1, start: 1000), b = proc(2, start: 2000)
    // A's thread was still active after B's was created, so B's can't be A's.
    let m = CodexMatcher.match(processes: [a, b], roots: [
        row("a1", created: 1010, active: 2300),
        row("b1", created: 2010, active: 2400),
    ], titles: nil)
    #expect(m.threads[1]?.id == "a1")
    #expect(m.threads[2]?.id == "b1")
    #expect(m.ambiguous.isEmpty)

    // B hasn't started a thread: B gets none, A keeps its own.
    let fresh = CodexMatcher.match(processes: [a, b], roots: [row("a1", created: 1010, active: 2300)], titles: nil)
    #expect(fresh.threads[1]?.id == "a1")
    #expect(fresh.threads[2] == nil)
    #expect(fresh.ambiguous.isEmpty)

    // A ran /new after B started: still only one consistent assignment.
    let renewed = CodexMatcher.match(processes: [a, b], roots: [
        row("a1", created: 1010, active: 2100),
        row("b1", created: 2010, active: 2350),
        row("a2", created: 2300, active: 2400),
    ], titles: nil)
    #expect(renewed.threads[1]?.id == "a2")
    #expect(renewed.threads[2]?.id == "b1")
}

@Test func contestedThreadsStayUnassignedWithoutATitle() {
    let a = proc(1, start: 1000), b = proc(2, start: 1001)
    // Both started together and one thread exists: either could own it.
    let m = CodexMatcher.match(processes: [a, b], roots: [row("t", created: 1010, active: 1100, name: "Fix bug")],
                               titles: nil)
    #expect(m.threads.isEmpty)
    #expect(m.ambiguous == [1, 2])
}

@Test func terminalTitleBreaksTies() {
    let a = proc(1, start: 1000, tty: "/dev/ttys001", terminal: .ghostty)
    let b = proc(2, start: 1001, tty: "/dev/ttys002", terminal: .ghostty)
    let roots = [
        row("ta", created: 1010, active: 1100, name: "Fix login bug"),
        row("tb", created: 1020, active: 1090, name: "Write docs"),
    ]
    #expect(!CodexMatcher.match(processes: [a, b], roots: roots, titles: nil).ambiguous.isEmpty)
    let titles = ["/dev/ttys001": "⠋ Write docs | proj", "/dev/ttys002": "[ ! ] Action Required | Fix login bug | proj"]
    let m = CodexMatcher.match(processes: [a, b], roots: roots, titles: titles)
    #expect(m.threads[1]?.id == "tb")
    #expect(m.threads[2]?.id == "ta")
    #expect(m.ambiguous.isEmpty)

    // One title known: the other TUI is deduced.
    let one = CodexMatcher.match(processes: [a, b], roots: roots, titles: ["/dev/ttys002": "Fix login bug | proj"])
    #expect(one.threads[2]?.id == "ta")
    #expect(one.threads[1]?.id == "tb")
}

// MARK: - Waiting

@Test func waitingPrefersTheTerminalTitle() {
    let busy = CodexRolloutInfo(turnActive: true, lastTurnEventAt: Date(timeIntervalSince1970: 100),
                                lastRecordAt: Date(timeIntervalSince1970: 105))
    let permission = CodexHookState(sessionID: "t", lastEvent: "PermissionRequest", updatedAtMillis: ms(106))
    #expect(CodexDiscovery.waiting(title: "[ . ] Action Required | x | y", hook: nil, info: busy) == "action required")
    #expect(CodexDiscovery.waiting(title: "⠋ x | y", hook: permission, info: busy) == nil)
    #expect(CodexDiscovery.waiting(title: nil, hook: permission, info: busy) == "approval")
}

@Test func permissionHookExpiresOnceAnythingIsRecordedOrTheTurnEnds() {
    let permission = CodexHookState(sessionID: "t", lastEvent: "PermissionRequest", updatedAtMillis: ms(106))
    func info(active: Bool, turnAt: Double, lastAt: Double) -> CodexRolloutInfo {
        CodexRolloutInfo(turnActive: active, lastTurnEventAt: Date(timeIntervalSince1970: turnAt),
                         lastRecordAt: Date(timeIntervalSince1970: lastAt))
    }
    // The tool ran (output recorded after the request).
    #expect(CodexDiscovery.waiting(title: nil, hook: permission, info: info(active: true, turnAt: 100, lastAt: 120)) == nil)
    // The turn ended.
    #expect(CodexDiscovery.waiting(title: nil, hook: permission, info: info(active: false, turnAt: 110, lastAt: 110)) == nil)
    // A request from an earlier turn.
    #expect(CodexDiscovery.waiting(title: nil, hook: permission, info: info(active: true, turnAt: 200, lastAt: 201)) == nil)
    // Other events never mean waiting.
    let stop = CodexHookState(sessionID: "t", lastEvent: "UserPromptSubmit", updatedAtMillis: ms(106))
    #expect(CodexDiscovery.waiting(title: nil, hook: stop, info: info(active: true, turnAt: 100, lastAt: 105)) == nil)
    #expect(CodexDiscovery.waiting(title: nil, hook: permission, info: nil) == nil)
}

// MARK: - Subagents

@Test func subagentTreeIsPreOrderWithDepthFromRunningAncestors() {
    var rows = [
        row("c1", created: 10), row("c2", created: 20), row("g1", created: 30), row("g2", created: 40),
    ]
    rows[0].parentID = "root"; rows[0].agentNickname = "Sagan"; rows[0].agentPath = "/root/repo_integration"
    rows[1].parentID = "root"; rows[1].agentRole = "explorer"
    rows[2].parentID = "c1"; rows[2].depth = 1
    rows[3].parentID = "c2"; rows[3].depth = 1  // c2 isn't running: g2 shows as a root
    let running = Dictionary(uniqueKeysWithValues: [rows[0], rows[2], rows[3]].map {
        ($0, CodexRolloutInfo(turnActive: true, lastTool: "exec"))
    })
    let tree = CodexDiscovery.subagentTree(rows: rows, running: running, rootID: "root")
    #expect(tree.map(\.id) == ["c1", "g1", "g2"])
    #expect(tree.map(\.depth) == [0, 1, 0])
    #expect(tree[0].agentType == "Sagan")
    #expect(tree[0].label == "repo integration")
    #expect(tree[0].activity == "exec")
    #expect(tree[1].parentID == "c1")
    #expect(tree[2].parentID == nil)
}

// MARK: - State DB

@Test func stateDBReadsRootsAndSubagents() throws {
    let dir = try TempDir()
    let path = dir.url.appendingPathComponent("state_5.sqlite").path
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL, source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL,
          archived INTEGER NOT NULL DEFAULT 0, git_branch TEXT, agent_nickname TEXT, agent_role TEXT,
          agent_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, thread_source TEXT, name TEXT,
          originator TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY,
          status TEXT NOT NULL);
        INSERT INTO threads VALUES ('root', '/r/root.jsonl', 1000, 1100, 'vscode', '/p', 'fix it', 0, 'main',
          NULL, NULL, NULL, 1000500, 1100500, 'user', 'Fix it', 'codex-tui');
        INSERT INTO threads VALUES ('emb', '/r/emb.jsonl', 1000, 1050, 'cli', '/p', 'x', 0, NULL,
          NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'codex_cli_rs');
        INSERT INTO threads VALUES ('ide', '/r/ide.jsonl', 1000, 1200, 'vscode', '/p', 'x', 0, NULL,
          NULL, NULL, NULL, 1000000, 1200000, 'user', NULL, 'codex_vscode');
        INSERT INTO threads VALUES ('exec', '/r/exec.jsonl', 1000, 1200, 'exec', '/p', 'x', 0, NULL,
          NULL, NULL, NULL, 1000000, 1200000, 'user', NULL, 'codex_exec');
        INSERT INTO threads VALUES ('arch', '/r/arch.jsonl', 1000, 1200, 'cli', '/p', 'x', 1, NULL,
          NULL, NULL, NULL, 1000000, 1200000, 'user', NULL, NULL);
        INSERT INTO threads VALUES ('old', '/r/old.jsonl', 10, 20, 'cli', '/p', 'x', 0, NULL,
          NULL, NULL, NULL, 10000, 20000, 'user', NULL, NULL);
        INSERT INTO threads VALUES ('c1', '/r/c1.jsonl', 1010, 1090, '{"subagent":{}}', '/p', '', 0, NULL,
          'Sagan', NULL, '/root/a', 1010000, 1090000, 'subagent', NULL, 'codex-tui');
        INSERT INTO threads VALUES ('g1', '/r/g1.jsonl', 1020, 1080, '{"subagent":{}}', '/p', '', 0, NULL,
          'Darwin', 'worker', '/root/a/b', 1020000, 1080000, 'subagent', NULL, 'codex-tui');
        INSERT INTO thread_spawn_edges VALUES ('root', 'c1', 'open'), ('c1', 'g1', 'open');
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let state = CodexStateDB(codexHome: dir.url)
    let roots = try #require(state.rootThreads(sinceMillis: 500_000))
    #expect(Set(roots.map(\.id)) == ["root", "emb"])
    let root = try #require(roots.first { $0.id == "root" })
    #expect(root.name == "Fix it")
    #expect(root.title == "fix it")
    #expect(root.gitBranch == "main")
    #expect(root.createdAtMillis == 1_000_500)
    #expect(root.updatedAtMillis == 1_100_500)
    // `_ms` missing: seconds * 1000.
    #expect(roots.first { $0.id == "emb" }?.updatedAtMillis == 1_050_000)

    let agents = state.subagentThreads(rootID: "root", sinceMillis: 0)
    #expect(agents.map(\.id) == ["c1", "g1"])
    #expect(agents.map(\.depth) == [0, 1])
    #expect(agents[1].parentID == "c1")
    #expect(agents[1].agentNickname == "Darwin")
    #expect(agents[1].agentRole == "worker")
    state.close()
    #expect(CodexStateDB(codexHome: dir.url.appendingPathComponent("missing")).rootThreads(sinceMillis: 0) == nil)
}

@Test func newestStateFileWins() throws {
    let dir = try TempDir()
    for name in ["state_4.sqlite", "state_12.sqlite", "state_5.sqlite", "state_x.sqlite", "logs_2.sqlite"] {
        try dir.write(name, "")
    }
    #expect(CodexStateDB.newestStateFile(in: dir.url)?.lastPathComponent == "state_12.sqlite")
}

// MARK: - End to end

@Test func discoveryBuildsCodexSessions() async throws {
    let dir = try TempDir()
    let project = dir.url.appendingPathComponent("proj").path
    try FileManager.default.createDirectory(atPath: project + "/.git", withIntermediateDirectories: true)
    try dir.write("proj/.git/HEAD", "ref: refs/heads/feature/x\n")
    let now = Date().timeIntervalSince1970
    let start = now - 600

    let rollout = try dir.write("sessions/root.jsonl", Rollout.lines(
        Rollout.meta(start + 10), Rollout.taskStarted(start + 20), Rollout.userMessage(start + 21, "find the bug"),
        Rollout.tokenCount(start + 30, total: 95_000)))
    let child = try dir.write("sessions/child.jsonl", Rollout.lines(
        Rollout.taskStarted(start + 20), Rollout.turnAborted(start + 20),  // copied parent history
        Rollout.taskStarted(start + 40), Rollout.toolCall(now - 5, name: "exec")))
    let done = try dir.write("sessions/done.jsonl", Rollout.lines(Rollout.taskStarted(start + 40), Rollout.taskComplete(start + 50)))

    var root = row("root", cwd: project, created: start + 10, active: now - 5, name: "Find the bug",
                   rollout: rollout.path)
    root.gitBranch = "main"
    var c1 = row("c1", cwd: project, created: start + 40, active: now - 5, rollout: child.path)
    c1.parentID = "root"; c1.agentNickname = "Sagan"; c1.agentPath = "/root/bug_hunt"
    var c2 = row("c2", cwd: project, created: start + 40, active: start + 50, rollout: done.path)
    c2.parentID = "root"
    let threads = FakeThreads(roots: [root], children: ["root": [c1, c2]])

    let tui = ProcessSnapshot(pid: 500, ppid: 400, startTime: Date(timeIntervalSince1970: start),
                              tty: "/dev/ttys005", executablePath: codexBinary)
    let fresh = ProcessSnapshot(pid: 501, ppid: 401, startTime: Date(timeIntervalSince1970: now - 30),
                                tty: "/dev/ttys006", executablePath: codexBinary)
    let daemon = ProcessSnapshot(pid: 600, ppid: 500, startTime: Date(timeIntervalSince1970: start + 4),
                                 tty: nil, executablePath: daemonBinary)
    let headless = ProcessSnapshot(pid: 700, ppid: 401, startTime: Date(timeIntervalSince1970: start),
                                   tty: "/dev/ttys007", executablePath: codexBinary)
    let inspector = FakeInspector(
        table: [
            500: tui, 501: fresh, 600: daemon, 700: headless,
            400: ProcessSnapshot(pid: 400, ppid: 300, startTime: .distantPast, executablePath: "/bin/zsh"),
            300: ProcessSnapshot(pid: 300, ppid: 1, startTime: .distantPast, executablePath: ghosttyBinary),
            401: ProcessSnapshot(pid: 401, ppid: 301, startTime: .distantPast, executablePath: "/bin/zsh"),
            301: ProcessSnapshot(pid: 301, ppid: 1, startTime: .distantPast, executablePath: terminalBinary),
        ],
        argv: [500: ["codex"], 501: ["codex"], 600: ["codex", "app-server"], 700: ["codex", "exec", "x"]],
        cwd: [500: project, 501: dir.url.path, 600: project, 700: project])

    let hookDir = dir.url.appendingPathComponent("hooks")
    try FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)
    let discovery = CodexDiscovery(
        codexHome: dir.url, hookStateDirectory: hookDir, inspector: inspector, threads: threads,
        titles: FakeTitles(titles: ["/dev/ttys005": "⠋ Find the bug | proj"]))

    let sessions = await discovery.scan()
    #expect(sessions.map(\.pid) == [500, 501])
    let s = try #require(sessions.first)
    #expect(s.id == "root")
    #expect(s.agent == .codex)
    #expect(s.title == "Find the bug")
    #expect(s.branch == "feature/x")  // live HEAD, not the branch the thread started on
    #expect(s.status == .busy)
    #expect(s.terminal == .ghostty)
    #expect(s.tty == "/dev/ttys005")
    #expect(s.lastPrompt == "find the bug")
    #expect(s.contextTokens == 95_000)
    #expect(s.contextWindow == 475_000)
    #expect(s.effectiveContextWindow == 475_000)
    #expect(s.subagents.map(\.id) == ["c1"])
    #expect(s.subagents.first?.agentType == "Sagan")

    let other = sessions[1]
    #expect(other.id.hasPrefix("codex-pid-501-"))
    #expect(other.status == .idle)
    #expect(other.terminal == .appleTerminal)
    #expect(other.contextTokens == nil)

    // The title says Action Required: waiting.
    let blocked = CodexDiscovery(
        codexHome: dir.url, hookStateDirectory: hookDir, inspector: inspector, threads: threads,
        titles: FakeTitles(titles: ["/dev/ttys005": "[ ! ] Action Required | Find the bug | proj"]))
    let waiting = await blocked.scan()
    #expect(waiting.first?.status == .waiting)
    #expect(waiting.first?.waitingFor == "action required")

    // No titles: the hook's PermissionRequest (newer than the last record) means waiting.
    try Data(#"{"session_id":"root","last_event":"PermissionRequest","turn_id":"u1","updated_at":\#(ms(now + 60))}"#.utf8)
        .write(to: hookDir.appendingPathComponent("root.json"))
    let hooked = CodexDiscovery(
        codexHome: dir.url, hookStateDirectory: hookDir, inspector: inspector, threads: threads, titles: nil)
    #expect(await hooked.scan().first?.waitingFor == "approval")

    // The TUI exits (the daemon lives on): nothing is listed and the DB is released.
    let gone = CodexDiscovery(
        codexHome: dir.url, inspector: FakeInspector(table: [600: daemon], argv: [600: ["codex", "app-server"]]),
        threads: threads, titles: nil)
    #expect(await gone.scan().isEmpty)
    #expect(threads.closed >= 1)
}

@Test func storeMergesClaudeAndCodexSessions() async throws {
    let home = try TempHome()
    let dir = try TempDir()
    let tui = ProcessSnapshot(pid: 500, ppid: 1, startTime: Date().addingTimeInterval(-60),
                              tty: "/dev/ttys005", executablePath: codexBinary)
    let codex = CodexDiscovery(
        codexHome: dir.url, inspector: FakeInspector(table: [500: tui], argv: [500: ["codex"]], cwd: [500: dir.url.path]),
        threads: FakeThreads(roots: []), titles: nil)
    let store = await SessionStore(claudeHome: home.url, codex: codex)
    await store.reload()
    let sessions = await store.sessions
    #expect(sessions.count == 1)
    #expect(sessions.first?.agent == .codex)
}

@Test func contextLabelsUseTheSessionWindow() {
    #expect(ContextUsage.label(121_300, window: 475_000) == "121k / 475k · 25%")
    #expect(ContextUsage.windowLabel(1_000_000) == "1M")
    #expect(ContextUsage.windowLabel(475_000) == "475k")
    let claude = ClaudeSession(id: "x", pid: 1, cwd: "/", title: "t", startedAt: .now, updatedAt: .now)
    #expect(claude.agent == .claude)
    #expect(claude.effectiveContextWindow == ContextUsage.window)
}

@Test func ghosttyTitleListingParses() {
    let out = "/dev/ttys001\u{1F}⠋ Fix | proj\u{1E}/dev/ttys002\u{1F}\u{1E}garbage\u{1E}"
    #expect(GhosttyTitleReader.parse(out) == ["/dev/ttys001": "⠋ Fix | proj", "/dev/ttys002": ""])
}

// MARK: - Live

/// `CW_LIVE=1 swift test --filter liveCodexDiscovery`: dumps the real Codex threads and sessions
/// (read-only: the state DB is opened read-only, rollouts are only read).
@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE"] == "1"))
func liveCodexDiscovery() async throws {
    let home = await CodexPaths.resolvedHome()
    let db = CodexStateDB(codexHome: home)
    let roots = db.rootThreads(sinceMillis: Int64((Date().timeIntervalSince1970 - 86_400) * 1000))
    print("LIVE codex: home=\(home.path) state=\(CodexStateDB.newestStateFile(in: home)?.lastPathComponent ?? "none") "
          + "roots(24h)=\(roots.map { "\($0.count)" } ?? "unavailable")")
    let reader = CodexRolloutReader()
    for r in roots ?? [] {
        let info = reader.info(at: URL(fileURLWithPath: r.rolloutPath))
        let agents = db.subagentThreads(rootID: r.id, sinceMillis: 0)
        print("""
            LIVE codex thread \(r.id) name=\(r.name.debugDescription) cwd=\(r.cwd) branch=\(r.gitBranch ?? "nil")
                  turnActive=\(info?.turnActive.debugDescription ?? "no rollout") context=\(info?.contextTokens ?? 0)/\(info?.contextWindow ?? 0) \
            tool=\(info?.lastTool ?? "nil") subagents=\(agents.map { "\($0.agentNickname ?? $0.id)@\($0.depth)" })
                  prompt=\(info?.lastPrompt?.prefix(80).description ?? "nil")
            """)
    }
    db.close()
    let discovery = CodexDiscovery(codexHome: home, hookStateDirectory: CodexHookStateStore.defaultDirectory)
    let start = Date()
    let sessions = await discovery.scan()
    print("LIVE codex: \(sessions.count) TUI session(s) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    for s in sessions {
        print("LIVE codex session pid=\(s.pid) id=\(s.id) title=\(s.title.debugDescription) status=\(s.status) "
              + "waiting=\(s.waitingFor ?? "-") tty=\(s.tty ?? "nil") terminal=\(s.terminal) "
              + "context=\(s.contextTokens ?? 0)/\(s.effectiveContextWindow) agents=\(s.subagents.map(\.label))")
    }
}
