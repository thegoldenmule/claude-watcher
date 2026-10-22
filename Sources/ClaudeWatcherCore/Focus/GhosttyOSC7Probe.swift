import Darwin
import Foundation
import os

/// Maps a session's tty to a Ghostty terminal by writing an OSC 7 ("current directory") escape
/// with a unique nonce path to the tty, asking Ghostty which terminal's `working directory`
/// now contains the nonce, then writing OSC 7 again with the real cwd. Invisible: OSC 7 only
/// updates Ghostty's notion of the pwd. ~75–90 ms in the spike.
///
/// Pure pieces (nonce, escape building, tty validation) are static and unit-tested.
public enum OSC7Probe {
    /// "CW-<pid>-<16 hex digits>". Only [A-Za-z0-9-], so it's safe in a URL path and
    /// AppleScript. Fixed-width random part; the lookup also requires it to be the whole last
    /// path component (see `GhosttyScripting.nonceMatches`).
    public static func makeNonce(pid: Int32, random: UInt64 = .random(in: .min ... .max)) -> String {
        let hex = String(random, radix: 16)
        return "CW-\(pid)-\(String(repeating: "0", count: max(0, 16 - hex.count)))\(hex)"
    }

    /// `ESC ] 7 ; file://<host>/tmp/<nonce> BEL`
    public static func probeSequence(host: String, nonce: String) -> String {
        "\u{1B}]7;file://\(host)/tmp/\(nonce)\u{07}"
    }

    /// `ESC ] 7 ; file://<host><percent-encoded cwd> BEL`
    public static func restoreSequence(host: String, cwd: String) -> String {
        "\u{1B}]7;file://\(host)\(percentEncodePath(cwd))\u{07}"
    }

    /// Percent-encodes a path for a file URL; also encodes control chars, so the sequence can't
    /// be terminated early by a BEL/ESC in the path.
    public static func percentEncodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%;?#")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Only plain pseudo-terminal device paths are ever written to.
    public static func isWritableTTYPath(_ tty: String) -> Bool {
        guard tty.hasPrefix("/dev/ttys") else { return false }
        let digits = tty.dropFirst("/dev/ttys".count)
        return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    /// Local host name as `hostname(1)` prints it (what Ghostty compares OSC 7 hosts against).
    public static func hostName() -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buf, buf.count - 1) == 0 else { return "localhost" }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? "localhost" : name
    }

    /// Bound on how long one sequence write waits for a flow-controlled tty to drain.
    static let writeTimeout: Duration = .milliseconds(200)

    /// Writes `string` to `tty`; true if every byte went out (see `write(_:toTTY:)`).
    static func write(_ string: String, toTTY tty: String) -> Bool {
        let bytes = Array(string.utf8)
        return write(bytes, toTTY: tty) == bytes.count
    }

    /// Writes `bytes` to `tty` without making it our controlling terminal and without blocking
    /// indefinitely (a flow-controlled tty returns EAGAIN instead of hanging; we then wait up to
    /// `writeTimeout` for it to drain). Returns how many bytes were written.
    static func write(_ bytes: [UInt8], toTTY tty: String) -> Int {
        guard isWritableTTYPath(tty) else { return 0 }
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        return writeAll(bytes, to: fd, timeout: writeTimeout)
    }

    /// Writes `bytes` to a non-blocking `fd`, retrying short writes and EAGAIN by waiting for
    /// `POLLOUT`, for at most `timeout` in total. Returns how many bytes were written.
    static func writeAll(_ bytes: [UInt8], to fd: Int32, timeout: Duration) -> Int {
        let deadline = ContinuousClock.now + timeout
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
            }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            guard n == 0 || errno == EAGAIN else { break }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { break }
            let (secs, attos) = remaining.components
            let ms = Int32(clamping: secs * 1000 + (attos + 999_999_999_999_999) / 1_000_000_000_000_000)
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, max(1, ms))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { break }
        }
        return offset
    }

    /// True if `pid` is alive and `tty` is its controlling terminal (guards against writing to a
    /// recycled tty after the session exited).
    static func isControllingTTY(_ tty: String, ofPID pid: Int32) -> Bool {
        guard let info = ProcessTree.kinfo(pid) else { return false }
        var st = stat()
        guard stat(tty, &st) == 0 else { return false }
        return info.kp_eproc.e_tdev == st.st_rdev
    }
}

