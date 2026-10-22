import Foundation

/// Installs / uninstalls the ClaudeWatcher hook in Claude Code's user settings.
///
/// Install copies the hook script to `~/Library/Application Support/ClaudeWatcher/` and merges
/// one matcher group per event into `~/.claude/settings.json` `hooks`. Our entries are
/// identified by their command containing `/claude-watcher-hook.sh`; everything else in the
/// file is preserved (key order, other hooks, other settings). The settings file is edited
/// with an order-preserving JSON model and printed in `JSON.stringify(_, null, 2)` style, so
/// the diff is limited to our entries (see `OrderedJSON` for the small caveats).
public enum HookInstaller {
    public enum InstallStatus: Sendable, Equatable {
        /// Script present and every event has exactly our expected entry.
        case installed
        /// No entries of ours in settings.
        case notInstalled
        /// Some of our entries exist but differ from what `install` would write, the script
        /// is missing, or it differs from the bundled source passed to `status`.
        case outdated
    }

    public enum InstallError: Error, CustomStringConvertible {
        case settingsNotAnObject
        case hooksNotAnObject
        case eventNotAnArray(String)
        case unreadableSettings(String)

        public var description: String {
            switch self {
            case .settingsNotAnObject: "settings.json is not a JSON object"
            case .hooksNotAnObject: "settings.json \"hooks\" is not an object"
            case let .eventNotAnArray(e): "settings.json hooks.\(e) is not an array"
            case let .unreadableSettings(m): "settings.json could not be parsed: \(m)"
            }
        }
    }

    public static let scriptFileName = "claude-watcher-hook.sh"

