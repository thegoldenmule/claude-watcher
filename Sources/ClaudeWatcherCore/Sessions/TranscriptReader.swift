import Foundation

/// Metadata extracted from a session transcript (`projects/<slug>/<sessionId>.jsonl`).
/// Every field follows "last line wins".
public struct TranscriptInfo: Sendable, Equatable {
    public var aiTitle: String?
    public var customTitle: String?
    public var agentName: String?
    public var lastPrompt: String?
    public var gitBranch: String?
    public var cwd: String?
    public var prURL: String?
    public var prNumber: Int?
    /// Main conversation's context size at its last reply (see `TranscriptParser.contextTokens`).
    public var contextTokens: Int?
    /// A record that sets the context size was seen (`contextTokens` may still be nil, e.g. a
    /// compaction without a size), so a later one can replace an older value with nil.
    var hasContextRecord = false

    public init(
        aiTitle: String? = nil, customTitle: String? = nil, agentName: String? = nil,
        lastPrompt: String? = nil, gitBranch: String? = nil, cwd: String? = nil,
        prURL: String? = nil, prNumber: Int? = nil, contextTokens: Int? = nil
    ) {
        self.aiTitle = aiTitle
        self.customTitle = customTitle
        self.agentName = agentName
        self.lastPrompt = lastPrompt
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.prURL = prURL
        self.prNumber = prNumber
        self.contextTokens = contextTokens
        self.hasContextRecord = contextTokens != nil
    }

    public var hasTitle: Bool { aiTitle != nil || customTitle != nil }

    /// Fields set in `newer` replace ours (newer = later in the file).
    public mutating func overlay(_ newer: TranscriptInfo) {
        if let v = newer.aiTitle { aiTitle = v }
        if let v = newer.customTitle { customTitle = v }
        if let v = newer.agentName { agentName = v }
        if let v = newer.lastPrompt { lastPrompt = v }
        if let v = newer.gitBranch { gitBranch = v }
        if let v = newer.cwd { cwd = v }
        if let v = newer.prURL { prURL = v; prNumber = newer.prNumber }
        if newer.hasContextRecord { setContext(newer.contextTokens) }
    }

    mutating func setContext(_ tokens: Int?) {
        contextTokens = tokens
        hasContextRecord = true
    }

    /// Fills only fields we don't have yet from `older` (older = earlier in the file).
    public mutating func fillMissing(from older: TranscriptInfo) {
        aiTitle = aiTitle ?? older.aiTitle
        customTitle = customTitle ?? older.customTitle
        agentName = agentName ?? older.agentName
        lastPrompt = lastPrompt ?? older.lastPrompt
        gitBranch = gitBranch ?? older.gitBranch
        cwd = cwd ?? older.cwd
        if prURL == nil { prURL = older.prURL; prNumber = older.prNumber }
        if !hasContextRecord, older.hasContextRecord { setContext(older.contextTokens) }
    }
}