/// Process-tree helpers (sysctl/libproc; no subprocesses).
enum ProcessTree {
    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func parentPID(of pid: Int32) -> Int32? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    static func name(of pid: Int32) -> String? {
        guard var info = kinfo(pid) else { return nil }
        return withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Ancestors of `pid` (excluding itself), nearest first, stopping at launchd.
    static func ancestors(of pid: Int32) -> [Int32] {
        var out: [Int32] = []
        var current = pid
        while let parent = parentPID(of: current), parent > 1, !out.contains(parent), out.count < 64 {
            out.append(parent)
            current = parent
        }
        return out
    }

    /// True if any ancestor is a tmux (server) process. Probing a tmux pty can't reach Ghostty.
    static func isInsideTmux(_ pid: Int32) -> Bool {
        ancestors(of: pid).contains { (name(of: $0) ?? "").hasPrefix("tmux") }
    }
}

/// Side effects of a probe, injectable for tests.
struct OSC7ProbeIO: Sendable {
    var isControllingTTY: @Sendable (_ tty: String, _ pid: Int32) -> Bool = { OSC7Probe.isControllingTTY($0, ofPID: $1) }
    /// Writes bytes to the tty with bounded retry; returns how many were written.
    var write: @Sendable (_ bytes: [UInt8], _ tty: String) -> Int = { OSC7Probe.write($0, toTTY: $1) }
    var hostName: @Sendable () -> String = { OSC7Probe.hostName() }
    var lock = OSC7ProbeLock()
}

/// Serialises OSC 7 probes per tty (concurrent probes on one tty clobber each other's pwd) and
/// coalesces concurrent requests for the same tty into one probe. In-process via `inFlight`;
/// across processes (the hook's detached probe) via `OSC7ProbeLock`.
public actor OSC7ProbeCoordinator {
    private var inFlight: [String: Task<Result<String?, AppleScriptError>, Never>] = [:]
    private let io: OSC7ProbeIO

    public init() { self.init(io: OSC7ProbeIO()) }

    /// `lockDirectory` overrides the hook-state directory that holds the shared probe locks.
    public init(lockDirectory: URL) { self.init(io: OSC7ProbeIO(lock: OSC7ProbeLock(directory: lockDirectory))) }

    init(io: OSC7ProbeIO) { self.io = io }

    static let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Focus")

    /// Returns the Ghostty terminal id hosting `tty`, or nil if the probe found nothing or was
    /// skipped (invalid tty, process gone, tty not the process's controlling terminal, another
    /// probe of this tty held the lock for too long, nonce not fully written).
    public func probe(tty: String, pid: Int32, restoreCwd: String, ghostty: GhosttyScripting)
        async throws(AppleScriptError) -> String?
    {
        if let existing = inFlight[tty] { return try await existing.value.get() }
        let io = self.io
        let task = Task { () -> Result<String?, AppleScriptError> in
            await Self.runProbe(tty: tty, pid: pid, restoreCwd: restoreCwd, ghostty: ghostty, io: io)
        }
        inFlight[tty] = task
        let result = await task.value
        inFlight[tty] = nil
        return try result.get()
    }

    static func runProbe(tty: String, pid: Int32, restoreCwd: String, ghostty: GhosttyScripting, io: OSC7ProbeIO)
        async -> Result<String?, AppleScriptError>
    {
        guard OSC7Probe.isWritableTTYPath(tty), io.isControllingTTY(tty, pid) else { return .success(nil) }
        guard let held = await io.lock.acquire(tty: tty) else {
            logger.notice("osc7 probe skipped: lock busy tty=\(tty, privacy: .public)")
            return .success(nil)
        }
        defer { held.release() }
        // Re-check after a possible wait: the session may have exited meanwhile.
        guard io.isControllingTTY(tty, pid) else { return .success(nil) }

        let host = io.hostName()
        let nonce = OSC7Probe.makeNonce(pid: pid)
        let probe = Array(OSC7Probe.probeSequence(host: host, nonce: nonce).utf8)
        let sent = io.write(probe, tty)
        guard sent > 0 else { return .success(nil) }  // nothing went out: nothing to undo
        defer {
            let cwd = restoreCwd.isEmpty ? NSHomeDirectory() : restoreCwd
            restore(tty: tty, host: host, cwd: cwd, nonceTerminated: sent == probe.count, io: io)
        }
        guard sent == probe.count else { return .success(nil) }
        do throws(AppleScriptError) {
            let ids = try await ghostty.terminalIDs(withNonceWorkingDirectory: nonce)
            return .success(ids.count == 1 ? ids[0] : nil)
        } catch {
            return .failure(error)
        }
    }

    /// Terminates a partially written nonce sequence with BEL, then writes the real cwd back
    /// (again BEL-terminated if it only partly went out). Logs and returns false on failure.
    @discardableResult
    static func restore(tty: String, host: String, cwd: String, nonceTerminated: Bool, io: OSC7ProbeIO) -> Bool {
        let bel: [UInt8] = [0x07]
        if !nonceTerminated, io.write(bel, tty) != 1 {
            logger.error("osc7 probe: couldn't terminate partial nonce tty=\(tty, privacy: .public)")
        }
        let restore = Array(OSC7Probe.restoreSequence(host: host, cwd: cwd).utf8)
        let written = io.write(restore, tty)
        guard written == restore.count else {
            if written > 0 { _ = io.write(bel, tty) }
            logger.error("""
                osc7 probe: cwd restore failed tty=\(tty, privacy: .public) \
                wrote=\(written)/\(restore.count)
                """)
            return false
        }
        return true
    }
}
