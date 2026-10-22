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

    @Test func uninstallRemovesOnlyOursAndRestoresOriginal() throws {
        let box = try Sandbox(settings: Self.fixture)
        defer { box.cleanup() }
        _ = try box.install()
        #expect(try box.uninstall() != nil)
        #expect(try box.read() == Self.fixture)
        #expect(box.status() == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: HookInstaller.installedScriptURL(installDirectory: box.installDir).path))
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
}
