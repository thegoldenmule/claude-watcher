import Foundation

/// What a Codex rollout (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<local ts>-<thread id>.jsonl`)
/// tells us about its thread. Every line is `{"timestamp","ordinal","type","payload"}`.
///
/// Turn state: `event_msg` `task_started` opens a turn; `task_complete` / `turn_aborted` close
/// it. Approval requests are never persisted (that's what the Codex hook is for). Context:
/// the last `token_count`'s `info.last_token_usage.total_tokens` against
/// `info.model_context_window` (already the effective window, ~95% of the model's), the
/// numbers Codex's own "% context left" uses. A subagent's rollout starts with a copy of its
/// parent's history; only its last records matter here, and those are its own.
public struct CodexRolloutInfo: Equatable, Sendable {
    /// true while the last turn event is `task_started`; nil before any turn event is seen.
    public var turnActive: Bool?
    public var lastTurnEventAt: Date?
    /// Timestamp of the newest record of any kind.
    public var lastRecordAt: Date?
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// Text of the newest user message (a `UserMessage` item).
    public var lastPrompt: String?
    /// Name of the newest tool call (`function_call` / `custom_tool_call`), e.g. "exec".
    public var lastTool: String?

    public init(
        turnActive: Bool? = nil, lastTurnEventAt: Date? = nil, lastRecordAt: Date? = nil,
        contextTokens: Int? = nil, contextWindow: Int? = nil, lastPrompt: String? = nil,
        lastTool: String? = nil
    ) {
        self.turnActive = turnActive
        self.lastTurnEventAt = lastTurnEventAt
        self.lastRecordAt = lastRecordAt
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.lastPrompt = lastPrompt
        self.lastTool = lastTool
    }

    /// Whether every field a backward scan looks for is known.
    var isComplete: Bool { turnActive != nil && contextTokens != nil && lastPrompt != nil }

    /// Fills fields still nil from `older` (values read further back in the file).
    mutating func fillMissing(from older: CodexRolloutInfo) {
        if turnActive == nil {
            turnActive = older.turnActive
            lastTurnEventAt = older.lastTurnEventAt
        }
        if lastRecordAt == nil { lastRecordAt = older.lastRecordAt }
        if contextTokens == nil { contextTokens = older.contextTokens }
        if contextWindow == nil { contextWindow = older.contextWindow }
        if lastPrompt == nil { lastPrompt = older.lastPrompt }
        if lastTool == nil { lastTool = older.lastTool }
    }
}

public enum CodexRolloutParser {
    /// Bytes of a line inspected before deciding whether to decode it.
    static let prefixLength = 512

    /// Applies one rollout line (oldest to newest) to `info`. Cheap for uninteresting lines:
    /// only the prefix is scanned, and only small, relevant records are JSON-decoded.
    public static func apply(line: Substring.UTF8View, to info: inout CodexRolloutInfo) {
        let prefix = String(decoding: line.prefix(prefixLength), as: UTF8.self)
        guard prefix.hasPrefix("{") else { return }
        let timestamp = stringValue(after: "\"timestamp\":\"", in: prefix).flatMap(parseDate)
        if let timestamp { info.lastRecordAt = timestamp }
        guard let payloadType = stringValue(after: "\"payload\":{\"type\":\"", in: prefix) else { return }
        switch payloadType {
        case "task_started":
            info.turnActive = true
            info.lastTurnEventAt = timestamp ?? info.lastTurnEventAt
            if let window = intValue(after: "\"model_context_window\":", in: String(decoding: line, as: UTF8.self)),
               window > 0 {
                info.contextWindow = window
            }
        case "task_complete", "turn_aborted":
            info.turnActive = false
            info.lastTurnEventAt = timestamp ?? info.lastTurnEventAt
        case "token_count":
            guard let object = decode(line), let payload = object["payload"] as? [String: Any],
                  let tokenInfo = payload["info"] as? [String: Any] else { return }
            if let last = tokenInfo["last_token_usage"] as? [String: Any],
               let total = (last["total_tokens"] as? NSNumber)?.intValue, total > 0 {
                info.contextTokens = total
            }
            if let window = (tokenInfo["model_context_window"] as? NSNumber)?.intValue, window > 0 {
                info.contextWindow = window
            }
        case "item_completed":
            guard prefix.contains("\"item\":{\"type\":\"UserMessage\""),
                  let object = decode(line), let payload = object["payload"] as? [String: Any],
                  let item = payload["item"] as? [String: Any],
                  let text = userText(item["content"]) else { return }
            info.lastPrompt = text
        case "function_call", "custom_tool_call":
            if let name = stringValue(after: "\"name\":\"", in: prefix) { info.lastTool = name }
        default:
            break
        }
    }

