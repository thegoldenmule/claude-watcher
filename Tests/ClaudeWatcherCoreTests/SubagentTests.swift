import Foundation
import Testing
@testable import ClaudeWatcherCore

private func agent(_ id: String, depth: Int = 0) -> SubagentInfo {
    SubagentInfo(id: id, agentType: "Explore", label: id, startedAt: .distantPast, lastActivityAt: .distantPast, depth: depth)
}

@Test func subagentTreePrefixes() {
    // a
    // ├ a1
    // │ └ a1x
    // └ a2
    // b
    let lines = SubagentTree.lines([agent("a"), agent("a1", depth: 1), agent("a1x", depth: 2), agent("a2", depth: 1), agent("b")])
    #expect(lines.map(\.prefix) == ["├ ", "│ ├ ", "│ │ └ ", "│ └ ", "└ "])
    #expect(lines.map(\.continuation) == ["│ ", "│ │ ", "│ │   ", "│   ", "  "])
    #expect(SubagentTree.lines([agent("only")]).map(\.prefix) == ["└ "])
    #expect(SubagentTree.lines([]).isEmpty)
}

@Test func elapsedFormatBoundaries() {
    #expect(ElapsedFormat.short(-5) == "0s")
    #expect(ElapsedFormat.short(0) == "0s")
    #expect(ElapsedFormat.short(59) == "59s")
    #expect(ElapsedFormat.short(60) == "1m")
    #expect(ElapsedFormat.short(3599) == "59m")
    #expect(ElapsedFormat.short(3900) == "1h05m")
}

// MARK: - Fixtures

