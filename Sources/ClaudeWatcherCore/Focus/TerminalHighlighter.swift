import Darwin
import Foundation
import os

/// Highlights a Claude session's Ghostty split pane by tinting its default background with
/// OSC 11 (`ESC ] 11 ; #rrggbb ESC \`) written to the session's tty, and restores the theme
/// background with OSC 111 (`ESC ] 111 ESC \`). Verified on Ghostty 1.3.1: only that split pane
/// changes, and cells with an explicit background keep it.
///
/// Ghostty only: a no-op for other terminals, tmux sessions, a nil/invalid tty, or a tty that is
/// no longer the session's controlling terminal. A tint is skipped (never waited for) while an
/// OSC 7 probe of the same tty holds a fresh `.probe-<tty>.lock`.
///
/// Our writes share the tty with Claude's own output, so one could land inside a multi-write
/// escape sequence Claude is drawing. To keep that rare, writes are minimal: a hover tint
/// isn't applied to a `.busy` session (it streams output; a busy hover just shows no tint, or
/// drops the tint when a keep-alive `beginHover` sees the session turn busy), re-tinting the
/// hovered pane in a new color is one write (no reset first), and a pulse is one tint plus one
/// reset (or settle to the hover tint). A pulse is still allowed on a busy session: it follows
/// an explicit focus, and it's only two writes.
///
/// Every public method returns immediately: tty I/O runs on a private serial queue. Hover
/// changes are coalesced (the queue applies only the latest wanted hover, resetting the previous
/// pane first), so a burst of hovers never queues stale tints.
///
/// A tty is recorded in `recoveryFile` before it's tinted and removed once its reset went out,
/// so `resetAll()` (at launch, panel hide, terminate) can clear a tint left behind by a crash.
/// A recovery reset only goes to a recorded tty that is still a `/dev/ttysN` char device with a
/// live process on it (controlling tty) descended from Ghostty: after a crash the tty number may
/// have been reused by an unrelated terminal. Other entries are dropped without a write; one
/// whose processes couldn't be listed, or whose reset didn't fully go out, keeps its entry for
/// the next `resetAll()`.
public final class TerminalHighlighter: @unchecked Sendable {
    public static let shared = TerminalHighlighter()

    /// `~/Library/Application Support/ClaudeWatcher/tinted-ttys`
    public static var defaultRecoveryFile: URL {
        HookInstaller.defaultInstallDirectory.appendingPathComponent("tinted-ttys", isDirectory: false)
    }

    static let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Highlight")

    let recoveryFile: URL
    let lockDirectory: URL
    let io: TerminalHighlighterIO
    let timing: TerminalHighlighterTiming
    private let queue = DispatchQueue(label: "com.thegoldenmule.ClaudeWatcher.highlighter", qos: .userInitiated)

    // MARK: Caller-side state (any thread), guarded by `requests`.

    private struct HoverRequest {
        var session: ClaudeSession
        var tint: GhosttyColor
        var generation: UInt64
    }

    private struct Requests {
        var hover: HoverRequest?
        var generation: UInt64 = 0
        var reconcileScheduled = false
    }

    private let requests = OSAllocatedUnfairLock(initialState: Requests())

    // MARK: Queue-confined state.

    private struct AppliedHover {
        var tty: String
        var tint: GhosttyColor
        var generation: UInt64
    }

    /// The hover tint the panes should show (unless a pulse currently owns that tty).
    private var hover: AppliedHover?
    /// ttys with a running pulse, and that pulse's id (a newer pulse or `resetAll` supersedes it).
    private var pulsing: [String: UInt64] = [:]
    private var nextPulseID: UInt64 = 0
    /// Recovery-file contents, loaded on first use.
    private var recorded: Set<String>?
    /// The file on disk doesn't match `recorded` (it held lines that didn't parse): rewrite it
    /// on the next save even if the set is unchanged.
    private var recoveryFileDirty = false
    private var recoveryDirectoryCreated = false

