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
