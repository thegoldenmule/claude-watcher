import Foundation

/// A live interactive Codex TUI process.
public struct CodexProcess: Sendable, Equatable {
    public var pid: Int32
    public var startTime: Date
    public var tty: String?
    /// Real path of the process's working directory.
    public var cwd: String
    public var terminal: TerminalKind
    /// Started as `codex resume …` / `codex fork …`: may continue a thread created before it.
    public var resumes: Bool

    public init(pid: Int32, startTime: Date, tty: String?, cwd: String, terminal: TerminalKind, resumes: Bool = false) {
        self.pid = pid
        self.startTime = startTime
        self.tty = tty
        self.cwd = cwd
        self.terminal = terminal
        self.resumes = resumes
    }

    var startMillis: Int64 { Int64((startTime.timeIntervalSince1970 * 1000).rounded()) }
}

/// Finds running Codex CLI sessions.
///
/// Codex keeps no per-process registry: discovery starts from processes (`ProcessRules.isCodexTUI`
/// with a controlling tty), then matches each TUI to its thread in Codex's state database
/// (`CodexStateDB`) by working directory and time (`CodexMatcher`), and reads the thread's
/// rollout (`CodexRolloutReader`) for busy/idle, context and the last prompt. Since Codex 0.16x
/// threads run in a shared app-server daemon that writes every rollout, so the TUI's open files
/// can't be used for the match. "Waiting" (an approval or question) is never persisted: it comes
/// from the Ghostty terminal title ("Action Required") when readable, else the Codex hook's
/// `PermissionRequest` (`CodexHookState`). Read-only: never writes under the Codex home.
public actor CodexDiscovery {
    public nonisolated let codexHome: URL
    public nonisolated let hookStateDirectory: URL?
    private let inspector: any ProcessInspecting
    private let threads: any CodexThreadSource
    private let titles: (any TerminalTitleReading)?
    private let rollouts = CodexRolloutReader()
    private var hookStates = CodexHookStateCache()

    /// pid@start → (is a Codex TUI, resumes); a process's executable and argv don't change.
    private var processCache: [String: (isTUI: Bool, resumes: Bool)] = [:]
    private var terminalCache: [String: TerminalKind] = [:]
    private var realpathCache: [String: String] = [:]
    private var gitBranchCache: [String: (String?, Date)] = [:]

    /// A subagent with no record for this long while its session isn't busy is treated as gone.
    static let staleAgentInterval: TimeInterval = 600

    public init(
        codexHome: URL,
        hookStateDirectory: URL? = nil,
        inspector: any ProcessInspecting = SystemProcessInspector(),
        threads: (any CodexThreadSource)? = nil,
        titles: (any TerminalTitleReading)? = GhosttyTitleReader()
    ) {
        self.codexHome = codexHome
        self.hookStateDirectory = hookStateDirectory
        self.inspector = inspector
        self.threads = threads ?? CodexStateDB(codexHome: codexHome)
        self.titles = titles
    }

    /// Codex TUI processes, oldest first.
    func liveProcesses() -> [CodexProcess] {
        var result: [CodexProcess] = []
        var liveKeys: Set<String> = []
        for pid in inspector.allPIDs() where inspector.processName(pid: pid) == "codex" {
            guard let snap = inspector.snapshot(pid: pid), let tty = snap.tty,
                  let path = snap.executablePath, (path as NSString).lastPathComponent == "codex"
            else { continue }
            let key = "\(pid)@\(snap.startTime.timeIntervalSince1970)"
            liveKeys.insert(key)
            let kind: (isTUI: Bool, resumes: Bool)
            if let cached = processCache[key] {
                kind = cached
            } else {
                let argv = inspector.arguments(pid: pid)
                let isTUI = ProcessRules.isCodexTUI(path, arguments: { argv })
                let sub = argv?.dropFirst().first(where: { !$0.hasPrefix("-") })
                kind = (isTUI, sub == "resume" || sub == "fork")
                processCache[key] = kind
            }
            guard kind.isTUI, let rawCwd = inspector.currentDirectory(pid: pid) else { continue }
            let terminal: TerminalKind
            if let cached = terminalCache[key] {
                terminal = cached
            } else {
                terminal = ProcessRules.terminalKind(
                    ancestorPaths: inspector.ancestors(of: pid).compactMap(\.executablePath))
                terminalCache[key] = terminal
            }
            result.append(CodexProcess(
                pid: pid, startTime: snap.startTime, tty: tty, cwd: realpath(rawCwd),
                terminal: terminal, resumes: kind.resumes))
        }
        processCache = processCache.filter { liveKeys.contains($0.key) }
        terminalCache = terminalCache.filter { liveKeys.contains($0.key) }
        return result.sorted { ($0.startTime, $0.pid) < ($1.startTime, $1.pid) }
    }

    /// Runs one discovery pass.
    public func scan() async -> [ClaudeSession] {
        let processes = liveProcesses()
        guard !processes.isEmpty else {
            threads.close()
            rollouts.forget(except: [])
            realpathCache = [:]
            gitBranchCache = [:]
            return []
        }
        let since = (processes.map(\.startMillis).min() ?? 0) - 5_000
        let roots = (threads.rootThreads(sinceMillis: since) ?? []).map { row -> CodexThreadRow in
            var r = row
            r.cwd = realpath(row.cwd)
            return r
        }

        // Rollout state of every candidate root, needed to decide whether titles are worth reading.
        var rootInfo: [String: CodexRolloutInfo] = [:]
        var livePaths: Set<String> = []
        let cwds = Set(processes.map(\.cwd))
        for row in roots where cwds.contains(row.cwd) {
            livePaths.insert(row.rolloutPath)
            if let info = rollouts.info(at: URL(fileURLWithPath: row.rolloutPath)) { rootInfo[row.id] = info }
        }

        var assignment = CodexMatcher.match(processes: processes, roots: roots, titles: nil)
        // Ghostty titles: to break ties between TUIs sharing a directory, and to see "Action
        // Required" on sessions mid-turn. One listing per scan, only when needed.
        var titlesByTTY: [String: String]?
        let ghosttyBusy = processes.contains { p in
            p.terminal == .ghostty && (assignment.threads[p.pid].flatMap { rootInfo[$0.id]?.turnActive } ?? false)
        }
        let ghosttyAmbiguous = processes.contains { $0.terminal == .ghostty && assignment.ambiguous.contains($0.pid) }
        if let titles, ghosttyBusy || ghosttyAmbiguous {
            titlesByTTY = await titles.ghosttyTitlesByTTY()
            if ghosttyAmbiguous, let titlesByTTY {
                assignment = CodexMatcher.match(processes: processes, roots: roots, titles: titlesByTTY)
            }
        }

        let hooks = hookStateDirectory.map { hookStates.load(directory: $0) } ?? [:]
        var sessions: [ClaudeSession] = []
        for process in processes {
            let title = process.tty.flatMap { titlesByTTY?[$0] }
            guard let row = assignment.threads[process.pid] else {
                sessions.append(unmatchedSession(process, ambiguous: assignment.ambiguous.contains(process.pid)))
                continue
            }
            let info = rootInfo[row.id]
            let turnActive = info?.turnActive ?? false
            let agents = runningSubagents(rootID: row.id, since: process.startMillis, rootBusy: turnActive,
                                          livePaths: &livePaths)
            var status: SessionStatus = turnActive || !agents.isEmpty ? .busy : .idle
            var waitingFor: String?
            if let waiting = Self.waiting(title: title, hook: hooks[row.id], info: info) {
                status = .waiting
                waitingFor = waiting
            }
            sessions.append(ClaudeSession(
                id: row.id,
                agent: .codex,
                pid: process.pid,
                cwd: process.cwd,
                title: Self.title(row),
                branch: gitBranch(cwd: process.cwd) ?? row.gitBranch,
                lastPrompt: info?.lastPrompt ?? SessionTitle.nonEmpty(row.title).map { String($0.prefix(500)) },
                status: status,
                waitingFor: waitingFor,
                tty: process.tty,
                terminal: process.terminal,
                startedAt: process.startTime,
                updatedAt: max(row.updatedAt, info?.lastRecordAt ?? .distantPast),
                subagents: agents,
                contextTokens: info?.contextTokens,
                contextWindow: info?.contextWindow))
        }

        rollouts.forget(except: livePaths)
        let liveCwds = Set(processes.map(\.cwd))
        gitBranchCache = gitBranchCache.filter { liveCwds.contains($0.key) }
        if realpathCache.count > 500 { realpathCache = [:] }
        return sessions
    }

    /// A TUI without a thread: not started yet (no prompt sent, or Codex hasn't recorded it),
    /// or one of several TUIs in a directory whose threads couldn't be told apart (then its
    /// state is unknown rather than guessed).
    private func unmatchedSession(_ process: CodexProcess, ambiguous: Bool) -> ClaudeSession {
        let base = (process.cwd as NSString).lastPathComponent
        return ClaudeSession(
            id: "codex-pid-\(process.pid)-\(process.startMillis)",
            agent: .codex,
            pid: process.pid,
            cwd: process.cwd,
            title: base.isEmpty ? "Codex" : base,
            branch: gitBranch(cwd: process.cwd),
            status: ambiguous ? .unknown : .idle,
            tty: process.tty,
            terminal: process.terminal,
            startedAt: process.startTime,
            updatedAt: process.startTime)
    }

    /// The thread name, else the first user message, else "Codex".
    static func title(_ row: CodexThreadRow) -> String {
        if let name = SessionTitle.nonEmpty(row.name) { return name }
        if let first = SessionTitle.nonEmpty(row.title) {
            let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
            return line.count > 60 ? String(line.prefix(59)) + "…" : line
        }
        return "Codex"
    }

    /// The prefix Codex puts in the terminal title while blocked on the user (it blinks
    /// between `[ ! ]` and `[ . ]`).
    static let actionRequiredMarker = "Action Required"

    /// What the session waits for, or nil. A readable Ghostty title is authoritative (it clears
    /// the moment the user answers); otherwise a `PermissionRequest` hook event counts while the
    /// turn it belongs to is still open and nothing was recorded since (a tool's output, the
    /// turn ending, …), which is what happens once the request is answered.
    static func waiting(title: String?, hook: CodexHookState?, info: CodexRolloutInfo?) -> String? {
        if let title { return title.contains(actionRequiredMarker) ? "action required" : nil }
        guard let hook, hook.isPermissionRequest, let info, info.turnActive == true else { return nil }
        if let turnStart = info.lastTurnEventAt, hook.updatedAt < turnStart { return nil }
        if let last = info.lastRecordAt, last > hook.updatedAt.addingTimeInterval(1) { return nil }
        return "approval"
    }

    private func runningSubagents(
        rootID: String, since: Int64, rootBusy: Bool, livePaths: inout Set<String>
    ) -> [SubagentInfo] {
        let rows = threads.subagentThreads(rootID: rootID, sinceMillis: since)
        guard !rows.isEmpty else { return [] }
        let now = Date()
        var running: [CodexThreadRow: CodexRolloutInfo] = [:]
        for row in rows {
            livePaths.insert(row.rolloutPath)
            guard let info = rollouts.info(at: URL(fileURLWithPath: row.rolloutPath)),
                  info.turnActive == true else { continue }
            if !rootBusy, let last = info.lastRecordAt, now.timeIntervalSince(last) > Self.staleAgentInterval { continue }
            running[row] = info
        }
        return Self.subagentTree(rows: rows, running: running, rootID: rootID)
    }

    /// Running subagents in pre-order (children after their parent, siblings by creation),
    /// depth relative to the nearest running ancestor.
    static func subagentTree(
        rows: [CodexThreadRow], running: [CodexThreadRow: CodexRolloutInfo], rootID: String
    ) -> [SubagentInfo] {
        let runningIDs = Set(running.keys.map(\.id))
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        /// The nearest running ancestor's id, or nil (displayed as a root).
        func displayParent(_ row: CodexThreadRow) -> String? {
            var parent = row.parentID
            var hops = 0
            while let p = parent, p != rootID, hops < 16 {
                if runningIDs.contains(p) { return p }
                parent = byID[p]?.parentID
                hops += 1
            }
            return nil
        }
        let ordered = running.keys.sorted { ($0.createdAtMillis, $0.id) < ($1.createdAtMillis, $1.id) }
        var children: [String?: [CodexThreadRow]] = [:]
        for row in ordered { children[displayParent(row), default: []].append(row) }
        var result: [SubagentInfo] = []
        func visit(_ parent: String?, depth: Int) {
            for row in children[parent] ?? [] {
                let info = running[row]
                let task = row.agentPath.map { ($0 as NSString).lastPathComponent }
                    .map { $0.replacingOccurrences(of: "_", with: " ") }
                result.append(SubagentInfo(
                    id: row.id,
                    parentID: parent,
                    agentType: SessionTitle.nonEmpty(row.agentNickname) ?? SessionTitle.nonEmpty(row.agentRole) ?? "agent",
                    label: SessionTitle.nonEmpty(task) ?? SessionTitle.nonEmpty(row.agentRole) ?? "subagent",
                    activity: info?.lastTool,
                    isBackground: true,
                    startedAt: row.createdAt,
                    lastActivityAt: info?.lastRecordAt ?? row.updatedAt,
                    depth: depth))
                visit(row.id, depth: depth + 1)
            }
        }
        visit(nil, depth: 0)
        return result
    }

    private func realpath(_ path: String) -> String {
        if let cached = realpathCache[path] { return cached }
        let resolved = ProcessRules.realpath(path) ?? path
        realpathCache[path] = resolved
        return resolved
    }

    private func gitBranch(cwd: String) -> String? {
        let now = Date()
        if let (branch, at) = gitBranchCache[cwd], now.timeIntervalSince(at) < 15 { return branch }
        let branch = SessionDiscovery.readGitBranch(cwd: cwd)
        gitBranchCache[cwd] = (branch, now)
        return branch
    }
}

