import Foundation
import Testing
@testable import ClaudeWatcherCore

/// Temp dirs only; the real ~/.codex is never touched.
@Suite struct CodexHookInstallerTests {
    final class Env: Sendable {
        let root: URL
        let codexHome: URL
        let installDir: URL
        let source: URL

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("codexinstall \(UUID().uuidString)")
            codexHome = root.appendingPathComponent(".codex", isDirectory: true)
            installDir = root.appendingPathComponent("Application Support/ClaudeWatcher", isDirectory: true)
            source = root.appendingPathComponent("codex-watcher-hook.sh")
            try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try Data("#!/bin/zsh -f\nexit 0\n".utf8).write(to: source)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        var hooksURL: URL { CodexHookInstaller.hooksURL(codexHome: codexHome) }
        var configURL: URL { CodexHookInstaller.configURL(codexHome: codexHome) }
        var scriptURL: URL { HookInstaller.installedScriptURL(installDirectory: installDir, profile: .codex) }
        var command: String { HookInstaller.hookCommand(scriptPath: scriptURL.path) }

        func install() throws {
            try CodexHookInstaller.install(hookScriptSource: source, codexHome: codexHome, installDirectory: installDir)
        }
        func status() -> CodexHookInstaller.Status {
            CodexHookInstaller.status(hookScriptSource: source, codexHome: codexHome, installDirectory: installDir)
        }
        func hooks() throws -> OrderedJSON { try OrderedJSON.parse(Data(contentsOf: hooksURL)) }
        func writeHooks(_ text: String) throws { try Data(text.utf8).write(to: hooksURL) }
        func writeConfig(_ text: String) throws { try Data(text.utf8).write(to: configURL) }

        /// config.toml trusting every handler of ours, in Codex's table-header form.
        func trustAll(hash: String = "sha256:abc") throws -> String {
            let keys = CodexHookInstaller.ourHandlerKeys(root: try hooks())
            return keys.map { "[hooks.state.\"\(hooksURL.path):\($0)\"]\ntrusted_hash = \"\(hash)\"\n" }
                .joined(separator: "\n")
        }
    }

    @Test func freshInstallCreatesHooksJSON() throws {
        let env = try Env()
        #expect(env.status() == .init(install: .notInstalled, needsTrust: false))
        try env.install()
        let root = try env.hooks()
        guard case let .object(pairs) = root else { Issue.record("not an object"); return }
        #expect(pairs.map(\.0) == ["hooks"])
        let events = root["hooks"]?.objectKeys ?? []
        #expect(events == HookInstaller.Profile.codex.events)
        for event in HookInstaller.Profile.codex.events {
            let handler = root["hooks"]?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first
            #expect(handler?["command"]?.stringValue == env.command)
            #expect(handler?["type"]?.stringValue == "command")
            #expect((handler?["async"] == .bool(true)) == (event != "SessionEnd"))
        }
        #expect(FileManager.default.isExecutableFile(atPath: env.scriptURL.path))
        #expect(env.scriptURL.lastPathComponent == "codex-watcher-hook.sh")
        // Installed, but Codex hasn't trusted it yet.
        #expect(env.status() == .init(install: .installed, needsTrust: true))
    }

    @Test func mergeKeepsForeignHooksDescriptionAndOrder() throws {
        let env = try Env()
        try env.writeHooks("""
        {
          "description": "my hooks",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/local/bin/notify stop"
                  }
                ]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "/usr/local/bin/guard"
                  }
                ]
              }
            ]
          }
        }

        """)
        try env.install()
        let root = try env.hooks()
        #expect(root["description"]?.stringValue == "my hooks")
        let keys = root["hooks"]?.objectKeys ?? []
        #expect(Array(keys.prefix(2)) == ["Stop", "PreToolUse"])
        let stop = root["hooks"]?["Stop"]?.arrayValue ?? []
        #expect(stop.count == 2)  // the foreign group stays first; ours is appended
        #expect(stop.first?["hooks"]?.arrayValue?.count == 1)
        #expect(stop.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue == "/usr/local/bin/notify stop")
        #expect(root["hooks"]?["PreToolUse"]?.arrayValue?.first?["matcher"]?.stringValue == "Bash")
        // Trust keys count foreign groups: ours is Stop group 1, handler 0.
        #expect(CodexHookInstaller.ourHandlerKeys(root: root).contains("stop:1:0"))
        #expect(env.status().install == .installed)
    }

    @Test func installIsIdempotent() throws {
        let env = try Env()
        try env.install()
        let first = try Data(contentsOf: env.hooksURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: env.hooksURL.path)
        let backup = try CodexHookInstaller.install(
            hookScriptSource: env.source, codexHome: env.codexHome, installDirectory: env.installDir)
        #expect(backup == nil)
        #expect(try Data(contentsOf: env.hooksURL) == first)
        let attrs2 = try FileManager.default.attributesOfItem(atPath: env.hooksURL.path)
        #expect(attrs[.modificationDate] as? Date == attrs2[.modificationDate] as? Date)
    }

