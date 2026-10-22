import Foundation

/// Errors from running an AppleScript, normalised from `NSAppleScript` error dictionaries.
public enum AppleScriptError: Error, Equatable, Sendable {
    /// Automation (Apple Events) permission denied (-1743) or would require consent (-1744).
    case notPermitted(app: String)
    /// Apple event timed out (-1712), or the Swift-side watchdog fired.
    case timedOut
    /// Target application isn't running (-600 / -609).
    case appNotRunning
    case compileFailed(String)
    case scriptError(code: Int, message: String)

    /// Phrase every `.notPermitted` message contains; `FocusResult.needsAutomationPermission`
    /// keys off it.
    static let notPermittedMarker = "isn't allowed to control"

    /// User-facing explanation, suitable for `FocusResult.failed(reason:)`.
    public func userMessage(app: String) -> String {
        switch self {
        case .notPermitted:
            return "ClaudeWatcher \(Self.notPermittedMarker) \(app). Grant it in System Settings → "
                + "Privacy & Security → Automation (enable \(app) under ClaudeWatcher)."
        case .timedOut:
            return "\(app) didn't respond in time (it may be busy)."
        case .appNotRunning:
            return "\(app) isn't running."
        case .compileFailed(let msg):
            return "Internal AppleScript compile error: \(msg)"
        case .scriptError(let code, let message):
            return "\(app) AppleScript error \(code): \(message)"
        }
    }

    static func from(errorInfo: NSDictionary?, app: String) -> AppleScriptError {
        let code = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = (errorInfo?[NSAppleScript.errorMessage] as? String)
            ?? (errorInfo?[NSAppleScript.errorBriefMessage] as? String) ?? "unknown error"
        return from(code: code, message: message, app: app)
    }

    static func from(code: Int, message: String, app: String) -> AppleScriptError {
        switch code {
        case -1743, -1744: return .notPermitted(app: app)
        case -1712: return .timedOut
        case -600, -609: return .appNotRunning
        default: return .scriptError(code: code, message: message)
        }
    }
}

/// AppleScript source helpers.
public enum AppleScriptSource {
    /// Returns `value` as an AppleScript string literal (quoted, with `\` and `"` escaped).
    /// Control characters other than tab/newline/return are dropped; those three are written
    /// as escapes so the literal stays on one line.
    public static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}

/// Something that can execute AppleScript source. Abstracted so focusers can be tested with
/// fakes and so the in-process runner can be swapped for `osascript`.
public protocol AppleScriptExecuting: Sendable {
    func run(_ source: String, app: String, timeout: Duration) async -> Result<String, AppleScriptError>
}

/// Runs `NSAppleScript` on the main thread.
///
/// Why main: NSAppleScript isn't thread-safe, and on a secondary thread Apple-event replies
/// from Ghostty for element queries (`id of every terminal`) never arrive: the script hangs
/// forever and even `with timeout` doesn't fire (reproduced with Ghostty 1.3.1; `get version`
/// works off-main, `every terminal` doesn't). On main it takes ~10–40 ms. Hang protection comes
/// from the `with timeout of 3 seconds` clause every generated script uses; a Swift watchdog
/// can't help while the main thread is blocked inside the script.
public final class AppleScriptRunner: AppleScriptExecuting, Sendable {
    public static let shared = AppleScriptRunner()

    public init() {}

    /// Executes `source` on the main actor and returns its result coerced to a string ("" if none).
    /// `timeout` is unused (see type docs); scripts must carry their own `with timeout`.
    public func run(_ source: String, app: String, timeout: Duration = .seconds(5)) async -> Result<String, AppleScriptError> {
        await MainActor.run { Self.execute(source, app: app) }
    }

    @MainActor
    static func execute(_ source: String, app: String) -> Result<String, AppleScriptError> {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(.compileFailed("NSAppleScript init failed"))
        }
        if !script.compileAndReturnError(&errorInfo) {
            let msg = (errorInfo?[NSAppleScript.errorMessage] as? String) ?? "unknown"
            return .failure(.compileFailed(msg))
        }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo { return .failure(AppleScriptError.from(errorInfo: errorInfo, app: app)) }
        return .success(descriptor.stringValue ?? "")
    }
}

/// Runs scripts through `/usr/bin/osascript` (one process per call). Slower than
/// `AppleScriptRunner` but isolates hangs/crashes in a child process. Note Automation
/// permission is then attributed to the responsible process (normally still this app).
public struct OsascriptRunner: AppleScriptExecuting {
    public init() {}

    public func run(_ source: String, app: String, timeout: Duration = .seconds(5)) async -> Result<String, AppleScriptError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let once = OnceBox<Result<String, AppleScriptError>>()
        return await withCheckedContinuation { continuation in
            once.setContinuation(continuation)
            process.terminationHandler = { p in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 {
                    once.resume(.success(stdout.hasSuffix("\n") ? String(stdout.dropLast()) : stdout))
                } else {
                    // osascript prints "...: execution error: <msg> (<code>)"
                    let code = OsascriptRunner.errorCode(in: stderr) ?? 0
                    once.resume(.failure(AppleScriptError.from(code: code, message: stderr, app: app)))
                }
            }
            do {
                try process.run()
            } catch {
                once.resume(.failure(.scriptError(code: 0, message: "\(error)")))
                return
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
                once.resume(.failure(.timedOut))
            }
        }
    }

    /// Extracts the trailing "(-1743)" style error code from osascript's stderr.
    static func errorCode(in stderr: String) -> Int? {
        guard let open = stderr.lastIndex(of: "("), let close = stderr.lastIndex(of: ")"), open < close else {
            return nil
        }
        return Int(stderr[stderr.index(after: open)..<close])
    }
}

/// Resumes a continuation exactly once.
private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var done = false

    func setContinuation(_ c: CheckedContinuation<T, Never>) {
        lock.withLock { continuation = c }
    }

    func resume(_ value: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
