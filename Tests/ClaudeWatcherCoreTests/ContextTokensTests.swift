import Foundation
import Testing
@testable import ClaudeWatcherCore

// MARK: - Fixtures

/// An assistant record shaped like Claude Code's (v2.1.3xx): usage nested in `message`.
private func assistant(
    input: Int? = 2, cacheCreation: Int? = 0, cacheRead: Int? = 0, output: Int = 50,
    model: String = "claude-opus-5-5", sidechain: Bool = false, pad: Int = 0
) -> String {
    var usage: [String] = []
    if let input { usage.append("\"input_tokens\":\(input)") }
    if let cacheCreation { usage.append("\"cache_creation_input_tokens\":\(cacheCreation)") }
    if let cacheRead { usage.append("\"cache_read_input_tokens\":\(cacheRead)") }
    usage.append("\"output_tokens\":\(output)")
    let text = String(repeating: "x", count: pad)
    return """
    {"parentUuid":"p","isSidechain":\(sidechain),"type":"assistant","uuid":"u",\
    "message":{"model":"\(model)","role":"assistant","type":"message",\
    "usage":{\(usage.joined(separator: ","))},"content":[{"type":"text","text":"\(text)"}]}}
    """
}

private func compactBoundary(postTokens: Int?) -> String {
    let post = postTokens.map { ",\"postTokens\":\($0)" } ?? ""
    return """
    {"parentUuid":null,"isSidechain":false,"type":"system","subtype":"compact_boundary",\
    "content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":587341\(post)}}
    """
}

private func userLine(pad: Int = 0) -> String {
    "{\"type\":\"user\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"\(String(repeating: "y", count: pad))\"}}"
}

private func lines(_ items: [String]) -> String { items.joined(separator: "\n") + "\n" }

// MARK: - Parser

@Test func contextTokensSumInputAndCacheFields() {
    let info = TranscriptParser.parse(lines([
        userLine(), assistant(input: 3, cacheCreation: 4155, cacheRead: 250_977, output: 348),
    ]))
    #expect(info.contextTokens == 3 + 4155 + 250_977)  // output tokens don't count
}

@Test func contextTokensMissingCacheFieldsCountZero() {
    let info = TranscriptParser.parse(lines([assistant(input: 1200, cacheCreation: nil, cacheRead: nil)]))
    #expect(info.contextTokens == 1200)
    let onlyRead = TranscriptParser.parse(lines([assistant(input: nil, cacheCreation: nil, cacheRead: 9000)]))
    #expect(onlyRead.contextTokens == 9000)
}

@Test func contextTokensLastQualifyingRecordWins() {
    let info = TranscriptParser.parse(lines([
        assistant(cacheRead: 10_000),
        userLine(),
        assistant(cacheRead: 20_000),
        // Sidechain (subagent) replies, API-error placeholders and all-zero usage are skipped.
        assistant(cacheRead: 900_000, sidechain: true),
        assistant(input: 0, cacheCreation: 0, cacheRead: 0, output: 0, model: "<synthetic>"),
        assistant(input: 0, cacheCreation: 0, cacheRead: 0, output: 0),
        "{\"type\":\"assistant\",\"gitBranch\":\"main\"}",  // no message at all
        userLine(),
    ]))
    #expect(info.contextTokens == 2 + 20_000)
}

@Test func contextTokensNilWithoutAssistantReplies() {
    #expect(TranscriptParser.parse(lines([userLine()])).contextTokens == nil)
    #expect(TranscriptParser.parse(lines([assistant(model: "<synthetic>")])).contextTokens == nil)
}

