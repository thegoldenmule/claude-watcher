import Foundation
import Testing
@testable import ClaudeWatcherCore

/// Runs hooks/codex-watcher-hook.sh with a temp state dir, with and without jq.
@Suite struct CodexHookScriptTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/codex-watcher-hook.sh")

    struct Run { var status: Int32; var stdout: String }

    final class Env: Sendable {
        let dir: URL
        let noJQ: Bool
        init(noJQ: Bool) throws {
            self.noJQ = noJQ
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("codexhook \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        @discardableResult
        func run(_ json: String) async throws -> Run {
            let env = ["HOME": dir.path, "PATH": "/usr/bin:/bin",
                       "CODEX_WATCHER_STATE_DIR": dir.path,
                       "CODEX_WATCHER_NO_JQ": noJQ ? "1" : "0"]
            let r = try await runProcess(CodexHookScriptTests.script, environment: env, stdin: Data(json.utf8))
            return Run(status: r.status, stdout: String(decoding: r.stdout, as: UTF8.self))
        }

        func states() -> [String: CodexHookState] {
            var cache = CodexHookStateCache()
            return cache.load(directory: dir)
        }

        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        }

        func visibleFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
        }
    }

    static func input(_ sid: String, _ event: String, turn: String? = "turn-1", agent: String? = nil,
                      cwd: String = "/tmp/with space/\"q\"") throws -> String {
        var obj: [String: Any] = ["session_id": sid, "hook_event_name": event, "cwd": cwd,
                                  "transcript_path": "/tmp/\(sid).jsonl", "model": "gpt",
                                  "permission_mode": "default"]
        if let turn { obj["turn_id"] = turn }
        if let agent { obj["agent_id"] = agent }
        if event == "PermissionRequest" {
            obj["tool_name"] = "exec_command"
            obj["tool_input"] = ["cmd": "echo \"hi\"", "nested": ["session_id": "evil"]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    @Test(arguments: [false, true])
    func writesStateSilently(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        let sid = "01a1ea15-c380-73a1-add9-25f6900a2704"
        let before = Int64(Date().timeIntervalSince1970 * 1000) - 1
        let r = try await env.run(try Self.input(sid, "PermissionRequest"))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        let state = try #require(env.states()[sid])
        #expect(state.lastEvent == "PermissionRequest")
        #expect(state.isPermissionRequest)
        #expect(state.turnID == "turn-1")
        #expect(state.agentID == nil)
        #expect(state.cwd == "/tmp/with space/\"q\"")
        #expect(state.updatedAtMillis >= before)
        #expect(env.visibleFiles() == ["\(sid).json"])
    }

    @Test(arguments: [false, true])
    func laterEventReplacesState(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        try await env.run(try Self.input("s-1", "UserPromptSubmit"))
        try await env.run(try Self.input("s-1", "PermissionRequest", agent: "01a1ea16-child"))
        #expect(env.states()["s-1"]?.agentID == "01a1ea16-child")
        let r = try await env.run(try Self.input("s-1", "Stop", turn: "turn-2"))
        #expect(r.stdout.isEmpty)
        let state = try #require(env.states()["s-1"])
        #expect(state.lastEvent == "Stop")
        #expect(state.turnID == "turn-2")
        #expect(state.agentID == nil)
    }

    @Test(arguments: [false, true])
    func sessionEndRemovesState(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        try await env.run(try Self.input("s-2", "SessionStart", turn: nil))
        #expect(env.exists("s-2.json"))
        let r = try await env.run(try Self.input("s-2", "SessionEnd", turn: nil))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(!env.exists("s-2.json"))
    }

    @Test(arguments: [false, true])
    func rejectsUnsafeSessionIDs(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        for sid in ["../escape", "", "a/b", ".hidden", "x y"] {
            let r = try await env.run(try Self.input(sid, "Stop"))
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
        }
        #expect(env.visibleFiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.dir.deletingLastPathComponent()
            .appendingPathComponent("escape.json").path))
    }

    @Test(arguments: [false, true])
    func toleratesGarbageInput(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        for input in ["", "not json", "{}", #"{"session_id":42}"#] {
            let r = try await env.run(input)
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
        }
        #expect(env.visibleFiles().isEmpty)
    }

    @Test(arguments: [false, true])
    func gcDropsOldStateFiles(noJQ: Bool) async throws {
        let env = try Env(noJQ: noJQ)
        let old = env.dir.appendingPathComponent("old.json")
        try Data(#"{"session_id":"old","last_event":"Stop","updated_at":1}"#.utf8).write(to: old)
        let past = Date().addingTimeInterval(-3 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        let recent = env.dir.appendingPathComponent("recent.json")
        try Data(#"{"session_id":"recent","last_event":"Stop","updated_at":1}"#.utf8).write(to: recent)
        try await env.run(try Self.input("s-3", "Stop"))
        #expect(!env.exists("old.json"))
        #expect(env.exists("recent.json"))
        #expect(env.exists("s-3.json"))
    }
}
