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

    final class Env: Sendable {
        let dir: URL
        let noJQ: Bool
        init(noJQ: Bool) throws {
            self.noJQ = noJQ
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("hookscript \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        @discardableResult
        func run(_ json: String, extraEnv: [String: String] = [:], cwd: URL? = nil) throws -> Run {
            let p = Process()
            p.executableURL = HookScriptTests.script
            if let cwd { p.currentDirectoryURL = cwd }
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

    /// Hook input with properly JSON-escaped strings (control chars become \uXXXX).
    static func jsonInput(_ sid: String, _ event: String, cwd: String) throws -> String {
        let obj: [String: String] = ["session_id": sid, "transcript_path": "/tmp/\(sid).jsonl", "cwd": cwd,
                                     "hook_event_name": event, "source": "startup"]
        return String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
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

    // MARK: Ghostty OSC 7 probe (fake tty file + stub osascript)

    /// Sets up a probe run: a regular file as the tty and an osascript stub that records the
    /// nonce it was asked about and prints `ids` (one per line).
    static func probeEnv(_ env: Env, ids: [String]) throws -> [String: String] {
        let tty = env.dir.appendingPathComponent("tty")
        try Data().write(to: tty)
        let stub = env.dir.appendingPathComponent("osascript-stub")
        let script = """
        #!/bin/sh
        for a; do last=$a; done
        printf '%s\\n' "$last" >> "$(dirname "$0")/nonces"
        printf '\(ids.joined(separator: "\\n"))'
        """
        try Data(script.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return ["CLAUDE_WATCHER_NO_GHOSTTY_PROBE": "0", "CLAUDE_WATCHER_TTY": tty.path,
                "CLAUDE_WATCHER_OSASCRIPT": stub.path]
    }

    static func waitFor(_ timeout: TimeInterval = 5, _ cond: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try cond() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return try cond()
    }

    /// The OSC 7 sequences written to the fake tty, as (host, path) still percent-encoded.
    /// Every byte inside a sequence must be printable ASCII without spaces.
    static func osc7Writes(_ env: Env) throws -> [(host: String, path: String)] {
        let bytes = try Data(contentsOf: env.dir.appendingPathComponent("tty"))
        var result: [(String, String)] = []
        for chunk in bytes.split(separator: 0x07, omittingEmptySubsequences: true) {
            let prefix = Array("\u{1B}]7;file://".utf8)
            #expect(Array(chunk.prefix(prefix.count)) == prefix)
            let body = chunk.dropFirst(prefix.count)
            #expect(body.allSatisfy { (0x21...0x7E).contains($0) }, "unsafe byte in OSC 7: \(Array(body))")
            let text = String(decoding: body, as: UTF8.self)
            let slash = text.firstIndex(of: "/") ?? text.endIndex
            result.append((String(text[..<slash]), String(text[slash...])))
        }
        return result
    }

    @Test(arguments: [false, true])
    func probeRestoresAnEncodedSafeCwd(noJQ: Bool) throws {
        let env = try Env(noJQ: noJQ)
        // A real directory, so the no-jq fallback (which gives up on JSON escapes and uses
        // $PWD) restores the same path as the jq path does.
        let weird = env.dir.appendingPathComponent("w %#?\\;\u{1B}]52;c;eA==\u{07} é漢")
        try FileManager.default.createDirectory(at: weird, withIntermediateDirectories: true)
        let cwd = try #require(realpath(weird.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let host = "h\u{1B}]52;c;x\u{07}/%"
        var extra = try Self.probeEnv(env, ids: ["GID-1"])
        extra["HOST"] = host
        let r = try env.run(try Self.jsonInput("s-1", "SessionStart", cwd: cwd), extraEnv: extra, cwd: weird)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(try Self.waitFor { try env.state("s-1")?.ghosttyTerminalID == "GID-1" })

        let writes = try Self.osc7Writes(env)
        try #require(writes.count == 2)
        let nonce = try String(contentsOf: env.dir.appendingPathComponent("nonces"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        #expect(writes[0].path == "/tmp/\(nonce)")
        #expect(writes[0].host.removingPercentEncoding == host)
        #expect(writes[1].host.removingPercentEncoding == host)
        #expect(writes[1].path.removingPercentEncoding == cwd)
        #expect(!writes[1].path.contains("?") && !writes[1].path.contains("#") && !writes[1].path.contains(";"))
        // The state file keeps the real cwd (jq path) / the raw JSON value (fallback).
        #expect(try env.state("s-1")?.cwd == cwd)
    }

    @Test func probeNonceIsDelimitedAndUniqueMatchRequired() throws {
        let env = try Env(noJQ: false)
        var extra = try Self.probeEnv(env, ids: ["GID-1", "GID-2"])
        try env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        // Two terminals report the nonce: ambiguous, so no id is recorded.
        #expect(try Self.waitFor { try Self.osc7Writes(env).count == 2 })
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try env.state("s-1")?.ghosttyTerminalID == nil)

        // The nonce ends in a delimiter, so an older nonce for the same pid that merely starts
        // with the same digits ("CW-<pid>-12345" vs "CW-<pid>-1234567") can't contain it.
        let nonces = try String(contentsOf: env.dir.appendingPathComponent("nonces"), encoding: .utf8)
        let nonce = try #require(nonces.split(separator: "\n").first.map(String.init))
        #expect(nonce.wholeMatch(of: /CW-\d+-\d+-x/) != nil, "nonce \(nonce)")

        // Exactly one match: recorded.
        extra = try Self.probeEnv(env, ids: ["GID-3"])
        try env.run(Self.input("s-2", "SessionStart"), extraEnv: extra)
        #expect(try Self.waitFor { try env.state("s-2")?.ghosttyTerminalID == "GID-3" })
    }

    @Test func probeIDSurvivesConcurrentHookWrites() throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"])
        try env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        // Hooks of the same session race the detached probe's patch; none may drop the id.
        let start = Date()
        while Date().timeIntervalSince(start) < 1.5 {
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                _ = try? env.run(Self.input("s-1", "UserPromptSubmit"))
            }
            if try env.state("s-1")?.ghosttyTerminalID != nil { break }
        }
        for _ in 0..<3 {
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                _ = try? env.run(Self.input("s-1", "UserPromptSubmit"))
            }
        }
        #expect(try env.state("s-1")?.ghosttyTerminalID == "GID-1")
        #expect(try env.state("s-1")?.lastEvent == "UserPromptSubmit")
    }

    // MARK: Per-session lock

    @Test func heldLockIsWaitedForBrieflyThenIgnored() throws {
        let env = try Env(noJQ: false)
        let lock = env.dir.appendingPathComponent(".lock-s-1")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let start = Date()
        let r = try env.run(Self.input("s-1", "Stop"))
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.status == 0)
        #expect(elapsed >= 0.15, "did not wait for the lock (\(elapsed)s)")
        #expect(elapsed < 2, "waited too long for the lock (\(elapsed)s)")
        #expect(try env.state("s-1") != nil)
        // Not ours, so not removed.
        #expect(FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func staleLockIsBroken() throws {
        let env = try Env(noJQ: false)
        let lock = env.dir.appendingPathComponent(".lock-s-1")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: lock.path)
        let r = try env.run(Self.input("s-1", "Stop"))
        #expect(r.status == 0)
        #expect(try env.state("s-1") != nil)
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }
}
