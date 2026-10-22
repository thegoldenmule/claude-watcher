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
/// Every public method returns immediately: tty I/O runs on a private serial queue. Hover
/// changes are coalesced (the queue applies only the latest wanted hover, resetting the previous
/// pane first), so a burst of hovers never queues stale tints.
///
/// A tty is recorded in `recoveryFile` before it's tinted and removed once its reset went out,
/// so `resetAll()` (at launch, panel hide, terminate) can clear a tint left behind by a crash.
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

    /// Brief attention pulse (tint, reset, tint at `pulseStep` intervals, ~450 ms in all, then
    /// OSC 111, or the hover tint if that pane is still hovered). Non-blocking, fire-and-forget.
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
    /// tints the new one. A pane owned by a running pulse isn't written; the pulse's last step
    /// leaves it in the hover state.
    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        let wanted = requests.withLock { r -> HoverRequest? in
            r.reconcileScheduled = false
            return r.hover
        }
        if let current = hover, let wanted, current.tty == wanted.session.tty, current.tint == wanted.tint {
            if current.generation != wanted.generation {
                hover?.generation = wanted.generation
                scheduleCap(generation: wanted.generation)
            }
            return
        }
        if let current = hover {
            hover = nil
            if pulsing[current.tty] == nil { writeReset(current.tty) }
        }
        guard let wanted, let tty = eligibleTTY(wanted.session) else { return }
        guard !isProbeLockFresh(tty: tty) else {
            Self.logger.debug("highlight skipped: probe lock held tty=\(tty, privacy: .public)")
            return
        }
        hover = AppliedHover(tty: tty, tint: wanted.tint, generation: wanted.generation)
        if pulsing[tty] == nil, !writeTint(wanted.tint, to: tty) { hover = nil; return }
        scheduleCap(generation: wanted.generation)
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
        // tint (0) -> reset (1 step) -> tint (2 steps) -> settle (3 steps, ~450 ms).
        let step = timing.pulseStep
        schedulePulseStep(after: step, tty: tty, id: id) { self.writeReset(tty) }
        schedulePulseStep(after: step * 2, tty: tty, id: id) { self.writeTint(tint, to: tty) }
        schedulePulseStep(after: step * 3, tty: tty, id: id) {
            self.pulsing[tty] = nil
            if let h = self.hover, h.tty == tty { self.writeTint(h.tint, to: tty) } else { self.writeReset(tty) }
        }
    }

    private func schedulePulseStep(after delay: Duration, tty: String, id: UInt64,
                                   _ body: @escaping @Sendable () -> Void)
    {
        queue.asyncAfter(deadline: .now() + Self.dispatchInterval(delay)) {
            guard self.pulsing[tty] == id else { return }  // superseded or reset
            body()
        }
    }

    private func performResetAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        hover = nil
        pulsing.removeAll()
        for tty in loadRecorded().sorted() where io.isTTYDevice(tty) {
            let sent = io.write(Self.resetSequence, tty)
            if sent > 0, sent < Self.resetSequence.count { _ = io.write(Self.stringTerminator, tty) }
        }
        recorded = []
        saveRecorded()
        // The request was cleared when resetAll was called, so a hover wanted now came later
        // (its reconcile may already have run before this reset).
        if requests.withLock({ $0.hover != nil }) { reconcile() }
    }

    // MARK: - Writes

    /// Records `tty`, then writes the tint. False if nothing went out (no tint to undo).
    @discardableResult
    private func writeTint(_ color: GhosttyColor, to tty: String) -> Bool {
        record(tty)
        let bytes = Self.tintSequence(color)
        let sent = io.write(bytes, tty)
        if sent == 0 {
            unrecord(tty)
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
        let sent = io.write(Self.resetSequence, tty)
        guard sent == Self.resetSequence.count else {
            if sent > 0 { _ = io.write(Self.stringTerminator, tty) }
            Self.logger.error("highlight: reset failed tty=\(tty, privacy: .public) wrote=\(sent)/\(Self.resetSequence.count)")
            return
        }
        unrecord(tty)
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
        guard let path = OSC7ProbeLock(directory: lockDirectory).lockPath(forTTY: tty) else { return false }
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return io.now().timeIntervalSince(mtime) < timing.probeLockFreshFor
    }

    /// A `/dev/ttysN` path that exists and is a character device.
    static func isTTYDevice(_ path: String) -> Bool {
        guard OSC7Probe.isWritableTTYPath(path) else { return false }
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFCHR
    }

    // MARK: - Recovery file

    private func loadRecorded() -> Set<String> {
        if let recorded { return recorded }
        let loaded = Self.parseRecoveryFile((try? String(contentsOf: recoveryFile, encoding: .utf8)) ?? "")
        recorded = loaded
        return loaded
    }

    private func record(_ tty: String) {
        var set = loadRecorded()
        guard set.insert(tty).inserted else { return }
        recorded = set
        saveRecorded()
    }

    private func unrecord(_ tty: String) {
        var set = loadRecorded()
        guard set.remove(tty) != nil else { return }
        recorded = set
        saveRecorded()
    }

    /// Atomic replace; removes the file when nothing is recorded.
    private func saveRecorded() {
        let set = recorded ?? []
        if set.isEmpty {
            try? FileManager.default.removeItem(at: recoveryFile)
            return
        }
        do {
            try FileManager.default.createDirectory(at: recoveryFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(Self.formatRecoveryFile(set).utf8).write(to: recoveryFile, options: .atomic)
        } catch {
            Self.logger.error("highlight: couldn't write recovery file: \(error.localizedDescription, privacy: .public)")
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
    /// Gate for `resetAll` (the session may be gone): the path is a `/dev/ttysN` char device.
    var isTTYDevice: @Sendable (_ path: String) -> Bool = { TerminalHighlighter.isTTYDevice($0) }
    var now: @Sendable () -> Date = { Date() }
}

struct TerminalHighlighterTiming: Sendable {
    /// A hover tint is dropped after this long without a new `beginHover`.
    var hoverCap: Duration = .seconds(3)
    /// Pulse: tint, reset, tint, settle, one step apart.
    var pulseStep: Duration = .milliseconds(150)
    /// A probe lock touched more recently than this blocks a tint.
    var probeLockFreshFor: TimeInterval = 10
}
