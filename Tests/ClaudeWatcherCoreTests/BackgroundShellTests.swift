import Foundation
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures (shapes from Claude Code 2.1.330 transcripts)

private func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

/// The assistant record of a Bash call.
private func bashCall(_ toolUseID: String, at: Date, command: String, description: String? = nil,
                      background: Bool = true) -> String {
    var input: [String: Any] = ["command": command]
    if let description { input["description"] = description }
    if background { input["run_in_background"] = true }
    return json(["type": "assistant", "timestamp": iso(at), "isSidechain": false,
                 "message": ["role": "assistant", "stop_reason": "tool_use",
                             "content": [["type": "tool_use", "id": toolUseID, "name": "Bash", "input": input]]]]) + "\n"
}

/// The tool_result record of a Bash call that went to the background as `taskID`.
private func backgroundResult(_ toolUseID: String, taskID: String, at: Date, timedOut: Bool = false) -> String {
    var result: [String: Any] = ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": taskID]
    if timedOut { result["timedOutAfterMs"] = 120_000 }
    return json(["type": "user", "timestamp": iso(at),
                 "message": ["role": "user", "content": [[
                     "tool_use_id": toolUseID, "type": "tool_result",
                     "content": "Command running in background with ID: \(taskID). Output is being written to: /tmp/x/tasks/\(taskID).output.",
                 ]]],
                 "toolUseResult": result]) + "\n"
}

private func notificationXML(_ id: String, status: String = "completed") -> String {
    "<task-notification>\n<task-id>\(id)</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n"
        + "<output-file>/tmp/x/tasks/\(id).output</output-file>\n<status>\(status)</status>\n"
        + "<summary>Background command \"x\" completed (exit code 0)</summary>\n</task-notification>"
}

private func queueLine(_ id: String, at: Date, operation: String = "enqueue", status: String = "completed") -> String {
    json(["type": "queue-operation", "operation": operation, "timestamp": iso(at), "sessionId": "s",
          "content": notificationXML(id, status: status)]) + "\n"
}

private func queuedCommandLine(_ id: String, at: Date) -> String {
    json(["type": "attachment", "timestamp": iso(at),
          "attachment": ["type": "queued_command", "commandMode": "task-notification",
                         "prompt": notificationXML(id)]]) + "\n"
}

private func taskStopResult(_ id: String, at: Date, type: String = "local_bash") -> String {
    let message = "Successfully stopped task: \(id) (sleep 100)"
    return json(["type": "user", "timestamp": iso(at),
                 "message": ["role": "user", "content": [[
                     "tool_use_id": "toolu_stop", "type": "tool_result",
                     "content": "{\"message\":\"\(message)\",\"task_id\":\"\(id)\"}",
                 ]]],
                 "toolUseResult": ["message": message, "task_id": id, "task_type": type, "command": "sleep 100"]]) + "\n"
}

private final class ShellFixture {
    let home: TempHome
    let transcript: URL
    let processStart = Date().addingTimeInterval(-60)
    let t = Date().addingTimeInterval(-30)

    init(_ lines: String...) throws {
        home = try TempHome()
        try home.write("projects/p/s.jsonl", "{\"type\":\"user\"}\n" + lines.joined())
        transcript = home.url.appendingPathComponent("projects/p/s.jsonl")
    }

    func at(_ seconds: TimeInterval) -> Date { t.addingTimeInterval(seconds) }
    func append(_ lines: String...) throws { try home.append("projects/p/s.jsonl", lines.joined()) }
    func shells(_ tracker: SubagentTracker, _ status: SessionStatus = .idle, now: Date = Date()) -> [BackgroundShellInfo] {
        tracker.backgroundShells(transcript: transcript, processStart: processStart, parentStatus: status, now: now)
    }
}

// MARK: - Tests

@Test func backgroundShellRunsUntilItsNotification() throws {
    let f = try ShellFixture()
    try f.append(bashCall("toolu_1", at: f.at(0), command: "ghx ci wait 12 --brief\necho done",
                          description: "Wait for CI on PR 12"),
                 backgroundResult("toolu_1", taskID: "b1", at: f.at(1)))
    let tracker = SubagentTracker()
    let running = f.shells(tracker)
    #expect(running.map(\.id) == ["b1"])
    #expect(running.first?.label == "Wait for CI on PR 12")
    #expect(running.first?.command == "ghx ci wait 12 --brief")
    #expect(running.first?.startedAt == Date(timeIntervalSince1970: f.at(1).timeIntervalSince1970.rounded(.down)))

    try f.append(queueLine("b1", at: f.at(20)))
    #expect(f.shells(tracker).isEmpty)
}

@Test func backgroundShellEndsOnAnyEndRecord() throws {
    let f = try ShellFixture()
    for (i, id) in ["q", "r", "a", "k", "failed"].enumerated() {
        try f.append(bashCall("toolu_\(id)", at: f.at(Double(i)), command: "sleep \(i)"),
                     backgroundResult("toolu_\(id)", taskID: id, at: f.at(Double(i))))
    }
    let tracker = SubagentTracker()
    #expect(f.shells(tracker).map(\.id) == ["q", "r", "a", "k", "failed"])
    try f.append(queueLine("q", at: f.at(10)),
                 queueLine("r", at: f.at(10), operation: "remove", status: "killed"),
                 queuedCommandLine("a", at: f.at(10)),
                 taskStopResult("k", at: f.at(10)),
                 queueLine("failed", at: f.at(10), status: "failed"))
    #expect(f.shells(tracker).isEmpty)
}