private func iso(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func userLine(_ at: Date, _ text: String = "go") -> String {
    json(["type": "user", "isSidechain": true, "timestamp": iso(at),
          "message": ["role": "user", "content": text]]) + "\n"
}

private func assistantLine(_ at: Date, stop: String?, block: [String: Any]) -> String {
    json(["type": "assistant", "isSidechain": true, "timestamp": iso(at),
          "message": ["role": "assistant", "stop_reason": stop.map { $0 as Any } ?? NSNull(), "content": [block]]]) + "\n"
}

private func toolUse(_ name: String, _ input: [String: Any]) -> [String: Any] {
    ["type": "tool_use", "name": name, "input": input]
}

private func notificationXML(_ id: String, status: String? = "completed") -> String {
    "<task-notification>\n<task-id>\(id)</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n"
        + (status.map { "<status>\($0)</status>\n" } ?? "") + "<summary>done</summary>\n</task-notification>"
}

private func queueLine(_ id: String, at: Date, operation: String = "enqueue", status: String? = "completed") -> String {
    var obj: [String: Any] = ["type": "queue-operation", "operation": operation, "timestamp": iso(at), "sessionId": "s"]
    if operation == "enqueue" { obj["content"] = notificationXML(id, status: status) }
    return json(obj) + "\n"
}

private func queuedCommandLine(_ id: String, at: Date) -> String {
    json(["type": "attachment", "isSidechain": true, "timestamp": iso(at),
          "attachment": ["type": "queued_command", "commandMode": "task-notification",
                         "prompt": notificationXML(id)]]) + "\n"
}

private func metaJSON(_ type: String = "Explore", description: String? = nil, name: String? = nil,
                      parent: String? = nil, shape: String = "background", stopped: Bool? = nil) -> String {
    var obj: [String: Any] = ["agentType": type, "toolUseId": "toolu_x", "requestShape": shape,
                              "spawnDepth": parent == nil ? 1 : 2, "requestNonInteractive": true]
    if let description { obj["description"] = description }
    if let name { obj["name"] = name }
    if let parent { obj["parentAgentId"] = parent }
    if let stopped { obj["stoppedByUser"] = stopped }
    return json(obj)
}

/// A session transcript with a `subagents/` dir in a temp Claude home.
private final class AgentFixture {
    let home: TempHome
    let transcript: URL
    let processStart = Date().addingTimeInterval(-60)
    let t = Date().addingTimeInterval(-30)  // record timestamps count up from here

    init() throws {
        home = try TempHome()
        try home.write("projects/p/s.jsonl", "{\"type\":\"user\"}\n")
        transcript = home.url.appendingPathComponent("projects/p/s.jsonl")
    }

    func agentPath(_ id: String, _ ext: String = "jsonl") -> String { "projects/p/s/subagents/agent-\(id).\(ext)" }
    func write(_ id: String, meta: String, _ lines: String...) throws {
        try home.write(agentPath(id, "meta.json"), meta)
        try home.write(agentPath(id), lines.joined())
    }
    func append(_ id: String, _ lines: String...) throws { try home.append(agentPath(id), lines.joined()) }
    func at(_ seconds: TimeInterval) -> Date { t.addingTimeInterval(seconds) }

    func running(_ tracker: SubagentTracker, _ status: SessionStatus = .busy, now: Date = Date()) -> [SubagentInfo] {
        tracker.running(transcript: transcript, processStart: processStart, parentStatus: status, now: now)
    }
}

// MARK: - Tracker

@Test func trackerReadsTypeLabelAndActivity() throws {
    let f = try AgentFixture()
    let before = Date()
    try f.write("a1", meta: metaJSON("Explore", description: "Find the parser", name: "finder"),
                userLine(f.at(0)), assistantLine(f.at(1), stop: "tool_use",
                                                 block: toolUse("Read", ["file_path": "/x/y/Foo.swift"])))
    try f.write("a2", meta: metaJSON("Plan", name: "planner"), userLine(f.at(2)))
    try f.write("a3", meta: metaJSON("general-purpose"), userLine(f.at(3)))
    let agents = f.running(SubagentTracker())
    #expect(agents.map(\.id).sorted() == ["a1", "a2", "a3"])
    let a1 = try #require(agents.first { $0.id == "a1" })
    #expect(a1.agentType == "Explore")
    #expect(a1.label == "Find the parser")
    #expect(a1.activity == "Read Foo.swift")
    #expect(a1.isBackground)
    #expect(a1.depth == 0 && a1.parentID == nil)
    #expect(a1.lastActivityAt == Date(timeIntervalSince1970: f.at(1).timeIntervalSince1970.rounded(.down)))
    // startedAt is the file's birthtime, floored to whole seconds.
    #expect(a1.startedAt.timeIntervalSince1970 == a1.startedAt.timeIntervalSince1970.rounded(.down))
    #expect(a1.startedAt >= before.addingTimeInterval(-1) && a1.startedAt <= Date())
    #expect(agents.first { $0.id == "a2" }?.label == "planner")
    #expect(agents.first { $0.id == "a3" }?.label == "general-purpose")
    #expect(agents.first { $0.id == "a3" }?.activity == nil)
}

@Test func tailStopReasons() {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func finished(_ text: String) -> Bool {
        var tail = AgentTail()
        AgentTail.apply(Data(text.utf8), to: &tail)
        return SubagentRules.isFinished(meta: nil, tail: tail, lastWrite: t, notifiedAt: nil,
                                        parentStatus: .busy, now: t, staleAfter: 600)
    }
    let read = toolUse("Read", ["file_path": "/a"])
    #expect(!finished(assistantLine(t, stop: "tool_use", block: read)))
    #expect(!finished(assistantLine(t, stop: nil, block: ["type": "thinking", "thinking": "hm"])))
    #expect(!finished(assistantLine(t, stop: "pause_turn", block: ["type": "text", "text": "x"])))
    for stop in ["end_turn", "stop_sequence", "max_tokens"] {
        #expect(finished(assistantLine(t, stop: stop, block: ["type": "text", "text": "done"])))
    }
    // A streamed block (null stop) followed by the message's last block (end_turn).
    #expect(finished(assistantLine(t, stop: nil, block: ["type": "thinking"])
                     + assistantLine(t, stop: "end_turn", block: ["type": "text", "text": "done"])))
    // A SendMessage resume: a user record after the end_turn.
    #expect(!finished(assistantLine(t, stop: "end_turn", block: ["type": "text", "text": "done"]) + userLine(t)))
    // Attachments after the end_turn aren't a resume.
    #expect(finished(assistantLine(t, stop: "end_turn", block: ["type": "text", "text": "done"])
                     + queuedCommandLine("child", at: t)))
}

