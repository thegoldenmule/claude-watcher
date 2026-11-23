import Foundation

/// Codex's plan usage, read locally from the rollouts' `token_count` events (no network): Codex
/// records its rate limits there after every model response (`CodexUsageReader`).
///
/// Status: no Codex home, no state DB, or no reading in the recent rollouts → `.unavailable`.
/// With a reading: `.stale` (keeping the newest one had) if the DB or a rollout that may hold a
/// newer reading couldn't be read, even if this pass found a newer one elsewhere (so the meter
/// doesn't flip between ok and stale while one active rollout stays unreadable); else `.ok`. The reading
/// may be days old (`asOf` is the event's time); `UsageWindow.displayPercent` shows 0 once a
/// window's `resetsAt` has passed. A newer reading always wins, so a resumed old thread rising
/// to the top of the DB can't roll the snapshot back.
public actor CodexUsageSource: UsageSource {
    public nonisolated let agent: AgentKind = .codex

    /// Poll interval with a reading (the pass is stat-keyed, so cheap)...
    static let pollInterval: TimeInterval = 30
    /// ...and while Codex shows no sign of use.
    static let unavailableInterval: TimeInterval = 300

    private let resolveHome: @Sendable () async -> URL
    private let chunkSize: Int
    private let maxScan: Int
    private var reader: CodexUsageReader?
    /// Blocking sqlite/file work runs here, off the cooperative pool; `reader` is only used on it.
    private let queue = DispatchQueue(label: "com.thegoldenmule.ClaudeWatcher.CodexUsage", qos: .utility)
    private var last: CodexRateLimitReading?

    /// Live: the Codex home is `$CODEX_HOME` (resolved like the Claude home, see `CodexPaths`).
    public init() {
        self.init(resolveHome: { await CodexPaths.resolvedHome() })
    }

    init(codexHome: URL, chunkSize: Int = 64 * 1024, maxScan: Int = 8 * 1024 * 1024) {
        self.init(resolveHome: { codexHome }, chunkSize: chunkSize, maxScan: maxScan)
    }

    init(resolveHome: @escaping @Sendable () async -> URL, chunkSize: Int = 64 * 1024, maxScan: Int = 8 * 1024 * 1024) {
        self.resolveHome = resolveHome
        self.chunkSize = chunkSize
        self.maxScan = maxScan
    }

    /// Rollout files opened so far (tests).
    var fileReads: Int {
        get async {
            guard let reader else { return 0 }
            return await onQueue { reader.fileReads }
        }
    }

    public func poll(now: Date) async -> UsagePollResult {
        let reader: CodexUsageReader
        if let existing = self.reader {
            reader = existing
        } else {
            let home = await resolveHome()
            reader = self.reader ?? CodexUsageReader(codexHome: home, chunkSize: chunkSize, maxScan: maxScan)
            self.reader = reader
        }
        let outcome = await onQueue { reader.scan() }
        switch outcome {
        case .unavailable:
            last = nil
            return result(.unavailable, Self.unavailableInterval)
        case .failed(let message):
            return last == nil
                ? result(.unavailable, Self.pollInterval)
                : result(.stale(Self.message(message)), Self.pollInterval)
        case .scanned(let reading, let errors):
            if let reading, last.map({ reading.timestamp >= $0.timestamp }) ?? true {
                last = reading
            }
            guard last != nil else {
                return result(.unavailable, errors.isEmpty ? Self.unavailableInterval : Self.pollInterval)
            }
            // An unreadable rollout may hold a newer reading (the reader only reports those).
            if let first = errors.first {
                return result(.stale(Self.message(first)), Self.pollInterval)
            }
            return result(.ok, Self.pollInterval)
        }
    }

    private func result(_ status: UsageStatus, _ next: TimeInterval) -> UsagePollResult {
        let snapshot = status == .unavailable ? nil : last?.snapshot
        return UsagePollResult(usage: AgentUsage(agent: .codex, snapshot: snapshot, status: status), nextPollIn: next)
    }

    static func message(_ detail: String) -> String { "Can't read Codex usage (\(detail))" }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
