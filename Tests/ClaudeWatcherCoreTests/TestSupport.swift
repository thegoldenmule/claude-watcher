import Foundation

// Swift Testing runs every test function (synchronous ones too) on the shared cooperative
// thread pool, in parallel. A test that blocks one of those threads (`waitUntilExit`,
// `Thread.sleep`, a blocking pipe read) starves every other test in the run: `Task.sleep`
// resumptions elsewhere have been seen arriving ~1 s late. These helpers keep blocking work
// off the pool.

/// What a subprocess run by `runProcess` produced.
struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

/// Runs `executable` to completion without blocking a cooperative thread: the exit is observed
/// through `terminationHandler`, stdin is written and stdout/stderr are read to EOF on dedicated
/// threads (both pipes drained concurrently, so a chatty child can't deadlock on a full pipe).
/// Returns once the process has exited and both pipes reached EOF.
func runProcess(_ executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
                currentDirectory: URL? = nil, stdin: Data? = nil) async throws -> ProcessResult {
    let p = Process()
    p.executableURL = executable
    p.arguments = arguments
    if let environment { p.environment = environment }
    if let currentDirectory { p.currentDirectoryURL = currentDirectory }
    let inPipe = stdin.map { _ in Pipe() }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardInput = inPipe ?? FileHandle.nullDevice
    p.standardOutput = outPipe
    p.standardError = errPipe
    let collector = ProcessResultCollector()
    p.terminationHandler = { collector.set(status: $0.terminationStatus) }
    return try await withCheckedThrowingContinuation { continuation in
        collector.continuation = continuation
        do {
            try p.run()
        } catch {
            collector.fail(error)
            return
        }
        Thread.detachNewThread { collector.set(stdout: outPipe.fileHandleForReading.readDataToEndOfFile()) }
        Thread.detachNewThread { collector.set(stderr: errPipe.fileHandleForReading.readDataToEndOfFile()) }
        if let stdin, let inPipe {
            Thread.detachNewThread {
                let writer = inPipe.fileHandleForWriting
                // A child that exits without reading must not SIGPIPE the test runner.
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
    }
}

/// Joins a process's exit status and both pipe contents, resuming the continuation once all three
/// have arrived (in any order).
private final class ProcessResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<ProcessResult, Error>?
    private var status: Int32?
    private var stdout: Data?
    private var stderr: Data?

    func set(status: Int32) { update { $0.status = status } }
    func set(stdout: Data) { update { $0.stdout = stdout } }
    func set(stderr: Data) { update { $0.stderr = stderr } }

    func fail(_ error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }

    private func update(_ body: (ProcessResultCollector) -> Void) {
        lock.lock()
        body(self)
        var ready: (CheckedContinuation<ProcessResult, Error>, ProcessResult)?
        if let continuation, let status, let stdout, let stderr {
            ready = (continuation, ProcessResult(status: status, stdout: stdout, stderr: stderr))
            self.continuation = nil
        }
        lock.unlock()
        if let (c, result) = ready { c.resume(returning: result) }
    }
}

/// Runs genuinely blocking work (tight `Thread.sleep` timing, blocking fd loops) on a dedicated
/// thread instead of the cooperative pool, and returns its result. Don't use `#expect` inside
/// `body`: it runs outside the test's task; return what to check instead.
func onDedicatedThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// A throwaway Claude home (`sessions/`, `projects/`) in the temp directory, removed on deinit.
final class TempHome {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cw-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relative: String, _ text: String) throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func append(_ relative: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url.appendingPathComponent(relative))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}