    /// Events we register for. All are async (never block Claude) except SessionEnd, which
    /// runs synchronously so it completes before `claude -p` teardown kills async hooks.
    public static let events = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]
    static let synchronousEvents: Set<String> = ["SessionEnd"]

    /// `~/.claude/settings.json`
    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// `~/Library/Application Support/ClaudeWatcher`
    public static var defaultInstallDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeWatcher", isDirectory: true)
    }

    public static func installedScriptURL(installDirectory: URL = defaultInstallDirectory) -> URL {
        installDirectory.appendingPathComponent(scriptFileName)
    }

    // MARK: Public API

    public static func status(
        hookScriptSource: URL? = nil,
        settingsURL: URL = defaultSettingsURL,
        installDirectory: URL = defaultInstallDirectory
    ) -> InstallStatus {
        let script = installedScriptURL(installDirectory: installDirectory)
        let command = hookCommand(scriptPath: script.path)
        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? OrderedJSON.parse(data) else { return .notInstalled }
        let state = entriesStatus(root: root, command: command)
        guard state != .notInstalled else { return .notInstalled }
        guard FileManager.default.isExecutableFile(atPath: script.path) else { return .outdated }
        if let source = hookScriptSource {
            guard let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: script), a == b else {
                return .outdated
            }
        }
        return state
    }

    /// Idempotent. Copies the script (chmod 755) and merges our hook entries into settings,
    /// replacing any previous entries of ours. Backs up settings.json to
    /// `settings.json.claudewatcher-backup-<yyyyMMdd-HHmmss>` before changing it; does not
    /// touch the file at all when it already has exactly our entries.
    /// - Returns: the backup URL if a backup was written.
    @discardableResult
    public static func install(
        hookScriptSource: URL,
        settingsURL: URL = defaultSettingsURL,
        installDirectory: URL = defaultInstallDirectory
    ) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let script = installedScriptURL(installDirectory: installDirectory)
        let scriptData = try Data(contentsOf: hookScriptSource)
        if (try? Data(contentsOf: script)) != scriptData {
            try scriptData.write(to: script, options: .atomic)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let command = hookCommand(scriptPath: script.path)
        return try editSettings(at: settingsURL) { root in
            try mergeEntries(into: &root, command: command)
        }
    }

    /// Removes only our entries (and event arrays / the `hooks` object if that leaves them
    /// empty) and deletes the installed script. Leaves the hook-state directory alone.
    /// - Returns: the backup URL if settings.json was changed.
    @discardableResult
    public static func uninstall(
        settingsURL: URL = defaultSettingsURL,
        installDirectory: URL = defaultInstallDirectory
    ) throws -> URL? {
        let backup = try editSettings(at: settingsURL, createIfMissing: false) { root in
            try removeEntries(from: &root)
        }
        let script = installedScriptURL(installDirectory: installDirectory)
        if FileManager.default.fileExists(atPath: script.path) {
            try FileManager.default.removeItem(at: script)
        }
        return backup
    }

    // MARK: Entries

    /// Shell command for the hook. Quoted: the default path contains a space.
    static func hookCommand(scriptPath: String) -> String {
        "'" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isOurs(_ handler: OrderedJSON) -> Bool {
        handler["command"]?.stringValue?.contains("/" + scriptFileName) ?? false
    }

    static func desiredHandler(event: String, command: String) -> OrderedJSON {
        var pairs: [(String, OrderedJSON)] = [("type", .string("command")), ("command", .string(command))]
        // SessionEnd stays synchronous and without a `timeout`: a per-hook timeout would
        // stretch Claude's 1.5s SessionEnd budget, and the script takes ~25ms.
        if !synchronousEvents.contains(event) {
            pairs.append(("async", .bool(true)))
        }
        return .object(pairs)
    }

    static func desiredGroup(event: String, command: String) -> OrderedJSON {
        // No matcher: matches all occurrences (and UserPromptSubmit/Stop ignore matchers).
        .object([("hooks", .array([desiredHandler(event: event, command: command)]))])
    }

    static func mergeEntries(into root: inout OrderedJSON, command: String) throws {
        try removeEntries(from: &root)
        guard case .object = root else { throw InstallError.settingsNotAnObject }
        var hooks = root["hooks"] ?? .object([])
        guard case .object = hooks else { throw InstallError.hooksNotAnObject }
        for event in events {
            var groups = hooks[event]?.arrayValue ?? []
            if let existing = hooks[event], existing.arrayValue == nil { throw InstallError.eventNotAnArray(event) }
            groups.append(desiredGroup(event: event, command: command))
            hooks.set(event, .array(groups))
        }
        root.set("hooks", hooks)
    }

    static func removeEntries(from root: inout OrderedJSON) throws {
        guard case .object = root else { throw InstallError.settingsNotAnObject }
        guard let hooksValue = root["hooks"] else { return }
        guard case let .object(eventPairs) = hooksValue else { throw InstallError.hooksNotAnObject }
        var changed = false
        var newPairs: [(String, OrderedJSON)] = []
        for (event, value) in eventPairs {
            guard case let .array(groups) = value else { newPairs.append((event, value)); continue }
            var newGroups: [OrderedJSON] = []
            for group in groups {
                guard case let .array(handlers)? = group["hooks"] else { newGroups.append(group); continue }
                let kept = handlers.filter { !isOurs($0) }
                if kept.count == handlers.count { newGroups.append(group); continue }
                changed = true
                if kept.isEmpty { continue }
                var g = group
                g.set("hooks", .array(kept))
                newGroups.append(g)
            }
            if newGroups.isEmpty && !groups.isEmpty { continue } // only ours were there
            newPairs.append((event, .array(newGroups)))
        }
        guard changed else { return }
        if newPairs.isEmpty {
            root.remove("hooks")
        } else {
            root.set("hooks", .object(newPairs))
        }
    }

    static func entriesStatus(root: OrderedJSON, command: String) -> InstallStatus {
        guard case let .object(eventPairs)? = root["hooks"] else { return .notInstalled }
        var foundAny = false
        var allExact = true
        for event in events {
            var ours: [OrderedJSON] = []
            for group in eventPairs.first(where: { $0.0 == event })?.1.arrayValue ?? [] {
                ours += (group["hooks"]?.arrayValue ?? []).filter(isOurs)
            }
            foundAny = foundAny || !ours.isEmpty
            if ours != [desiredHandler(event: event, command: command)] { allExact = false }
        }
        // Stray entries of ours under events we no longer register.
        for (event, value) in eventPairs where !events.contains(event) {
            for group in value.arrayValue ?? [] where (group["hooks"]?.arrayValue ?? []).contains(where: isOurs) {
                foundAny = true
                allExact = false
            }
        }
        if !foundAny { return .notInstalled }
        return allExact ? .installed : .outdated
    }

    // MARK: Settings file I/O

    /// Pure transform used by install/uninstall (and tests): returns the new file contents,
    /// or nil when nothing changes.
    static func transformedSettings(
        _ data: Data?,
        _ transform: (inout OrderedJSON) throws -> Void
    ) throws -> Data? {
        let original: OrderedJSON
        var indent = "  "
        var trailingNewline = true
        if let data, !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
            do { original = try OrderedJSON.parse(data) } catch {
                throw InstallError.unreadableSettings(String(describing: error))
            }
            indent = detectIndent(data) ?? "  "
            trailingNewline = data.last == 0x0A
        } else {
            original = .object([])
        }
        var root = original
        try transform(&root)
        if root == original, data != nil { return nil }
        var text = root.serialized(indent: indent)
        if trailingNewline { text += "\n" }
        return Data(text.utf8)
    }

    static func detectIndent(_ data: Data) -> String? {
        let bytes = Array(data)
        guard let nl = bytes.firstIndex(of: 0x0A) else { return nil }
        var i = nl + 1
        var run: [UInt8] = []
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { run.append(bytes[i]); i += 1 }
        return run.isEmpty ? nil : String(decoding: run, as: UTF8.self)
    }

    /// Reads, transforms, backs up, and atomically writes settings. Follows a symlinked
    /// settings.json (dotfile setups) and keeps the file's permissions.
    static func editSettings(
        at settingsURL: URL,
        createIfMissing: Bool = true,
        _ transform: (inout OrderedJSON) throws -> Void
    ) throws -> URL? {
        let fm = FileManager.default
        let target = settingsURL.resolvingSymlinksInPath()
        let exists = fm.fileExists(atPath: target.path)
        if !exists && !createIfMissing { return nil }
        let data = exists ? try Data(contentsOf: target) : nil
        guard let newData = try transformedSettings(data, transform) else { return nil }

        var backup: URL?
        var permissions: Any?
        if exists {
            permissions = try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]
            let stamp = backupTimestamp()
            var candidate = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent).claudewatcher-backup-\(stamp)")
            var n = 1
            while fm.fileExists(atPath: candidate.path) {
                candidate = target.deletingLastPathComponent()
                    .appendingPathComponent("\(target.lastPathComponent).claudewatcher-backup-\(stamp)-\(n)")
                n += 1
            }
            try fm.copyItem(at: target, to: candidate)
            backup = candidate
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try newData.write(to: target, options: .atomic)
        if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
        return backup
    }

    static func backupTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
