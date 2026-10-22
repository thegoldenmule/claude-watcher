import Foundation
import Testing
@testable import ClaudeWatcherCore

/// All tests use temp dirs; the real ~/.claude/settings.json is never touched.
@Suite struct HookInstallerTests {
    /// Mirrors the shape of a real user settings file (JSON.stringify(_, null, 2) style).
    static let fixture = """
    {
      "permissions": {
        "allow": [
          "Bash(make:*)"
        ]
      },
      "model": "opus",
      "hooks": {
        "Notification": [
          {
            "matcher": "idle_prompt",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/homebrew/notifier.sh notification claude"
              }
            ]
          }
        ],
        "Stop": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/homebrew/notifier.sh stop claude"
              },
              {
                "type": "command",
                "command": "node /Users/me/.claude/hooks/commit-log.mjs",
                "timeout": 10
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "echo \\"hi\\" — ünïcode",
        "padding": 0
      },
      "effortLevel": 1.5e0,
      "tui": {},
      "list": []
    }

    """

    struct Sandbox {
        let root: URL
        var settings: URL { root.appendingPathComponent(".claude/settings.json") }
        var installDir: URL { root.appendingPathComponent("Library/Application Support/ClaudeWatcher") }
        var source: URL { root.appendingPathComponent("src/claude-watcher-hook.sh") }

        init(settings contents: String?) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("hookinstaller-\(UUID().uuidString)")
            let fm = FileManager.default
            try fm.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("#!/bin/zsh -f\nexit 0\n".utf8).write(to: source)
            if let contents { try Data(contents.utf8).write(to: settings) }
        }