extension CodexThreadRow: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Pure thread ↔ TUI matching.
public enum CodexMatcher {
    public struct Assignment: Equatable, Sendable {
        /// pid → its thread.
        public var threads: [Int32: CodexThreadRow] = [:]
        /// TUIs left without a thread because several could own the same threads.
        public var ambiguous: Set<Int32> = []
    }

    /// Slack for clock/rounding differences between a process's start and Codex's timestamps.
    static let slackMillis: Int64 = 2_000

    /// Whether `row` could be `process`'s current thread: in its directory, used since the
    /// process started, and (unless it was started with `resume`/`fork`) created after it.
    static func eligible(_ row: CodexThreadRow, for process: CodexProcess) -> Bool {
        guard row.cwd == process.cwd, row.activeAtMillis >= process.startMillis - slackMillis else { return false }
        return process.resumes || row.createdAtMillis >= process.startMillis - slackMillis
    }

    /// Upper bound on assignments enumerated for one directory before giving up (ambiguous).
    static let maxAssignments = 200_000

    /// Assigns each TUI its current thread.
    ///
    /// A TUI alone in its directory gets its most recently active eligible thread. TUIs that
    /// share a directory compete for the same threads, and are only assigned what can be
    /// deduced, never guessed:
    /// 1. a terminal title (`titles`, by tty) containing exactly one candidate's thread name
    ///    fixes that TUI's current thread (Codex's default title is
    ///    `<activity> <thread name> | <project>`);
    /// 2. every way of giving each candidate thread to a TUI it's eligible for is enumerated,
    ///    keeping those where each TUI's threads follow one another (`/new` starts a thread after
    ///    the previous one's last activity) and title-fixed threads are their TUI's latest;
    /// 3. a TUI whose latest thread (or lack of one) is the same in every consistent assignment
    ///    gets it; the others are reported `ambiguous` and left unassigned.
    public static func match(
        processes: [CodexProcess], roots: [CodexThreadRow], titles: [String: String]?
    ) -> Assignment {
        var assignment = Assignment()
        for (cwd, group) in Dictionary(grouping: processes, by: \.cwd) {
            let threads = roots.filter { row in row.cwd == cwd && group.contains { eligible(row, for: $0) } }
            if group.count == 1 {
                let p = group[0]
                if let row = threads.filter({ eligible($0, for: p) })
                    .max(by: { ($0.activeAtMillis, $0.id) < ($1.activeAtMillis, $1.id) }) {
                    assignment.threads[p.pid] = row
                }
                continue
            }
            var fixed: [Int32: CodexThreadRow] = [:]
            if let titles {
                for p in group {
                    guard let tty = p.tty, let title = titles[tty] else { continue }
                    let named = threads.filter { row in
                        guard eligible(row, for: p), let name = SessionTitle.nonEmpty(row.name) else { return false }
                        return title.contains(name)
                    }
                    if named.count == 1, !fixed.values.contains(named[0]) { fixed[p.pid] = named[0] }
                }
            }
            guard let currents = consistentCurrents(group: group, threads: threads, fixed: fixed) else {
                for p in group {
                    if let row = fixed[p.pid] {
                        assignment.threads[p.pid] = row
                    } else {
                        assignment.ambiguous.insert(p.pid)
                    }
                }
                continue
            }
            for p in group {
                let options = currents[p.pid] ?? []
                if options.count == 1, let only = options.first {
                    if let row = only { assignment.threads[p.pid] = row }
                } else {
                    assignment.ambiguous.insert(p.pid)
                }
            }
        }
        return assignment
    }

