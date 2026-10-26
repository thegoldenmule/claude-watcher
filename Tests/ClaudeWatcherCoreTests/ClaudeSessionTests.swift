import Foundation
import Testing
@testable import ClaudeWatcherCore

@Test func constructsSession() {
    let now = Date()
    let session = ClaudeSession(
        id: "abc-123",
        pid: 4242,
        cwd: "/tmp/project",
        title: "project",
        branch: "main",
        status: .busy,
        tty: "/dev/ttys001",
        terminal: .ghostty,
        startedAt: now,
        updatedAt: now
    )
    #expect(session.id == "abc-123")
    #expect(session.status == .busy)
    #expect(session.terminal == .ghostty)
    #expect(session.lastPrompt == nil)
}

@Test func contextUsageLevels() {
    #expect(ContextUsage.fraction(250_000) == 0.25)
    #expect(ContextUsage.fraction(2_000_000) == 1)
    #expect(ContextUsage.fraction(-5) == 0)
    #expect(ContextUsage.level(0.49) == .normal)
    #expect(ContextUsage.level(0.5) == .warning)
    #expect(ContextUsage.level(0.749) == .warning)
    #expect(ContextUsage.level(0.75) == .critical)
    #expect(ContextUsage.shortTokens(850) == "850")
    #expect(ContextUsage.shortTokens(245_123) == "245k")
    #expect(ContextUsage.shortTokens(1_000_000) == "1.0M")
    #expect(ContextUsage.percent(290_000) == 29)
    #expect(ContextUsage.percent(749_999) == 74)
    #expect(ContextUsage.percent(750_000) == 75)
    #expect(ContextUsage.percent(3_000_000) == 100)
    #expect(ContextUsage.percent(-1) == 0)
    #expect(ContextUsage.percent(1, window: 0) == 0)
    #expect(ContextUsage.label(245_123) == "245k / 1M · 24%")
    #expect(ContextUsage.label(1_000_000) == "1.0M / 1M · 100%")
    #expect(ContextUsage.label(100_000, window: 200_000) == "100k / 200k · 50%")
}
