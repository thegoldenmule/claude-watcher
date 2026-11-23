import Foundation

/// A background shell the main conversation launched and that hasn't ended yet.
struct ShellLaunch: Equatable {
    var label: String
    var command: String?
    var at: Date
}

/// Incremental index of a session transcript's background-task records: the agents' "finished"
/// notifications (`SubagentTracker`) and the main conversation's background shells.
///
/// The whole file is indexed once (streamed in chunks, decoding only lines that hold a marker),
/// then only appended lines. A new inode or a shrunken file is re-indexed from scratch.
///
/// Background shells (Claude Code 2.1.330): a Bash `tool_use` (`run_in_background`, or a
/// foreground command that timed out or that the user backgrounded), then its `tool_result`
/// user record whose `toolUseResult.backgroundTaskId` names the task. It ends with a
/// `<task-notification>` for that task id (`<status>` completed/failed/killed) in a
/// `queue-operation` (enqueue or remove), a `queued_command` attachment, or (parked `bg`
/// sessions, which may write no queue record) a `user` record with `origin.kind`
/// "task-notification" whose content is the notification; or with a TaskStop result
/// (`toolUseResult.task_id`, message "Successfully stopped task…").
struct TranscriptTaskIndex: Equatable {
    struct BashCall: Equatable {
        var toolUseID: String
        var label: String
        var command: String?
    }

    var inode: UInt64
    var consumed: UInt64 = 0
    /// task id -> latest enqueued `<task-notification>` (agents' finished notices).
    var notices: [String: SubagentNotice] = [:]
    /// task id -> a background shell launched and not ended.
    var shells: [String: ShellLaunch] = [:]
    /// Task ids whose end was seen, so a launch recorded after its end isn't revived.
    var ended: Set<String> = []
    /// Task ids with an enqueued notice. A delivered user record's later time is used only for
    /// ids without one (parked `bg` sessions): delivery can lag the enqueue by seconds, past an
    /// agent's resume.
    var enqueued: Set<String> = []
    /// The latest Bash calls, so a result that went to the background finds its call (results
    /// follow their call within a few lines; parallel calls interleave a little).
    var recentBash: [BashCall] = []
    static let recentBashLimit = 64

    init(inode: UInt64) {
        self.inode = inode
    }

    private static let markers = [
        "\"queue-operation\"", "\"queued_command\"", "\"backgroundTaskId\"", "\"name\":\"Bash\"",
        "Successfully stopped task", "\"kind\":\"task-notification\"",
    ].map { Data($0.utf8) }

    /// Brings the index up to the file at `path`; nil when the file is gone.
    static func updated(_ index: TranscriptTaskIndex?, path: String, chunkBytes: Int) -> TranscriptTaskIndex? {
        guard let stat = FileStat(path: path) else { return nil }
        var index = index ?? TranscriptTaskIndex(inode: stat.inode)
        if index.inode != stat.inode || stat.size < index.consumed {
            index = TranscriptTaskIndex(inode: stat.inode)
        }
        guard stat.size > index.consumed, let handle = FileHandle(forReadingAtPath: path) else { return index }
        defer { try? handle.close() }
        var offset = index.consumed
        var carry = Data()  // the partial line at the end of the previous chunk
        while offset < stat.size {
            let length = min(UInt64(chunkBytes), stat.size - offset)
            guard let chunk = FileStat.read(handle, offset: offset, length: length), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            var buffer = carry
            buffer.append(chunk)
            guard let lastNL = buffer.lastIndex(of: 0x0A) else {
                carry = buffer
                continue
            }
            let end = buffer.index(after: lastNL)
            for range in lines(in: buffer[buffer.startIndex..<end], containingAny: markers) {
                index.apply(line: buffer.subdata(in: range))
            }
            index.consumed += UInt64(end - buffer.startIndex)
            carry = buffer.subdata(in: end..<buffer.endIndex)
        }
        return index
    }