        func read() throws -> String { try String(contentsOf: settings, encoding: .utf8) }
        func json() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        }
        func install() throws -> URL? {
            try HookInstaller.install(hookScriptSource: source, settingsURL: settings, installDirectory: installDir)
        }
        func uninstall() throws -> URL? {
            try HookInstaller.uninstall(settingsURL: settings, installDirectory: installDir)
        }
        func status(source: URL? = nil) -> HookInstaller.InstallStatus {
            HookInstaller.status(hookScriptSource: source, settingsURL: settings, installDirectory: installDir)
        }
        func backups() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: settings.deletingLastPathComponent().path)
                .filter { $0.contains("claudewatcher-backup-") }
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static func handlers(_ json: [String: Any], _ event: String) -> [[String: Any]] {
        let hooks = json["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    static func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    static func leftoverTempFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("claudewatcher-tmp-") }
    }

    static func ours(_ json: [String: Any], _ event: String) -> [[String: Any]] {
        handlers(json, event).filter { ($0["command"] as? String)?.contains("/claude-watcher-hook.sh") == true }
    }

    @Test func orderedJSONRoundTripsFixtureByteForByte() throws {
        let parsed = try OrderedJSON.parse(Data(Self.fixture.utf8))
        #expect(parsed.serialized() + "\n" == Self.fixture)
    }

    @Test func installMergesAndPreservesEverything() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        #expect(box.status() == .notInstalled)

        let backup = try #require(try box.install())
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.fixture)
        #expect(box.status(source: box.source) == .installed)

        let json = try box.json()
        // Other settings and hooks preserved.
        #expect(json["model"] as? String == "opus")
        #expect((json["statusLine"] as? [String: Any])?["command"] as? String == "echo \"hi\" — ünïcode")
        let stop = Self.handlers(json, "Stop").compactMap { $0["command"] as? String }
        #expect(stop.contains("/opt/homebrew/notifier.sh stop claude"))
        #expect(stop.contains("node /Users/me/.claude/hooks/commit-log.mjs"))
        let notification = (json["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]]
        #expect(notification?.first?["matcher"] as? String == "idle_prompt")

        // Exactly one entry of ours per event; async except SessionEnd.
        for event in HookInstaller.events {
            let mine = Self.ours(json, event)
            #expect(mine.count == 1, "event \(event)")
            #expect(mine.first?["type"] as? String == "command")
            #expect((mine.first?["async"] as? Bool) == (event == "SessionEnd" ? nil : true), "event \(event)")
        }
        let command = try #require(Self.ours(json, "Stop").first?["command"] as? String)
        #expect(command == "'\(box.installDir.path)/claude-watcher-hook.sh'")

        // Key order and formatting preserved: the original text minus our additions is unchanged.
        let text = try box.read()
        #expect(text.hasPrefix("{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(make:*)\"\n    ]\n  },\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Notification\": [\n      {\n        \"matcher\": \"idle_prompt\","))
        #expect(text.contains("\"effortLevel\": 1.5e0,"))
        #expect(text.hasSuffix("  \"tui\": {},\n  \"list\": []\n}\n"))

        // Script copied and executable.
        let script = HookInstaller.installedScriptURL(installDirectory: box.installDir)
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
        #expect(try Data(contentsOf: script) == Data(contentsOf: box.source))
    }

    @Test func installIsIdempotent() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        _ = try box.install()
        let first = try box.read()
        #expect(try box.install() == nil) // nothing to change, no backup
        #expect(try box.read() == first)
        #expect(try box.backups().count == 1)
        for event in HookInstaller.events {
            #expect(Self.ours(try box.json(), event).count == 1)
        }
    }

    /// `hooks` holding only our (current) entries, followed by other root keys: a reinstall
    /// must not remove and re-append them (which would move `hooks` after `model`).
    @Test func reinstallOverOnlyOurEntriesChangesNothing() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        let command = HookInstaller.hookCommand(
            scriptPath: HookInstaller.installedScriptURL(installDirectory: box.installDir).path)
        let hooks = OrderedJSON.object(HookInstaller.events.map {
            ($0, .array([HookInstaller.desiredGroup(event: $0, command: command)]))
        })
        let original = OrderedJSON.object([("hooks", hooks), ("model", .string("opus"))]).serialized() + "\n"
        try Data(original.utf8).write(to: box.settings)

        #expect(try HookInstaller.transformedSettings(Data(original.utf8)) {
            try HookInstaller.mergeEntries(into: &$0, command: command)
        } == nil)
        #expect(try box.install() == nil) // no write, no backup
        #expect(try box.read() == original)
        #expect(try box.backups().isEmpty)
        #expect(box.status(source: box.source) == .installed)

        // Uninstall still prunes the containers that held only ours.
        #expect(try box.uninstall() != nil)
        #expect(try box.read() == "{\n  \"model\": \"opus\"\n}\n")
    }

    /// Outdated handlers of ours are rewritten where they are: same event key, same group
    /// (matcher kept), same position among foreign handlers; duplicates are dropped, a handler
    /// stuck in a group with a restricting matcher is moved out, missing events are appended.
    @Test func outdatedEntriesAreUpdatedInPlace() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        let old = "'/old/place/claude-watcher-hook.sh'"
        let original = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "",
                "hooks": [
                  {
                    "type": "command",
                    "command": "before.sh"
                  },
                  {
                    "type": "command",
                    "command": "\(old)",
                    "timeout": 5
                  },
                  {
                    "type": "command",
                    "command": "after.sh"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "\(old)"
                  }
                ]
              }
            ],
            "Notification": [
              {
                "matcher": "idle_prompt",
                "hooks": [
                  {
                    "type": "command",
                    "command": "\(old)"
                  },
                  {
                    "type": "command",
                    "command": "notifier.sh"
                  }
                ]
              }
            ],
            "SessionEnd": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "\(old)",
                    "async": true
                  }
                ]
              }
            ],
            "PreCompact": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "\(old)"
                  }
                ]
              }
            ]
          },
          "model": "opus"
        }

        """
        try Data(original.utf8).write(to: box.settings)
        #expect(box.status() == .outdated)
        #expect(try box.install() != nil)
        #expect(box.status(source: box.source) == .installed)

        let command = HookInstaller.hookCommand(
            scriptPath: HookInstaller.installedScriptURL(installDirectory: box.installDir).path)
        let root = try OrderedJSON.parse(Data(contentsOf: box.settings))
        guard case let .object(rootPairs) = root, case let .object(eventPairs)? = root["hooks"] else {
            Issue.record("not an object"); return
        }
        #expect(rootPairs.map(\.0) == ["hooks", "model"])
        // Existing events keep their order; the stray PreCompact entry is gone; missing events appended.
        #expect(eventPairs.map(\.0) == ["Stop", "Notification", "SessionEnd", "SessionStart", "UserPromptSubmit"])

        let desiredStop = HookInstaller.desiredHandler(event: "Stop", command: command)
        #expect(root["hooks"]?["Stop"] == .array([
            .object([("matcher", .string("")), ("hooks", .array([
                .object([("type", .string("command")), ("command", .string("before.sh"))]),
                desiredStop,
                .object([("type", .string("command")), ("command", .string("after.sh"))]),
            ]))]),
        ]))
        #expect(root["hooks"]?["Notification"] == .array([
            .object([("matcher", .string("idle_prompt")), ("hooks", .array([
                .object([("type", .string("command")), ("command", .string("notifier.sh"))]),
            ]))]),
            HookInstaller.desiredGroup(event: "Notification", command: command),
        ]))
        #expect(root["hooks"]?["SessionEnd"] == .array([HookInstaller.desiredGroup(event: "SessionEnd", command: command)]))

        // Now current: a second install changes nothing.
        let after = try box.read()
        #expect(try box.install() == nil)
        #expect(try box.read() == after)
    }

    @Test func defaultSettingsURLFollowsClaudeHome() {
        #expect(HookInstaller.defaultSettingsURL
            == SessionDiscovery.defaultClaudeHome.appendingPathComponent("settings.json"))
        let custom = URL(fileURLWithPath: "/tmp/custom-claude", isDirectory: true)
        #expect(HookInstaller.settingsURL(claudeHome: custom).path == "/tmp/custom-claude/settings.json")
    }

    @Test func uninstallRemovesOnlyOursAndRestoresOriginal() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        _ = try box.install()
        #expect(try box.uninstall() != nil)
        #expect(try box.read() == Self.fixture)
        #expect(box.status() == .notInstalled)
        #expect(box.status(source: box.source) == .notInstalled)
        // Script replaced by an executable no-op stub, not deleted (running sessions still call it).
        let script = HookInstaller.installedScriptURL(installDirectory: box.installDir)
        #expect(try Data(contentsOf: script) == HookInstaller.noOpScript)
        #expect(try Self.mode(script) == 0o755)
        #expect(try Self.leftoverTempFiles(box.installDir).isEmpty)
        // Second uninstall: no-op.
        #expect(try box.uninstall() == nil)
        #expect(try box.read() == Self.fixture)
    }

    @Test func uninstallKeepsForeignHandlersSharingAGroup() throws {
        let mixed = """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/old/place/claude-watcher-hook.sh'"
                  },
                  {
                    "type": "command",
                    "command": "other.sh"
                  }
                ]
              }
            ]
          }
        }

        """
        let box = try Sandbox(settings: mixed)
        defer { box.cleanup() }
        #expect(box.status() == .outdated)
        _ = try box.uninstall()
        let stop = Self.handlers(try box.json(), "Stop")
        #expect(stop.count == 1)
        #expect(stop.first?["command"] as? String == "other.sh")
    }

    @Test func installHandlesMissingFile() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        #expect(box.status() == .notInstalled)
        #expect(try box.install() == nil) // nothing to back up
        let json = try box.json()
        #expect(Array(json.keys) == ["hooks"])
        #expect(box.status() == .installed)
        _ = try box.uninstall()
        #expect(try box.read() == "{}\n")
    }

    @Test func installHandlesMissingHooksKey() throws {
        let original = "{\n  \"model\": \"opus\"\n}\n"
        let box = try Sandbox(settings: original)
        defer { box.cleanup() }
        _ = try box.install()
        let json = try box.json()
        #expect(json["model"] as? String == "opus")
        for event in HookInstaller.events { #expect(Self.ours(json, event).count == 1) }
        #expect(try box.read().hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"SessionStart\": ["))
        _ = try box.uninstall()
        #expect(try box.read() == original)
    }

    @Test func statusDetectsOutdated() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        _ = try box.install()
        // Different bundled script -> outdated.
        let newer = box.root.appendingPathComponent("src/newer.sh")
        try Data("#!/bin/zsh -f\n# v2\nexit 0\n".utf8).write(to: newer)
        #expect(box.status(source: newer) == .outdated)
        // Reinstalling from it updates the script (settings unchanged, no new backup).
        #expect(try HookInstaller.install(hookScriptSource: newer, settingsURL: box.settings, installDirectory: box.installDir) == nil)
        #expect(box.status(source: newer) == .installed)
        // Installed script removed -> outdated.
        try FileManager.default.removeItem(at: HookInstaller.installedScriptURL(installDirectory: box.installDir))
        #expect(box.status() == .outdated)
    }

    @Test func statusOutdatedWhenOneEventMissing() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        _ = try box.install()
        var root = try OrderedJSON.parse(Data(contentsOf: box.settings))
        var hooks = try #require(root["hooks"])
        hooks.remove("UserPromptSubmit")
        root.set("hooks", hooks)
        try Data(root.serialized().utf8).write(to: box.settings)
        #expect(box.status() == .outdated)
        _ = try box.install()
        #expect(box.status() == .installed)
    }

    @Test func refusesNonObjectSettingsWithoutWriting() throws {
        let box = try Sandbox(settings: "[1, 2]\n")
        defer { box.cleanup() }
        #expect(throws: HookInstaller.InstallError.self) { try box.install() }
        #expect(try box.read() == "[1, 2]\n")
        let bad = try Sandbox(settings: "{ \"a\": ")
        defer { bad.cleanup() }
        #expect(throws: HookInstaller.InstallError.self) { try bad.install() }
        #expect(try bad.read() == "{ \"a\": ")
    }

    @Test func followsSymlinkedSettings() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        let real = box.root.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.fixture.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: box.settings, withDestinationURL: real)
        _ = try box.install()
        let attrs = try FileManager.default.attributesOfItem(atPath: box.settings.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(Self.ours(try box.json(), "Stop").count == 1)
    }

    // MARK: Atomic script publishing

    @Test func writeAtomicallySetsModeBeforeRename() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        let target = box.root.appendingPathComponent("script.sh")
        try Data("old\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let payload = Data("#!/bin/sh\necho new\n".utf8)
        var sawTemp = false
        try HookInstaller.writeAtomically(payload, to: target, mode: 0o755) { temp throws in
            sawTemp = true
            // The file that is about to be renamed into place is already complete and 0755,
            // and the destination still holds the old file.
            #expect(temp.deletingLastPathComponent().path == target.deletingLastPathComponent().path)
            #expect(try Self.mode(temp) == 0o755)
            #expect(try Data(contentsOf: temp) == payload)
            #expect(try Data(contentsOf: target) == Data("old\n".utf8))
        }
        #expect(sawTemp)
        #expect(try Self.mode(target) == 0o755)
        #expect(try Data(contentsOf: target) == payload)
        #expect(try Self.leftoverTempFiles(box.root).isEmpty)
    }

    @Test func writeAtomicallyAbortLeavesTargetAndNoTemp() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        let target = box.root.appendingPathComponent("script.sh")
        try Data("old\n".utf8).write(to: target)
        struct Abort: Error {}
        #expect(throws: Abort.self) {
            try HookInstaller.writeAtomically(Data("new".utf8), to: target, mode: 0o755) { _ in throw Abort() }
        }
        #expect(try Data(contentsOf: target) == Data("old\n".utf8))
        #expect(try Self.leftoverTempFiles(box.root).isEmpty)
    }

    @Test func installPublishesExecutableScriptAndReplacesStub() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        let script = HookInstaller.installedScriptURL(installDirectory: box.installDir)
        // A previous non-executable copy is replaced by a new 0755 file, not chmodded in place.
        try FileManager.default.createDirectory(at: box.installDir, withIntermediateDirectories: true)
        try Data("stale\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        _ = try box.install()
        #expect(try Self.mode(script) == 0o755)
        #expect(try Data(contentsOf: script) == Data(contentsOf: box.source))
        #expect(try Self.leftoverTempFiles(box.installDir).isEmpty)
        // Uninstall -> stub; reinstall replaces the stub with the real script.
        _ = try box.uninstall()
        #expect(try Data(contentsOf: script) == HookInstaller.noOpScript)
        _ = try box.install()
        #expect(try Data(contentsOf: script) == Data(contentsOf: box.source))
        #expect(box.status(source: box.source) == .installed)
    }

    @Test func noOpStubRunsAndExitsZero() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        _ = try box.install()
        _ = try box.uninstall()
        let process = Process()
        process.executableURL = HookInstaller.installedScriptURL(installDirectory: box.installDir)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    // MARK: Lost-update protection

    @Test func concurrentSaveBetweenReadAndWriteIsRetried() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        let concurrent = Self.fixture.replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
        var commits = 0
        var transforms = 0
        let command = HookInstaller.hookCommand(scriptPath: "/x/claude-watcher-hook.sh")
        let backup = try HookInstaller.editSettings(at: box.settings, beforeCommit: {
            commits += 1
            if commits == 1 { try Data(concurrent.utf8).write(to: box.settings, options: .atomic) }
        }) { root in
            transforms += 1
            try HookInstaller.mergeEntries(into: &root, command: command)
        }
        #expect(commits == 2)
        #expect(transforms == 2)
        // The concurrent change survives and our entries were applied on top of it.
        let json = try box.json()
        #expect(json["model"] as? String == "sonnet")
        #expect(Self.ours(json, "Stop").count == 1)
        // One backup, of the content we actually transformed.
        #expect(try box.backups().count == 1)
        #expect(try String(contentsOf: try #require(backup), encoding: .utf8) == concurrent)
        #expect(try Self.leftoverTempFiles(box.settings.deletingLastPathComponent()).isEmpty)
    }

    @Test func inPlaceRewriteIsDetected() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        var commits = 0
        _ = try HookInstaller.editSettings(at: box.settings, beforeCommit: {
            commits += 1
            guard commits == 1 else { return }
            // Same inode, different size (like Claude Code's in-place rewrites).
            let h = try FileHandle(forWritingTo: box.settings)
            try h.seekToEnd()
            try h.write(contentsOf: Data("\n".utf8))
            try h.close()
        }) { root in root.set("added", .bool(true)) }
        #expect(commits == 2)
        #expect(try box.json()["added"] as? Bool == true)
    }

    @Test func persistentConflictGivesUpWithoutWriting() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        var commits = 0
        var last = ""
        #expect {
            try HookInstaller.editSettings(at: box.settings, beforeCommit: {
                commits += 1
                last = Self.fixture.replacingOccurrences(of: "\"opus\"", with: "\"opus-\(commits)\"")
                try Data(last.utf8).write(to: box.settings, options: .atomic)
            }) { root in root.set("added", .bool(true)) }
        } throws: { error in
            guard case .settingsChangedConcurrently(let n)? = error as? HookInstaller.InstallError else { return false }
            return n == HookInstaller.maxEditAttempts
        }
        #expect(commits == HookInstaller.maxEditAttempts)
        #expect(try box.read() == last) // the other writer's content, untouched
        #expect(try box.backups().isEmpty)
        #expect(try Self.leftoverTempFiles(box.settings.deletingLastPathComponent()).isEmpty)
    }

    @Test func createdSettingsConflictWhenFileAppears() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        var commits = 0
        _ = try HookInstaller.editSettings(at: box.settings, beforeCommit: {
            commits += 1
            if commits == 1 { try Data("{\n  \"model\": \"opus\"\n}\n".utf8).write(to: box.settings) }
        }) { root in root.set("added", .bool(true)) }
        #expect(commits == 2)
        let json = try box.json()
        #expect(json["model"] as? String == "opus")
        #expect(json["added"] as? Bool == true)
    }

    @Test func editKeepsSettingsPermissions() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: box.settings.path)
        let backup = try #require(try box.install())
        #expect(try Self.mode(box.settings) == 0o600)
        #expect(try Self.mode(backup) == 0o600)
    }

    // MARK: Lossless parsing

    @Test func refusesUnpairedSurrogatesWithoutWriting() throws {
        for literal in [#""\uD83D""#, #""\uDE00""#, #""\uD83Dx""#, #""\uD83D\u0041""#] {
            let original = "{\n  \"s\": \(literal)\n}\n"
            let box = try Sandbox(settings: original)
            defer { box.cleanup() }
            #expect(throws: HookInstaller.InstallError.self, "\(literal)") { try box.install() }
            #expect(try box.read() == original)
            #expect(try box.backups().isEmpty)
        }
        // A proper pair still parses (and is printed as the character itself).
        let pair = try OrderedJSON.parse(Data(#"{"s": "\uD83D\uDE00"}"#.utf8))
        #expect(pair["s"]?.stringValue == "\u{1F600}")
    }

    @Test func refusesInvalidUTF8WithoutWriting() throws {
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        let original = Data("{\n  \"s\": \"a".utf8) + Data([0xFF, 0xFE]) + Data("\"\n}\n".utf8)
        try original.write(to: box.settings)
        #expect(throws: HookInstaller.InstallError.self) { try box.install() }
        #expect(try Data(contentsOf: box.settings) == original)
        #expect(try box.backups().isEmpty)
        #expect(box.status() == .notInstalled)
    }

    @Test func preservesBOM() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let original = bom + Data(Self.fixture.utf8)
        let box = try Sandbox(settings: nil)
        defer { box.cleanup() }
        try original.write(to: box.settings)
        _ = try box.install()
        let installed = try Data(contentsOf: box.settings)
        #expect(installed.starts(with: bom))
        #expect(box.status() == .installed)
        _ = try box.uninstall()
        #expect(try Data(contentsOf: box.settings) == original)
        // BOM-only / whitespace-only files count as empty and keep the BOM.
        let empty = try #require(try HookInstaller.transformedSettings(bom + Data("\n".utf8)) { $0.set("a", .bool(true)) })
        #expect(empty == bom + Data("{\n  \"a\": true\n}\n".utf8))
    }
}

/// Opt-in, touches the real ~/.claude/settings.json:
///   CLAUDE_WATCHER_REAL_INSTALL=1 swift test --filter RealHookInstall
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDE_WATCHER_REAL_INSTALL"] == "1"))
struct RealHookInstall {
    @Test func installForReal() throws {
        let source = HookScriptTests.script
        // The real file must survive an order-preserving parse/print unchanged before we edit it.
        let original = try Data(contentsOf: HookInstaller.defaultSettingsURL)
        #expect(try HookInstaller.transformedSettings(original) { _ in } == nil)
        let reprinted = try OrderedJSON.parse(original).serialized(indent: HookInstaller.detectIndent(original) ?? "  ")
            + (original.last == 0x0A ? "\n" : "")
        #expect(Data(reprinted.utf8) == original, "real settings.json does not round-trip byte-for-byte")
        let backup = try HookInstaller.install(hookScriptSource: source)
        print("CLAUDE_WATCHER_BACKUP=\(backup?.path ?? "none")")
        #expect(HookInstaller.status(hookScriptSource: source) == .installed)
    }
}