    /// Parses complete lines of `data` (oldest first) into `info`.
    public static func apply(data: Data, to info: inout CodexRolloutInfo) {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            apply(line: line.utf8, to: &info)
        }
    }

    /// First text of a `UserMessage` item's content, with whitespace runs collapsed to one space.
    static func userText(_ content: Any?) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }
        for part in parts {
            if let text = part["text"] as? String {
                let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !flat.isEmpty { return String(flat.prefix(500)) }
            }
        }
        return nil
    }

    static func decode(_ line: Substring.UTF8View) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    /// The JSON string starting right after `marker` (no escape handling: used for ids, types,
    /// tool names and timestamps, which don't contain quotes).
    static func stringValue(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    static func intValue(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()
    private static let formatterLock = NSLock()

    static func parseDate(_ text: String) -> Date? {
        formatterLock.withLock { fractional.date(from: text) ?? whole.date(from: text) }
    }
}

/// Incremental, stat-keyed reader of rollout files: the first read takes the file's tail (and
/// scans further back, in chunks, only for fields the tail lacks); later reads parse only the
/// appended bytes. Rollouts are append-only while their thread is loaded.
public final class CodexRolloutReader: @unchecked Sendable {
    static let tailBytes = 256 * 1024
    static let backwardChunk = 256 * 1024
    static let maxBackwardScan = 16 * 1024 * 1024

    private struct Entry {
        var inode: UInt64
        var size: Int64
        var mtime: Date
        /// Bytes consumed: up to the end of the last complete line.
        var offset: Int64
        var info: CodexRolloutInfo
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// The thread's info, or nil if the file doesn't exist (yet: Codex creates it at the first
    /// prompt) or can't be read.
    public func info(at url: URL) -> CodexRolloutInfo? {
        let path = url.path
        var st = stat()
        guard stat(path, &st) == 0 else {
            entries[path] = nil
            return nil
        }
        let inode = UInt64(st.st_ino)
        let size = Int64(st.st_size)
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        if var entry = entries[path], entry.inode == inode, size >= entry.offset {
            if entry.size == size && entry.mtime == mtime { return entry.info }
            guard let handle = FileHandle(forReadingAtPath: path) else { return entry.info }
            defer { try? handle.close() }
            if size > entry.offset {
                try? handle.seek(toOffset: UInt64(entry.offset))
                if let data = try? handle.read(upToCount: Int(size - entry.offset)) {
                    let complete = Self.completeLines(data)
                    CodexRolloutParser.apply(data: complete, to: &entry.info)
                    entry.offset += Int64(complete.count)
                }
            }
            entry.size = size
            entry.mtime = mtime
            entries[path] = entry
            return entry.info
        }
        // New, replaced or truncated file: read from the tail.
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let start = max(0, size - Int64(Self.tailBytes))
        try? handle.seek(toOffset: UInt64(start))
        guard let raw = try? handle.read(upToCount: Int(size - start)) else { return nil }
        var tail = raw
        if start > 0, let nl = tail.firstIndex(of: 0x0A) {
            tail = tail[(nl + 1)...]  // drop the partial first line
        } else if start > 0 {
            tail = Data()
        }
        let complete = Self.completeLines(Data(tail))
        var info = CodexRolloutInfo()
        CodexRolloutParser.apply(data: complete, to: &info)
        let consumed = start + Int64(raw.count - tail.count) + Int64(complete.count)
        if !info.isComplete && start > 0 {
            info.fillMissing(from: Self.scanBackward(handle: handle, before: start + Int64(raw.count - tail.count)))
        }
        entries[path] = Entry(inode: inode, size: size, mtime: mtime, offset: consumed, info: info)
        return info
    }

    /// Reads chunks before `end`, newest first, until every field is found or the budget is
    /// spent. Lines spanning a chunk boundary are carried over to the next (older) chunk.
    static func scanBackward(handle: FileHandle, before end: Int64) -> CodexRolloutInfo {
        var result = CodexRolloutInfo()
        var position = end
        var carry = Data()  // the partial first line of the previously read (newer) chunk
        var scanned: Int64 = 0
        while position > 0, scanned < maxBackwardScan, !result.isComplete {
            let start = max(0, position - Int64(backwardChunk))
            try? handle.seek(toOffset: UInt64(start))
            guard var chunk = try? handle.read(upToCount: Int(position - start)) else { break }
            chunk.append(carry)
            if start > 0, let nl = chunk.firstIndex(of: 0x0A) {
                carry = Data(chunk[..<nl])
                chunk = Data(chunk[(nl + 1)...])
            } else {
                carry = Data()
            }
            var older = CodexRolloutInfo()
            CodexRolloutParser.apply(data: chunk, to: &older)
            result.fillMissing(from: older)
            scanned += position - start
            position = start
        }
        return result
    }

    /// `data` up to and including its last newline.
    static func completeLines(_ data: Data) -> Data {
        guard let last = data.lastIndex(of: 0x0A) else { return Data() }
        return Data(data[...last])
    }

    /// Drops cached files not in `paths`.
    public func forget(except paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }
}
