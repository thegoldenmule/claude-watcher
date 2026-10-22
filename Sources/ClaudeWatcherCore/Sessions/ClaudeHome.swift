import Darwin
import Foundation

/// Resolves `$CLAUDE_CONFIG_DIR` the way the user's terminal sees it. An app launched by
/// LaunchServices (Finder, `open`, login item) doesn't inherit the shell's environment, so
/// after our own environment we ask `launchctl getenv`, then a login + interactive shell.
enum ClaudeHome {
    static let variable = "CLAUDE_CONFIG_DIR"
    static let probeTimeout: TimeInterval = 2

    /// Resolved once, lazily (Swift globals/statics initialize exactly once, thread-safely).
    /// Touching it may block for seconds; async code awaits `resolvedAsync()` instead.
    static let resolved: URL = SessionDiscovery.resolveClaudeHome(
        env: ProcessInfo.processInfo.environment,
        launchctlValue: launchctlValue(),
        shellValue: shellValue(),
        home: FileManager.default.homeDirectoryForCurrentUser.path)

    /// Serial queue that resolves `resolved` (prewarm) and hands it to async waiters, so a
    /// waiter never blocks a Swift-concurrency thread inside the one-time initializer.
    static let queue = DispatchQueue(label: "com.thegoldenmule.ClaudeWatcher.ClaudeHome", qos: .userInitiated)

    static func prewarm() {
        queue.async { _ = resolved }
    }

    static func resolvedAsync() async -> URL {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: resolved) }
        }
    }

    static func launchctlValue() -> String? {
        run("/bin/launchctl", ["getenv", variable])?.trimmingCharacters(in: .newlines)
    }

    static let marker = "__CLAUDE_WATCHER_CONFIG_DIR__="

    /// `$SHELL -lic …` printing the variable after a marker. rc files (and a login shell's
    /// logout file) may print anything before or after, so only the text following the last
    /// marker, up to the end of that line, counts.
    static func shellValue() -> String? {
        var shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if !shell.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/zsh" }
        let command = "printf '\\n%s%s\\n' '\(marker)' \"$\(variable)\""
        return run(shell, ["-lic", command], acceptOnTimeout: hasMarkedLine).flatMap(markedValue)
    }

    /// Whether `output` already holds a complete (newline-terminated) marker line, so it can be
    /// used even if the shell (say, a logout file) is still running when the probe times out.
    static func hasMarkedLine(_ output: String) -> Bool {
        guard let range = output.range(of: marker, options: .backwards) else { return false }
        return output[range.upperBound...].contains { $0 == "\n" || $0 == "\r" }
    }

    /// The rest of the line after the last `marker` in `output`, or nil if there is none.
    static func markedValue(_ output: String) -> String? {
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        return String(output[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" })
    }

    /// Runs `path args…` in a new session (no controlling terminal, so an interactive shell
    /// can't grab or stop on the user's tty), stdin and stderr on /dev/null, and returns its
    /// stdout. Reading stops at EOF, or once `path` has exited and the pipe is drained (a job it
    /// backgrounded may hold stdout open indefinitely). The process group is killed if anything
    /// is left running. After `timeout` returns nil, unless `acceptOnTimeout` accepts the output
    /// read so far.
    static func run(
        _ path: String, _ args: [String], timeout: TimeInterval = probeTimeout,
        acceptOnTimeout: (String) -> Bool = { _ in false }
    ) -> String? {
        var pipe: [Int32] = [-1, -1]
        guard Darwin.pipe(&pipe) == 0 else { return nil }
        let (readFD, writeFD) = (pipe[0], pipe[1])
        defer { close(readFD) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // New session (and process group); don't leak our other descriptors into the shell.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        close(writeFD)
        guard spawned == 0 else { return nil }

        var output = Data()
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)

        enum ReadResult { case data, idle, eof, failed }
        /// One poll (up to `waitMs`) and, if readable, one read into `output`.
        func readAvailable(waitMs: Int32) -> ReadResult {
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0 { return errno == EINTR ? .idle : .failed }
            if ready == 0 { return .idle }
            let n = read(readFD, &buffer, buffer.count)
            if n < 0 { return errno == EINTR || errno == EAGAIN ? .idle : .failed }
            if n == 0 { return .eof }  // every writer (the shell and its jobs) is done
            output.append(contentsOf: buffer[0..<n])
            return output.count > 1 << 20 ? .failed : .data  // runaway rc output
        }
        func reap() -> Bool {
            let r = waitpid(pid, &status, WNOHANG)
            return r == pid || (r < 0 && errno != EINTR)
        }

        var last = ReadResult.idle
        var exited = false, timedOut = false
        while true {
            if reap() {
                // The shell is gone, but a job it backgrounded may keep stdout open: take what
                // is already in the pipe and stop rather than wait for EOF.
                exited = true
                let drainUntil = Date().addingTimeInterval(0.05)
                repeat { last = readAvailable(waitMs: 0) } while last == .data && Date() < drainUntil
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            // Short waits, so the shell's exit is noticed promptly while a job holds stdout.
            last = readAvailable(waitMs: Int32(min(remaining * 1000, 20).rounded(.up)))
            if last == .eof || last == .failed { break }
        }
        let eof = last == .eof, failed = last == .failed
        // EOF: give the shell until the deadline to exit (e.g. running a logout file).
        while eof, !exited {
            if reap() { exited = true; break }
            if deadline.timeIntervalSinceNow <= 0 { timedOut = true; break }
            usleep(5_000)
        }
        if !exited {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        } else if !eof {
            // Background jobs still hold stdout; don't leave them running.
            kill(-pid, SIGKILL)
        }
        guard !failed else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        if timedOut, !acceptOnTimeout(text) { return nil }
        return text
    }
}
