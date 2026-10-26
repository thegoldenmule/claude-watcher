import Foundation

/// `<sid>/subagents/agent-<id>.meta.json`, written at launch and rewritten later
/// (`stoppedByUser` when the user stops the agent). Every field is optional on disk.
struct SubagentMeta: Decodable, Equatable {
    var agentType: String?
    var description: String?
    var name: String?
    var parentAgentId: String?
    var spawnDepth: Int?
    var requestShape: String?        // "background" | "foreground"
    var stoppedByUser: Bool?

    var isBackground: Bool { requestShape == "background" }
}

/// A `<task-notification>` for an agent: when it was enqueued, and whether the agent stopped
/// "with background work of its own still running" (parked: it's still alive and resumes when
/// that work reports; Claude Code notifies again then).
struct SubagentNotice: Equatable {
    var at: Date
    var parked = false

    /// The later of two notices for the same agent.
    static func latest(_ a: SubagentNotice, _ b: SubagentNotice) -> SubagentNotice { b.at > a.at ? b : a }
}

/// What an agent's jsonl tail says, "last wins" across reads.
struct AgentTail: Equatable {
    var lastRecordAt: Date?
    /// `message.stop_reason` of the last assistant record (nil while streaming or mid-tool).
    var lastAssistantStop: String?
    /// A user record follows the last assistant record (a tool result, or a SendMessage resume).
    var userAfterLastAssistant = false
    /// The last user/assistant record is "[Request interrupted by user…]": a stopped or failed
    /// agent writes it just after its notification is enqueued.
    var interrupted = false
    var activity: String?
    /// Label of the last tool call it ran with `run_in_background` (what a parked agent waits on).
    var backgroundLaunch: String?
    /// task-id -> notice, from `queued_command` attachments: finished children of this agent.
    var notifications: [String: SubagentNotice] = [:]

    /// Applies the complete JSONL lines in `data`, in file order. Malformed lines are skipped.
    static func apply(_ data: Data, to tail: inout AgentTail) {
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let at = (obj["timestamp"] as? String).flatMap(SubagentRules.date)
            if let at { tail.lastRecordAt = at }
            switch obj["type"] as? String {
            case "assistant":
                let message = obj["message"] as? [String: Any]
                // Streaming blocks carry a null stop_reason; the message's last block the real one.
                tail.lastAssistantStop = message?["stop_reason"] as? String
                tail.userAfterLastAssistant = false
                tail.interrupted = false
                if let blocks = message?["content"] as? [[String: Any]],
                   let label = blocks.lazy.reversed().compactMap(SubagentActivity.label(block:)).first {
                    tail.activity = label
                }
                for block in message?["content"] as? [[String: Any]] ?? []
                where block["type"] as? String == "tool_use"
                    && (block["input"] as? [String: Any])?["run_in_background"] as? Bool == true {
                    tail.backgroundLaunch = SubagentActivity.label(block: block)
                }
            case "user":
                tail.userAfterLastAssistant = true
                let content = (obj["message"] as? [String: Any])?["content"]
                tail.interrupted = SubagentRules.text(content)?.hasPrefix("[Request interrupted by user") == true
            case "attachment":
                guard let attachment = obj["attachment"] as? [String: Any],
                      attachment["type"] as? String == "queued_command",
                      let text = SubagentRules.text(attachment["prompt"]),
                      let id = SubagentRules.finishedTaskID(in: text),
                      let at = at ?? (attachment["timestamp"] as? String).flatMap(SubagentRules.date)
                else { break }
                let notice = SubagentNotice(at: at, parked: SubagentRules.isParked(text))
                tail.notifications[id] = tail.notifications[id].map { .latest($0, notice) } ?? notice
            default:
                break
            }
        }
    }
}

/// Short "what is it doing" labels from assistant content blocks.
enum SubagentActivity {
    static let maxLength = 60

