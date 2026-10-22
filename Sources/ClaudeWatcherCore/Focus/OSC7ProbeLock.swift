import Darwin
import Foundation

/// Cross-process lock around an OSC 7 probe of one tty, shared with the hook's detached shell
/// probe (`hooks/claude-watcher-hook.sh`): both rewrite the same terminal's pwd, so concurrent
/// probes would clobber each other's nonce. Protocol (must match the shell side):
///
/// - Path: `<hook-state dir>/.probe-<ttyname>.lock` (e.g. `.probe-ttys001.lock`), a directory.
/// - Acquire: `mkdir` (atomic), then write `<lock>/owner` = `<pid> <random token>`.
/// - Wait: poll every ~25 ms for up to 1 s (async sleep), then give up (skip the probe).
/// - Stale: lock dir mtime older than 10 s. Break it by renaming it to `<lock>.stale-<random>`
///   (atomic, one breaker wins), removing that, then retrying the `mkdir`.
/// - Release: only if `owner` still holds our token: remove `owner`, then `rmdir`.
public struct OSC7ProbeLock: Sendable {
    public var directory: URL
    public var maxWait: Duration
    public var pollInterval: Duration
    public var staleAfter: TimeInterval

    public init(directory: URL = HookStateStore.defaultDirectory, maxWait: Duration = .seconds(1),
                pollInterval: Duration = .milliseconds(25), staleAfter: TimeInterval = 10)
    {
        self.directory = directory
        self.maxWait = maxWait
        self.pollInterval = pollInterval
        self.staleAfter = staleAfter
    }

    /// A held lock. Release it exactly once (in a `defer`).
    public struct Held: Sendable {
        public let path: String
        public let token: String

        /// Removes the lock if `owner` still carries our token. Returns false (and leaves the
        /// lock alone) if it was broken as stale and re-taken by someone else.
        @discardableResult
        public func release() -> Bool {
            let owner = path + "/owner"
            guard let data = FileManager.default.contents(atPath: owner),
                  OSC7ProbeLock.ownerToken(String(decoding: data, as: UTF8.self)) == token
            else { return false }
            unlink(owner)
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
                return .acquired(Held(path: path, token: token))
            }
            guard errno == EEXIST else { return .failed }
            guard breakIfStale(path) else { return .busy }
        }
        return .busy
    }

    /// If the lock at `path` is older than `staleAfter`, renames it aside (atomic: only one
    /// breaker wins) and removes it. Returns true if the lock is gone (by us or anyone).
    func breakIfStale(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        guard Date().timeIntervalSince1970 - mtime > staleAfter else { return false }
        let aside = "\(path).stale-\(Self.makeToken())"
        if rename(path, aside) == 0 {
            try? FileManager.default.removeItem(atPath: aside)
            return true
        }
        return errno == ENOENT  // another breaker won
    }

    /// The token field of an `owner` file (`<pid> <token>`).
    static func ownerToken(_ contents: String) -> String? {
        let fields = contents.split(whereSeparator: \.isWhitespace)
        return fields.count == 2 ? String(fields[1]) : nil
    }

    static func makeToken() -> String {
        let hex = String(UInt64.random(in: .min ... .max), radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
