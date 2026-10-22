import Darwin
import Foundation

/// Resolves `$CLAUDE_CONFIG_DIR` the way the user's terminal sees it. An app launched by
/// LaunchServices (Finder, `open`, login item) doesn't inherit the shell's environment, so
/// after our own environment we ask `launchctl getenv`, then a login + interactive shell.
enum ClaudeHome {
    static let variable = "CLAUDE_CONFIG_DIR"
    static let probeTimeout: TimeInterval = 2

    /// Resolved once, lazily (Swift globals/statics initialize exactly once, thread-safely).
    static let resolved: URL = SessionDiscovery.resolveClaudeHome(
        env: ProcessInfo.processInfo.environment,
        launchctlValue: launchctlValue(),
        shellValue: shellValue(),
        home: FileManager.default.homeDirectoryForCurrentUser.path,
        fileExists: { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        })

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
        return run(shell, ["-lic", command]).flatMap(markedValue)
    }

    /// The rest of the line after the last `marker` in `output`, or nil if there is none.
    static func markedValue(_ output: String) -> String? {
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        return String(output[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" })
    }

    /// Runs `path args…` in a new session (no controlling terminal, so an interactive shell
    /// can't grab or stop on the user's tty), stdin and stderr on /dev/null, and returns its
    /// stdout. Kills the whole process group and returns nil after `timeout`.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = probeTimeout) -> String? {
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
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { timedOut = true; break }
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
            if ready < 0 { if errno == EINTR { continue }; timedOut = true; break }
            if ready == 0 { continue }
            let n = read(readFD, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }  // EOF: every writer (the shell and anything it forked) is done
            output.append(contentsOf: buffer[0..<n])
            if output.count > 1 << 20 { timedOut = true; break }  // runaway rc output
        }
        // Stdout closed; give the shell until the deadline to exit (e.g. running a logout file).
        var status: Int32 = 0
        var reaped = false
        while !timedOut {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r < 0 && errno != EINTR) { reaped = true; break }
            if deadline.timeIntervalSinceNow <= 0 { break }
            usleep(5_000)
        }
        if !reaped {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        }
        guard !timedOut else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}