    /// Applies one transcript line. Lines without a relevant record change nothing.
    mutating func apply(line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let at = (obj["timestamp"] as? String).flatMap(SubagentRules.date)
        switch obj["type"] as? String {
        case "queue-operation":
            guard let content = SubagentRules.text(obj["content"]) else { return }
            for n in SubagentRules.finishedNotifications(in: content) { end(n.taskID) }
            if let notice = SubagentRules.notification(obj) {
                notices[notice.taskID] = notices[notice.taskID].map { .latest($0, notice.notice) } ?? notice.notice
                enqueued.insert(notice.taskID)
            }
        case "attachment":
            guard let attachment = obj["attachment"] as? [String: Any],
                  attachment["type"] as? String == "queued_command",
                  let text = SubagentRules.text(attachment["prompt"]) else { return }
            for n in SubagentRules.finishedNotifications(in: text) { end(n.taskID) }
        case "assistant":
            let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in blocks where block["type"] as? String == "tool_use" && block["name"] as? String == "Bash" {
                guard let id = block["id"] as? String else { continue }
                let (label, command) = BackgroundShellRules.label(input: block["input"] as? [String: Any] ?? [:])
                recentBash.append(BashCall(toolUseID: id, label: label, command: command))
            }
            if recentBash.count > Self.recentBashLimit {
                recentBash.removeFirst(recentBash.count - Self.recentBashLimit)
            }
        case "user":
            if (obj["origin"] as? [String: Any])?["kind"] as? String == "task-notification",
               let content = SubagentRules.text((obj["message"] as? [String: Any])?["content"]) {
                for n in SubagentRules.finishedNotifications(in: content) {
                    end(n.taskID)
                    guard let at, !enqueued.contains(n.taskID) else { continue }
                    let notice = SubagentNotice(at: at, parked: n.parked)
                    notices[n.taskID] = notices[n.taskID].map { .latest($0, notice) } ?? notice
                }
                return
            }
            guard let result = obj["toolUseResult"] as? [String: Any] else { return }
            if let taskID = SessionTitle.nonEmpty(result["backgroundTaskId"] as? String), !ended.contains(taskID) {
                let blocks = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let useID = blocks.first { $0["type"] as? String == "tool_result" }?["tool_use_id"] as? String
                let call = useID.flatMap { id in recentBash.last { $0.toolUseID == id } }
                shells[taskID] = ShellLaunch(
                    label: call?.label ?? "background command", command: call?.command, at: at ?? .distantPast)
            }
            if let stopped = SessionTitle.nonEmpty(result["task_id"] as? String),
               (result["message"] as? String)?.hasPrefix("Successfully stopped task") == true {
                end(stopped)
            }
        default:
            break
        }
    }

    private mutating func end(_ id: String) {
        shells[id] = nil
        ended.insert(id)
    }

    /// The ranges of the lines of `buffer` that hold any of `markers`, in file order, each once.
    /// Found with byte searches so the rest of the buffer is never split or decoded.
    static func lines(in buffer: Data, containingAny markers: [Data]) -> [Range<Data.Index>] {
        var ends: [Data.Index: Data.Index] = [:]  // line start -> line end
        for marker in markers {
            var from = buffer.startIndex
            while from < buffer.endIndex, let hit = buffer.range(of: marker, in: from..<buffer.endIndex) {
                let lineStart = buffer[buffer.startIndex..<hit.lowerBound].lastIndex(of: 0x0A)
                    .map { buffer.index(after: $0) } ?? buffer.startIndex
                let lineEnd = buffer[hit.upperBound...].firstIndex(of: 0x0A) ?? buffer.endIndex
                ends[lineStart] = lineEnd
                from = lineEnd
            }
        }
        return ends.keys.sorted().map { $0..<ends[$0]! }
    }
}

enum BackgroundShellRules {
    /// A Bash call's display label (its description, else its command's first line) and, when
    /// the label is the description, the command's first line. Both clipped.
    static func label(input: [String: Any]) -> (label: String, command: String?) {
        let description = SessionTitle.nonEmpty(input["description"] as? String)
        let command = (input["command"] as? String)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .lazy.compactMap { SessionTitle.nonEmpty(String($0)) }.first
        if let description { return (SubagentActivity.clip(description), command.map(SubagentActivity.clip)) }
        return (command.map(SubagentActivity.clip) ?? "background command", nil)
    }

    /// How long a running shell keeps an idle session busy. Most wait on CI or a build and
    /// end within minutes; one still running after this is likely a server (a dev server), and
    /// its session waits on the user: still listed, but shown stopped.
    static let busyWindow: TimeInterval = 60 * 60

    /// Whether `shell` still counts toward its idle session being busy.
    static func keepsBusy(_ shell: BackgroundShellInfo, now: Date) -> Bool {
        now.timeIntervalSince(shell.startedAt) <= busyWindow
    }

    /// The running shells: launched since the session's process started (Claude Code's
    /// background shells die with it) and not ended. A shell with no end record for
    /// `staleAfter` while the session isn't busy is dropped too: a backstop in case its end was
    /// never written (it may legitimately run that long, e.g. a dev server).
    static func running(_ shells: [String: ShellLaunch], processStart: Date, parentStatus: SessionStatus,
                        now: Date, staleAfter: TimeInterval) -> [BackgroundShellInfo] {
        let cutoff = processStart.addingTimeInterval(-ProcessRules.startTolerance)
        return shells
            .filter { _, s in
                s.at >= cutoff && !(parentStatus != .busy && now.timeIntervalSince(s.at) > staleAfter)
            }
            .map { id, s in
                BackgroundShellInfo(id: id, label: s.label, command: s.command,
                                    startedAt: Date(timeIntervalSince1970: s.at.timeIntervalSince1970.rounded(.down)))
            }
            .sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }
}

/// The stat fields the trackers key their caches on.
struct FileStat: Equatable {
    var inode: UInt64
    var size: UInt64
    var mtime: Date
    var birthtime: Date

    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        func date(_ ts: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000)
        }
        inode = UInt64(st.st_ino)
        size = UInt64(max(0, st.st_size))
        mtime = date(st.st_mtimespec)
        birthtime = date(st.st_birthtimespec)
    }

    static func read(_ handle: FileHandle, offset: UInt64, length: UInt64) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: Int(length)) ?? Data()
        } catch {
            return nil
        }
    }
}
