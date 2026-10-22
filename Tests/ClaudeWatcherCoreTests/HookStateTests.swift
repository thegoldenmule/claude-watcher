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
        try Data("GID".utf8).write(to: dir.appendingPathComponent(".a.ghostty.tmp.123"))
        let all = HookStateStore.loadAll(directory: dir)
        #expect(Array(all.keys) == ["a"])
        #expect(all["a"]?.claudePID == 1)
        #expect(HookStateStore.loadAll(directory: dir.appendingPathComponent("missing")).isEmpty)
    }

    @Test func decodesVersion2OutputWithoutGhosttyField() throws {
        let json = #"{"session_id":"s1","claude_pid":11205,"tty":"/dev/ttys001","term_program":"ghostty","cwd":"/x","transcript_path":null,"last_event":"Stop","updated_at":1792682463626}"#
        let state = try JSONDecoder().decode(HookState.self, from: Data(json.utf8))
        #expect(state.ghosttyTerminalID == nil)
        #expect(state.tty == "/dev/ttys001")
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hookstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ text: String, _ dir: URL, _ name: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    @Test func sidecarFillsAndOverridesGhosttyID() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"session_id":"a","claude_pid":1,"last_event":"Stop","updated_at":5}"#, dir, "a.json")
        try Self.write(#"{"session_id":"b","claude_pid":2,"last_event":"Stop","ghostty_terminal_id":"OLD","updated_at":5}"#, dir, "b.json")
        try Self.write(#"{"session_id":"c","claude_pid":3,"last_event":"Stop","ghostty_terminal_id":"KEEP","updated_at":5}"#, dir, "c.json")
        try Self.write("0FD9735C-6645-44F3-975D-7BC605D03215\n", dir, "a.ghostty")
        try Self.write("NEW-1", dir, "b.ghostty")
        try Self.write("bad\"id", dir, "c.ghostty")          // junk sidecar: ignored, JSON value kept
        try Self.write("ORPHAN", dir, "gone.ghostty")        // no state file: ignored
        try Self.write("TMP", dir, ".a.ghostty.tmp.42")
        let all = HookStateStore.loadAll(directory: dir)
        #expect(Set(all.keys) == ["a", "b", "c"])
        #expect(all["a"]?.ghosttyTerminalID == "0FD9735C-6645-44F3-975D-7BC605D03215")
        #expect(all["b"]?.ghosttyTerminalID == "NEW-1")
        #expect(all["c"]?.ghosttyTerminalID == "KEEP")
    }

    @Test func cachePicksUpSidecarChangesWithoutStateChanges() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"session_id":"a","claude_pid":1,"last_event":"Stop","updated_at":5}"#, dir, "a.json")
        var cache = HookStateCache()
        #expect(cache.load(directory: dir)["a"]?.ghosttyTerminalID == nil)
        try Self.write("GID-1", dir, "a.ghostty")
        #expect(cache.load(directory: dir)["a"]?.ghosttyTerminalID == "GID-1")
        // A rewrite of the state file (cached sidecar entry reused) keeps the id.
        try Self.write(#"{"session_id":"a","claude_pid":1,"last_event":"UserPromptSubmit","updated_at":6}"#, dir, "a.json")
        let s = cache.load(directory: dir)["a"]
        #expect(s?.lastEvent == "UserPromptSubmit")
        #expect(s?.ghosttyTerminalID == "GID-1")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.ghostty"))
        #expect(cache.load(directory: dir)["a"]?.ghosttyTerminalID == nil)
    }

    @Test func parsesSidecarConservatively() {
        #expect(HookStateStore.parseSidecar(Data("  ABC-123\n".utf8)) == "ABC-123")
        #expect(HookStateStore.parseSidecar(Data("".utf8)) == nil)
        #expect(HookStateStore.parseSidecar(Data("a b".utf8)) == nil)
        #expect(HookStateStore.parseSidecar(Data("é".utf8)) == nil)
        #expect(HookStateStore.parseSidecar(Data(String(repeating: "a", count: 200).utf8)) == nil)
        #expect(HookStateStore.sidecarSessionID("s-1.ghostty") == "s-1")
        #expect(HookStateStore.sidecarSessionID(".s-1.ghostty") == nil)
        #expect(HookStateStore.sidecarSessionID(".ghostty") == nil)
        #expect(HookStateStore.sidecarSessionID("s-1.json") == nil)
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
