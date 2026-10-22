import AppKit
import os

// MARK: - Resolver strategies

/// A strategy for mapping a session to a Ghostty terminal id. `GhosttyFocuser` runs its
/// resolvers in order and focuses the first `.unique` id that is live (not missing / zombie).
public protocol GhosttyTerminalResolver: Sendable {
    /// Short name for diagnostics ("tty-property", "osc7-probe", …).
    var name: String { get }
    /// Whether a successful focus from this resolver should be cached under the session pid.
    var cachesResult: Bool { get }
    func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution
}

extension GhosttyTerminalResolver {
    public var cachesResult: Bool { false }
}

/// 1. Ghostty's own `tty` terminal property (Ghostty > 1.3.1). Feature-detected once per
///    Ghostty process; on 1.3.1 the lookup errors and the resolver turns itself off.
public struct TTYPropertyResolver: GhosttyTerminalResolver {
    public let name = "tty-property"
    let support: GhosttyFeatureCache

    public init(support: GhosttyFeatureCache = GhosttyFeatureCache()) {
        self.support = support
    }

    public func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        guard let tty = session.tty, !tty.isEmpty,
              let ghosttyPID = AppActivation.runningApp(bundleID: AppActivation.ghosttyBundleID)?.processIdentifier,
              await support.ttyProperty(ghosttyPID: ghosttyPID) != false
        else { return .notFound }
        let ids = try await ghostty.terminalIDs(forTTY: AppleTerminalFocuser.normalizeTTY(tty))
        await support.setTTYProperty(ids != nil, ghosttyPID: ghosttyPID)
        guard let ids, ids.count == 1 else { return .notFound }
        return .unique(terminalID: ids[0])
    }
}

/// 2. `session.ghosttyTerminalID`, recorded by the hook when known.
public struct KnownTerminalIDResolver: GhosttyTerminalResolver {
    public let name = "hook-id"
    public init() {}
    public func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        guard let id = session.ghosttyTerminalID, !id.isEmpty else { return .notFound }
        return .unique(terminalID: id)
    }
}

/// 3. In-memory pid → terminal id cache, filled by resolvers with `cachesResult`. The focus
///    script validates existence; misses and zombies are evicted by `GhosttyFocuser`.
public struct CachedTerminalResolver: GhosttyTerminalResolver {
    public let name = "cache"
    let cache: GhosttyTerminalCache
    public init(cache: GhosttyTerminalCache) { self.cache = cache }
    public func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        guard let id = await cache.terminalID(pid: session.pid, tty: session.tty) else { return .notFound }
        return .unique(terminalID: id)
    }
}

/// 4. OSC 7 nonce probe on the session's tty (see `OSC7Probe`). Skipped without a tty or
///    inside tmux. Results are cached.
public struct OSC7ProbeResolver: GhosttyTerminalResolver {
    public let name = "osc7-probe"
    public var cachesResult: Bool { true }
    let coordinator: OSC7ProbeCoordinator

    public init(coordinator: OSC7ProbeCoordinator = OSC7ProbeCoordinator()) {
        self.coordinator = coordinator
    }

    public func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        guard let raw = session.tty, !raw.isEmpty, !ProcessTree.isInsideTmux(session.pid) else { return .notFound }
        let tty = AppleTerminalFocuser.normalizeTTY(raw)
        guard let id = try await coordinator.probe(tty: tty, pid: session.pid, restoreCwd: session.cwd, ghostty: ghostty)
        else { return .notFound }
        return .unique(terminalID: id)
    }
}

/// 5. Title + cwd heuristic over a single listing call (`GhosttyMatcher.match`).
public struct TitleCwdResolver: GhosttyTerminalResolver {
    public let name = "title-cwd"
    public init() {}
    public func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        GhosttyMatcher.match(session: session, in: try await ghostty.listTerminals())
    }
}

// MARK: - Shared state

/// pid → (tty, terminal id). Entries for dead pids are pruned on insert.
public actor GhosttyTerminalCache {
    private var entries: [Int32: (tty: String?, id: String)] = [:]

    public init() {}

    public func terminalID(pid: Int32, tty: String?) -> String? {
        guard let e = entries[pid] else { return nil }
        guard e.tty == tty else { entries[pid] = nil; return nil }
        return e.id
    }

    public func store(pid: Int32, tty: String?, id: String) {
        entries = entries.filter { kill($0.key, 0) == 0 || errno == EPERM }
        entries[pid] = (tty, id)
    }

    public func evict(pid: Int32, id: String) {
        if entries[pid]?.id == id { entries[pid] = nil }
    }
}

/// Remembers per Ghostty process whether optional dictionary features exist.
public actor GhosttyFeatureCache {
    private var ttyPropertyByPID: [Int32: Bool] = [:]
    public init() {}
    /// nil = not yet detected.
    public func ttyProperty(ghosttyPID: Int32) -> Bool? { ttyPropertyByPID[ghosttyPID] }
    public func setTTYProperty(_ supported: Bool, ghosttyPID: Int32) { ttyPropertyByPID[ghosttyPID] = supported }
}