@Test func parsesOnlyEnqueuedTaskNotifications() throws {
    let t = Date(timeIntervalSince1970: 1_800_000_000.25)
    let parsed = try #require(SubagentRules.parseNotification(Data(queueLine("a1", at: t).utf8)))
    #expect(parsed.taskID == "a1")
    #expect(abs(parsed.at.timeIntervalSince(t)) < 0.001)
    #expect(SubagentRules.parseNotification(Data(queueLine("a1", at: t, operation: "dequeue").utf8)) == nil)
    #expect(SubagentRules.parseNotification(Data(queueLine("a1", at: t, operation: "remove").utf8)) == nil)
    // A Monitor event (no <status>), and an agent hand-back message.
    #expect(SubagentRules.parseNotification(Data(queueLine("b1", at: t, status: nil).utf8)) == nil)
    let handBack = json(["type": "queue-operation", "operation": "enqueue", "timestamp": iso(t),
                         "content": "<agent-message from=\"a1\">\nreport\n</agent-message>"])
    #expect(SubagentRules.parseNotification(Data(handBack.utf8)) == nil)
    // Content as an array of text blocks; timestamps without fractional seconds.
    let blocks = json(["type": "queue-operation", "operation": "enqueue", "timestamp": "2026-10-26T15:14:52Z",
                       "content": [["type": "text", "text": notificationXML("c1")]]])
    #expect(SubagentRules.parseNotification(Data(blocks.utf8))?.taskID == "c1")
}

@Test func parentTranscriptNotificationFinishesAgent() throws {
    let f = try AgentFixture()
    let tracker = SubagentTracker()
    try f.write("a1", meta: metaJSON(), userLine(f.at(0)),
                assistantLine(f.at(5), stop: "tool_use", block: toolUse("Bash", ["command": "make"])))
    #expect(f.running(tracker).map(\.id) == ["a1"])
    // dequeue/remove don't count; an enqueue at or after the last record does.
    try f.home.append("projects/p/s.jsonl", queueLine("a1", at: f.at(10), operation: "dequeue")
                      + queueLine("a1", at: f.at(10), operation: "remove"))
    #expect(f.running(tracker).map(\.id) == ["a1"])
    try f.home.append("projects/p/s.jsonl", queueLine("a1", at: f.at(10)))
    #expect(f.running(tracker).isEmpty)
    // Resumed (SendMessage): records after the notification.
    try f.append("a1", userLine(f.at(20), "more"),
                 assistantLine(f.at(21), stop: "tool_use", block: toolUse("Grep", ["pattern": "TODO"])))
    let resumed = f.running(tracker)
    #expect(resumed.map(\.id) == ["a1"])
    #expect(resumed.first?.activity == "Grep TODO")
}

@Test func trackerSkipsAgentsWrittenBeforeProcessStart() throws {
    let f = try AgentFixture()
    try f.write("old", meta: metaJSON(), userLine(f.at(0)))
    try f.write("new", meta: metaJSON(), userLine(f.at(0)))
    let old = f.home.url.appendingPathComponent(f.agentPath("old")).path
    try FileManager.default.setAttributes([.modificationDate: f.processStart.addingTimeInterval(-10)], ofItemAtPath: old)
    #expect(f.running(SubagentTracker()).map(\.id) == ["new"])
}

