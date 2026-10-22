import Foundation

/// Scans a Claude home directory (`~/.claude`) for live interactive sessions.
/// Read-only: never writes under the Claude home, and never opens `*.key` files.
/// All file/process IO happens on this actor, off the main thread.
public actor SessionDiscovery {
    public nonisolated let claudeHome: URL
    /// ClaudeWatcher hook output (`HookStateStore.defaultDirectory`), joined in for
    /// `ghosttyTerminalID`. nil disables the join (tests, or the hook isn't wanted).
    public nonisolated let hookStateDirectory: URL?
    private let inspector: any ProcessInspecting
    private let transcripts = TranscriptReader()
    private let history = HistoryIndex()

    /// Last successfully parsed record per registry file, used when a file is mid-rewrite.
    private var lastGoodRecords: [String: SessionRecord] = [:]
    /// Terminal classification per (pid, start time); ancestry doesn't change for a process.
    private var terminalCache: [String: TerminalKind] = [:]
    /// sessionId -> transcript URL.
    private var transcriptURLs: [String: URL] = [:]
    /// sessionId -> last time we globbed for a missing transcript.
    private var lastGlob: [String: Date] = [:]
    /// cwd -> (branch, fetched at).
    private var gitBranchCache: [String: (String?, Date)] = [:]
    private var hookStates = HookStateCache()

    public init(
        claudeHome: URL,
        hookStateDirectory: URL? = nil,
        inspector: any ProcessInspecting = SystemProcessInspector()
    ) {
        self.claudeHome = claudeHome
        self.hookStateDirectory = hookStateDirectory
        self.inspector = inspector
    }

    /// Claude Code's config directory, resolved once and cached (see `ClaudeHome`).
    /// The first call may spawn `launchctl` and a login shell (bounded at ~2 s each, ~0.1 s
    /// typically); call `prewarmDefaultClaudeHome()` early to do that off the main thread.
    public static var defaultClaudeHome: URL { ClaudeHome.resolved }

    /// Starts resolving `defaultClaudeHome` on a background queue. Idempotent.
    public static func prewarmDefaultClaudeHome() {
        DispatchQueue.global(qos: .userInitiated).async { _ = ClaudeHome.resolved }
    }

    /// Pure resolution of Claude Code's config directory: the first non-empty of `env`'s
    /// `CLAUDE_CONFIG_DIR`, `launchctlValue`, `shellValue`, with a leading `~` expanded against
    /// `home`; `home/.claude` if none is set or the chosen directory doesn't exist. The later
    /// sources are autoclosures so they're only evaluated when the earlier ones are empty.
    public static func resolveClaudeHome(
        env: [String: String],
        launchctlValue: @autoclosure () -> String?,
        shellValue: @autoclosure () -> String?,
        home: String,
        fileExists: (String) -> Bool
    ) -> URL {
        let fallback = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        func clean(_ value: String?) -> String? {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        guard let raw = clean(env["CLAUDE_CONFIG_DIR"]) ?? clean(launchctlValue()) ?? clean(shellValue())
        else { return fallback }
        var path = raw
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }
        guard path.hasPrefix("/"), fileExists(path) else { return fallback }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public nonisolated var sessionsDirectory: URL { claudeHome.appendingPathComponent("sessions", isDirectory: true) }
    nonisolated var projectsDirectory: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }
    nonisolated var historyFile: URL { claudeHome.appendingPathComponent("history.jsonl") }

    /// Registry file names we read: exactly `<digits>.json`. Never `<pid>.<hash>.key`.
    public static func isRegistryFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return !stem.isEmpty && stem.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Claude Code's project directory slug: every non-alphanumeric character becomes "-".
    public static func projectSlug(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) ? Character(scalar) : "-"
        })
    }

    /// Runs one discovery pass and returns sessions sorted by start time.
    public func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: sessionsDirectory.path)) ?? []
        let registryNames = names.filter(Self.isRegistryFileName)

        var records: [SessionRecord] = []
        var seenFiles: Set<String> = []
        for name in registryNames {
            seenFiles.insert(name)
            let url = sessionsDirectory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url), let record = SessionRecord.parse(data) {
                lastGoodRecords[name] = record
                records.append(record)
            } else if let previous = lastGoodRecords[name] {
                records.append(previous)  // partial write in progress; reuse last good copy
            }
        }
        lastGoodRecords = lastGoodRecords.filter { seenFiles.contains($0.key) }

        let states = hookStateDirectory.map { hookStates.load(directory: $0) } ?? [:]
        let statesByPID = HookStateStore.latestByPID(states)

        var sessions: [ClaudeSession] = []
        var liveTranscriptPaths: Set<String> = []
        var liveTerminalKeys: Set<String> = []
        for record in records where record.isInteractive {
            let process = inspector.snapshot(pid: record.pid)
            guard ProcessRules.isLive(record, process: process, arguments: { inspector.arguments(pid: record.pid) }),
                  let process
            else { continue }

            let terminalKey = "\(process.pid)@\(process.startTime.timeIntervalSince1970)"
            liveTerminalKeys.insert(terminalKey)
            let terminal: TerminalKind
            if let cached = terminalCache[terminalKey] {
                terminal = cached
            } else {
                let paths = inspector.ancestors(of: process.pid).compactMap(\.executablePath)
                terminal = ProcessRules.terminalKind(ancestorPaths: paths)
                terminalCache[terminalKey] = terminal
            }

            var info: TranscriptInfo?
            if let url = transcriptURL(for: record) {
                info = transcripts.info(at: url)
                if info != nil { liveTranscriptPaths.insert(url.path) }
            }

            let title = SessionTitle.resolve(
                name: record.name, nameSource: record.nameSource,
                customTitle: info?.customTitle, aiTitle: info?.aiTitle, cwd: record.cwd)
            let branch = info?.gitBranch ?? gitBranch(cwd: record.cwd)
            let lastPrompt = info?.lastPrompt
                ?? history.lastPrompt(sessionId: record.sessionId, historyURL: historyFile)
            let startedAt = record.startedAtDate ?? process.startTime
            let waitingFor = record.sessionStatus == .waiting ? SessionTitle.nonEmpty(record.waitingFor) : nil
            let hook = HookStateStore.match(
                sessionID: record.sessionId, pid: record.pid, tty: process.tty,
                processStart: process.startTime, states: states, byPID: statesByPID)

            sessions.append(ClaudeSession(
                id: record.sessionId,
                pid: record.pid,
                cwd: record.cwd,
                title: title,
                branch: branch,
                lastPrompt: lastPrompt,
                status: record.sessionStatus,
                waitingFor: waitingFor,
                tty: process.tty,
                terminal: terminal,
                ghosttyTerminalID: terminal == .ghostty ? SessionTitle.nonEmpty(hook?.ghosttyTerminalID) : nil,
                startedAt: startedAt,
                updatedAt: record.updatedAtDate ?? startedAt))
        }

        transcripts.forget(except: liveTranscriptPaths)
        terminalCache = terminalCache.filter { liveTerminalKeys.contains($0.key) }
        let liveIDs = Set(sessions.map(\.id))
        transcriptURLs = transcriptURLs.filter { liveIDs.contains($0.key) }
        lastGlob = lastGlob.filter { liveIDs.contains($0.key) }
        let liveCwds = Set(sessions.map(\.cwd))
        gitBranchCache = gitBranchCache.filter { liveCwds.contains($0.key) }

        return Self.finalize(sessions)
    }

    /// Stable order (startedAt, then pid) and unique ids: if two processes report the
    /// same sessionId, keep the most recently updated one.
    public static func finalize(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        var byID: [String: ClaudeSession] = [:]
        for s in sessions {
            if let existing = byID[s.id], existing.updatedAt >= s.updatedAt { continue }
            byID[s.id] = s
        }
        return byID.values.sorted {
            ($0.startedAt, $0.pid) < ($1.startedAt, $1.pid)
        }
    }

    // MARK: - Transcript lookup

    private func transcriptURL(for record: SessionRecord) -> URL? {
        let fm = FileManager.default
        let fileName = record.sessionId + ".jsonl"
        if let cached = transcriptURLs[record.sessionId], fm.fileExists(atPath: cached.path) {
            return cached
        }
        let direct = projectsDirectory
            .appendingPathComponent(Self.projectSlug(for: record.cwd), isDirectory: true)
            .appendingPathComponent(fileName)
        if fm.fileExists(atPath: direct.path) {
            transcriptURLs[record.sessionId] = direct
            return direct
        }
        // cwd may have changed since the transcript was created: glob projects/*/<id>.jsonl,
        // throttled because brand-new sessions have no transcript until the first prompt.
        let now = Date()
        if let last = lastGlob[record.sessionId], now.timeIntervalSince(last) < 10 { return nil }
        lastGlob[record.sessionId] = now
        let dirs = (try? fm.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
        for dir in dirs {
            let candidate = projectsDirectory.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent(fileName)
            if fm.fileExists(atPath: candidate.path) {
                transcriptURLs[record.sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    // MARK: - Git fallback

    private func gitBranch(cwd: String) -> String? {
        let now = Date()
        if let (branch, at) = gitBranchCache[cwd], now.timeIntervalSince(at) < 15 { return branch }
        let branch = Self.readGitBranch(cwd: cwd)
        gitBranchCache[cwd] = (branch, now)
        return branch
    }

    /// Equivalent of `git -C cwd branch --show-current` without spawning git:
    /// finds `.git` (dir or `gitdir:` file for worktrees) and reads `HEAD`.
    public static func readGitBranch(cwd: String) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL
        for _ in 0..<64 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:")
                    else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/")
                        ? URL(fileURLWithPath: path)
                        : dir.appendingPathComponent(path)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                else { return nil }
                return parseGitHead(head)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// "ref: refs/heads/main" -> "main"; detached HEAD -> nil.
    public static func parseGitHead(_ head: String) -> String? {
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard trimmed.hasPrefix(prefix) else { return nil }
        let name = String(trimmed.dropFirst(prefix.count))
        return name.isEmpty ? nil : name
    }
}