    /// "Read Foo.swift", "Grep TODO", "Bash Run the tests", "WebFetch example.com", …
    static func label(tool: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? {
            guard let s = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }
        let detail: String?
        switch tool {
        case "Read", "Edit", "Write", "NotebookEdit":
            detail = (string("file_path") ?? string("notebook_path")).map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob":
            detail = string("pattern")
        case "Bash":
            detail = string("description")
                ?? string("command")?.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        case "Agent", "Task":
            detail = string("description")
        case "WebFetch":
            detail = string("url").flatMap { URL(string: $0)?.host() } ?? string("url")
        case "WebSearch":
            detail = string("query")
        default:
            detail = nil
        }
        return clip(detail.map { "\(tool) \($0)" } ?? tool)
    }

    /// The label of one content block: tool_use -> tool label, thinking -> "thinking",
    /// text -> "responding"; nil for anything else.
    static func label(block: [String: Any]) -> String? {
        switch block["type"] as? String {
        case "tool_use":
            guard let name = block["name"] as? String, !name.isEmpty else { return nil }
            return label(tool: name, input: block["input"] as? [String: Any] ?? [:])
        case "thinking", "redacted_thinking":
            return "thinking"
        case "text":
            return "responding"
        default:
            return nil
        }
    }

    /// Newlines and runs of whitespace collapsed to one space; at most `maxLength` characters.
    static func clip(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > maxLength else { return flat }
        return String(flat.prefix(maxLength - 1)) + "…"
    }
}

enum SubagentRules {
    /// `stop_reason`s that end an agent's turn; null, tool_use and pause_turn mean it's still going.
    static let terminalStops: Set<String> = ["end_turn", "stop_sequence", "max_tokens"]

    /// Whether an agent is done. Any of:
    /// 1. the user stopped it (meta rewritten with `stoppedByUser`);
    /// 2. a "finished" notification at or after its last record (a SendMessage resume writes
    ///    new records after the notification), unless it says the agent is parked: then it's
    ///    running (waiting on its own background work) until `parkedStaleAfter` without activity
    ///    while the session isn't busy, and rules 3-5 don't apply;
    /// 3. its last assistant message ended the turn and no user record (resume) followed, or its
    ///    last record is an interruption (written just after a "failed" notification);
    /// 4. a foreground root agent while the session is idle (a foreground agent blocks its
    ///    session, so an idle prompt means it returned; `.waiting` may be its permission prompt).
    ///    Nested foreground agents are decided by their parent agent (`SubagentTracker`);
    /// 5. stale: no activity for `staleAfter` while the session isn't busy (killed with the
    ///    process before it could write anything final).
    static func isFinished(
        meta: SubagentMeta?, tail: AgentTail, lastWrite: Date, notifiedAt: Date?, parked: Bool = false,
        parentStatus: SessionStatus, now: Date, staleAfter: TimeInterval,
        parkedStaleAfter: TimeInterval = defaultParkedStaleAfter
    ) -> Bool {
        if meta?.stoppedByUser == true { return true }
        let lastActivity = tail.lastRecordAt ?? lastWrite
        if let notifiedAt, notifiedAt >= lastActivity {
            guard parked else { return true }
            return parentStatus != .busy && now.timeIntervalSince(lastActivity) > parkedStaleAfter
        }
        if let stop = tail.lastAssistantStop, terminalStops.contains(stop), !tail.userAfterLastAssistant {
            return true
        }
        if tail.interrupted { return true }
        let isBackground = meta?.isBackground ?? true
        if !isBackground, meta?.parentAgentId == nil, parentStatus == .idle { return true }
        if parentStatus != .busy, now.timeIntervalSince(lastActivity) > staleAfter { return true }
        return false
    }

    /// A parked agent may wait hours on CI or a training run, and ends only with a later
    /// notification or its session's exit; this is just a backstop.
    static let defaultParkedStaleAfter: TimeInterval = 24 * 60 * 60

