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
        func run(_ json: String, extraEnv: [String: String] = [:], cwd: URL? = nil) async throws -> Run {
            var env = ["HOME": dir.path, "PATH": "/usr/bin:/bin",
                       "CLAUDE_WATCHER_STATE_DIR": dir.path,
                       "CLAUDE_WATCHER_CLAUDE_PID": String(ProcessInfo.processInfo.processIdentifier),
                       "CLAUDE_WATCHER_NO_GHOSTTY_PROBE": "1",
                       "TERM_PROGRAM": "ghostty",
                       "CLAUDE_WATCHER_NO_JQ": noJQ ? "1" : "0"]
            env.merge(extraEnv) { $1 }
            let r = try await runProcess(HookScriptTests.script, environment: env, currentDirectory: cwd,
                                         stdin: Data(json.utf8))
            return Run(status: r.status, stdout: String(decoding: r.stdout, as: UTF8.self))
        }

        /// The state as the app sees it: `<sid>.json` joined with its `<sid>.ghostty` sidecar.
        func state(_ sid: String) throws -> HookState? {
            HookStateStore.loadAll(directory: dir)[sid]
        }

        func json(_ sid: String) -> String? {
            try? String(contentsOf: dir.appendingPathComponent("\(sid).json"), encoding: .utf8)
        }

        func sidecar(_ sid: String) -> String? {
            try? String(contentsOf: dir.appendingPathComponent("\(sid).ghostty"), encoding: .utf8)
        }

        func setGhosttyID(_ sid: String, _ id: String) throws {
            try Data(id.utf8).write(to: dir.appendingPathComponent("\(sid).ghostty"))
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
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
    func writesStateOnSessionStart(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        let r = try await env.run(Self.input("s-1", "SessionStart"))
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
        // The id lives only in the sidecar now.
        #expect(env.json("s-1")?.contains("ghostty_terminal_id") == false)
        // Only the state file (plus GC stamp) remains; no temp files, no locks.
        let names = try FileManager.default.contentsOfDirectory(atPath: env.dir.path).sorted()
        #expect(names == [".gc-stamp", "s-1.json"])
    }

    @Test(arguments: [false, true])
    func preservesGhosttyIDAndUpdatesEvent(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        try await env.run(Self.input("s-1", "SessionStart"))
        try env.setGhosttyID("s-1", "0FD9735C-6645-44F3-975D-7BC605D03215")
        try await env.run(Self.input("s-1", "UserPromptSubmit"))
        let s = try #require(try env.state("s-1"))
        #expect(s.lastEvent == "UserPromptSubmit")
        #expect(s.ghosttyTerminalID == "0FD9735C-6645-44F3-975D-7BC605D03215")
        #expect(env.sidecar("s-1") == "0FD9735C-6645-44F3-975D-7BC605D03215")
    }

    @Test func concurrentHooksNeverTouchTheSidecar() async throws {
        let env = try Env(noJQ: false)
        try await env.run(Self.input("s-1", "SessionStart"))
        try env.setGhosttyID("s-1", "GID-1")
        let sidecar = env.dir.appendingPathComponent("s-1.ghostty")
        let inode = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.systemFileNumber] as? Int
        await withTaskGroup { group in
            for i in 0..<16 {
                group.addTask { _ = try? await env.run(Self.input("s-1", i.isMultiple(of: 2) ? "UserPromptSubmit" : "Stop")) }
            }
        }
        #expect(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.systemFileNumber] as? Int == inode)
        #expect(try env.state("s-1")?.ghosttyTerminalID == "GID-1")
        #expect(env.json("s-1")?.contains("GID-1") == false)
    }

    @Test(arguments: [false, true])
    func sessionEndDeletesAndBlocksLateWriters(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        try await env.run(Self.input("s-1", "SessionStart"))
        #expect(try await env.run(Self.input("s-1", "SessionEnd")).status == 0)
        #expect(try env.state("s-1") == nil)
        // A late async Stop must not resurrect the file.
        try await env.run(Self.input("s-1", "Stop"))
        #expect(try env.state("s-1") == nil)
        // A resume of the same id starts it again.
        try await env.run(Self.input("s-1", "SessionStart"))
        #expect(try env.state("s-1") != nil)
    }

    @Test(arguments: [false, true])
    func clearSupersedesSamePIDAndAdoptsGhosttyID(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        try await env.run(Self.input("old", "SessionStart"))
        try env.setGhosttyID("old", "GID-1")
        try await env.run(Self.input("old", "SessionEnd"))
        // The tombstone keeps its sidecar for the successor.
        #expect(env.exists("old.ended") && env.sidecar("old") == "GID-1")
        try await env.run(Self.input("new", "SessionStart"))
        #expect(try env.state("old") == nil)
        #expect(try env.state("new")?.ghosttyTerminalID == "GID-1")
        #expect(env.sidecar("new") == "GID-1")
        // A still-live file for the same pid (no SessionEnd seen) is also dropped, sidecar included.
        try await env.run(Self.input("newer", "SessionStart"))
        #expect(try env.state("new") == nil)
        #expect(env.sidecar("new") == nil)
        #expect(try env.state("newer")?.ghosttyTerminalID == "GID-1")
    }

    @Test func successorInAnotherTerminalDoesNotInherit() async throws {
        let env = try Env(noJQ: false)
        try await env.run(Self.input("old", "SessionStart"), extraEnv: ["CLAUDE_WATCHER_TTY": "/dev/ttys901"])
        try env.setGhosttyID("old", "GID-1")
        try await env.run(Self.input("new", "SessionStart"), extraEnv: ["CLAUDE_WATCHER_TTY": "/dev/ttys902"])
        #expect(try env.state("new")?.ghosttyTerminalID == nil)
        #expect(env.sidecar("new") == nil)
    }

    @Test func ownSidecarSurvivesOnlyARestartInTheSameProcess() async throws {
        let env = try Env(noJQ: false)
        try await env.run(Self.input("s-1", "SessionStart"))
        try env.setGhosttyID("s-1", "GID-1")
        // SessionStart "compact" (same id, same process): kept.
        try await env.run(Self.input("s-1", "SessionStart"))
        #expect(try env.state("s-1")?.ghosttyTerminalID == "GID-1")
        // --resume of the same id in another claude process (our parent here): dropped.
        try await env.run(Self.input("s-1", "SessionEnd"))
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: ["CLAUDE_WATCHER_CLAUDE_PID": String(getppid())])
        #expect(try env.state("s-1")?.claudePID == getppid())
        #expect(try env.state("s-1")?.ghosttyTerminalID == nil)
        #expect(env.sidecar("s-1") == nil)
    }

    @Test(arguments: [false, true])
    func ignoresBadInputSilently(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        for bad in ["", "not json", #"{"session_id":"../evil","hook_event_name":"Stop"}"#,
                    #"{"session_id":".hidden","hook_event_name":"Stop"}"#, #"{"hook_event_name":"Stop"}"#] {
            let r = try await env.run(bad)
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: env.dir.path)
        #expect(names.allSatisfy { $0.hasPrefix(".") })
    }

    @Test func skipsWhenNoClaudeAncestor() async throws {
        let env = try Env(noJQ: false)
        // A pid that does not exist: the walk finds no claude process, so nothing is written.
        let r = try await env.run(Self.input("s-1", "SessionStart"), extraEnv: ["CLAUDE_WATCHER_CLAUDE_PID": "999999"])
        #expect(r.status == 0)
        #expect(try env.state("s-1") == nil)
    }

    @Test func garbageCollectsDeadPIDs() async throws {
        let env = try Env(noJQ: false)
        let dead = #"{"session_id":"dead","claude_pid":999999,"last_event":"Stop","updated_at":1}"#
        let notClaude = #"{"session_id":"init","claude_pid":1,"last_event":"Stop","updated_at":1}"#
        try Data(dead.utf8).write(to: env.dir.appendingPathComponent("dead.json"))
        try Data(notClaude.utf8).write(to: env.dir.appendingPathComponent("init.json"))
        try env.setGhosttyID("dead", "GID-D")
        try env.setGhosttyID("orphan", "GID-O")
        try Data().write(to: env.dir.appendingPathComponent("ended.ended"))
        try env.setGhosttyID("ended", "GID-E")
        let grave = env.dir.appendingPathComponent(".probe-ttys009.lock.stale-1")
        try FileManager.default.createDirectory(at: grave, withIntermediateDirectories: true)
        try Data("1 x".utf8).write(to: grave.appendingPathComponent("owner"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: grave.path)
        try await env.run(Self.input("s-1", "Stop"))
        #expect(try env.state("dead") == nil)
        #expect(try env.state("init") == nil)
        #expect(try env.state("s-1") != nil)
        #expect(env.sidecar("dead") == nil)
        #expect(env.sidecar("orphan") == nil)
        #expect(env.sidecar("ended") == "GID-E")   // tombstone still there: kept for a successor
        #expect(!env.exists(grave.lastPathComponent))
    }

    // MARK: npm installs (node running @anthropic-ai/claude-code)

    /// A fake npm layout without spaces in its path (ps args are split on spaces): `node` is a
    /// symlink to tail (argv0 basename "node"), `bin/claude` and `bin/cc` link to the package's
    /// cli.js, `other.js` is some other script.
    final class FakeNode {
        let root: URL
        var procs: [Process] = []
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("cwnpm-\(UUID().uuidString)")
            let fm = FileManager.default
            let pkg = root.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code")
            try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Data().write(to: pkg.appendingPathComponent("cli.js"))
            try Data().write(to: root.appendingPathComponent("other.js"))
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("node").path, withDestinationPath: "/usr/bin/tail")
            for name in ["claude", "cc"] {
                try fm.createSymbolicLink(atPath: root.appendingPathComponent("bin/\(name)").path,
                                          withDestinationPath: "../lib/node_modules/@anthropic-ai/claude-code/cli.js")
            }
        }
        deinit {
            for p in procs where p.isRunning { p.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        /// Runs `node <args…>` (tail -f, so it stays up); returns its pid.
        func spawn(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = root.appendingPathComponent("node")
            p.arguments = args.map { $0.replacingOccurrences(of: "$ROOT", with: root.path) }
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            procs.append(p)
            return p.processIdentifier
        }
    }

    @Test func detectsNPMInstallsInTheWalkAndGC() async throws {
        let env = try Env(noJQ: false)
        let node = try FakeNode()
        let viaBin = try node.spawn(["-f", "$ROOT/bin/claude"])   // argv[1] basename "claude"
        let viaLink = try node.spawn(["-f", "$ROOT/bin/cc"])      // resolves into the package
        let other = try node.spawn(["-f", "$ROOT/other.js"])
        try await Task.sleep(for: .seconds(0.2))
        for (sid, pid) in [("npm-bin", viaBin), ("npm-link", viaLink), ("other", other)] {
            try await env.run(Self.input(sid, "SessionStart"),
                        extraEnv: ["CLAUDE_WATCHER_CLAUDE_PID": "", "CLAUDE_WATCHER_WALK_FROM": String(pid)])
        }
        #expect(try env.state("npm-bin")?.claudePID == viaBin)
        #expect(try env.state("npm-link")?.claudePID == viaLink)
        // Not claude: the walk goes on past it (to whatever claude runs these tests, if any).
        #expect(try env.state("other")?.claudePID != other)

        // GC keeps state of live npm claudes and drops that of a live node running something else.
        for (sid, pid) in [("gc-bin", viaBin), ("gc-link", viaLink), ("gc-other", other)] {
            let json = #"{"session_id":"\#(sid)","claude_pid":\#(pid),"last_event":"Stop","updated_at":1}"#
            try Data(json.utf8).write(to: env.dir.appendingPathComponent("\(sid).json"))
        }
        try FileManager.default.removeItem(at: env.dir.appendingPathComponent(".gc-stamp"))
        try await env.run(Self.input("s-1", "Stop"))
        #expect(env.exists("gc-bin.json"))
        #expect(env.exists("gc-link.json"))
        #expect(!env.exists("gc-other.json"))
    }

    // MARK: Hook version 1 migration (Ghostty id inline in <sid>.json)

    /// Rewrites `<sid>.json` as hook version 1 wrote it: with the id inline.
    func makeV1(_ env: Env, _ sid: String, id: String) throws {
        let json = try #require(env.json(sid))
        let v1 = json.replacingOccurrences(of: #""updated_at""#, with: #""ghostty_terminal_id":\#(id),"updated_at""#)
        try Data(v1.utf8).write(to: env.dir.appendingPathComponent("\(sid).json"))
    }

    @Test(arguments: [false, true])
    func migratesAV1InlineIDToTheSidecar(noJQ: Bool) async throws {
        // A fresh dir per case: sessions of one pid and tty would adopt each other's ids.
        for event in ["Stop", "SessionStart", "SessionEnd"] {
            let env = try Env(noJQ: noJQ)
            let sid = "s-\(event)"
            try await env.run(Self.input(sid, "Stop"))
            try makeV1(env, sid, id: #""0FD9735C-6645-44F3-975D-7BC605D03215""#)
            try await env.run(Self.input(sid, event))
            #expect(env.sidecar(sid) == "0FD9735C-6645-44F3-975D-7BC605D03215", "\(event)")
            if event != "SessionEnd" {
                #expect(env.json(sid)?.contains("ghostty_terminal_id") == false)
                #expect(try env.state(sid)?.ghosttyTerminalID == "0FD9735C-6645-44F3-975D-7BC605D03215")
            }
        }
        // null, an invalid id, or an existing sidecar: nothing (else) written.
        for (sid, id) in [("n", "null"), ("bad", #""bad id;rm""#), ("long", "\"\(String(repeating: "A", count: 129))\"")] {
            let env = try Env(noJQ: noJQ)
            try await env.run(Self.input(sid, "Stop"))
            try makeV1(env, sid, id: id)
            try await env.run(Self.input(sid, "Stop"))
            #expect(env.sidecar(sid) == nil, "\(sid)")
        }
        let env = try Env(noJQ: noJQ)
        try await env.run(Self.input("kept", "Stop"))
        try env.setGhosttyID("kept", "GID-NEW")
        try makeV1(env, "kept", id: #""GID-OLD""#)
        try await env.run(Self.input("kept", "Stop"))
        #expect(env.sidecar("kept") == "GID-NEW")
    }

    /// A /clear successor of a version-1 session (id only inline in the predecessor's JSON).
    @Test func clearSuccessorAdoptsAV1InlineID() async throws {
        let env = try Env(noJQ: false)
        try await env.run(Self.input("old", "SessionStart"))
        try makeV1(env, "old", id: #""GID-V1""#)
        try FileManager.default.moveItem(at: env.dir.appendingPathComponent("old.json"),
                                         to: env.dir.appendingPathComponent("old.ended"))   // v1 SessionEnd
        try await env.run(Self.input("new", "SessionStart"))
        #expect(try env.state("new")?.ghosttyTerminalID == "GID-V1")
    }

    // MARK: Tombstone age (R2-11)

    func mtime(_ env: Env, _ name: String) throws -> Date {
        try #require(try FileManager.default.attributesOfItem(atPath: env.dir.appendingPathComponent(name).path)[.modificationDate] as? Date)
    }

    func age(_ env: Env, _ name: String, by seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)],
                                              ofItemAtPath: env.dir.appendingPathComponent(name).path)
    }

    @Test func tombstoneIsFreshAndSurvivesGCForTheSuccessor() async throws {
        let env = try Env(noJQ: false)
        try await env.run(Self.input("old", "SessionStart"))
        try env.setGhosttyID("old", "GID-1")
        // The last write was long ago (idle session), then SessionEnd: the tombstone is new.
        try age(env, "old.json", by: 7200)
        try await env.run(Self.input("old", "SessionEnd"))
        #expect(abs(try mtime(env, "old.ended").timeIntervalSinceNow) < 60)
        // GC due now: it must neither take the fresh tombstone nor run before adoption.
        try FileManager.default.removeItem(at: env.dir.appendingPathComponent(".gc-stamp"))
        try await env.run(Self.input("other", "Stop"))
        #expect(env.exists("old.ended") && env.sidecar("old") == "GID-1")
        try await env.run(Self.input("new", "SessionStart"))
        #expect(try env.state("new")?.ghosttyTerminalID == "GID-1")
    }

    @Test func successorAdoptsBeforeGCDropsAnOldTombstone() async throws {
        let env = try Env(noJQ: false)
        try await env.run(Self.input("old", "SessionStart"))
        try env.setGhosttyID("old", "GID-1")
        try await env.run(Self.input("old", "SessionEnd"))
        try age(env, "old.ended", by: 7200)
        try FileManager.default.removeItem(at: env.dir.appendingPathComponent(".gc-stamp"))
        try await env.run(Self.input("new", "SessionStart"))
        #expect(try env.state("new")?.ghosttyTerminalID == "GID-1")
        #expect(!env.exists("old.ended") && env.sidecar("old") == nil)   // GC'd, after adoption
    }

    @Test func isFast() async throws {
        let env = try Env(noJQ: false)
        try await env.run(Self.input("s-1", "SessionStart"))
        let start = Date()
        for _ in 0..<10 { try await env.run(Self.input("s-1", "Stop")) }
        let perRun = Date().timeIntervalSince(start) / 10
        #expect(perRun < 0.2, "hook took \(Int(perRun * 1000))ms per run")
    }

    // MARK: Ghostty OSC 7 probe (fake tty file + stub osascript)

    /// Sets up a probe run: a regular file as the tty (unless `fifo`) and an osascript stub that
    /// records the nonce it was asked about (in `nonces`), sleeps `delay` seconds and prints
    /// `ids` (one per line).
    static func probeEnv(_ env: Env, ids: [String], delay: Double = 0, fifo: Bool = false) throws -> [String: String] {
        let tty = env.dir.appendingPathComponent("tty")
        if fifo {
            try? FileManager.default.removeItem(at: tty)
            #expect(mkfifo(tty.path, 0o600) == 0)
        } else {
            try Data().write(to: tty)
        }
        let stub = env.dir.appendingPathComponent("osascript-stub")
        let script = """
        #!/bin/sh
        for a; do last=$a; done
        printf '%s\\n' "$last" >> "$(dirname "$0")/nonces"
        sleep \(delay)
        printf '\(ids.joined(separator: "\\n"))'
        """
        try Data(script.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return ["CLAUDE_WATCHER_NO_GHOSTTY_PROBE": "0", "CLAUDE_WATCHER_TTY": tty.path,
                "CLAUDE_WATCHER_OSASCRIPT": stub.path]
    }

    /// Polls `cond` every 10 ms until it holds or `timeout` passes, suspending (not blocking a
    /// cooperative thread) between polls.
    static func waitFor(_ timeout: TimeInterval = 5, _ cond: () throws -> Bool) async rethrows -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return try cond()
    }

    /// `waitFor` for code already running on a dedicated thread (see `onDedicatedThread`).
    static func blockingWaitFor(_ timeout: TimeInterval, _ cond: () throws -> Bool) rethrows -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try cond() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try cond()
    }

    /// The OSC 7 sequences in `bytes`, as (host, path) still percent-encoded.
    /// Every byte inside a sequence must be printable ASCII without spaces.
    static func osc7Sequences(_ bytes: Data) -> [(host: String, path: String)] {
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

    /// The OSC 7 sequences written to the fake tty file.
    static func osc7Writes(_ env: Env) throws -> [(host: String, path: String)] {
        osc7Sequences(try Data(contentsOf: env.dir.appendingPathComponent("tty")))
    }

    static let probeLock = ".probe-tty.lock"

    @Test(arguments: [false, true])
    func probeRestoresAnEncodedSafeCwd(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        // A real directory, so the no-jq fallback (which gives up on JSON escapes and uses
        // $PWD) restores the same path as the jq path does.
        let weird = env.dir.appendingPathComponent("w %#?\\;\u{1B}]52;c;eA==\u{07} é漢")
        try FileManager.default.createDirectory(at: weird, withIntermediateDirectories: true)
        let cwd = try #require(realpath(weird.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        let host = "h\u{1B}]52;c;x\u{07}/%"
        var extra = try Self.probeEnv(env, ids: ["GID-1"])
        extra["HOST"] = host
        let r = try await env.run(try Self.jsonInput("s-1", "SessionStart", cwd: cwd), extraEnv: extra, cwd: weird)
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(try await Self.waitFor { try env.state("s-1")?.ghosttyTerminalID == "GID-1" })
        // The probe writes the sidecar and leaves <sid>.json alone; it released its lock first.
        #expect(env.sidecar("s-1") == "GID-1")
        #expect(env.json("s-1")?.contains("GID-1") == false)
        #expect(!env.exists(Self.probeLock))

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

    @Test func probeNonceIsDelimitedAndUniqueMatchRequired() async throws {
        let env = try Env(noJQ: false)
        var extra = try Self.probeEnv(env, ids: ["GID-1", "GID-2"])
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        // Two terminals report the nonce: ambiguous, so no id is recorded.
        #expect(try await Self.waitFor { try Self.osc7Writes(env).count == 2 })
        try await Task.sleep(for: .seconds(0.3))
        #expect(try env.state("s-1")?.ghosttyTerminalID == nil)
        #expect(env.sidecar("s-1") == nil)

        // The nonce ends in a delimiter, so an older nonce for the same pid that merely starts
        // with the same digits ("CW-<pid>-12345" vs "CW-<pid>-1234567") can't contain it.
        let nonces = try String(contentsOf: env.dir.appendingPathComponent("nonces"), encoding: .utf8)
        let nonce = try #require(nonces.split(separator: "\n").first.map(String.init))
        #expect(nonce.wholeMatch(of: /CW-\d+-\d+-x/) != nil, "nonce \(nonce)")

        // Exactly one match: recorded.
        extra = try Self.probeEnv(env, ids: ["GID-3"])
        try await env.run(Self.input("s-2", "SessionStart"), extraEnv: extra)
        #expect(try await Self.waitFor { try env.state("s-2")?.ghosttyTerminalID == "GID-3" })
    }

    @Test func probeAppleScriptHasATimeout() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        #expect(text.contains("with timeout of 3 seconds"))
    }

    @Test func probeIDSurvivesConcurrentHookWrites() async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"], delay: 0.2)
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        // Hooks of the same session race the detached probe; none may drop the id.
        func burst() async {
            await withTaskGroup { group in
                for _ in 0..<4 { group.addTask { _ = try? await env.run(Self.input("s-1", "UserPromptSubmit")) } }
            }
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            await burst()
            if try env.state("s-1")?.ghosttyTerminalID != nil { break }
        }
        for _ in 0..<3 { await burst() }
        #expect(try env.state("s-1")?.ghosttyTerminalID == "GID-1")
        #expect(try env.state("s-1")?.lastEvent == "UserPromptSubmit")
    }

    @Test func probeHandsTheIDToAClearSuccessor() async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"], delay: 0.6)
        try await env.run(Self.input("old", "SessionStart"), extraEnv: extra)
        // /clear while the probe is still asking Ghostty: the old session ends and a new one
        // starts in the same process and terminal, with nothing to inherit yet.
        #expect(await Self.waitFor { env.exists("nonces") })
        try await env.run(Self.input("old", "SessionEnd"))
        var successor = extra
        successor["CLAUDE_WATCHER_NO_GHOSTTY_PROBE"] = "1"
        try await env.run(Self.input("new", "SessionStart"), extraEnv: successor)
        #expect(try env.state("new")?.ghosttyTerminalID == nil)
        #expect(try await Self.waitFor { try env.state("new")?.ghosttyTerminalID == "GID-1" })
        #expect(env.sidecar("old") == "GID-1")   // next to the tombstone, for a later successor
        #expect(try env.state("old") == nil)
    }

    // MARK: Probe lock (shared with the app's OSC 7 probe)

    func makeLock(_ env: Env, owner: String, age: TimeInterval = 0) throws -> URL {
        let lock = env.dir.appendingPathComponent(Self.probeLock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try Data(owner.utf8).write(to: lock.appendingPathComponent("owner"))
        if age > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: lock.path)
        }
        return lock
    }

    @Test func probeWaitsForAHeldLock() async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"])
        let lock = try makeLock(env, owner: "1 app-token")
        let start = Date()
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        #expect(Date().timeIntervalSince(start) < 0.5, "the main hook must not wait for the probe lock")
        try await Task.sleep(for: .seconds(0.4))
        #expect(!env.exists("nonces"))
        try FileManager.default.removeItem(at: lock)   // the other probe releases its lock
        #expect(try await Self.waitFor(2) { try env.state("s-1")?.ghosttyTerminalID == "GID-1" })
        #expect(!env.exists(Self.probeLock))
    }

    @Test func probeGivesUpOnALockHeldOverOneSecond() async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"])
        let lock = try makeLock(env, owner: "1 app-token")
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        try await Task.sleep(for: .seconds(1.5))
        try FileManager.default.removeItem(at: lock)
        try await Task.sleep(for: .seconds(0.5))
        // It gave up after ~1 s instead of probing once the lock went away.
        #expect(!env.exists("nonces"))
        #expect(env.sidecar("s-1") == nil)
        #expect(!env.exists(Self.probeLock))
    }

    static let deadPID = "999999"
    static var myPID: String { String(ProcessInfo.processInfo.processIdentifier) }

    /// Protocol v2: a lock whose owner pid is dead is stale at once, whatever its age; one
    /// without a (parseable) owner only after 10 s; one whose owner is alive only after 120 s.
    static let staleLocks: [(String, Double)] = [
        ("\(deadPID) dead-token", 0), ("\(deadPID) dead-token", 30), ("", 30), ("garbage", 30), ("0 tok", 30),
        ("\(myPID) alive-token", 200), ("1 launchd-token", 200)]
    static let liveLocks: [(String, Double)] = [("\(myPID) alive-token", 60), ("1 launchd-token", 60), ("", 0)]

    @Test(arguments: staleLocks)
    func staleProbeLockIsBrokenByRename(owner: String, age: Double) async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"])
        // Not empty (owner file inside), so a plain rmdir could not have removed it.
        let lock = try makeLock(env, owner: owner, age: age)
        if owner.isEmpty {
            try FileManager.default.removeItem(at: lock.appendingPathComponent("owner"))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: lock.path)
        }
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        #expect(try await Self.waitFor { try env.state("s-1")?.ghosttyTerminalID == "GID-1" })
        let names = try FileManager.default.contentsOfDirectory(atPath: env.dir.path)
        #expect(!names.contains { $0.hasPrefix(".probe-") }, "\(names)")
    }

    /// A live owner (ours; pid 1 answers EPERM) is never broken before the 120 s cap, and a
    /// young lock without an owner (mkdir done, owner not yet written) is not either.
    @Test(arguments: liveLocks)
    func liveOrYoungProbeLockIsNotBroken(owner: String, age: Double) async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"])
        let lock = try makeLock(env, owner: owner, age: age)
        if owner.isEmpty { try FileManager.default.removeItem(at: lock.appendingPathComponent("owner")) }
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        try await Task.sleep(for: .seconds(1.5))
        #expect(!env.exists("nonces"))
        #expect(env.sidecar("s-1") == nil)
        if !owner.isEmpty {
            #expect(try String(contentsOf: lock.appendingPathComponent("owner"), encoding: .utf8) == owner)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: env.dir.path)
        #expect(names.filter { $0.hasPrefix(".probe-") } == [Self.probeLock], "\(names)")
    }

    /// R2-7: the lock judged stale is replaced by a fresh one before the rename. The breaker
    /// sees a different owner in the aside dir, puts the fresh lock back and keeps waiting.
    @Test func freshLockRenamedByMistakeIsRestored() async throws {
        let env = try Env(noJQ: false)
        var extra = try Self.probeEnv(env, ids: ["GID-1"])
        _ = try makeLock(env, owner: "\(Self.deadPID) dead-token")
        let swap = env.dir.appendingPathComponent("swap-lock")
        let script = """
        #!/bin/sh
        d=$(dirname "$0")
        [ -e "$d/swapped" ] && exit 0
        : > "$d/swapped"
        rm -rf "$d/\(Self.probeLock)"
        mkdir "$d/\(Self.probeLock)"
        printf '%s' '\(Self.myPID) fresh-token' > "$d/\(Self.probeLock)/owner"
        """
        try Data(script.utf8).write(to: swap)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swap.path)
        extra["CLAUDE_WATCHER_TEST_BEFORE_LOCK_BREAK"] = swap.path
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        #expect(await Self.waitFor { env.exists("swapped") })
        try await Task.sleep(for: .seconds(1.5))
        // Restored (not broken, not nested), and the probe gave up instead of probing.
        let owner = env.dir.appendingPathComponent(Self.probeLock).appendingPathComponent("owner")
        #expect(try String(contentsOf: owner, encoding: .utf8) == "\(Self.myPID) fresh-token")
        let inside = try FileManager.default.contentsOfDirectory(atPath: owner.deletingLastPathComponent().path)
        #expect(inside == ["owner"])
        let names = try FileManager.default.contentsOfDirectory(atPath: env.dir.path)
        #expect(names.filter { $0.hasPrefix(".probe-") } == [Self.probeLock], "\(names)")
        #expect(!env.exists("nonces"))
        #expect(env.sidecar("s-1") == nil)
    }

    @Test func probeReleasesOnlyALockItStillOwns() async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"], delay: 0.5)
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        let lock = env.dir.appendingPathComponent(Self.probeLock)
        let ownerFile = lock.appendingPathComponent("owner")
        #expect(await Self.waitFor { env.exists("nonces") })
        let owner = try String(contentsOf: ownerFile, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(owner.wholeMatch(of: /\d+ \S+/) != nil, "owner \(owner)")
        // Someone breaks the probe's lock (as if stale) and takes it while the probe runs.
        try FileManager.default.moveItem(at: lock, to: env.dir.appendingPathComponent("\(Self.probeLock).stale-test"))
        try FileManager.default.removeItem(at: env.dir.appendingPathComponent("\(Self.probeLock).stale-test"))
        _ = try makeLock(env, owner: "1 theirs")
        #expect(try await Self.waitFor { try env.state("s-1")?.ghosttyTerminalID == "GID-1" })
        #expect(try String(contentsOf: ownerFile, encoding: .utf8) == "1 theirs")
    }

    // MARK: Non-blocking tty writes (FIFO standing in for a flow-controlled tty)

    /// A FIFO "tty" whose pipe buffer is completely full (NUL filler), plus its read end.
    static func fullFIFO(_ env: Env) -> (read: Int32, write: Int32) {
        let path = env.dir.appendingPathComponent("tty").path
        let r = open(path, O_RDONLY | O_NONBLOCK)
        let w = open(path, O_WRONLY | O_NONBLOCK)
        #expect(r >= 0 && w >= 0)
        let zeros = [UInt8](repeating: 0, count: 4096)
        while write(w, zeros, zeros.count) > 0 {}
        while write(w, zeros, 1) > 0 {}
        return (r, w)
    }

    /// Reads up to `count` bytes (all available when nil) from a non-blocking fd.
    static func drain(_ fd: Int32, _ count: Int? = nil) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while count.map({ out.count < $0 }) ?? true {
            let want = min(buf.count, count.map { $0 - out.count } ?? buf.count)
            let n = read(fd, &buf, want)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// Drains `fd` in `chunk`-byte steps every `interval` until `done`, then completely.
    /// Returns everything read except the NUL filler. Blocks: call it via `onDedicatedThread`,
    /// whose precise `Thread.sleep` cadence the probe's retry budgets are measured against.
    static func drainSlowly(_ fd: Int32, chunk: Int, every interval: TimeInterval, until done: () -> Bool) -> Data {
        var out = Data()
        let end = Date().addingTimeInterval(10)
        while !done() && Date() < end {
            out.append(drain(fd, chunk))
            Thread.sleep(forTimeInterval: interval)
        }
        out.append(drain(fd))
        return out.filter { $0 != 0 }
    }

    @Test func probeRetriesShortWritesAndEAGAIN() async throws {
        let env = try Env(noJQ: false)
        var extra = try Self.probeEnv(env, ids: ["GID-1"], fifo: true)
        let host = String(repeating: "h", count: 1500)   // > PIPE_BUF: writes can be partial
        extra["HOST"] = host
        let fifo = Self.fullFIFO(env)
        defer { close(fifo.read); close(fifo.write) }
        try await env.run(Self.input("s-1", "SessionStart", cwd: "/tmp"), extraEnv: extra)
        // Free 1000 bytes every 30 ms: each ~1.5 KB sequence starts on a full pipe (EAGAIN)
        // and needs two partial writes, well within the 200 ms retry budget.
        let rfd = fifo.read
        let bytes = try await onDedicatedThread {
            Self.drainSlowly(rfd, chunk: 1000, every: 0.03) { env.sidecar("s-1") != nil }
        }
        #expect(env.sidecar("s-1") == "GID-1")
        let writes = Self.osc7Sequences(bytes)
        try #require(writes.count == 2, "\(writes.map(\.path))")
        #expect(writes.allSatisfy { $0.host == host })
        #expect(writes[0].path.hasPrefix("/tmp/CW-"))
        #expect(writes[1].path == "/tmp")
    }

    static func available(_ fd: Int32) -> Int32 {
        var n: Int32 = 0
        return ioctl(fd, 0x4004_667F /* FIONREAD */, &n) == 0 ? n : -1
    }

    @Test func probeTerminatesAPartialNonceAndStillRestores() async throws {
        let env = try Env(noJQ: false)
        var extra = try Self.probeEnv(env, ids: ["GID-1"], fifo: true)
        let host = String(repeating: "h", count: 1500)
        extra["HOST"] = host
        let fifo = Self.fullFIFO(env)
        defer { close(fifo.read); close(fifo.write) }
        let capacity = Self.available(fifo.read)
        // 700 bytes free: the ~1.5 KB nonce sequence goes out only partly (macOS pipes take a
        // partial write once >= PIPE_BUF is free), then nothing more fits for its 200 ms budget.
        #expect(Self.drain(fifo.read, 700).count == 700)
        try await env.run(Self.input("s-1", "SessionStart", cwd: "/tmp"), extraEnv: extra)
        // Timed on a dedicated thread: the drain must land in a 200 ms window.
        let rfd = fifo.read
        let (filled, bytes) = try await onDedicatedThread {
            let filled = Self.blockingWaitFor(2) { Self.available(rfd) == capacity }
            // Room again after the nonce gave up (+200 ms) but within the BEL's retry budget (+400 ms).
            Thread.sleep(forTimeInterval: 0.3)
            return (filled, Self.drainSlowly(rfd, chunk: 4096, every: 0.01) { !env.exists(Self.probeLock) })
        }
        #expect(filled, "no partial write")
        // Partial nonce, BEL, then the full restore: never an unterminated OSC string.
        let chunks = bytes.split(separator: 0x07, omittingEmptySubsequences: false)
        try #require(chunks.count == 3, "\(chunks.map(\.count))")
        let prefix = Data("\u{1B}]7;file://".utf8)
        #expect(Data(chunks[0]) == (prefix + Data(host.utf8)).prefix(700))
        #expect(Data(chunks[1]) == prefix + Data(host.utf8) + Data("/tmp".utf8))
        #expect(chunks[2].isEmpty)
        #expect(!env.exists("nonces"), "a partial nonce must not be looked up")
        #expect(env.sidecar("s-1") == nil)
    }

    @Test func probeGivesUpOnATTYThatNeverDrains() async throws {
        let env = try Env(noJQ: false)
        let extra = try Self.probeEnv(env, ids: ["GID-1"], fifo: true)
        let fifo = Self.fullFIFO(env)
        defer { close(fifo.read); close(fifo.write) }
        try await env.run(Self.input("s-1", "SessionStart"), extraEnv: extra)
        // Nothing fits: the probe gives up within its ~200 ms write budget, touching nothing.
        try await Task.sleep(for: .seconds(1))
        #expect(!env.exists(Self.probeLock))
        #expect(!env.exists("nonces"))
        #expect(Self.drain(fifo.read).allSatisfy { $0 == 0 })
        #expect(env.sidecar("s-1") == nil)
    }
}
