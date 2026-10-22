import Foundation
import Observation

/// Owns the live list of Claude Code sessions.
///
/// Change notification:
/// - vnode sources on `~/.claude/sessions` and the hook-state directory catch files being
///   created, deleted or atomically replaced (the hook writes temp + rename);
/// - one vnode source per live session's `<pid>.json` catches in-place rewrites: Claude Code
///   rewrites the registry file in place on every status change (same inode since the session
///   started; the directory's mtime doesn't move), which a directory source never sees;
/// - a `pollInterval` poll is the safety net (process exit, transcripts, missing directories).
/// Discovery runs off the main actor; `sessions` is only assigned when it changes.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [ClaudeSession] = []

    @ObservationIgnored public let discovery: SessionDiscovery
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// path -> source, for the watched directories and registry files.
    @ObservationIgnored private var sources: [String: any DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var running = false

    /// The real store: `~/.claude` plus the ClaudeWatcher hook-state directory.
    public convenience init() {
        self.init(
            claudeHome: SessionDiscovery.defaultClaudeHome,
            hookStateDirectory: HookStateStore.defaultDirectory)
    }

    public init(
        claudeHome: URL,
        hookStateDirectory: URL? = nil,
        inspector: any ProcessInspecting = SystemProcessInspector(),
        pollInterval: Duration = .seconds(2)
    ) {
        self.discovery = SessionDiscovery(
            claudeHome: claudeHome, hookStateDirectory: hookStateDirectory, inspector: inspector)
        self.pollInterval = pollInterval
    }

    isolated deinit {
        stop()
    }

    public func start() {
        guard !running else { return }
        running = true
        installDirectoryWatchers()
        refresh()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.installDirectoryWatchers()  // no-op if already watching; retries if a dir was missing
                self.refresh()
            }
        }
    }

    public func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        for source in sources.values { source.cancel() }
        sources = [:]
    }

    /// Requests a discovery pass; coalesces with one already in flight.
    public func refresh() {
        if scanning {
            rescanPending = true
            return
        }
        scanning = true
        Task { [discovery] in
            let result = await discovery.scan()
            self.apply(result)
            self.scanning = false
            if self.rescanPending {
                self.rescanPending = false
                self.refresh()
            }
        }
    }

    /// Runs a discovery pass and waits for it to be applied (useful for tests and tools).
    public func reload() async {
        let result = await discovery.scan()
        apply(result)
    }

    private func apply(_ result: [ClaudeSession]) {
        if result != sessions { sessions = result }
        syncRegistryFileWatchers()
    }

    // MARK: - Watchers

    private var watchedDirectories: [URL] {
        [discovery.sessionsDirectory] + (discovery.hookStateDirectory.map { [$0] } ?? [])
    }

    private func installDirectoryWatchers() {
        for dir in watchedDirectories { watch(path: dir.path, events: [.write, .delete, .rename, .extend, .attrib]) }
    }

    /// Watches exactly the registry files of the sessions currently listed.
    private func syncRegistryFileWatchers() {
        guard running else { return }
        let dirPaths = Set(watchedDirectories.map(\.path))
        let wanted = Set(sessions.map {
            discovery.sessionsDirectory.appendingPathComponent("\($0.pid).json").path
        })
        for (path, source) in sources where !dirPaths.contains(path) && !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
        }
        // No .attrib: our own reads could touch atime and loop.
        for path in wanted { watch(path: path, events: [.write, .extend, .delete, .rename]) }
    }

    /// Installs a vnode source on `path` (file or directory) that triggers `refresh()`. If the
    /// node is deleted or renamed away the source is dropped; the next poll / scan re-adds it.
    private func watch(path: String, events: DispatchSource.FileSystemEvent) {
        guard running, sources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }  // missing / no permission: polling will retry
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                let flags = source.data
                if flags.contains(.delete) || flags.contains(.rename) {
                    source.cancel()
                    if self.sources[path] === source { self.sources[path] = nil }
                }
                self.refresh()
            }
        }
        source.setCancelHandler { close(fd) }
        sources[path] = source
        source.resume()
    }
}