    /// Whether an agent is done, from rules that need no file contents: stopped by the user, or
    /// no write for `parkedStaleAfter` while the session isn't busy. True here implies
    /// `isFinished` with any tail and notice (a last record is never later than the mtime).
    static func isFinishedUnread(meta: SubagentMeta?, lastWrite: Date, parentStatus: SessionStatus,
                                 now: Date, parkedStaleAfter: TimeInterval) -> Bool {
        meta?.stoppedByUser == true
            || (parentStatus != .busy && now.timeIntervalSince(lastWrite) > parkedStaleAfter)
    }

    /// The notification says the agent stopped with background work of its own still running.
    static func isParked(_ text: String) -> Bool {
        text.contains("background work of its own still running")
    }

    /// A parent-transcript line `{"type":"queue-operation","operation":"enqueue",…}` whose
    /// content is a `<task-notification>` with a `<status>`: (task id = agent id, enqueue time).
    /// dequeue/remove lines, agent hand-back messages and status-less (Monitor) events: nil.
    static func parseNotification(_ line: Data) -> (taskID: String, at: Date, parked: Bool)? {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              obj["type"] as? String == "queue-operation",
              obj["operation"] as? String == "enqueue",
              let content = text(obj["content"]),
              let id = finishedTaskID(in: content),
              let at = (obj["timestamp"] as? String).flatMap(date)
        else { return nil }
        return (id, at, isParked(content))
    }