    public convenience init(recoveryFile: URL = TerminalHighlighter.defaultRecoveryFile,
                            lockDirectory: URL = HookStateStore.defaultDirectory)
    {
        self.init(recoveryFile: recoveryFile, lockDirectory: lockDirectory,
                  io: TerminalHighlighterIO(), timing: TerminalHighlighterTiming())
    }

    init(recoveryFile: URL, lockDirectory: URL, io: TerminalHighlighterIO, timing: TerminalHighlighterTiming) {
        self.recoveryFile = recoveryFile
        self.lockDirectory = lockDirectory
        self.io = io
        self.timing = timing
    }

    // MARK: - Escape sequences

    /// `ESC ] 11 ; #rrggbb ESC \`: sets this pane's default background.
    public static func tintSequence(_ color: GhosttyColor) -> [UInt8] {
        Array("\u{1B}]11;\(color.hexString)\u{1B}\\".utf8)
    }

    /// `ESC ] 111 ESC \`: restores the configured background.
    public static let resetSequence: [UInt8] = Array("\u{1B}]111\u{1B}\\".utf8)

    /// String terminator, written after a partial sequence so the terminal isn't left mid-OSC.
    static let stringTerminator: [UInt8] = [0x1B, 0x5C]

    // MARK: - Public API

    /// Tint this session's pane until endHover()/another beginHover. Non-blocking; returns immediately.
    /// No-op unless session.terminal == .ghostty, tty is /dev/ttysN and is the pid's controlling tty, and not under tmux.
    /// Also a no-op (resetting a tint this pane already has) while `session.status == .busy`.
    /// Auto-resets after a 3 s safety cap.
    public func beginHover(_ session: ClaudeSession, tint: GhosttyColor) {
        requests.withLock {
            $0.generation &+= 1
            $0.hover = HoverRequest(session: session, tint: tint, generation: $0.generation)
        }
        scheduleReconcile()
    }

    /// Reset the currently hovered pane (if any). Non-blocking.
    public func endHover() {
        requests.withLock { $0.hover = nil }
        scheduleReconcile()
    }

    /// Brief attention pulse: one tint, then after `pulseDuration` (~400 ms) one OSC 111, or the
    /// hover tint if that pane is still hovered. Non-blocking, fire-and-forget. Allowed on busy
    /// sessions (two writes).
    public func pulse(_ session: ClaudeSession, tint: GhosttyColor) {
        queue.async { self.startPulse(session, tint: tint) }
    }

    /// Sends OSC 111 to every tty recorded as possibly tinted (from the recovery file) and
    /// clears it; also drops any hover and stops running pulses. Non-blocking.
    public func resetAll() {
        requests.withLock { $0.hover = nil }
        queue.async { self.performResetAll() }
    }