@Test func compactBoundaryReplacesPreCompactionSize() {
    let compacted = TranscriptParser.parse(lines([
        assistant(cacheRead: 587_000), compactBoundary(postTokens: 10_455), userLine(),
    ]))
    #expect(compacted.contextTokens == 10_455)
    // The next reply reports the real size.
    let replied = TranscriptParser.parse(lines([
        assistant(cacheRead: 587_000), compactBoundary(postTokens: 10_455), assistant(cacheRead: 50_000),
    ]))
    #expect(replied.contextTokens == 50_002)
    // A boundary without a size: unknown, not the stale pre-compaction size, even after overlay.
    var info = TranscriptParser.parse(lines([assistant(cacheRead: 587_000)]))
    info.overlay(TranscriptParser.parse(lines([compactBoundary(postTokens: nil)])))
    #expect(info.contextTokens == nil)
    // A chunk with no context record leaves the value alone.
    info = TranscriptParser.parse(lines([assistant(cacheRead: 587_000)]))
    info.overlay(TranscriptParser.parse(lines([userLine()])))
    #expect(info.contextTokens == 587_002)
}

// MARK: - Reader

@Test func readerUpdatesContextTokensIncrementally() throws {
    let home = try TempHome()
    let rel = "projects/p/s1.jsonl"
    try home.write(rel, lines([userLine(), assistant(cacheRead: 30_000)]))
    let reader = TranscriptReader(tailBytes: 1024)
    let url = home.url.appendingPathComponent(rel)
    #expect(reader.info(at: url)?.contextTokens == 30_002)

    // Appended: a user turn and a sidechain reply leave it; a new main reply replaces it.
    try home.append(rel, lines([userLine(), assistant(cacheRead: 800_000, sidechain: true)]))
    #expect(reader.info(at: url)?.contextTokens == 30_002)
    let partial = assistant(cacheRead: 45_000)
    try home.append(rel, String(partial.prefix(40)))  // mid-write: not parsed yet
    #expect(reader.info(at: url)?.contextTokens == 30_002)
    try home.append(rel, String(partial.dropFirst(40)) + "\n")
    #expect(reader.info(at: url)?.contextTokens == 45_002)
}

@Test func readerScansBackForContextTokensBeforeTheTail() throws {
    let home = try TempHome()
    let rel = "projects/p/s1.jsonl"
    // The last reply sits before the 1 KB tail, which holds only big user records.
    var items = [
        "{\"type\":\"ai-title\",\"aiTitle\":\"Title\"}",
        assistant(cacheRead: 11_000),
        assistant(cacheRead: 22_000, pad: 300),
        assistant(cacheRead: 99_000, sidechain: true),
        assistant(input: 0, cacheCreation: 0, cacheRead: 0, output: 0, model: "<synthetic>"),
    ]
    items += Array(repeating: userLine(pad: 400), count: 20)
    try home.write(rel, lines(items))
    let reader = TranscriptReader(tailBytes: 1024)
    let url = home.url.appendingPathComponent(rel)
    let info = try #require(reader.info(at: url))
    #expect(info.contextTokens == 22_002)
    #expect(info.aiTitle == "Title")
}

@Test func readerBackwardScanStopsAtCompactBoundary() throws {
    let home = try TempHome()
    let rel = "projects/p/s1.jsonl"
    var items = [assistant(cacheRead: 900_000), compactBoundary(postTokens: 12_000)]
    items += Array(repeating: userLine(pad: 400), count: 20)
    try home.write(rel, lines(items))
    let reader = TranscriptReader(tailBytes: 1024)
    #expect(reader.info(at: home.url.appendingPathComponent(rel))?.contextTokens == 12_000)
}

@Test func readerReTailKeepsNewestContextTokens() throws {
    let home = try TempHome()
    let rel = "projects/p/s1.jsonl"
    try home.write(rel, lines(["{\"type\":\"ai-title\",\"aiTitle\":\"T\"}", assistant(cacheRead: 5000)]))
    // Small incremental limit: a large append re-tails over the old knowledge.
    let reader = TranscriptReader(tailBytes: 1024, maxIncremental: 2048)
    let url = home.url.appendingPathComponent(rel)
    #expect(reader.info(at: url)?.contextTokens == 5002)

    // The newest reply lands in the skipped middle, followed by more than a tail of user records.
    var items = [assistant(cacheRead: 70_000)]
    items += Array(repeating: userLine(pad: 400), count: 10)
    try home.append(rel, lines(items))
    let info = try #require(reader.info(at: url))
    #expect(info.contextTokens == 70_002)
    #expect(info.aiTitle == "T")
}
