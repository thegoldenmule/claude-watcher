import Darwin
import Foundation

/// Point-in-time facts about a process.
public struct ProcessSnapshot: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var startTime: Date
    /// e.g. "/dev/ttys001"; nil when the process has no controlling terminal.
    public var tty: String?
    /// Absolute executable path, if readable.
    public var executablePath: String?

    public init(pid: Int32, ppid: Int32, startTime: Date, tty: String? = nil, executablePath: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.startTime = startTime
        self.tty = tty
        self.executablePath = executablePath
    }
}

/// Abstraction over libproc so discovery can be tested with fake process tables.
public protocol ProcessInspecting: Sendable {
    func snapshot(pid: Int32) -> ProcessSnapshot?
    /// The process's argv (argv[0] first), if readable. Comparatively expensive: callers
    /// should only ask when the executable alone is not conclusive (e.g. `node`).
    func arguments(pid: Int32) -> [String]?
}

extension ProcessInspecting {
    public func arguments(pid: Int32) -> [String]? { nil }

    /// Ancestors of `pid` (parent first), stopping before launchd (pid 1).
    public func ancestors(of pid: Int32, maxDepth: Int = 24) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var current = snapshot(pid: pid)?.ppid ?? 0
        var seen: Set<Int32> = [pid]
        while current > 1, result.count < maxDepth, !seen.contains(current),
              let snap = snapshot(pid: current) {
            seen.insert(current)
            result.append(snap)
            current = snap.ppid
        }
        return result
    }
}

/// Real implementation backed by `proc_pidinfo(PROC_PIDTBSDINFO)` / `proc_pidpath`,
/// falling back to `sysctl(KERN_PROC_PID)` when libproc refuses (e.g. root-owned `login`).
public struct SystemProcessInspector: ProcessInspecting {
    public init() {}

    public func snapshot(pid: Int32) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var ppid: Int32
        var start: Date
        var tdev: UInt32

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            ppid = Int32(bitPattern: info.pbi_ppid)
            start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
            tdev = info.e_tdev
        } else if let kp = Self.kinfo(pid: pid) {
            ppid = kp.kp_eproc.e_ppid
            let tv = kp.kp_proc.p_un.__p_starttime
            start = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
            tdev = UInt32(bitPattern: kp.kp_eproc.e_tdev)
        } else {
            return nil
        }

        return ProcessSnapshot(
            pid: pid, ppid: ppid, startTime: start,
            tty: Self.ttyPath(tdev), executablePath: Self.path(pid: pid))
    }

    static func ttyPath(_ tdev: UInt32) -> String? {
        // NODEV is (dev_t)-1.
        guard tdev != UInt32.max, tdev != 0 else { return nil }
        guard let name = devname(dev_t(bitPattern: tdev), S_IFCHR) else { return nil }
        let s = String(cString: name)
        guard !s.isEmpty, s != "??" else { return nil }
        return "/dev/" + s
    }

    static func path(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        let bytes = buffer.prefix(Int(n)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func arguments(pid: Int32) -> [String]? {
        guard pid > 0 else { return nil }
        var argmax: Int32 = 0
        var argmaxLen = MemoryLayout<Int32>.size
        var argmaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMib, 2, &argmax, &argmaxLen, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var len = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &len, nil, 0) == 0 else { return nil }
        return Self.parseProcArgs2(buffer.prefix(len))
    }

    /// Parses a `KERN_PROCARGS2` buffer: `int argc`, the exec path, NUL padding, then
    /// `argc` NUL-terminated argument strings (followed by the environment, ignored).
    static func parseProcArgs2(_ bytes: ArraySlice<UInt8>) -> [String]? {
        let intSize = MemoryLayout<Int32>.size
        guard bytes.count >= intSize else { return nil }
        let argc = bytes.prefix(intSize).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc >= 0 else { return nil }
        var i = bytes.startIndex + intSize
        // Skip the exec path, then the NUL padding after it.
        while i < bytes.endIndex, bytes[i] != 0 { i += 1 }
        while i < bytes.endIndex, bytes[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < bytes.endIndex {
            let start = i
            while i < bytes.endIndex, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func kinfo(pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &kp, &len, nil, 0) == 0, len > 0,
              kp.kp_proc.p_pid == pid
        else { return nil }
        return kp
    }
}

/// Pure process-related rules.
public enum ProcessRules {
    /// Allowed difference between `procStart` (second resolution) and the real start time.
    public static let startTolerance: TimeInterval = 2

    /// Whether `executablePath` runs Claude Code. Mirrors the hook's `find_claude`: a binary
    /// named `claude` (Homebrew cask, symlinked installs), the native installer's
    /// `…/claude/versions/<ver>`, the cask's `Caskroom/claude-code/`, or `node` running the npm
    /// package. `arguments` is only consulted for `node`, so the argv read stays rare.
    public static func isClaudeExecutable(_ executablePath: String?, arguments: () -> [String]?) -> Bool {
        guard let path = executablePath, !path.isEmpty else { return false }
        if path.contains("/claude/versions/") || path.contains("Caskroom/claude-code/") { return true }
        let name = (path as NSString).lastPathComponent
        if name == "claude" { return true }
        guard name == "node" else { return false }
        return arguments()?.contains { $0.contains("@anthropic-ai/claude-code") } ?? false
    }

    /// A registry record is live when its pid exists, runs a Claude Code binary, and
    /// started when the record says (guards against pid reuse by stale files).
    /// `arguments` supplies the process's argv; it is only called for `node` processes.
    public static func isLive(
        _ record: SessionRecord, process: ProcessSnapshot?, arguments: () -> [String]? = { nil }
    ) -> Bool {
        guard let process, process.pid == record.pid else { return false }
        guard isClaudeExecutable(process.executablePath, arguments: arguments) else { return false }
        if let procStart = record.procStartDate {
            return abs(process.startTime.timeIntervalSince(procStart)) <= startTolerance
        }
        if let startedAt = record.startedAtDate {
            // startedAt is written shortly after the process starts.
            let delta = startedAt.timeIntervalSince(process.startTime)
            return delta >= -startTolerance && delta <= 600
        }
        return true
    }

    /// Classifies the hosting terminal from ancestor executable paths (nearest first).
    public static func terminalKind(ancestorPaths: [String]) -> TerminalKind {
        for path in ancestorPaths {
            if path.contains("/Ghostty.app/") { return .ghostty }
            if path.contains("/Terminal.app/") { return .appleTerminal }
        }
        // Nearest enclosing .app bundle, e.g. "iTerm", "Code".
        for path in ancestorPaths {
            if let range = path.range(of: ".app/") {
                let bundle = (String(path[..<range.lowerBound]) as NSString).lastPathComponent
                if !bundle.isEmpty { return .other(bundle) }
            }
        }
        // Otherwise the outermost non-shell ancestor (e.g. "tmux", "sshd").
        let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "-zsh", "-bash", "-sh", "-fish"]
        for path in ancestorPaths.reversed() {
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty, !shells.contains(name) { return .other(name) }
        }
        return .other("unknown")
    }
}
