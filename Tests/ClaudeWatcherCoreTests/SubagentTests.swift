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