@Test func metaRewriteStoppedByUserFinishesAgent() throws {
    let f = try AgentFixture()
    let tracker = SubagentTracker()
    try f.write("a1", meta: metaJSON(description: "work"), userLine(f.at(0)))
    #expect(f.running(tracker).map(\.id) == ["a1"])
    try f.home.write(f.agentPath("a1", "meta.json"), metaJSON(description: "work", stopped: true))
    #expect(f.running(tracker).isEmpty)
}

@Test func foregroundAndStaleRules() {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    var tail = AgentTail()
    AgentTail.apply(Data(assistantLine(t, stop: "tool_use", block: toolUse("Read", ["file_path": "/a"])).utf8), to: &tail)
    func finished(_ meta: SubagentMeta, _ status: SessionStatus, after: TimeInterval = 5) -> Bool {
        SubagentRules.isFinished(meta: meta, tail: tail, lastWrite: t, notifiedAt: nil,
                                 parentStatus: status, now: t.addingTimeInterval(after), staleAfter: 600)
    }
    let fg = SubagentMeta(agentType: "Explore", requestShape: "foreground")
    let bg = SubagentMeta(agentType: "Explore", requestShape: "background")
    let nestedFG = SubagentMeta(agentType: "Explore", parentAgentId: "p", requestShape: "foreground")
    #expect(finished(fg, .idle))
    #expect(!finished(fg, .waiting))  // its permission prompt
    #expect(!finished(fg, .busy))
    #expect(!finished(nestedFG, .idle))  // decided by its parent agent
    #expect(!finished(bg, .idle))
    #expect(finished(bg, .idle, after: 601))
    #expect(finished(bg, .waiting, after: 601))
    #expect(!finished(bg, .busy, after: 3600))
    #expect(finished(SubagentMeta(stoppedByUser: true), .busy))
    // A notification before the last record doesn't finish it.
    #expect(!SubagentRules.isFinished(meta: bg, tail: tail, lastWrite: t, notifiedAt: t.addingTimeInterval(-1),
                                      parentStatus: .busy, now: t, staleAfter: 600))
}

@Test func trackerNestsChildrenUnderRunningParents() throws {
    let f = try AgentFixture()
    let tracker = SubagentTracker()
    let working = toolUse("Agent", ["description": "Dig deeper"])
    try f.write("p1", meta: metaJSON("Plan", description: "plan"), userLine(f.at(0)),
                assistantLine(f.at(1), stop: "tool_use", block: working))
    try f.write("c1", meta: metaJSON("Explore", description: "dig", parent: "p1"), userLine(f.at(2)),
                assistantLine(f.at(3), stop: "tool_use", block: toolUse("Glob", ["pattern": "**/*.swift"])))
    try f.write("f1", meta: metaJSON("Explore", description: "fg", parent: "p1", shape: "foreground"),
                userLine(f.at(2)))
    try f.write("r2", meta: metaJSON("Explore", description: "other"), userLine(f.at(4)))
    let first = f.running(tracker)
    #expect(first.map(\.id).filter { $0 != "f1" && $0 != "c1" } == ["p1", "r2"])
    #expect(Set(first.prefix(3).map(\.id)) == ["p1", "c1", "f1"])
    #expect(first.first { $0.id == "c1" }?.depth == 1)
    #expect(first.first { $0.id == "c1" }?.parentID == "p1")
    #expect(first.first { $0.id == "p1" }?.activity == "Agent Dig deeper")

    // The parent ends: its background child becomes a root; its foreground child is done.
    try f.append("p1", assistantLine(f.at(5), stop: "end_turn", block: ["type": "text", "text": "ok"]))
    let second = f.running(tracker)
    #expect(Set(second.map(\.id)) == ["c1", "r2"])
    #expect(second.allSatisfy { $0.depth == 0 })

    // The child's notification lands in the parent agent's jsonl.
    try f.append("p1", queuedCommandLine("c1", at: f.at(6)))
    #expect(f.running(tracker).map(\.id) == ["r2"])
}

