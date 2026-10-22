import Darwin
import Foundation

/// Cross-process lock around an OSC 7 probe of one tty, shared with the hook's detached shell
/// probe (`hooks/claude-watcher-hook.sh`): both rewrite the same terminal's pwd, so concurrent
/// probes would clobber each other's nonce. Protocol v2 (must match the shell side):
///
/// - Path: `<hook-state dir>/.probe-<ttyname>.lock` (e.g. `.probe-ttys001.lock`), a directory.
/// - Acquire: `mkdir` (atomic), then write `<lock>/owner` = `<pid> <random token>\n`.
/// - Wait: poll every ~25 ms for up to 1 s (async sleep), then give up (skip the probe).
/// - Heartbeat: the holder touches the lock dir about every 2 s until release, so a long hold
///   (e.g. a first-run Automation prompt blocking the AppleScript) doesn't look abandoned.
/// - Stale: owner readable and its pid dead (`kill(pid, 0)` → ESRCH; EPERM means alive); or
///   owner missing/unreadable and dir mtime older than 10 s; or owner pid alive but dir mtime
///   older than 120 s (hard cap against pid reuse).
/// - Break: remember the owner content S judged stale, rename the lock to
///   `<lock>.stale-<random>`, re-read the aside owner. Equal to S: remove the aside dir and retry
///   the `mkdir`. Different (we moved a fresh lock away): rename it back (if a lock already
///   exists again, remove the aside dir instead) and treat the lock as busy.
/// - Release: only if `owner` still holds our token: remove `owner`, then `rmdir`.
public struct OSC7ProbeLock: Sendable {
    public var directory: URL
    public var maxWait: Duration
    public var pollInterval: Duration
    /// Staleness age for a lock without a readable owner.
    public var staleAfter: TimeInterval
    /// Staleness age for a lock whose owner pid is still alive (pid-reuse cap).
    public var aliveOwnerStaleAfter: TimeInterval
    public var heartbeatInterval: Duration

    public init(directory: URL = HookStateStore.defaultDirectory, maxWait: Duration = .seconds(1),
                pollInterval: Duration = .milliseconds(25), staleAfter: TimeInterval = 10,
                aliveOwnerStaleAfter: TimeInterval = 120, heartbeatInterval: Duration = .seconds(2))
    {
        self.directory = directory
        self.maxWait = maxWait
        self.pollInterval = pollInterval
        self.staleAfter = staleAfter
        self.aliveOwnerStaleAfter = aliveOwnerStaleAfter
        self.heartbeatInterval = heartbeatInterval
    }

    /// A held lock. Release it exactly once (in a `defer`).
    public struct Held: Sendable {
        public let path: String
        public let token: String
        let heartbeat: Task<Void, Never>

        /// Stops the heartbeat and removes the lock if `owner` still carries our token. Returns
        /// false (and leaves the lock alone) if it was broken as stale and re-taken by someone else.
        @discardableResult
        public func release() -> Bool {
            heartbeat.cancel()
            guard OSC7ProbeLock.ownerToken(OSC7ProbeLock.readOwner(path) ?? "") == token else { return false }
            unlink(path + "/owner")
            return rmdir(path) == 0
        }
    }

    enum Attempt {
        case acquired(Held)
        /// Held by someone else (and not stale).
        case busy
        /// Unusable (bad tty name, unwritable directory, …): don't wait.
        case failed
    }

