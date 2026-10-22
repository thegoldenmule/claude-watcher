import Darwin
import Foundation

/// Maps a session's tty to a Ghostty terminal by writing an OSC 7 ("current directory") escape
/// with a unique nonce path to the tty, asking Ghostty which terminal's `working directory`
/// now contains the nonce, then writing OSC 7 again with the real cwd. Invisible: OSC 7 only
/// updates Ghostty's notion of the pwd. ~75–90 ms in the spike.
///
/// Pure pieces (nonce, escape building, tty validation) are static and unit-tested.
public enum OSC7Probe {
    /// "CW-<pid>-<random hex>". Only [A-Za-z0-9-], so it's safe in a URL path and AppleScript.
    public static func makeNonce(pid: Int32, random: UInt64 = .random(in: .min ... .max)) -> String {
        "CW-\(pid)-\(String(random, radix: 16))"
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

    /// Writes `string` to `tty` without making it our controlling terminal and without blocking
    /// (a flow-controlled tty returns EAGAIN instead of hanging).
    static func write(_ string: String, toTTY tty: String) -> Bool {
        guard isWritableTTYPath(tty) else { return false }
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(string.utf8)
        return bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == bytes.count
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

/// Serialises OSC 7 probes per tty (concurrent probes on one tty clobber each other's pwd)
/// and coalesces concurrent requests for the same tty into one probe.
public actor OSC7ProbeCoordinator {
    private var inFlight: [String: Task<Result<String?, AppleScriptError>, Never>] = [:]

    public init() {}

    /// Returns the Ghostty terminal id hosting `tty`, or nil if the probe found nothing or was
    /// skipped (invalid tty, process gone, tty not the process's controlling terminal).
    public func probe(tty: String, pid: Int32, restoreCwd: String, ghostty: GhosttyScripting)
        async throws(AppleScriptError) -> String?
    {
        if let existing = inFlight[tty] { return try await existing.value.get() }
        let task = Task { () -> Result<String?, AppleScriptError> in
            await Self.runProbe(tty: tty, pid: pid, restoreCwd: restoreCwd, ghostty: ghostty)
        }
        inFlight[tty] = task
        let result = await task.value
        inFlight[tty] = nil
        return try result.get()
    }

    private static func runProbe(tty: String, pid: Int32, restoreCwd: String, ghostty: GhosttyScripting)
        async -> Result<String?, AppleScriptError>
    {
        guard OSC7Probe.isWritableTTYPath(tty), OSC7Probe.isControllingTTY(tty, ofPID: pid) else {
            return .success(nil)
        }
        let host = OSC7Probe.hostName()
        let nonce = OSC7Probe.makeNonce(pid: pid)
        guard OSC7Probe.write(OSC7Probe.probeSequence(host: host, nonce: nonce), toTTY: tty) else {
            return .success(nil)
        }
        defer {
            let cwd = restoreCwd.isEmpty ? NSHomeDirectory() : restoreCwd
            _ = OSC7Probe.write(OSC7Probe.restoreSequence(host: host, cwd: cwd), toTTY: tty)
        }
        do throws(AppleScriptError) {
            let ids = try await ghostty.terminalIDs(withWorkingDirectoryContaining: nonce)
            return .success(ids.count == 1 ? ids[0] : nil)
        } catch {
            return .failure(error)
        }
    }
}