@Test func subagentTreeOrdersByStartAndKeepsOrphansAsRoots() {
    func info(_ id: String, _ parent: String?, _ start: TimeInterval) -> SubagentInfo {
        SubagentInfo(id: id, parentID: parent, agentType: "x", label: id,
                     startedAt: Date(timeIntervalSince1970: start), lastActivityAt: .distantPast)
    }
    let tree = SubagentTracker.tree([
        info("b", nil, 2), info("a", nil, 1), info("a2", "a", 4), info("a1", "a", 3),
        info("a1x", "a1", 5), info("orphan", "gone", 0), info("same", nil, 1),
    ])
    #expect(tree.map(\.id) == ["orphan", "a", "a1", "a1x", "a2", "same", "b"])
    #expect(tree.map(\.depth) == [0, 0, 1, 2, 1, 0, 0])
}

@Test func parentTranscriptIndexFollowsAppendsAndRewrites() throws {
    let f = try AgentFixture()
    // Tiny chunks: lines straddle chunk boundaries.
    let tracker = SubagentTracker(chunkBytes: 64)
    try f.write("a1", meta: metaJSON(), userLine(f.at(0)),
                assistantLine(f.at(1), stop: "tool_use", block: toolUse("Read", ["file_path": "/a"])))
    try f.write("a2", meta: metaJSON(), userLine(f.at(0)),
                assistantLine(f.at(1), stop: "tool_use", block: toolUse("Read", ["file_path": "/b"])))
    var filler = ""
    for i in 0..<20 { filler += json(["type": "user", "n": i, "pad": String(repeating: "x", count: 50)]) + "\n" }
    try f.home.write("projects/p/s.jsonl", filler + queueLine("a1", at: f.at(2)) + filler)
    #expect(f.running(tracker).map(\.id) == ["a2"])

    // Appended (in two writes: a partial line first).
    let line = queueLine("a2", at: f.at(2))
    let cut = line.index(line.startIndex, offsetBy: 30)
    try f.home.append("projects/p/s.jsonl", String(line[..<cut]))
    #expect(f.running(tracker).map(\.id) == ["a2"])
    try f.home.append("projects/p/s.jsonl", String(line[cut...]))
    #expect(f.running(tracker).isEmpty)

    // Replaced by a new file without the notifications: nothing stale survives.
    let url = f.transcript
    try FileManager.default.removeItem(at: url)
    try f.home.write("projects/p/s.jsonl", filler)
    #expect(f.running(tracker).map(\.id).sorted() == ["a1", "a2"])

    // Truncated in place (same inode, smaller): re-indexed.
    try f.home.write("projects/p/s.jsonl", filler + filler + queueLine("a2", at: f.at(2)))
    #expect(f.running(tracker).map(\.id) == ["a1"])
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data(queueLine("a1", at: f.at(2)).utf8))
    try handle.close()
    #expect(f.running(tracker).map(\.id) == ["a2"])
}

@Test func trackerRetailsLargeAppendsAndSurvivesGiantLines() throws {
    let f = try AgentFixture()
    let tracker = SubagentTracker(tailBytes: 1024)
    var text = userLine(f.at(0))
    for i in 0..<40 { text += userLine(f.at(1), "filler \(i) " + String(repeating: "y", count: 60)) }
    text += assistantLine(f.at(2), stop: "tool_use", block: toolUse("Edit", ["file_path": "/p/Bar.swift"]))
    try f.write("a1", meta: metaJSON(), text)
    let first = try #require(f.running(tracker).first)
    #expect(first.activity == "Edit Bar.swift")
    #expect(first.lastActivityAt == Date(timeIntervalSince1970: f.at(2).timeIntervalSince1970.rounded(.down)))

    // One line bigger than the tail: no complete line to parse; mtime stands in, activity stays.
    try f.append("a1", userLine(f.at(3), String(repeating: "z", count: 4096)))
    let mtime = try #require(try FileManager.default.attributesOfItem(
        atPath: f.home.url.appendingPathComponent(f.agentPath("a1")).path)[.modificationDate] as? Date)
    let second = try #require(f.running(tracker).first)
    #expect(second.activity == "Edit Bar.swift")
    #expect(second.lastActivityAt == Date(timeIntervalSince1970: mtime.timeIntervalSince1970.rounded(.down)))

    // Lines after it parse again, incrementally.
    try f.append("a1", assistantLine(f.at(4), stop: "tool_use", block: toolUse("WebSearch", ["query": "swift"])))
    #expect(f.running(tracker).first?.activity == "WebSearch swift")
}