    /// The `<task-id>` of a `<task-notification>` that carries a `<status>`, else nil.
    static func finishedTaskID(in text: String) -> String? {
        guard text.contains("<task-notification>"), text.contains("<status>"),
              let open = text.range(of: "<task-id>"),
              let close = text.range(of: "</task-id>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let id = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// A string, or the concatenated `text` of an array of content blocks.
    static func text(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let blocks = any as? [[String: Any]] {
            let joined = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// "2026-10-26T15:30:11.463Z" (fractional seconds optional).
    static func date(_ s: String) -> Date? {
        (try? fractional.parse(s)) ?? (try? whole.parse(s))
    }
}

/// Finds a session's running subagents: `<transcript minus .jsonl>/subagents/agent-<id>.jsonl`
/// (+ `.meta.json`), judged by `SubagentRules.isFinished`.
///
/// Cheap on repeat calls: the listing is cached on the directory's mtime, meta on its stat,
/// and an agent's jsonl is read only when its stat changes (just the appended lines, or a
/// fresh `tailBytes` tail). Files last written before the session's process started are never
/// opened (long or resumed sessions keep hundreds of old agents). The parent transcript's
/// notifications are indexed only once some agent was written recently enough to be running.
/// Not thread-safe; owned by `SessionDiscovery`.
final class SubagentTracker {
    private struct FileStat: Equatable {
        var inode: UInt64
        var size: UInt64
        var mtime: Date
        var birthtime: Date
    }

    private struct Agent {
        var stat: FileStat
        var startedAt: Date            // birthtime on first sight, floored
        var metaStat: FileStat?
        var meta: SubagentMeta?
        /// Stat of the jsonl when the tail was last brought up to date; nil = never read.
        var tailStat: FileStat?
        /// Offset just past the last complete line applied.
        var consumed: UInt64 = 0
        var tail = AgentTail()
    }

    private struct NotificationIndex {
        var inode: UInt64
        var consumed: UInt64
        var times: [String: SubagentNotice]
    }

    private struct State {
        var listingMtime: Date?
        var ids: [String] = []
        var agents: [String: Agent] = [:]
        var index: NotificationIndex?
    }

    let tailBytes: UInt64
    let staleAfter: TimeInterval
    let parkedStaleAfter: TimeInterval
    /// Chunk size for indexing the parent transcript.
    let chunkBytes: Int
    private var states: [String: State] = [:]

    init(tailBytes: UInt64 = 64 * 1024, staleAfter: TimeInterval = 10 * 60,
         parkedStaleAfter: TimeInterval = SubagentRules.defaultParkedStaleAfter, chunkBytes: Int = 1024 * 1024) {
        self.tailBytes = tailBytes
        self.staleAfter = staleAfter
        self.parkedStaleAfter = parkedStaleAfter
        self.chunkBytes = chunkBytes
    }

    func forget(except transcriptPaths: Set<String>) {
        states = states.filter { transcriptPaths.contains($0.key) }
    }

    /// The running subagents of the session whose transcript is `transcript`, in pre-order:
    /// by (startedAt, id), each child right under its running parent (depth = parent + 1);
    /// a child whose parent isn't running is a root.
    func running(transcript: URL, processStart: Date, parentStatus: SessionStatus,
                 now: Date = Date()) -> [SubagentInfo] {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        var state = states[transcript.path] ?? State()
        defer { states[transcript.path] = state }

        guard let dirStat = Self.fileStat(dir.path) else {
            state = State()
            return []
        }
        if state.listingMtime != dirStat.mtime {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            state.ids = names.compactMap(Self.agentID(fileName:))
            state.listingMtime = dirStat.mtime
        }

        // Candidates: written since the process started.
        let cutoff = processStart.addingTimeInterval(-ProcessRules.startTolerance)
        var agents: [String: Agent] = [:]
        for id in state.ids {
            let base = dir.appendingPathComponent("agent-\(id)").path
            guard let stat = Self.fileStat(base + ".jsonl"), stat.mtime >= cutoff else { continue }
            var agent: Agent
            if let cached = state.agents[id], cached.stat.inode == stat.inode {
                agent = cached
                agent.stat = stat
            } else {
                agent = Agent(stat: stat, startedAt: Self.floor(stat.birthtime))
            }
            let metaStat = Self.fileStat(base + ".meta.json")
            if metaStat != agent.metaStat {
                agent.metaStat = metaStat
                agent.meta = metaStat == nil ? nil
                    : (try? Data(contentsOf: URL(fileURLWithPath: base + ".meta.json")))
                        .flatMap { try? JSONDecoder().decode(SubagentMeta.self, from: $0) }
            }
            agents[id] = agent
        }

        func finished(_ id: String, notice: SubagentNotice?) -> Bool {
            let a = agents[id]!
            return SubagentRules.isFinished(
                meta: a.meta, tail: a.tail, lastWrite: a.stat.mtime, notifiedAt: notice?.at,
                parked: notice?.parked ?? false, parentStatus: parentStatus, now: now,
                staleAfter: staleAfter, parkedStaleAfter: parkedStaleAfter)
        }
        func refreshTail(_ id: String) {
            guard var a = agents[id] else { return }
            refresh(&a, path: dir.appendingPathComponent("agent-\(id).jsonl").path)
            agents[id] = a
        }

        // 1. Rules that need no file contents.
        var undecided = agents.keys.filter { id in
            !SubagentRules.isFinishedUnread(meta: agents[id]!.meta, lastWrite: agents[id]!.stat.mtime,
                                            parentStatus: parentStatus, now: now,
                                            parkedStaleAfter: parkedStaleAfter)
        }
        // 2. The tails (and the parent agents' tails, whose queued_commands notify children).
        for id in undecided { refreshTail(id) }
        for id in undecided { if let p = agents[id]?.meta?.parentAgentId, agents[p] != nil { refreshTail(p) } }
        var notices: [String: SubagentNotice] = [:]
        for a in agents.values where a.tailStat != nil {
            notices.merge(a.tail.notifications, uniquingKeysWith: SubagentNotice.latest)
        }
        // 3. The parent transcript's notifications. Needed even for a tail that ended its turn:
        // a parked notice there keeps it running.
        if !undecided.isEmpty {
            updateIndex(&state, transcript: transcript.path)
            notices.merge(state.index?.times ?? [:], uniquingKeysWith: SubagentNotice.latest)
            undecided = undecided.filter { !finished($0, notice: notices[$0]) }
        }
        state.agents = agents

        // A nested foreground agent blocks its parent agent: done once the parent is.
        var running = Set(undecided)
        var changed = true
        while changed {
            changed = false
            for id in running {
                guard let meta = agents[id]?.meta, !meta.isBackground, let parent = meta.parentAgentId,
                      !running.contains(parent)
                else { continue }
                running.remove(id)
                changed = true
            }
        }
        return Self.tree(running.map { id in
            let a = agents[id]!
            let type = SessionTitle.nonEmpty(a.meta?.agentType) ?? "agent"
            // Running past its own "finished" notice: parked on its background work.
            let parked = notices[id].map { $0.parked && $0.at >= (a.tail.lastRecordAt ?? a.stat.mtime) } ?? false
            return SubagentInfo(
                id: id,
                parentID: SessionTitle.nonEmpty(a.meta?.parentAgentId),
                agentType: type,
                label: SessionTitle.nonEmpty(a.meta?.description) ?? SessionTitle.nonEmpty(a.meta?.name) ?? type,
                activity: parked
                    ? SubagentActivity.clip("waiting on " + (a.tail.backgroundLaunch ?? "background work"))
                    : a.tail.activity,
                isBackground: a.meta?.isBackground ?? true,
                startedAt: a.startedAt,
                lastActivityAt: Self.floor(a.tail.lastRecordAt ?? a.stat.mtime))
        })
    }

    /// Pre-order by (startedAt, id); children under a parent in `agents`, else roots.
    static func tree(_ agents: [SubagentInfo]) -> [SubagentInfo] {
        let ids = Set(agents.map(\.id))
        var children: [String: [SubagentInfo]] = [:]
        var roots: [SubagentInfo] = []
        for a in agents {
            if let p = a.parentID, p != a.id, ids.contains(p) {
                children[p, default: []].append(a)
            } else {
                roots.append(a)
            }
        }
        func sorted(_ list: [SubagentInfo]) -> [SubagentInfo] {
            list.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        }
        var out: [SubagentInfo] = []
        var visited: Set<String> = []
        func visit(_ a: SubagentInfo, depth: Int) {
            guard visited.insert(a.id).inserted else { return }
            var a = a
            a.depth = depth
            out.append(a)
            for c in sorted(children[a.id] ?? []) { visit(c, depth: depth + 1) }
        }
        for r in sorted(roots) { visit(r, depth: 0) }
        return out
    }

    /// "agent-<id>.jsonl" -> id; nil for meta files and anything else.
    static func agentID(fileName name: String) -> String? {
        guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { return nil }
        let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
        return id.isEmpty ? nil : id
    }

    // MARK: - Agent tails

    /// Brings `agent.tail` up to the jsonl's current stat: only appended complete lines when
    /// that's at most `tailBytes`, else a fresh tail of the last `tailBytes` (over the old tail
    /// for the same inode). No complete line in a fresh tail (one giant line): mtime stands in
    /// for the last record, the previous activity is kept.
    private func refresh(_ agent: inout Agent, path: String) {
        let stat = agent.stat
        if agent.tailStat == stat { return }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        if let old = agent.tailStat, old.inode == stat.inode, stat.size >= agent.consumed,
           stat.size - agent.consumed <= tailBytes {
            if stat.size > agent.consumed,
               let data = Self.read(handle, offset: agent.consumed, length: stat.size - agent.consumed),
               let lastNL = data.lastIndex(of: 0x0A) {
                let end = data.index(after: lastNL)
                AgentTail.apply(data.subdata(in: data.startIndex..<end), to: &agent.tail)
                agent.consumed += UInt64(end - data.startIndex)
            }
            agent.tailStat = stat
            return
        }
        var tail = agent.tailStat?.inode == stat.inode ? agent.tail : AgentTail()
        let start = stat.size > tailBytes ? stat.size - tailBytes : 0
        guard var data = Self.read(handle, offset: start, length: stat.size - start) else { return }
        var lineStart = start
        if start > 0 {
            if let nl = data.firstIndex(of: 0x0A) {
                let cut = data.index(after: nl)
                lineStart = start + UInt64(cut - data.startIndex)
                data = data.subdata(in: cut..<data.endIndex)
            } else {
                data = Data()
                lineStart = stat.size
            }
        }
        var consumed = lineStart
        if let lastNL = data.lastIndex(of: 0x0A) {
            let end = data.index(after: lastNL)
            consumed = lineStart + UInt64(end - data.startIndex)
            AgentTail.apply(data.subdata(in: data.startIndex..<end), to: &tail)
        } else {
            tail.lastRecordAt = stat.mtime
        }
        agent.tail = tail
        agent.consumed = consumed
        agent.tailStat = stat
    }

    // MARK: - Parent transcript notifications

    private let queueMarker = Data("\"queue-operation\"".utf8)
    private let taskIDMarker = Data("<task-id>".utf8)

    /// Indexes the transcript's enqueue notifications: the whole file once (streamed in
    /// `chunkBytes` chunks, decoding only lines with both markers), then appended lines.
    /// A new inode or a shrunken file is re-indexed from scratch.
    private func updateIndex(_ state: inout State, transcript path: String) {
        guard let stat = Self.fileStat(path) else {
            state.index = nil
            return
        }
        var index = state.index ?? NotificationIndex(inode: stat.inode, consumed: 0, times: [:])
        if index.inode != stat.inode || stat.size < index.consumed {
            index = NotificationIndex(inode: stat.inode, consumed: 0, times: [:])
        }
        defer { state.index = index }
        guard stat.size > index.consumed, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var offset = index.consumed
        var carry = Data()  // the partial line at the end of the previous chunk
        while offset < stat.size {
            let length = min(UInt64(chunkBytes), stat.size - offset)
            guard let chunk = Self.read(handle, offset: offset, length: length), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            var buffer = carry
            buffer.append(chunk)
            guard let lastNL = buffer.lastIndex(of: 0x0A) else {
                carry = buffer
                continue
            }
            let end = buffer.index(after: lastNL)
            Self.forEachLine(in: buffer[buffer.startIndex..<end], containing: queueMarker) { line in
                guard line.range(of: taskIDMarker) != nil,
                      let (id, at, parked) = SubagentRules.parseNotification(Data(line)) else { return }
                let notice = SubagentNotice(at: at, parked: parked)
                index.times[id] = index.times[id].map { .latest($0, notice) } ?? notice
            }
            index.consumed += UInt64(end - buffer.startIndex)
            carry = buffer.subdata(in: end..<buffer.endIndex)
        }
    }

    /// Calls `body` once per line of `buffer` holding `marker`, found with a byte search so the
    /// rest of the buffer is never split or decoded.
    static func forEachLine(in buffer: Data, containing marker: Data, _ body: (Data) -> Void) {
        var from = buffer.startIndex
        while from < buffer.endIndex, let hit = buffer.range(of: marker, in: from..<buffer.endIndex) {
            let lineStart = buffer[buffer.startIndex..<hit.lowerBound].lastIndex(of: 0x0A)
                .map { buffer.index(after: $0) } ?? buffer.startIndex
            let lineEnd = buffer[hit.upperBound...].firstIndex(of: 0x0A) ?? buffer.endIndex
            body(buffer.subdata(in: lineStart..<lineEnd))
            from = lineEnd
        }
    }

    // MARK: - IO

    private static func fileStat(_ path: String) -> FileStat? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        func date(_ ts: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
        }
        return FileStat(inode: UInt64(st.st_ino), size: UInt64(max(0, st.st_size)),
                        mtime: date(st.st_mtimespec), birthtime: date(st.st_birthtimespec))
    }

    private static func read(_ handle: FileHandle, offset: UInt64, length: UInt64) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: Int(length)) ?? Data()
        } catch {
            return nil
        }
    }

    private static func floor(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
