import Foundation

/// Result of asking Ghostty to focus a terminal id.
public enum GhosttyFocusOutcome: Sendable, Equatable {
    case focused
    /// No terminal with that id.
    case notFound
    /// The id exists but is a "zombie" (closed window's terminal lingering in `every terminal`):
    /// `focus` fails with "Terminal is not in a window." (-10000).
    case stale
}

/// Talks to Ghostty's AppleScript dictionary (Ghostty ≥ 1.3: windows → tabs → terminals).
/// All scripts target the bundle id and are only run after checking Ghostty is running, so
/// they never launch it.
public struct GhosttyScripting: Sendable {
    public let runner: any AppleScriptExecuting
    static let app = "Ghostty"
    static let tell = "tell application id \"\(AppActivation.ghosttyBundleID)\""

    public init(runner: any AppleScriptExecuting = AppleScriptRunner.shared) {
        self.runner = runner
    }

    // MARK: Scripts (pure)

    /// Returns every terminal as `id US name US wd RS …` via bulk property fetches
    /// (3 Apple events regardless of terminal count).
    public static let listScript = """
        with timeout of 3 seconds
          \(tell)
            set {ids, nms, wds} to {id, name, working directory} of every terminal
          end tell
        end timeout
        if (count of ids) is not (count of nms) or (count of ids) is not (count of wds) then error "terminal list changed while reading" number -1700
        set US to character id 31
        set RS to character id 30
        set out to ""
        repeat with i from 1 to count of ids
          set n to ""
          set d to ""
          try
            set n to (item i of nms) as text
          end try
          try
            set d to (item i of wds) as text
          end try
          set out to out & ((item i of ids) as text) & US & n & US & d & RS
        end repeat
        return out
        """

    /// Focuses `terminal id <id>`; returns "ok", "notfound" or "stale" (-10000, zombie terminal).
    public static func focusScript(terminalID: String) -> String {
        let ref = "terminal id \(AppleScriptSource.quoted(terminalID))"
        return """
            with timeout of 3 seconds
              \(tell)
                if not (exists \(ref)) then return "notfound"
                try
                  focus \(ref)
                on error errMsg number errNum
                  if errNum is -10000 then return "stale"
                  error errMsg number errNum
                end try
              end tell
            end timeout
            return "ok"
            """
    }

    /// Ghostty > 1.3.1 adds a `tty` terminal property. On 1.3.1 `tty` isn't a dictionary term,
    /// so this compiles as a variable reference and fails at runtime (-2753): "unsupported".
    /// Returns ids joined by RS.
    public static func ttyLookupScript(tty: String) -> String {
        """
        with timeout of 3 seconds
          \(tell)
            set ids to id of every terminal whose tty is \(AppleScriptSource.quoted(tty))
          end tell
        end timeout
        set RS to character id 30
        set out to ""
        repeat with i in ids
          set out to out & (i as text) & RS
        end repeat
        return out
        """
    }

    /// One non-delaying lookup of terminals whose working directory contains `nonce` (set via
    /// OSC 7). Returns `id US US wd RS …` (the listing format, empty name), "" if none.
    /// Polling happens in Swift between separate runs, so the main thread (where
    /// `AppleScriptRunner` executes) is free between polls. (A bulk `{id, working directory} of
    /// every terminal whose …` doesn't evaluate in Ghostty 1.3.1, so the matches, normally 0–1,
    /// are read one by one.)
    public static func nonceLookupScript(nonce: String) -> String {
        """
        set US to character id 31
        set RS to character id 30
        set out to ""
        with timeout of 3 seconds
          \(tell)
            repeat with t in (every terminal whose working directory contains \(AppleScriptSource.quoted(nonce)))
              set d to ""
              try
                set d to (working directory of t) as text
              end try
              set out to out & ((id of t) as text) & US & US & d & RS
            end repeat
          end tell
        end timeout
        return out
        """
    }

    /// Ids from `nonceLookupScript` output whose working directory's last path component is
    /// exactly `nonce`. The `/` before it and end-of-path after it delimit the nonce, so a
    /// longer nonce that merely contains this one (substring/prefix collision) never matches.
    public static func nonceMatches(_ output: String, nonce: String) -> [String] {
        guard !nonce.isEmpty else { return [] }
        return GhosttyMatcher.parseListing(output).filter {
            let wd = GhosttyMatcher.normalizePath($0.workingDirectory)
            return wd.hasPrefix("/") && (wd as NSString).lastPathComponent == nonce
        }.map(\.id)
    }

    /// Splits RS-joined id output.
    public static func parseIDs(_ output: String) -> [String] {
        output.split(separator: GhosttyMatcher.recordSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Calls

    public func listTerminals() async throws(AppleScriptError) -> [GhosttyTerminalInfo] {
        var lastError = AppleScriptError.timedOut
        for _ in 0..<2 {  // one retry if the list changed mid-read
            switch await runner.run(Self.listScript, app: Self.app, timeout: .seconds(5)) {
            case .success(let out): return GhosttyMatcher.parseListing(out)
            case .failure(.scriptError(-1700, let msg)): lastError = .scriptError(code: -1700, message: msg)
            case .failure(let e): throw e
            }
        }
        throw lastError
    }

    public func focus(terminalID: String) async throws(AppleScriptError) -> GhosttyFocusOutcome {
        switch await runner.run(Self.focusScript(terminalID: terminalID), app: Self.app, timeout: .seconds(5)) {
        case .success("ok"): return .focused
        case .success("stale"): return .stale
        case .success: return .notFound
        case .failure(let e): throw e
        }
    }

    /// `nil` when this Ghostty has no `tty` property (any non-permission, non-timeout error).
    public func terminalIDs(forTTY tty: String) async throws(AppleScriptError) -> [String]? {
        switch await runner.run(Self.ttyLookupScript(tty: tty), app: Self.app, timeout: .seconds(5)) {
        case .success(let out): return Self.parseIDs(out)
        case .failure(let e):
            switch e {
            case .notPermitted, .timedOut, .appNotRunning: throw e
            case .compileFailed, .scriptError: return nil
            }
        }
    }

    /// Polls up to `attempts` times, `interval` apart, for terminals whose working directory is
    /// the OSC 7 nonce path. Each poll is a separate, short script; the wait happens here in
    /// Swift so the main thread isn't blocked by an AppleScript `delay`. Stops at the first
    /// non-empty result (callers treat anything but exactly one id as no match). Returns [] if
    /// cancelled while waiting.
    public func terminalIDs(withNonceWorkingDirectory nonce: String, attempts: Int = 6,
                            interval: Duration = .milliseconds(30)) async throws(AppleScriptError) -> [String]
    {
        let script = Self.nonceLookupScript(nonce: nonce)
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 {
                do { try await Task.sleep(for: interval) } catch { return [] }
            }
            switch await runner.run(script, app: Self.app, timeout: .seconds(5)) {
            case .success(let out):
                let ids = Self.nonceMatches(out, nonce: nonce)
                if !ids.isEmpty { return ids }
            case .failure(let e): throw e
            }
        }
        return []
    }
}