public enum TranscriptParser {
    /// Parses a buffer of complete JSONL lines in file order. Malformed lines are skipped.
    public static func parse(_ data: Data) -> TranscriptInfo {
        var info = TranscriptInfo()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            apply(line: Data(line), to: &info)
        }
        return info
    }

    /// Parses a JSONL string (tests/convenience).
    public static func parse(_ text: String) -> TranscriptInfo { parse(Data(text.utf8)) }

    static func apply(line: Data, to info: inout TranscriptInfo) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        switch obj["type"] as? String {
        case "ai-title":
            if let v = str(obj["aiTitle"]) { info.aiTitle = v }
        case "custom-title":
            // Field name not observed on disk (v2.1.30x); accept the likely spellings.
            if let v = str(obj["customTitle"]) ?? str(obj["title"]) { info.customTitle = v }
        case "agent-name":
            if let v = str(obj["agentName"]) { info.agentName = v }
        case "last-prompt":
            if let v = str(obj["lastPrompt"]) { info.lastPrompt = v }
        case "pr-link":
            if let v = str(obj["prUrl"]) {
                info.prURL = v
                info.prNumber = (obj["prNumber"] as? NSNumber)?.intValue
            }
        case "assistant":
            if let tokens = contextTokens(assistant: obj) { info.setContext(tokens) }
        case "system":
            // `/compact`: the next reply reports the smaller context; until then, use the
            // compacted size (it omits the system prompt and tools, ~40k, so it reads low)
            // rather than keep the pre-compaction size.
            if obj["subtype"] as? String == "compact_boundary", obj["isSidechain"] as? Bool != true {
                let meta = obj["compactMetadata"] as? [String: Any]
                info.setContext((meta?["postTokens"] as? NSNumber)?.intValue)
            }
        default:
            break
        }
        if let v = str(obj["gitBranch"]) { info.gitBranch = v }
        if let v = str(obj["cwd"]) { info.cwd = v }
    }

    /// Context size at a main-conversation reply: `input_tokens + cache_creation_input_tokens +
    /// cache_read_input_tokens` of `message.usage` (missing fields count 0). nil for sidechain
    /// records, `<synthetic>` ones (API-error placeholders) and all-zero usage.
    static func contextTokens(assistant obj: [String: Any]) -> Int? {
        guard obj["isSidechain"] as? Bool != true,
              let message = obj["message"] as? [String: Any],
              message["model"] as? String != "<synthetic>",
              let usage = message["usage"] as? [String: Any]
        else { return nil }
        let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        return total > 0 ? total : nil
    }

    private static func str(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Incrementally reads transcripts: the first read tails the last `tailBytes`
/// (scanning backward for a title, or the context size, if the tail has none); later reads only parse
/// bytes appended since. Unchanged files (inode, size, mtime) are not re-read.
/// Not thread-safe; owned by `SessionDiscovery`.
final class TranscriptReader {
    struct Entry {
        var inode: UInt64
        var size: UInt64
        var mtime: Date
        /// Offset just past the last complete line consumed.
        var consumed: UInt64
        var info: TranscriptInfo
    }

    let tailBytes: UInt64
    /// Max bytes to scan backward looking for a title.
    let maxBackwardScan: UInt64
    /// If more than this was appended since last read, re-tail instead of reading it all.
    let maxIncremental: UInt64
    private var entries: [String: Entry] = [:]

    init(tailBytes: UInt64 = 256 * 1024, maxBackwardScan: UInt64 = 64 * 1024 * 1024,
         maxIncremental: UInt64 = 4 * 1024 * 1024) {
        self.tailBytes = tailBytes
        self.maxBackwardScan = maxBackwardScan
        self.maxIncremental = maxIncremental
    }

    func forget(except paths: Set<String>) {
        entries = entries.filter { paths.contains($0.key) }
    }

    func info(at url: URL) -> TranscriptInfo? {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else {
            entries[path] = nil
            return nil
        }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast

        if var entry = entries[path], entry.inode == inode, size >= entry.consumed {
            if entry.size == size, entry.mtime == mtime { return entry.info }
            let delta = size - entry.consumed
            if delta <= maxIncremental {
                guard let handle = FileHandle(forReadingAtPath: path) else { return entry.info }
                defer { try? handle.close() }
                if let (data, consumedLen) = readCompleteLines(handle, from: entry.consumed, to: size) {
                    entry.info.overlay(TranscriptParser.parse(data))
                    entry.consumed += consumedLen
                }
                entry.size = size
                entry.mtime = mtime
                entries[path] = entry
                return entry.info
            }
            // Too much appended: re-tail, but keep older knowledge underneath.
            let fresh = freshRead(path: path, size: size, inode: inode, mtime: mtime, base: entry.info)
            entries[path] = fresh
            return fresh?.info
        }

        let fresh = freshRead(path: path, size: size, inode: inode, mtime: mtime, base: nil)
        entries[path] = fresh
        return fresh?.info
    }

    private func freshRead(path: String, size: UInt64, inode: UInt64, mtime: Date,
                           base: TranscriptInfo?) -> Entry? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let start = size > tailBytes ? size - tailBytes : 0
        guard var data = read(handle, offset: start, length: size - start) else { return nil }

        var lineStart: UInt64 = start
        if start > 0 {
            // Drop the partial first line.
            guard let nl = data.firstIndex(of: 0x0A) else {
                // Tail is one giant partial line; consume nothing yet.
                var info = base ?? TranscriptInfo()
                backfill(&info, tailHadContext: false, handle, before: start)
                return Entry(inode: inode, size: size, mtime: mtime, consumed: size, info: info)
            }
            let cut = data.index(after: nl)
            lineStart = start + UInt64(cut - data.startIndex)
            data = data.subdata(in: cut..<data.endIndex)
        }
        // Keep only complete lines; the trailing partial line is read next time.
        var consumed = lineStart
        if let lastNL = data.lastIndex(of: 0x0A) {
            let end = data.index(after: lastNL)
            consumed = lineStart + UInt64(end - data.startIndex)
            data = data.subdata(in: data.startIndex..<end)
        } else {
            data = Data()
        }

        let tail = TranscriptParser.parse(data)
        var info = base ?? TranscriptInfo()
        info.overlay(tail)
        if lineStart > 0 {
            backfill(&info, tailHadContext: tail.hasContextRecord, handle, before: lineStart)
        }
        return Entry(inode: inode, size: size, mtime: mtime, consumed: consumed, info: info)
    }

    /// Fills in, from before the tail, a title if we have none, and the context size if the
    /// tail held no context record. Every main-conversation reply records one, so the tail
    /// almost always has it; scanning back is bounded by `maxBackwardScan` and happens once
    /// per file. A context record found there is newer than any in `info` (an older read's).
    private func backfill(_ info: inout TranscriptInfo, tailHadContext: Bool,
                          _ handle: FileHandle, before: UInt64) {
        let wantTitle = !info.hasTitle, wantContext = !tailHadContext
        guard wantTitle || wantContext else { return }
        let found = backwardScan(handle, before: before, wantTitle: wantTitle, wantContext: wantContext)
        info.fillMissing(from: TranscriptInfo(aiTitle: found.aiTitle, customTitle: found.customTitle))
        if found.hasContextRecord { info.setContext(found.contextTokens) }
    }

    /// Scans backward from `before` (a line boundary) in chunks until what's wanted (a title,
    /// the context size) is found, the start of file, or `maxBackwardScan` bytes. Returns the
    /// latest values seen.
    private func backwardScan(_ handle: FileHandle, before: UInt64,
                              wantTitle: Bool, wantContext: Bool) -> TranscriptInfo {
        var result = TranscriptInfo()
        var end = before
        var carry = Data()  // bytes of a line that started before the current chunk
        var scanned: UInt64 = 0
        let titleMarker = Data("-title\"".utf8)
        // Usage records and compaction boundaries; escaped (quoted) occurrences don't match.
        let contextMarkers = [Data("\"input_tokens\"".utf8), Data("\"compact_boundary\"".utf8)]
        while end > 0, scanned < maxBackwardScan {
            let needTitle = wantTitle && !result.hasTitle
            let needContext = wantContext && !result.hasContextRecord
            guard needTitle || needContext else { break }
            let chunkStart = end > tailBytes ? end - tailBytes : 0
            guard let chunk = read(handle, offset: chunkStart, length: end - chunkStart) else { break }
            scanned += end - chunkStart
            var buffer = chunk
            buffer.append(carry)
            var parseable = buffer
            if chunkStart > 0 {
                guard let nl = buffer.firstIndex(of: 0x0A) else {
                    carry = buffer
                    end = chunkStart
                    continue
                }
                carry = buffer.subdata(in: buffer.startIndex..<nl)
                parseable = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
            } else {
                carry = Data()
            }
            // Only title and context lines matter here; skip decoding everything else.
            var chunkInfo = TranscriptInfo()
            for line in parseable.split(separator: 0x0A) {
                let wanted = (needTitle && line.range(of: titleMarker) != nil)
                    || (needContext && contextMarkers.contains { line.range(of: $0) != nil })
                if wanted { TranscriptParser.apply(line: Data(line), to: &chunkInfo) }
            }
            if needTitle {
                result.fillMissing(from: TranscriptInfo(
                    aiTitle: chunkInfo.aiTitle, customTitle: chunkInfo.customTitle))
            }
            if needContext, chunkInfo.hasContextRecord { result.setContext(chunkInfo.contextTokens) }
            end = chunkStart
        }
        return result
    }

    private func readCompleteLines(_ handle: FileHandle, from: UInt64, to: UInt64) -> (Data, UInt64)? {
        guard to > from, let data = read(handle, offset: from, length: to - from) else { return nil }
        guard let lastNL = data.lastIndex(of: 0x0A) else { return (Data(), 0) }
        let end = data.index(after: lastNL)
        return (data.subdata(in: data.startIndex..<end), UInt64(end - data.startIndex))
    }

    private func read(_ handle: FileHandle, offset: UInt64, length: UInt64) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: Int(length)) ?? Data()
        } catch {
            return nil
        }
    }
}