@Test func backgroundShellLabels() throws {
    let f = try ShellFixture(
        // A foreground command that timed out into the background: no run_in_background.
        bashCall("toolu_t", at: Date(), command: "swift test", description: "Run the tests", background: false),
        backgroundResult("toolu_t", taskID: "timed", at: Date(), timedOut: true),
        // No description: the command's first non-blank line, no separate command.
        bashCall("toolu_c", at: Date(), command: "\n  npm run dev  \nmore"),
        backgroundResult("toolu_c", taskID: "cmd", at: Date()),
        // A result whose call wasn't seen.
        backgroundResult("toolu_missing", taskID: "orphan", at: Date()))
    let byID = Dictionary(uniqueKeysWithValues: f.shells(SubagentTracker()).map { ($0.id, $0) })
    #expect(byID["timed"]?.label == "Run the tests")
    #expect(byID["timed"]?.command == "swift test")
    #expect(byID["cmd"]?.label == "npm run dev")
    #expect(byID["cmd"]?.command == nil)
    #expect(byID["orphan"]?.label == "background command")
    // An agent stopped with TaskStop doesn't touch shells; a foreground Bash result isn't one.
    #expect(byID.count == 3)
}

@Test func backgroundShellsBeforeProcessStartOrStaleAreDropped() throws {
    let f = try ShellFixture()
    let early = f.processStart.addingTimeInterval(-600)
    try f.append(bashCall("toolu_old", at: early, command: "sleep 1000"),
                 backgroundResult("toolu_old", taskID: "old", at: early),
                 bashCall("toolu_new", at: f.at(0), command: "sleep 1000"),
                 backgroundResult("toolu_new", taskID: "new", at: f.at(0)))
    let tracker = SubagentTracker()
    #expect(f.shells(tracker).map(\.id) == ["new"])
    let later = Date().addingTimeInterval(25 * 3600)
    #expect(f.shells(tracker, .idle, now: later).isEmpty)
    #expect(f.shells(tracker, .busy, now: later).map(\.id) == ["new"])
}

@Test func backgroundShellIndexIsIncrementalAcrossChunks() throws {
    let f = try ShellFixture()
    // A tiny chunk size splits every line across chunks.
    let tracker = SubagentTracker(chunkBytes: 64)
    #expect(f.shells(tracker).isEmpty)
    try f.append(bashCall("toolu_1", at: f.at(0), command: "make test", description: "Run tests"),
                 backgroundResult("toolu_1", taskID: "b1", at: f.at(1)))
    #expect(f.shells(tracker).map(\.label) == ["Run tests"])
    // A partial line isn't applied until it's complete.
    let end = queueLine("b1", at: f.at(5))
    try f.append(String(end.prefix(40)))
    #expect(f.shells(tracker).map(\.id) == ["b1"])
    try f.append(String(end.dropFirst(40)))
    #expect(f.shells(tracker).isEmpty)
    // A rewritten (new inode) transcript is re-indexed from scratch.
    try FileManager.default.removeItem(at: f.transcript)
    try f.home.write("projects/p/s.jsonl", bashCall("toolu_2", at: f.at(6), command: "sleep 9")
        + backgroundResult("toolu_2", taskID: "b2", at: f.at(6)))
    #expect(f.shells(tracker).map(\.id) == ["b2"])
}

@Test func agentsAndShellsShareTheTranscriptIndex() throws {
    // No subagents dir: `running` resets its state but must keep the index.
    let f = try ShellFixture(bashCall("toolu_1", at: Date(), command: "sleep 9"),
                             backgroundResult("toolu_1", taskID: "b1", at: Date()))
    let tracker = SubagentTracker()
    #expect(f.shells(tracker).map(\.id) == ["b1"])
    #expect(tracker.running(transcript: f.transcript, processStart: f.processStart, parentStatus: .idle).isEmpty)
    #expect(f.shells(tracker).map(\.id) == ["b1"])
}

@Test func bashRingKeepsOnlyRecentCalls() {
    var index = TranscriptTaskIndex(inode: 1)
    let t = Date()
    for i in 0..<(TranscriptTaskIndex.recentBashLimit + 10) {
        index.apply(line: Data(bashCall("toolu_\(i)", at: t, command: "echo \(i)", background: false).utf8))
    }
    #expect(index.recentBash.count == TranscriptTaskIndex.recentBashLimit)
    #expect(index.recentBash.last?.toolUseID == "toolu_\(TranscriptTaskIndex.recentBashLimit + 9)")
    // An agent's notice still lands in `notices`, as `SubagentTracker` expects.
    index.apply(line: Data(queueLine("agent1", at: t).utf8))
    #expect(index.notices["agent1"]?.at.timeIntervalSince1970.rounded() == t.timeIntervalSince1970.rounded())
}

@Test func treePrefixesByDepth() {
    // Agents a (with child a1), then a shell at depth 0: the shell is the last root.
    let p = SubagentTree.prefixes(depths: [0, 1, 0])
    #expect(p.map(\.prefix) == ["├── ", "│   └── ", "└── "])
    #expect(p.map(\.continuation) == ["│   ", "│       ", "    "])
}