@Test func trackerIgnoresOtherFilesAndAcceptsAnyAgentID() throws {
    let f = try AgentFixture()
    let id = "ai-cant-rememeber-7816966e49beba7f"
    try f.write(id, meta: metaJSON("fork", description: "forked"), userLine(f.at(0)))
    try f.home.write("projects/p/s/subagents/agent-\(id).forked-skill.json", "{}")
    try f.home.write("projects/p/s/subagents/agent-x.forked-skill.marker.json", "{}")
    try f.home.write("projects/p/s/subagents/notes.jsonl", userLine(f.at(0)))
    #expect(f.running(SubagentTracker()).map(\.id) == [id])
    #expect(SubagentTracker.agentID(fileName: "agent-a1.jsonl") == "a1")
    #expect(SubagentTracker.agentID(fileName: "agent-a1.meta.json") == nil)
    #expect(SubagentTracker.agentID(fileName: "agent-.jsonl") == nil)

    // No subagents dir at all.
    let empty = try AgentFixture()
    #expect(empty.running(SubagentTracker()).isEmpty)
}

@Test func activityLabels() {
    func label(_ tool: String, _ input: [String: Any]) -> String { SubagentActivity.label(tool: tool, input: input) }
    #expect(label("Read", ["file_path": "/a/b/Foo.swift"]) == "Read Foo.swift")
    #expect(label("Edit", ["file_path": "/a/Bar.swift"]) == "Edit Bar.swift")
    #expect(label("Write", ["file_path": "/a/new.txt"]) == "Write new.txt")
    #expect(label("NotebookEdit", ["notebook_path": "/n/x.ipynb"]) == "NotebookEdit x.ipynb")
    #expect(label("Grep", ["pattern": "TODO|FIXME"]) == "Grep TODO|FIXME")
    #expect(label("Glob", ["pattern": "**/*.swift"]) == "Glob **/*.swift")
    #expect(label("Bash", ["command": "make test", "description": "Run the tests"]) == "Bash Run the tests")
    #expect(label("Bash", ["command": "cd /x &&\n  make test\nmore"]) == "Bash cd /x &&")
    #expect(label("Agent", ["description": "Map the code"]) == "Agent Map the code")
    #expect(label("Task", ["description": "Old name"]) == "Task Old name")
    #expect(label("WebFetch", ["url": "https://docs.example.com/a/b?q=1"]) == "WebFetch docs.example.com")
    #expect(label("WebSearch", ["query": "swift  testing\nparallel"]) == "WebSearch swift testing parallel")
    #expect(label("TodoWrite", ["todos": []]) == "TodoWrite")
    #expect(label("Read", [:]) == "Read")
    let long = label("Grep", ["pattern": String(repeating: "a", count: 100)])
    #expect(long.count == 60 && long.hasSuffix("…"))
    #expect(SubagentActivity.label(block: ["type": "thinking", "thinking": ""]) == "thinking")
    #expect(SubagentActivity.label(block: ["type": "text", "text": "hi"]) == "responding")
    #expect(SubagentActivity.label(block: ["type": "image"]) == nil)
    #expect(SubagentActivity.label(block: toolUse("Read", ["file_path": "/x/y.md"])) == "Read y.md")
}