/// Fallback source of last prompts: `~/.claude/history.jsonl` (`display`, `sessionId`).
/// Reads only the tail; cached by (size, mtime).
final class HistoryIndex {
    private var key: (UInt64, Date)?
    private var prompts: [String: String] = [:]
    let tailBytes: UInt64

    init(tailBytes: UInt64 = 512 * 1024) { self.tailBytes = tailBytes }

    func lastPrompt(sessionId: String, historyURL: URL) -> String? {
        refresh(historyURL)
        return prompts[sessionId]
    }

    private func refresh(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value
        else { prompts = [:]; key = nil; return }
        let mtime = attrs[.modificationDate] as? Date ?? .distantPast
        if let key, key.0 == size, key.1 == mtime { return }
        key = (size, mtime)
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? handle.close() }
        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.readToEnd()
        else { return }
        if start > 0, let nl = data.firstIndex(of: 0x0A) {
            data = data.subdata(in: data.index(after: nl)..<data.endIndex)
        }
        prompts = Self.parse(data)
    }

    /// sessionId -> latest non-slash-command `display`.
    static func parse(_ data: Data) -> [String: String] {
        var map: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let display = (obj["display"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !display.isEmpty, !display.hasPrefix("/")
            else { continue }
            map[sid] = display
        }
        return map
    }
}
