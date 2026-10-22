import Foundation

/// Installs / uninstalls the ClaudeWatcher hook in Claude Code's user settings.
///
/// Install copies the hook script to `~/Library/Application Support/ClaudeWatcher/` and merges
/// one matcher group per event into Claude Code's `settings.json` `hooks` (see `defaultSettingsURL`). Our entries are
/// identified by their command containing `/claude-watcher-hook.sh`; everything else in the
/// file is preserved (key order, other hooks, other settings). The settings file is edited
/// with an order-preserving JSON model and printed in `JSON.stringify(_, null, 2)` style, so
/// the diff is limited to our entries (see `OrderedJSON` for the small caveats).
public enum HookInstaller {
    public enum InstallStatus: Sendable, Equatable {
        /// Script present and every event has exactly our expected entry, in a match-all group.
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
        /// settings.json changed between our read and our write on every attempt.
        case settingsChangedConcurrently(attempts: Int)

        public var description: String {
            switch self {
            case .settingsNotAnObject: "settings.json is not a JSON object"
            case .hooksNotAnObject: "settings.json \"hooks\" is not an object"
            case let .eventNotAnArray(e): "settings.json hooks.\(e) is not an array"
            case let .unreadableSettings(m): "settings.json could not be parsed: \(m)"
            case let .settingsChangedConcurrently(n):
                "settings.json kept changing while it was being edited (gave up after \(n) attempts); try again"
            }
        }
    }

    public static let scriptFileName = "claude-watcher-hook.sh"

    /// What `uninstall` leaves at the script path (see there).
    static let noOpScript = Data("#!/bin/sh\nexit 0\n".utf8)

    /// Read-transform-write attempts before giving up on a settings.json that keeps changing.
    static let maxEditAttempts = 3