    /// `resetAll()` for `applicationWillTerminate`: waits at most `timeout` for it to finish.
    public func resetAllSync(timeout: Duration = .milliseconds(200)) {
        requests.withLock { $0.hover = nil }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.performResetAll()
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.dispatchInterval(timeout))
    }

    /// Blocks until all queued work has run (not pending timers). Tests only, off the main thread.
    func waitUntilIdle() { queue.sync {} }

    // MARK: - Queue work

    private func scheduleReconcile() {
        let schedule = requests.withLock { r -> Bool in
            guard !r.reconcileScheduled else { return false }
            r.reconcileScheduled = true
            return true
        }
        guard schedule else { return }
        queue.async { self.reconcile() }
    }

    /// Moves the panes from `hover` to the latest requested hover: resets the old pane, then
    /// tints the new one; the same pane in a new color gets just the new tint. A pane owned by a
    /// running pulse isn't written; the pulse's last step leaves it in the hover state.
    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        let wanted = requests.withLock { r -> HoverRequest? in
            r.reconcileScheduled = false
            return r.hover
        }
        if let current = hover, let wanted, current.tty == wanted.session.tty, current.tint == wanted.tint,
           wanted.session.status != .busy
        {
            if current.generation != wanted.generation {
                hover?.generation = wanted.generation
                scheduleCap(generation: wanted.generation)
            }
            return
        }
        let target = wanted.flatMap(hoverTTY)
        if let current = hover, current.tty != target {
            hover = nil
            if pulsing[current.tty] == nil { writeReset(current.tty) }
        }
        guard let wanted, let tty = target else { return }
        let previous = hover  // nil, or this pane in another color
        hover = AppliedHover(tty: tty, tint: wanted.tint, generation: wanted.generation)
        if pulsing[tty] == nil, !writeTint(wanted.tint, to: tty) {
            // Nothing went out: the pane still shows the previous tint (if any). Keep tracking
            // it, under this request's generation and cap, so endHover/the cap reset it and a
            // keep-alive beginHover retries the recolor.
            guard var previous else { hover = nil; return }
            previous.generation = wanted.generation
            hover = previous
        }
        scheduleCap(generation: wanted.generation)
    }

    /// The tty a hover on `request` may tint: eligible, not busy, no fresh probe lock.
    private func hoverTTY(_ request: HoverRequest) -> String? {
        guard request.session.status != .busy, let tty = eligibleTTY(request.session) else { return nil }
        guard !isProbeLockFresh(tty: tty) else {
            Self.logger.debug("highlight skipped: probe lock held tty=\(tty, privacy: .public)")
            return nil
        }
        return tty
    }

    /// Safety cap: if the hover with `generation` is still wanted after `hoverCap`, drop it.
    private func scheduleCap(generation: UInt64) {
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(timing.hoverCap)) {
            let expired = self.requests.withLock { r -> Bool in
                guard r.hover?.generation == generation else { return false }
                r.hover = nil
                return true
            }
            if expired { self.reconcile() }
        }
    }

    private func startPulse(_ session: ClaudeSession, tint: GhosttyColor) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let tty = eligibleTTY(session), !isProbeLockFresh(tty: tty) else { return }
        nextPulseID &+= 1
        let id = nextPulseID
        pulsing[tty] = id
        guard writeTint(tint, to: tty) else { pulsing[tty] = nil; return }
        // Two writes in all: the tint now, then settle to the hover tint (if that pane is hovered
        // in another color; nothing if it's the same) or reset.
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(timing.pulseDuration)) {
            guard self.pulsing[tty] == id else { return }  // superseded or reset
            self.pulsing[tty] = nil
            if let h = self.hover, h.tty == tty {
                // A failed settle leaves the pulse tint up: track that, so a keep-alive
                // beginHover retries the hover tint.
                if h.tint != tint, !self.writeTint(h.tint, to: tty) { self.hover?.tint = tint }
            } else {
                self.writeReset(tty)
            }
        }
    }

    private func performResetAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        hover = nil
        pulsing.removeAll()
        let before = loadRecorded()
        var keep = Set<String>()
        for tty in before.sorted() {
            switch io.recoveryState(tty) {
            case .ghostty:
                if !sendReset(tty) { keep.insert(tty) }  // retried by the next resetAll
            case .unknown:
                keep.insert(tty)  // couldn't list its processes: try again next time
            case .notGhostty:
                break  // gone, or no live Ghostty-hosted process (maybe a reused tty number): drop
            }
        }
        setRecorded(keep)
        // The request was cleared when resetAll was called, so a hover wanted now came later
        // (its reconcile may already have run before this reset).
        if requests.withLock({ $0.hover != nil }) { reconcile() }
    }

    // MARK: - Writes

    /// Records `tty`, then writes the tint. False if nothing went out. A tty this call newly
    /// recorded is then forgotten again; one that was already recorded may still show an earlier
    /// tint, so it stays recorded.
    @discardableResult
    private func writeTint(_ color: GhosttyColor, to tty: String) -> Bool {
        let wasRecorded = loadRecorded().contains(tty)
        record(tty)
        let bytes = Self.tintSequence(color)
        let sent = io.write(bytes, tty)
        if sent == 0 {
            if !wasRecorded { unrecord(tty) }
            return false
        }
        if sent < bytes.count {
            _ = io.write(Self.stringTerminator, tty)
            Self.logger.error("highlight: partial tint tty=\(tty, privacy: .public) wrote=\(sent)/\(bytes.count)")
        }
        return true
    }

    /// Writes OSC 111; forgets the tty once it fully went out (else `resetAll` retries it).
    private func writeReset(_ tty: String) {
        if sendReset(tty) { unrecord(tty) }
    }

    /// Writes OSC 111 (closing a partial one with ST); true if it fully went out.
    private func sendReset(_ tty: String) -> Bool {
        let sent = io.write(Self.resetSequence, tty)
        guard sent == Self.resetSequence.count else {
            if sent > 0 { _ = io.write(Self.stringTerminator, tty) }
            Self.logger.error("highlight: reset failed tty=\(tty, privacy: .public) wrote=\(sent)/\(Self.resetSequence.count)")
            return false
        }
        return true
    }

    // MARK: - Eligibility

    /// The session's tty if it may be tinted: Ghostty, a `/dev/ttysN` that is the live pid's
    /// controlling terminal, and no tmux in between.
    private func eligibleTTY(_ session: ClaudeSession) -> String? {
        guard session.terminal == .ghostty, let tty = session.tty, session.pid > 0,
              OSC7Probe.isWritableTTYPath(tty), io.isControllingTTY(tty, session.pid),
              !io.isInsideTmux(session.pid)
        else { return nil }
        return tty
    }

    /// True if an OSC 7 probe lock for `tty` exists and was touched within `probeLockFreshFor`
    /// (holders heartbeat every 2 s). Never takes the lock: a tint must not wait.
    func isProbeLockFresh(tty: String) -> Bool {
        guard let path = OSC7ProbeLock(directory: lockDirectory).lockPath(forTTY: tty),
              let age = OSC7ProbeLock.age(path)
        else { return false }
        return age < timing.probeLockFreshFor
    }

    /// Gate for a recovery reset, with a single `stat`: `path` is a `/dev/ttysN` char device and
    /// some live process has it as its controlling tty with a Ghostty ancestor (the tint-time
    /// checks, minus the session we no longer know). A tty whose number was reused by another
    /// terminal, or a pane whose processes all exited, is `.notGhostty`; `.unknown` if the
    /// processes on it couldn't be listed.
    static func recoveryState(ofTTY path: String) -> RecoveryTTYState {
        var st = stat()
        guard OSC7Probe.isWritableTTYPath(path), stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFCHR
        else { return .notGhostty }
        guard let pids = pids(withControllingTTY: st.st_rdev) else { return .unknown }
        let ghostty = pids.contains { pid in
            let paths = ProcessTree.ancestors(of: pid).compactMap { SystemProcessInspector.path(pid: $0) }
            return ProcessRules.terminalKind(ancestorPaths: paths) == .ghostty
        }
        return ghostty ? .ghostty : .notGhostty
    }

    /// Pids whose controlling tty is device `dev` (`sysctl KERN_PROC_TTY`); nil if the sysctl
    /// failed (unknown, not "none").
    static func pids(withControllingTTY dev: dev_t) -> [Int32]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, dev]
        for _ in 0..<3 {  // the table can grow between the size query and the read
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            guard size > 0 else { return [] }
            let stride = MemoryLayout<kinfo_proc>.stride
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
            size = procs.count * stride
            let rc = procs.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if rc == 0 {
                return procs.prefix(size / stride).map(\.kp_proc.p_pid).filter { $0 > 0 }
            }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    // MARK: - Recovery file

    private func loadRecorded() -> Set<String> {
        if let recorded { return recorded }
        // Lossy decode: a file that isn't valid UTF-8 keeps its readable lines and is rewritten.
        let data = try? Data(contentsOf: recoveryFile)
        let loaded = Self.parseRecoveryFile(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
        recorded = loaded
        // Junk lines, invalid bytes or a non-canonical layout get cleaned up by the next save.
        recoveryFileDirty = data.map { $0 != Data(Self.formatRecoveryFile(loaded).utf8) } ?? false
        return loaded
    }

    private func record(_ tty: String) {
        var set = loadRecorded()
        set.insert(tty)
        setRecorded(set)
    }

    private func unrecord(_ tty: String) {
        var set = loadRecorded()
        set.remove(tty)
        setRecorded(set)
    }

    /// Updates the recorded set, writing the file only if that changes what's on disk.
    private func setRecorded(_ set: Set<String>) {
        let old = loadRecorded()
        guard set != old || recoveryFileDirty else { return }
        recorded = set
        recoveryFileDirty = !saveRecorded(set)
    }

    /// Atomic replace; removes the file when nothing is recorded. False if that failed.
    private func saveRecorded(_ set: Set<String>) -> Bool {
        let fm = FileManager.default
        if set.isEmpty {
            do {
                try fm.removeItem(at: recoveryFile)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
            } catch {
                return false
            }
            return true
        }
        do {
            if !recoveryDirectoryCreated {
                try fm.createDirectory(at: recoveryFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                recoveryDirectoryCreated = true
            }
            try Data(Self.formatRecoveryFile(set).utf8).write(to: recoveryFile, options: .atomic)
            return true
        } catch {
            recoveryDirectoryCreated = false  // it may have been deleted: recreate it next time
            Self.logger.error("highlight: couldn't write recovery file: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One tty path per line; anything that isn't a `/dev/ttysN` path is ignored.
    static func parseRecoveryFile(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(OSC7Probe.isWritableTTYPath))
    }

    static func formatRecoveryFile(_ ttys: Set<String>) -> String {
        ttys.sorted().map { $0 + "\n" }.joined()
    }

    static func dispatchInterval(_ d: Duration) -> DispatchTimeInterval {
        let (secs, attos) = d.components
        return .nanoseconds(Int(clamping: secs * 1_000_000_000 + attos / 1_000_000_000))
    }
}

/// Side effects of `TerminalHighlighter`, injectable for tests.
struct TerminalHighlighterIO: Sendable {
    /// Writes bytes to the tty (non-blocking open, bounded retry); returns how many went out.
    var write: @Sendable (_ bytes: [UInt8], _ tty: String) -> Int = { OSC7Probe.write($0, toTTY: $1) }
    var isControllingTTY: @Sendable (_ tty: String, _ pid: Int32) -> Bool = { OSC7Probe.isControllingTTY($0, ofPID: $1) }
    var isInsideTmux: @Sendable (_ pid: Int32) -> Bool = { ProcessTree.isInsideTmux($0) }
    /// Gate for `resetAll` (the session may be gone): is the path a `/dev/ttysN` char device
    /// with a live Ghostty-hosted process on it.
    var recoveryState: @Sendable (_ path: String) -> RecoveryTTYState = { TerminalHighlighter.recoveryState(ofTTY: $0) }
}

/// Whether `resetAll` may send a recovery reset to a recorded tty.
enum RecoveryTTYState: Sendable, Equatable {
    /// A `/dev/ttysN` char device with a live Ghostty-hosted process on it: reset it.
    case ghostty
    /// Gone, not a tty device, or no live Ghostty-hosted process on it: drop the entry.
    case notGhostty
    /// The processes on it couldn't be listed: keep the entry for the next try.
    case unknown
}

struct TerminalHighlighterTiming: Sendable {
    /// A hover tint is dropped after this long without a new `beginHover`.
    var hoverCap: Duration = .seconds(3)
    /// Pulse: the tint, then this long until the reset (or settle to the hover tint).
    var pulseDuration: Duration = .milliseconds(400)
    /// A probe lock touched more recently than this blocks a tint.
    var probeLockFreshFor: TimeInterval = 10
}
