import Foundation
import Testing
@testable import ClaudeWatcherCore

/// Runs hooks/claude-watcher-hook.sh with a temp state dir. The claude pid is pinned to this
/// test process via CLAUDE_WATCHER_CLAUDE_PID, and the Ghostty probe is disabled.
@Suite struct HookScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/claude-watcher-hook.sh")

    struct Run { var status: Int32; var stdout: String }

    final class Env {
        let dir: URL
        let noJQ: Bool
        init(noJQ: Bool) throws {
            self.noJQ = noJQ
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("hookscript \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        @discardableResult
        func run(_ json: String, extraEnv: [String: String] = [:]) throws -> Run {
            let p = Process()
            p.executableURL = HookScriptTests.script
            var env = ["HOME": dir.path, "PATH": "/usr/bin:/bin",
                       "CLAUDE_WATCHER_STATE_DIR": dir.path,
                       "CLAUDE_WATCHER_CLAUDE_PID": String(ProcessInfo.processInfo.processIdentifier),
                       "CLAUDE_WATCHER_NO_GHOSTTY_PROBE": "1",
                       "TERM_PROGRAM": "ghostty",
                       "CLAUDE_WATCHER_NO_JQ": noJQ ? "1" : "0"]
            env.merge(extraEnv) { $1 }
            p.environment = env
            let stdin = Pipe(), stdout = Pipe()
            p.standardInput = stdin
            p.standardOutput = stdout
            p.standardError = FileHandle.nullDevice
            try p.run()
            stdin.fileHandleForWriting.write(Data(json.utf8))
            try stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Run(status: p.terminationStatus, stdout: String(decoding: out, as: UTF8.self))
        }

        func state(_ sid: String) throws -> HookState? {
            let url = dir.appendingPathComponent("\(sid).json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(HookState.self, from: Data(contentsOf: url))
        }

        func setGhosttyID(_ sid: String, _ id: String) throws {
            let url = dir.appendingPathComponent("\(sid).json")
            var text = try String(contentsOf: url, encoding: .utf8)
            text = text.replacingOccurrences(of: "\"ghostty_terminal_id\":null", with: "\"ghostty_terminal_id\":\"\(id)\"")
            try Data(text.utf8).write(to: url)
        }
    }

    static func input(_ sid: String, _ event: String, cwd: String = "/tmp/with space/\"q\"") -> String {
        #"{"session_id":"\#(sid)","transcript_path":"/tmp/\#(sid).jsonl","cwd":"\#(cwd.replacingOccurrences(of: "\"", with: "\\\""))","hook_event_name":"\#(event)","source":"startup"}"#
    }

    @Test(arguments: [false, true])
    func writesStateOnSessionStart(noJQ: Bool) throws {
        let env = try Env(noJQ: noJQ)
        let r = try env.run(Self.input("s-1", "SessionStart"))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        let s = try #require(try env.state("s-1"))
        #expect(s.sessionID == "s-1")
        #expect(s.claudePID == ProcessInfo.processInfo.processIdentifier)
        #expect(s.termProgram == "ghostty")
        #expect(s.cwd == "/tmp/with space/\"q\"")
        #expect(s.transcriptPath == "/tmp/s-1.jsonl")
        #expect(s.lastEvent == "SessionStart")
        #expect(s.ghosttyTerminalID == nil)
        #expect(abs(s.updatedAt.timeIntervalSinceNow) < 60)
        // Only the state file (plus GC stamp) remains; no temp files.
        let names = try FileManager.default.contentsOfDirectory(atPath: env.dir.path).sorted()
        #expect(names == [".gc-stamp", "s-1.json"])
    }

    @Test(arguments: [false, true])
    func preservesGhosttyIDAndUpdatesEvent(noJQ: Bool) throws {
        let env = try Env(noJQ: noJQ)
        try env.run(Self.input("s-1", "SessionStart"))
        try env.setGhosttyID("s-1", "0FD9735C-6645-44F3-975D-7BC605D03215")
        try env.run(Self.input("s-1", "UserPromptSubmit"))
        let s = try #require(try env.state("s-1"))
        #expect(s.lastEvent == "UserPromptSubmit")
        #expect(s.ghosttyTerminalID == "0FD9735C-6645-44F3-975D-7BC605D03215")
    }

    @Test(arguments: [false, true])
    func sessionEndDeletesAndBlocksLateWriters(noJQ: Bool) throws {
        let env = try Env(noJQ: noJQ)
        try env.run(Self.input("s-1", "SessionStart"))
        #expect(try env.run(Self.input("s-1", "SessionEnd")).status == 0)
        #expect(try env.state("s-1") == nil)
        // A late async Stop must not resurrect the file.
        try env.run(Self.input("s-1", "Stop"))
        #expect(try env.state("s-1") == nil)
        // A resume of the same id starts it again.
        try env.run(Self.input("s-1", "SessionStart"))
        #expect(try env.state("s-1") != nil)
    }

    @Test(arguments: [false, true])
    func clearSupersedesSamePIDAndAdoptsGhosttyID(noJQ: Bool) throws {
        let env = try Env(noJQ: noJQ)
        try env.run(Self.input("old", "SessionStart"))
        try env.setGhosttyID("old", "GID-1")
        try env.run(Self.input("old", "SessionEnd"))
        try env.run(Self.input("new", "SessionStart"))
        #expect(try env.state("old") == nil)
        #expect(try env.state("new")?.ghosttyTerminalID == "GID-1")
        // A still-live file for the same pid (no SessionEnd seen) is also dropped.
        try env.run(Self.input("newer", "SessionStart"))
        #expect(try env.state("new") == nil)
        #expect(try env.state("newer")?.ghosttyTerminalID == "GID-1")
    }

    @Test(arguments: [false, true])
    func ignoresBadInputSilently(noJQ: Bool) throws {
        let env = try Env(noJQ: noJQ)
        for bad in ["", "not json", #"{"session_id":"../evil","hook_event_name":"Stop"}"#,
                    #"{"session_id":".hidden","hook_event_name":"Stop"}"#, #"{"hook_event_name":"Stop"}"#] {
            let r = try env.run(bad)
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: env.dir.path)
        #expect(names.allSatisfy { $0.hasPrefix(".") })
    }

    @Test func skipsWhenNoClaudeAncestor() throws {
        let env = try Env(noJQ: false)
        // A pid that does not exist: the walk finds no claude process, so nothing is written.
        let r = try env.run(Self.input("s-1", "SessionStart"), extraEnv: ["CLAUDE_WATCHER_CLAUDE_PID": "999999"])
        #expect(r.status == 0)
        #expect(try env.state("s-1") == nil)
    }

    @Test func garbageCollectsDeadPIDs() throws {
        let env = try Env(noJQ: false)
        let dead = #"{"session_id":"dead","claude_pid":999999,"last_event":"Stop","updated_at":1}"#
        let notClaude = #"{"session_id":"init","claude_pid":1,"last_event":"Stop","updated_at":1}"#
        try Data(dead.utf8).write(to: env.dir.appendingPathComponent("dead.json"))
        try Data(notClaude.utf8).write(to: env.dir.appendingPathComponent("init.json"))
        try env.run(Self.input("s-1", "Stop"))
        #expect(try env.state("dead") == nil)
        #expect(try env.state("init") == nil)
        #expect(try env.state("s-1") != nil)
    }

    @Test func isFast() throws {
        let env = try Env(noJQ: false)
        try env.run(Self.input("s-1", "SessionStart"))
        let start = Date()
        for _ in 0..<10 { try env.run(Self.input("s-1", "Stop")) }
        let perRun = Date().timeIntervalSince(start) / 10
        #expect(perRun < 0.2, "hook took \(Int(perRun * 1000))ms per run")
    }
}