    /// For each TUI, the set of its possible latest threads (nil = none) over every consistent
    /// assignment; nil if there is none, or too many to enumerate.
    static func consistentCurrents(
        group: [CodexProcess], threads: [CodexThreadRow], fixed: [Int32: CodexThreadRow]
    ) -> [Int32: Set<CodexThreadRow?>]? {
        let sorted = threads.sorted { ($0.createdAtMillis, $0.id) < ($1.createdAtMillis, $1.id) }
        let options: [[Int32]] = sorted.map { row in
            if let owner = fixed.first(where: { $0.value.id == row.id })?.key { return [owner] }
            return group.filter { eligible(row, for: $0) }.map(\.pid)
        }
        var total = 1
        for o in options {
            total = total.multipliedReportingOverflow(by: max(1, o.count)).partialValue
            if total > maxAssignments { return nil }
        }
        var result: [Int32: Set<CodexThreadRow?>] = [:]
        var found = false
        // Per TUI, its latest thread so far (threads are visited in creation order).
        var latest: [Int32: CodexThreadRow] = [:]
        func visit(_ i: Int) {
            if i == sorted.count {
                for (pid, row) in fixed where latest[pid]?.id != row.id { return }
                found = true
                for p in group { result[p.pid, default: []].insert(latest[p.pid]) }
                return
            }
            let row = sorted[i]
            for pid in options[i] {
                let previous = latest[pid]
                // The TUI's previous thread must have gone quiet before this one was created.
                if let previous, previous.activeAtMillis > row.createdAtMillis + slackMillis { continue }
                latest[pid] = row
                visit(i + 1)
                latest[pid] = previous
            }
        }
        visit(0)
        return found ? result : nil
    }
}