    /// Events we register for. All are async (never block Claude) except SessionEnd, which
    /// runs synchronously so it completes before `claude -p` teardown kills async hooks.
    public static let events = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]
    static let synchronousEvents: Set<String> = ["SessionEnd"]

    /// `settings.json` in Claude Code's config directory: `$CLAUDE_CONFIG_DIR` when set, else
    /// `~/.claude` (the same directory session discovery reads).
    public static var defaultSettingsURL: URL {
        settingsURL(claudeHome: SessionDiscovery.defaultClaudeHome)
    }

    static func settingsURL(claudeHome: URL) -> URL {
        claudeHome.appendingPathComponent("settings.json")
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

    /// Idempotent. Copies the script (mode 755, published atomically so a hook firing mid-install
    /// never finds a non-executable file) and merges our hook entries into settings,
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
            try writeAtomically(scriptData, to: script, mode: 0o755)
        } else {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        let command = hookCommand(scriptPath: script.path)
        return try editSettings(at: settingsURL) { root in
            try mergeEntries(into: &root, command: command)
        }
    }

    /// Removes only our entries (and event arrays / the `hooks` object if that leaves them
    /// empty). Leaves the hook-state directory alone.
    ///
    /// The installed script is not deleted but atomically replaced with a no-op stub
    /// (`#!/bin/sh` / `exit 0`): running Claude Code sessions snapshot their hooks at startup
    /// and keep invoking the old path until they exit, and a missing script would make every
    /// event of theirs report an exit-127 hook error. `status` is based on the settings.json
    /// entries, so it still reports `.notInstalled` with the stub in place.
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
        if FileManager.default.fileExists(atPath: script.path),
           (try? Data(contentsOf: script)) != noOpScript {
            try writeAtomically(noOpScript, to: script, mode: 0o755)
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

    /// Brings our entries up to date with minimal edits: for each registered event, the first
    /// handler of ours in a match-all group is replaced in place (its group, the event key and
    /// `hooks` keep their positions) and any further handlers of ours are removed; a group is
    /// appended only for an event that has no such handler. Stray handlers of ours under events
    /// we no longer register are removed. Settings that already hold exactly our entries are
    /// left equal, so `transformedSettings` reports no change and nothing is written.
    static func mergeEntries(into root: inout OrderedJSON, command: String) throws {
        guard case .object = root else { throw InstallError.settingsNotAnObject }
        let hooksValue = root["hooks"] ?? .object([])
        guard case let .object(eventPairs) = hooksValue else { throw InstallError.hooksNotAnObject }
        for event in events {
            if let existing = hooksValue[event], existing.arrayValue == nil { throw InstallError.eventNotAnArray(event) }
        }
        var newPairs: [(String, OrderedJSON)] = []
        for (event, value) in eventPairs {
            guard case let .array(groups) = value else { newPairs.append((event, value)); continue }
            guard events.contains(event) else {
                // Stray entries of ours: drop them, and the event key if only ours were there.
                let kept = rewritingOurs(in: groups, keep: nil)
                if kept.isEmpty && !groups.isEmpty { continue }
                newPairs.append((event, .array(kept)))
                continue
            }
            let desired = desiredHandler(event: event, command: command)
            if let keep = keeperIndex(in: groups) {
                newPairs.append((event, .array(rewritingOurs(in: groups, keep: (keep, desired)))))
            } else {
                var kept = rewritingOurs(in: groups, keep: nil)
                kept.append(desiredGroup(event: event, command: command))
                newPairs.append((event, .array(kept)))
            }
        }
        for event in events where !newPairs.contains(where: { $0.0 == event }) {
            newPairs.append((event, .array([desiredGroup(event: event, command: command)])))
        }
        root.set("hooks", .object(newPairs))
    }

    /// Removes only our handlers. Groups, event arrays and the `hooks` object that this leaves
    /// empty are pruned (only when they held something of ours, never pre-existing empties).
    static func removeEntries(from root: inout OrderedJSON) throws {
        guard case .object = root else { throw InstallError.settingsNotAnObject }
        guard let hooksValue = root["hooks"] else { return }
        guard case let .object(eventPairs) = hooksValue else { throw InstallError.hooksNotAnObject }
        var changed = false
        var newPairs: [(String, OrderedJSON)] = []
        for (event, value) in eventPairs {
            guard case let .array(groups) = value else { newPairs.append((event, value)); continue }
            let kept = rewritingOurs(in: groups, keep: nil)
            if kept != groups { changed = true }
            if kept.isEmpty && !groups.isEmpty { continue } // only ours were there
            newPairs.append((event, .array(kept)))
        }
        guard changed else { return }
        if newPairs.isEmpty {
            root.remove("hooks")
        } else {
            root.set("hooks", .object(newPairs))
        }
    }

    /// A group our handler may stay in: no matcher, or one that matches everything. A handler of
    /// ours in a group with a restricting matcher (e.g. a foreign `idle_prompt` group) would not
    /// fire for every event, so it is moved out into a group of its own instead.
    static func isMatchAll(_ group: OrderedJSON) -> Bool {
        switch group["matcher"] {
        case nil, .string("")?, .string("*")?: true
        default: false
        }
    }

    /// (group, handler) index of the first handler of ours that can be updated in place.
    static func keeperIndex(in groups: [OrderedJSON]) -> (group: Int, handler: Int)? {
        for (gi, group) in groups.enumerated() where isMatchAll(group) {
            if let hi = group["hooks"]?.arrayValue?.firstIndex(where: isOurs) { return (gi, hi) }
        }
        return nil
    }

    /// Returns `groups` with every handler of ours removed, except the one at `keep`, which is
    /// replaced by its handler value in place. A group left with no handlers by the removal is
    /// dropped; groups without handlers of ours are returned untouched.
    static func rewritingOurs(
        in groups: [OrderedJSON],
        keep: ((group: Int, handler: Int), OrderedJSON)?
    ) -> [OrderedJSON] {
        var result: [OrderedJSON] = []
        for (gi, group) in groups.enumerated() {
            guard case let .array(handlers)? = group["hooks"], handlers.contains(where: isOurs) else {
                result.append(group)
                continue
            }
            var kept: [OrderedJSON] = []
            for (hi, handler) in handlers.enumerated() {
                if !isOurs(handler) {
                    kept.append(handler)
                } else if let keep, keep.0.group == gi, keep.0.handler == hi {
                    kept.append(keep.1)
                }
            }
            if kept.isEmpty { continue }
            var g = group
            g.set("hooks", .array(kept))
            result.append(g)
        }
        return result
    }

    /// `.installed` only if every registered event has exactly our desired handler, in a
    /// match-all group (the same rule `mergeEntries` uses). A handler of ours under a restricting
    /// matcher counts as found but makes the result `.outdated`: it would not fire for every event.
    static func entriesStatus(root: OrderedJSON, command: String) -> InstallStatus {
        guard case let .object(eventPairs)? = root["hooks"] else { return .notInstalled }
        var foundAny = false
        var allExact = true
        for event in events {
            var ours: [OrderedJSON] = []
            for group in eventPairs.first(where: { $0.0 == event })?.1.arrayValue ?? [] {
                let mine = (group["hooks"]?.arrayValue ?? []).filter(isOurs)
                guard !mine.isEmpty else { continue }
                foundAny = true
                if isMatchAll(group) { ours += mine } else { allExact = false }
            }
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
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = data?.starts(with: bom) ?? false
        if let data, !data.dropFirst(hasBOM ? bom.count : 0).allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
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
        return Data((hasBOM ? bom : []) + Array(text.utf8))
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
    ///
    /// Guards against lost updates: the file's (device, inode, size, mtime) is captured before
    /// reading and re-checked right before the new file is renamed into place. If Claude Code
    /// or the user saved it in between, the attempt is discarded (backup included) and the
    /// read-transform-write is redone, up to `maxEditAttempts` times.
    /// - Parameter beforeCommit: test hook, called after the transform and right before the
    ///   conflict check of each attempt.
    static func editSettings(
        at settingsURL: URL,
        createIfMissing: Bool = true,
        beforeCommit: () throws -> Void = {},
        _ transform: (inout OrderedJSON) throws -> Void
    ) throws -> URL? {
        let fm = FileManager.default
        let target = settingsURL.resolvingSymlinksInPath()
        for _ in 0..<maxEditAttempts {
            let before = try FileSnapshot(path: target.path)
            if before == nil && !createIfMissing { return nil }
            let data = before != nil ? try Data(contentsOf: target) : nil
            guard let newData = try transformedSettings(data, transform) else { return nil }

            var backup: URL?
            if let data, let before {
                let stamp = backupTimestamp()
                var candidate = target.deletingLastPathComponent()
                    .appendingPathComponent("\(target.lastPathComponent).claudewatcher-backup-\(stamp)")
                var n = 1
                while fm.fileExists(atPath: candidate.path) {
                    candidate = target.deletingLastPathComponent()
                        .appendingPathComponent("\(target.lastPathComponent).claudewatcher-backup-\(stamp)-\(n)")
                    n += 1
                }
                // The bytes we read, not a fresh copy, so the backup matches what we transformed.
                try writeAtomically(data, to: candidate, mode: before.permissions)
                backup = candidate
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            do {
                try writeAtomically(newData, to: target, mode: before?.permissions ?? 0o644) { _ in
                    try beforeCommit()
                    guard try FileSnapshot(path: target.path) == before else { throw EditConflict() }
                }
                return backup
            } catch is EditConflict {
                if let backup { try? fm.removeItem(at: backup) }
            }
        }
        throw InstallError.settingsChangedConcurrently(attempts: maxEditAttempts)
    }

    private struct EditConflict: Error {}

    /// Identity of a file's current contents: equal snapshots mean nobody replaced or rewrote it.
    struct FileSnapshot: Equatable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var mtimeSeconds: Int
        var mtimeNanoseconds: Int
        /// Carried along for rewriting the file; not part of equality.
        var permissions: mode_t

        /// nil when the file does not exist.
        init?(path: String) throws {
            var st = stat()
            guard stat(path, &st) == 0 else {
                if errno == ENOENT { return nil }
                throw posixError(errno, path: path)
            }
            device = Int64(st.st_dev)
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            mtimeSeconds = st.st_mtimespec.tv_sec
            mtimeNanoseconds = st.st_mtimespec.tv_nsec
            permissions = st.st_mode & 0o7777
        }

        static func == (a: FileSnapshot, b: FileSnapshot) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.mtimeSeconds == b.mtimeSeconds && a.mtimeNanoseconds == b.mtimeNanoseconds
        }
    }

    /// Writes `data` to a temp file next to `url`, sets `mode` on it, then `rename()`s it into
    /// place, so readers only ever see the old file or the complete new one with its final
    /// permissions. `beforeRename` gets the temp file's URL; throwing from it aborts the write
    /// (the temp file is removed and `url` is left untouched).
    static func writeAtomically(
        _ data: Data,
        to url: URL,
        mode: mode_t,
        beforeRename: (URL) throws -> Void = { _ in }
    ) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).claudewatcher-tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError(errno, path: temp.path) }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fchmod(fd, mode) == 0 else { throw posixError(errno, path: temp.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try beforeRename(temp)
        guard rename(temp.path, url.path) == 0 else { throw posixError(errno, path: url.path) }
        renamed = true
    }

    static func posixError(_ code: Int32, path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    static func backupTimestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
