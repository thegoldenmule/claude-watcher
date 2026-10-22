import Foundation
import Observation

/// Owns the live list of Claude Code sessions.
///
/// Watches `~/.claude/sessions` (vnode events on the directory) and polls every
/// `pollInterval` as a safety net, since status changes may rewrite files in place.
/// Discovery runs off the main actor; `sessions` is only assigned when it changes.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var sessions: [ClaudeSession] = []

    @ObservationIgnored public let discovery: SessionDiscovery
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var dirSource: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var running = false

    public convenience init() {
        self.init(claudeHome: SessionDiscovery.defaultClaudeHome)
    }

    public init(
        claudeHome: URL,
        inspector: any ProcessInspecting = SystemProcessInspector(),
        pollInterval: Duration = .seconds(2)
    ) {
        self.discovery = SessionDiscovery(claudeHome: claudeHome, inspector: inspector)
        self.pollInterval = pollInterval
    }

    isolated deinit {
        stop()
    }

    public func start() {
        guard !running else { return }
        running = true
        installWatcher()
        refresh()
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.installWatcher()  // no-op if already watching; retries if dir was missing
                self.refresh()
            }
        }
    }

    public func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        dirSource?.cancel()
        dirSource = nil
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
    }

    private func installWatcher() {
        guard running, dirSource == nil else { return }
        let path = discovery.sessionsDirectory.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }  // missing dir / no permission: polling will retry
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = source.data
                if flags.contains(.delete) || flags.contains(.rename) {
                    // Directory replaced: drop this watcher; the poll re-installs it.
                    self.dirSource?.cancel()
                    self.dirSource = nil
                }
                self.refresh()
            }
        }
        source.setCancelHandler { close(fd) }
        dirSource = source
        source.resume()
    }
}
