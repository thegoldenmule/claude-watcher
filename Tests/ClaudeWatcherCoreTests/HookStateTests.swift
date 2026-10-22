import Foundation
import Testing
@testable import ClaudeWatcherCore

@Suite struct HookStateTests {
    @Test func roundTripsThroughJSON() throws {
        let state = HookState(
            sessionID: "abc-123", claudePID: 4242, tty: "/dev/ttys001", termProgram: "ghostty",
            cwd: "/tmp/p", transcriptPath: "/tmp/p/t.jsonl", lastEvent: "Stop",
            ghosttyTerminalID: "0FD9735C-6645-44F3-975D-7BC605D03215", updatedAtMillis: 1_792_682_704_878)
        let data = try JSONEncoder().encode(state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["session_id", "claude_pid", "tty", "term_program", "cwd",
                                     "transcript_path", "last_event", "ghostty_terminal_id", "updated_at"])
        #expect(try JSONDecoder().decode(HookState.self, from: data) == state)
        #expect(state.updatedAt.timeIntervalSince1970 == 1_792_682_704.878)
    }

    @Test func decodesScriptOutputWithNulls() throws {
        let json = #"{"session_id":"s1","claude_pid":11205,"tty":null,"term_program":"ghostty","cwd":"/x","transcript_path":null,"last_event":"SessionStart","ghostty_terminal_id":null,"updated_at":1792682463626}"#
        let state = try JSONDecoder().decode(HookState.self, from: Data(json.utf8))
        #expect(state.sessionID == "s1")
        #expect(state.claudePID == 11205)
        #expect(state.tty == nil)
        #expect(state.ghosttyTerminalID == nil)
        #expect(state.lastEvent == "SessionStart")
    }

    @Test func loadAllSkipsJunkAndTempFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hookstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = #"{"session_id":"a","claude_pid":1,"last_event":"Stop","updated_at":5}"#
        try Data(good.utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("b.json"))
        try Data(good.utf8).write(to: dir.appendingPathComponent(".a.json.tmp.123"))
        try Data(good.utf8).write(to: dir.appendingPathComponent("c.ended"))
        let all = HookStateStore.loadAll(directory: dir)
        #expect(Array(all.keys) == ["a"])
        #expect(all["a"]?.claudePID == 1)
        #expect(HookStateStore.loadAll(directory: dir.appendingPathComponent("missing")).isEmpty)
    }

    @Test func latestByPIDPrefersNewest() {
        let old = HookState(sessionID: "old", claudePID: 7, lastEvent: "Stop", updatedAtMillis: 1)
        let new = HookState(sessionID: "new", claudePID: 7, lastEvent: "SessionStart", updatedAtMillis: 2)
        #expect(HookStateStore.latestByPID(["old": old, "new": new])[7]?.sessionID == "new")
    }

    @Test func defaultDirectoryIsUnderApplicationSupport() {
        #expect(HookStateStore.defaultDirectory.path.hasSuffix("Library/Application Support/ClaudeWatcher/hook-state"))
    }
}