    /// `<directory>/.probe-<ttyname>.lock`, or nil for a tty name unusable in a file name.
    func lockPath(forTTY tty: String) -> String? {
        let name = (tty as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
        else { return nil }
        return directory.appendingPathComponent(".probe-\(name).lock", isDirectory: true).path
    }

    /// Waits (polling, never blocking a thread) up to `maxWait` for the lock. Nil means skip
    /// the probe: still busy, cancelled, or the lock can't be created.
    public func acquire(tty: String) async -> Held? {
        let deadline = ContinuousClock.now + maxWait
        while true {
            switch tryAcquire(tty: tty) {
            case .acquired(let held): return held
            case .failed: return nil
            case .busy:
                guard ContinuousClock.now < deadline else { return nil }
                do { try await Task.sleep(for: pollInterval) } catch { return nil }
            }
        }
    }

    /// One non-blocking attempt; breaks a stale lock and retries once.
    func tryAcquire(tty: String) -> Attempt {
        guard let path = lockPath(forTTY: tty) else { return .failed }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<2 {
            if mkdir(path, 0o700) == 0 {
                let token = Self.makeToken()
                let owner = "\(getpid()) \(token)\n"
                guard FileManager.default.createFile(atPath: path + "/owner", contents: Data(owner.utf8)) else {
                    unlink(path + "/owner")
                    rmdir(path)
                    return .failed
                }
                return .acquired(Held(path: path, token: token,
                                      heartbeat: Self.startHeartbeat(path: path, token: token, every: heartbeatInterval)))
            }
            guard errno == EEXIST else { return .failed }
            guard breakIfStale(path) else { return .busy }
        }
        return .busy
    }

    /// Touches the lock dir every `interval` until cancelled or the lock is no longer ours.
    static func startHeartbeat(path: String, token: String, every interval: Duration) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard ownerToken(readOwner(path) ?? "") == token else { return }
                utimes(path, nil)
            }
        }
    }

    /// If the lock at `path` is stale (see the type doc), breaks it by renaming it aside. Returns
    /// true if the lock is gone (by us or anyone) and `mkdir` should be retried; false if busy.
    /// `beforeRename`/`afterRename` are test seams for simulating concurrent lockers.
    func breakIfStale(_ path: String, beforeRename: () -> Void = {}, afterRename: () -> Void = {}) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let owner = Self.readOwner(path)
        guard isStale(owner: owner, age: Date().timeIntervalSince1970 - mtime) else { return false }

        beforeRename()
        let aside = "\(path).stale-\(Self.makeToken())"
        guard rename(path, aside) == 0 else { return errno == ENOENT }  // ENOENT: another breaker won
        afterRename()
        if Self.readOwner(aside) == owner {
            try? FileManager.default.removeItem(atPath: aside)
            return true
        }
        // We renamed away a fresh lock: put it back without clobbering a newer one (RENAME_EXCL
        // also refuses to replace an empty, just-mkdir'd lock dir), else drop it.
        if renamex_np(aside, path, UInt32(RENAME_EXCL)) != 0 {
            try? FileManager.default.removeItem(atPath: aside)
        }
        return false
    }

    /// Staleness rule for a lock with owner content `owner` (nil: missing/unreadable) whose dir
    /// mtime is `age` seconds old.
    func isStale(owner: String?, age: TimeInterval) -> Bool {
        guard let owner, let pid = Self.ownerPID(owner) else { return age > staleAfter }
        return !Self.isAlive(pid) || age > aliveOwnerStaleAfter
    }

    /// Contents of `<lock>/owner`, or nil if missing/unreadable.
    static func readOwner(_ lockPath: String) -> String? {
        FileManager.default.contents(atPath: lockPath + "/owner").map { String(decoding: $0, as: UTF8.self) }
    }

    /// The pid field of an `owner` file (`<pid> <token>`), if it is a positive number.
    static func ownerPID(_ contents: String) -> pid_t? {
        let fields = contents.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let pid = pid_t(fields[0]), pid > 0 else { return nil }
        return pid
    }

    /// The token field of an `owner` file (`<pid> <token>`).
    static func ownerToken(_ contents: String) -> String? {
        let fields = contents.split(whereSeparator: \.isWhitespace)
        return fields.count == 2 ? String(fields[1]) : nil
    }

    /// `kill(pid, 0)`: success or EPERM means the process exists.
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func makeToken() -> String {
        let hex = String(UInt64.random(in: .min ... .max), radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