// MARK: - Focuser

/// What to do when no resolver is certain but the title/cwd heuristic produced candidates.
public enum GhosttyAmbiguityPolicy: Sendable {
    /// Only activate Ghostty and report `.appActivatedOnly(reason:)`. Default.
    case activateAppOnly
    /// Focus the first (best-ranked) candidate, still reporting `.appActivatedOnly(reason:)`
    /// so the UI can say it was a guess.
    case focusFirstCandidate
}

/// Diagnostics from one focus attempt.
public struct GhosttyFocusReport: Sendable, Equatable {
    public var result: FocusResult
    /// Name of the resolver whose terminal was focused, if any.
    public var resolver: String?
    public var terminalID: String?
}

/// Focuses the Ghostty terminal hosting a session. Ghostty's `focus` command raises the window
/// and switches Spaces (verified, Ghostty 1.3.1). Never launches Ghostty.
///
/// Default resolution chain: tty property → hook id → pid cache → OSC 7 probe → unique
/// title+cwd → activate Ghostty (`.appActivatedOnly`). A resolver's id that turns out missing
/// or a zombie ("Terminal is not in a window.", -10000) falls through to the next resolver.
///
/// Keep one instance alive (the cache and probe lock live in it).
///
/// Results: `.focused` (exact terminal), `.appActivatedOnly` (ambiguous / not found; Ghostty
/// raised), `.failed` (Ghostty not running, Automation denied, timeout, script error).
public struct GhosttyFocuser: SessionFocuser {
    public var resolvers: [any GhosttyTerminalResolver]
    public var ambiguityPolicy: GhosttyAmbiguityPolicy
    public var ghostty: GhosttyScripting
    public let cache: GhosttyTerminalCache

    public init(
        resolvers: [any GhosttyTerminalResolver]? = nil,
        ambiguityPolicy: GhosttyAmbiguityPolicy = .activateAppOnly,
        ghostty: GhosttyScripting = GhosttyScripting(),
        cache: GhosttyTerminalCache = GhosttyTerminalCache()
    ) {
        self.cache = cache
        self.resolvers = resolvers ?? [
            TTYPropertyResolver(),
            KnownTerminalIDResolver(),
            CachedTerminalResolver(cache: cache),
            OSC7ProbeResolver(),
            TitleCwdResolver(),
        ]
        self.ambiguityPolicy = ambiguityPolicy
        self.ghostty = ghostty
    }

    static let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Focus")

    public func focus(_ session: ClaudeSession) async -> FocusResult {
        let report = await focusWithReport(session)
        Self.logger.notice("""
            ghostty focus pid=\(session.pid) hookID=\(session.ghosttyTerminalID ?? "-", privacy: .public) \
            resolver=\(report.resolver ?? "-", privacy: .public) terminal=\(report.terminalID ?? "-", privacy: .public) \
            result=\(String(describing: report.result), privacy: .public)
            """)
        return report.result
    }

    public func focusWithReport(_ session: ClaudeSession) async -> GhosttyFocusReport {
        guard let app = AppActivation.runningApp(bundleID: AppActivation.ghosttyBundleID) else {
            return GhosttyFocusReport(result: .failed(reason: "Ghostty isn't running."))
        }
        await AppActivation.yieldActivation(to: app)
        do throws(AppleScriptError) {
            var firstAmbiguous: (candidates: [String], reason: String)?
            for resolver in resolvers {
                switch try await resolver.resolve(session, ghostty: ghostty) {
                case .unique(let id):
                    switch try await ghostty.focus(terminalID: id) {
                    case .focused:
                        if resolver.cachesResult { await cache.store(pid: session.pid, tty: session.tty, id: id) }
                        return GhosttyFocusReport(result: .focused, resolver: resolver.name, terminalID: id)
                    case .notFound, .stale:
                        await cache.evict(pid: session.pid, id: id)  // fall through
                    }
                case .ambiguous(let candidates, let reason):
                    if firstAmbiguous == nil, !candidates.isEmpty { firstAmbiguous = (candidates, reason) }
                case .notFound:
                    break
                }
            }
            if let (candidates, reason) = firstAmbiguous, ambiguityPolicy == .focusFirstCandidate,
               try await ghostty.focus(terminalID: candidates[0]) == .focused {
                return GhosttyFocusReport(result: .appActivatedOnly(reason: "\(reason); focused the first match."),
                                          resolver: "ambiguous-first", terminalID: candidates[0])
            }
            await AppActivation.activate(app)
            let reason = firstAmbiguous?.reason ?? "Couldn't find this session's Ghostty terminal."
            return GhosttyFocusReport(result: .appActivatedOnly(reason: reason))
        } catch {
            return GhosttyFocusReport(result: .failed(reason: error.userMessage(app: GhosttyScripting.app)))
        }
    }
}

extension GhosttyFocusReport {
    init(result: FocusResult) { self.init(result: result, resolver: nil, terminalID: nil) }
}