    @Test func trustPresenceDecidesNeedsTrust() throws {
        let env = try Env()
        try env.install()
        #expect(env.status().needsTrust)
        try env.writeConfig("model = \"gpt\"\n\n" + (try env.trustAll()))
        #expect(env.status() == .init(install: .installed, needsTrust: false))

        // One handler missing.
        let keys = CodexHookInstaller.ourHandlerKeys(root: try env.hooks())
        let partial = keys.dropFirst().map {
            "[hooks.state.\"\(env.hooksURL.path):\($0)\"]\ntrusted_hash = \"sha256:x\"\n"
        }.joined()
        try env.writeConfig(partial)
        #expect(env.status().needsTrust)

        // Disabled counts as not runnable.
        try env.writeConfig((try env.trustAll()) + "\n[hooks.state.\"\(env.hooksURL.path):\(keys[0])\"]\nenabled = false\n")
        #expect(env.status().needsTrust)
    }

    @Test func trustAcceptsOtherTOMLForms() throws {
        let env = try Env()
        try env.install()
        let keys = CodexHookInstaller.ourHandlerKeys(root: try env.hooks())
        let path = env.hooksURL.path
        // Dotted keys under [hooks.state] and inline tables under [hooks].
        var toml = "[hooks.state]\n"
        for key in keys.prefix(3) { toml += "\"\(path):\(key)\".trusted_hash = \"sha256:1\"  # ok\n" }
        toml += "\n[hooks]\n"
        for key in keys.dropFirst(3) { toml += "state.\"\(path):\(key)\" = { enabled = true, trusted_hash = 'sha256:2' }\n" }
        try env.writeConfig(toml)
        #expect(env.status() == .init(install: .installed, needsTrust: false))
    }

    @Test func tomlScanner() {
        let states = CodexHookTrust.states(configTOML: """
        model = "x"
        [hooks.state."/a/hooks.json:stop:0:0"]
        trusted_hash = "sha256:aa"
        enabled = false
        [[profiles]]
        trusted_hash = "nope"
        [hooks.state."/a/q\\"uote.json:stop:0:0"]
        trusted_hash = "sha256:\\u0062b"
        [other]
        "hooks.state.x".trusted_hash = "no"
        """)
        #expect(states["/a/hooks.json:stop:0:0"] == .init(trustedHash: "sha256:aa", enabled: false))
        #expect(states["/a/q\"uote.json:stop:0:0"]?.trustedHash == "sha256:bb")
        #expect(states.count == 2)
    }

    @Test func eventKeyLabels() {
        #expect(CodexHookInstaller.eventKeyLabel("PermissionRequest") == "permission_request")
        #expect(CodexHookInstaller.eventKeyLabel("SessionStart") == "session_start")
        #expect(CodexHookInstaller.eventKeyLabel("UserPromptSubmit") == "user_prompt_submit")
        #expect(CodexHookInstaller.eventKeyLabel("Stop") == "stop")
    }

    @Test func outdatedWhenScriptDiffersOrEntryChanged() throws {
        let env = try Env()
        try env.install()
        try Data("#!/bin/zsh -f\n# v2\nexit 0\n".utf8).write(to: env.source)
        #expect(env.status() == .init(install: .outdated, needsTrust: false))
        try env.install()
        #expect(env.status().install == .installed)
        // Drop `async` from one of ours.
        var root = try env.hooks()
        var stop = root["hooks"]?["Stop"]?.arrayValue ?? []
        stop[0].set("hooks", .array([.object([("type", .string("command")), ("command", .string(env.command))])]))
        var hooks = root["hooks"]!
        hooks.set("Stop", .array(stop))
        root.set("hooks", hooks)
        try Data(root.serialized(indent: "  ").utf8).write(to: env.hooksURL)
        #expect(env.status().install == .outdated)
    }

    @Test func uninstallRemovesOnlyOursAndLeavesStub() throws {
        let env = try Env()
        try env.writeHooks(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/foreign"}]}]}}"#)
        try env.install()
        try CodexHookInstaller.uninstall(codexHome: env.codexHome, installDirectory: env.installDir)
        let root = try env.hooks()
        #expect(root["hooks"]?.objectKeys == ["Stop"])
        #expect(root["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue?.count == 1)
        #expect(try Data(contentsOf: env.scriptURL) == HookInstaller.noOpScript)
        #expect(env.status().install == .notInstalled)
    }

    @Test func claudeAndCodexEntriesDontTouchEachOther() throws {
        let env = try Env()
        let claudeCommand = HookInstaller.hookCommand(
            scriptPath: HookInstaller.installedScriptURL(installDirectory: env.installDir).path)
        var root = OrderedJSON.object([])
        try HookInstaller.mergeEntries(into: &root, command: claudeCommand)
        try HookInstaller.mergeEntries(into: &root, command: env.command, profile: .codex)
        #expect(HookInstaller.entriesStatus(root: root, command: claudeCommand) == .installed)
        #expect(HookInstaller.entriesStatus(root: root, command: env.command, profile: .codex) == .installed)
        try HookInstaller.removeEntries(from: &root, profile: .codex)
        #expect(HookInstaller.entriesStatus(root: root, command: claudeCommand) == .installed)
        #expect(HookInstaller.entriesStatus(root: root, command: env.command, profile: .codex) == .notInstalled)
    }

    @Test func codexPresence() throws {
        let env = try Env()
        #expect(CodexHookInstaller.isCodexPresent(codexHome: env.codexHome))
        #expect(!CodexHookInstaller.isCodexPresent(codexHome: env.root.appendingPathComponent("nope")))
    }
}

private extension OrderedJSON {
    var objectKeys: [String]? {
        if case let .object(pairs) = self { return pairs.map(\.0) }
        return nil
    }
}
