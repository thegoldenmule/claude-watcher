import AppKit

/// Talks to Ghostty's AppleScript dictionary (Ghostty ≥ 1.3: windows → tabs → terminals).
public struct GhosttyScripting: Sendable {
    public let runner: any AppleScriptExecuting
    static let app = "Ghostty"

    public init(runner: any AppleScriptExecuting = AppleScriptRunner.shared) {
        self.runner = runner
    }

    /// AppleScript that returns every terminal as `id US name US wd RS …` in one round of
    /// bulk property fetches (3 Apple events regardless of terminal count).
    public static let listScript = """
        with timeout of 3 seconds
          tell application id "\(AppActivation.ghosttyBundleID)"
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

    /// AppleScript that focuses `terminal id <id>`, returning "ok" or "notfound".
    public static func focusScript(terminalID: String) -> String {
        let ref = "terminal id \(AppleScriptSource.quoted(terminalID))"
        return """
            with timeout of 3 seconds
              tell application id "\(AppActivation.ghosttyBundleID)"
                if not (exists \(ref)) then return "notfound"
                focus \(ref)
              end tell
            end timeout
            return "ok"
            """
    }

    public func listTerminals() async throws(AppleScriptError) -> [GhosttyTerminalInfo] {
        var lastError = AppleScriptError.timedOut
        for _ in 0..<2 {  // one retry if the list changed mid-read
            switch await runner.run(Self.listScript, app: Self.app, timeout: .seconds(5)) {
            case .success(let out): return GhosttyMatcher.parseListing(out)
            case .failure(.scriptError(-1700, _)): lastError = .scriptError(code: -1700, message: "list changed")
            case .failure(let e): throw e
            }
        }
        throw lastError
    }

    /// Returns true if focused, false if no such terminal.
    public func focus(terminalID: String) async throws(AppleScriptError) -> Bool {
        switch await runner.run(Self.focusScript(terminalID: terminalID), app: Self.app, timeout: .seconds(5)) {
        case .success(let out): return out == "ok"
        case .failure(let e): throw e
        }
    }
}

/// A strategy for mapping a session to a Ghostty terminal. Strategies run in order; the first
/// `.unique` that still exists wins. Plug new ones (e.g. tty-based) into `GhosttyFocuser`.
public protocol GhosttyTerminalResolver: Sendable {
    func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution
}

/// Uses `session.ghosttyTerminalID` (recorded by the hook) when present.
public struct KnownTerminalIDResolver: GhosttyTerminalResolver {
    public init() {}
    public func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        guard let id = session.ghosttyTerminalID, !id.isEmpty else { return .notFound }
        return .unique(terminalID: id)
    }
}

/// Lists all terminals in one script call and applies `GhosttyMatcher.match` (title + cwd).
public struct TitleCwdResolver: GhosttyTerminalResolver {
    public init() {}
    public func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        GhosttyMatcher.match(session: session, in: try await ghostty.listTerminals())
    }
}

/// What to do when the resolvers only produce ambiguous candidates.
public enum GhosttyAmbiguityPolicy: Sendable {
    /// Focus the first (best-ranked) candidate, but report `.appActivatedOnly(reason:)` so the
    /// UI can tell the user it was a guess. Default: landing on a likely tab in the right
    /// window/Space beats just raising Ghostty.
    case focusFirstCandidate
    /// Only activate Ghostty and report `.appActivatedOnly(reason:)`.
    case activateAppOnly
}

/// Focuses the Ghostty terminal hosting a session. Ghostty's `focus` command raises the window
/// and switches Spaces (verified with Ghostty 1.3.1). Never launches Ghostty.
///
/// Results:
/// - `.focused`: a resolver produced a unique terminal and it was focused.
/// - `.appActivatedOnly`: ambiguous match (see `ambiguityPolicy`) or no match; Ghostty raised.
/// - `.failed`: Ghostty not running, Automation permission denied, timeout, script error.
public struct GhosttyFocuser: SessionFocuser {
    public var resolvers: [any GhosttyTerminalResolver]
    public var ambiguityPolicy: GhosttyAmbiguityPolicy
    public var ghostty: GhosttyScripting

    public init(
        resolvers: [any GhosttyTerminalResolver] = [KnownTerminalIDResolver(), TitleCwdResolver()],
        ambiguityPolicy: GhosttyAmbiguityPolicy = .focusFirstCandidate,
        ghostty: GhosttyScripting = GhosttyScripting()
    ) {
        self.resolvers = resolvers
        self.ambiguityPolicy = ambiguityPolicy
        self.ghostty = ghostty
    }

    public func focus(_ session: ClaudeSession) async -> FocusResult {
        guard let app = AppActivation.runningApp(bundleID: AppActivation.ghosttyBundleID) else {
            return .failed(reason: "Ghostty isn't running.")
        }
        await AppActivation.yieldActivation(to: app)
        do throws(AppleScriptError) {
            var firstAmbiguous: (candidates: [String], reason: String)?
            for resolver in resolvers {
                switch try await resolver.resolve(session, ghostty: ghostty) {
                case .unique(let id):
                    if try await ghostty.focus(terminalID: id) { return .focused }
                    // Stale id (terminal closed): fall through to the next strategy.
                case .ambiguous(let candidates, let reason):
                    if firstAmbiguous == nil, !candidates.isEmpty { firstAmbiguous = (candidates, reason) }
                case .notFound:
                    break
                }
            }
            if let (candidates, reason) = firstAmbiguous {
                if ambiguityPolicy == .focusFirstCandidate, try await ghostty.focus(terminalID: candidates[0]) {
                    return .appActivatedOnly(reason: "\(reason); focused the first match.")
                }
                await AppActivation.activate(app)
                return .appActivatedOnly(reason: reason)
            }
            await AppActivation.activate(app)
            return .appActivatedOnly(reason: "Couldn't find this session's Ghostty terminal.")
        } catch {
            return .failed(reason: error.userMessage(app: GhosttyScripting.app))
        }
    }
}
