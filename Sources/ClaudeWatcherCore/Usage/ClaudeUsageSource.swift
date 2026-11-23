import CryptoKit
import Foundation

/// Claude Code's plan usage (session ~5 h and weekly windows), fetched with Claude Code's own
/// OAuth token from `api.anthropic.com/api/oauth/usage`.
///
/// Credentials are re-read on every poll (picking up tokens Claude Code refreshed) and never
/// refreshed here. A token the server rejected is remembered only by its SHA-256 and not sent
/// again until it changes or `rejectedTokenRetry` passes. All timing uses the `now` passed to
/// `poll`, so tests drive it without a clock. If that clock goes backwards, a pending wait is
/// re-anchored at `now` so it never exceeds the delay it was set to.
public actor ClaudeUsageSource: UsageSource {
    public nonisolated let agent: AgentKind = .claude

    /// Loads Claude Code's credentials (`now` ranks candidates by expiry). Injected in tests.
    typealias LoadCredentials = @Sendable (_ now: Date) async throws -> ClaudeCredentials

    // MARK: Tuning
    static let baseInterval: TimeInterval = 300
    static let maxBackoff: TimeInterval = 1800
    static let maxRetryAfter: TimeInterval = 3600
    /// First retry after a network failure; doubles up to `baseInterval`.
    static let networkRetryInterval: TimeInterval = 30
    /// Re-check credentials this soon when there's no usable token (no API call is made).
    static let credentialRecheckInterval: TimeInterval = 60
    /// After a cancelled poll.
    static let cancelledRetryInterval: TimeInterval = 30
    /// A rejected token is sent again after this, in case the rejection was transient.
    static let rejectedTokenRetry: TimeInterval = 300

    private let loadCredentials: LoadCredentials
    private let fetch: ClaudeUsageAPI.Fetch
    private let userAgent: String

    // MARK: State
    private var snapshot: UsageSnapshot?
    private var status: UsageStatus = .loading
    private var rateLimit: RateLimit?
    private var consecutiveRateLimits = 0
    private var consecutiveKeychainFailures = 0
    private var consecutiveNetworkFailures = 0
    private var rejectedToken: RejectedToken?

    private struct RejectedToken {
        let hash: SHA256.Digest
        let statusCode: Int
        var retryAt: Date
    }

    /// No request before `until`, which was set `delay` seconds ahead.
    private struct RateLimit {
        var until: Date
        let delay: TimeInterval
    }

    /// Live dependencies: the Keychain / credentials file under the resolved Claude home, and
    /// an ephemeral URLSession.
    public init() {
        let version = AppVersionInfo.main.shortVersion ?? "dev"
        self.init(loadCredentials: { try await ClaudeCredentialStore.loadLive(now: $0) },
                  fetch: ClaudeUsageAPI.defaultFetch,
                  userAgent: "ClaudeWatcher/\(version)")
    }

    init(loadCredentials: @escaping LoadCredentials, fetch: @escaping ClaudeUsageAPI.Fetch, userAgent: String) {
        self.loadCredentials = loadCredentials
        self.fetch = fetch
        self.userAgent = userAgent
    }

    public func poll(now: Date) async -> UsagePollResult {
        if let retryAt = rejectedToken?.retryAt, retryAt.timeIntervalSince(now) > Self.rejectedTokenRetry {
            rejectedToken?.retryAt = now.addingTimeInterval(Self.rejectedTokenRetry)   // the clock went back
        }
        // Inside a 429 backoff (e.g. polled early after wake): don't ask again yet. A wait that
        // has passed is dropped, so a later backwards clock jump can't revive it.
        if let limit = rateLimit {
            if limit.until <= now {
                rateLimit = nil
            } else {
                if limit.until.timeIntervalSince(now) > limit.delay {
                    rateLimit?.until = now.addingTimeInterval(limit.delay)   // the clock went back
                }
                return result(nextPollIn: min(limit.until.timeIntervalSince(now), limit.delay))
            }
        }
        var sentTokenHash: SHA256.Digest?
        do {
            let credentials = try await loadCredentials(now)
            consecutiveKeychainFailures = 0
            guard !credentials.isExpired(now: now) else { throw ClaudeUsageError.tokenExpired }
            let hash = credentials.tokenHash
            if let rejectedToken, rejectedToken.hash == hash, now < rejectedToken.retryAt {
                throw ClaudeUsageError.unauthorized(rejectedToken.statusCode)
            }
            sentTokenHash = hash
            snapshot = try await ClaudeUsageAPI.fetch(
                token: credentials.accessToken, userAgent: userAgent, now: now, fetch: fetch)
            status = .ok
            consecutiveRateLimits = 0
            consecutiveNetworkFailures = 0
            rateLimit = nil
            rejectedToken = nil
            return result(nextPollIn: Self.baseInterval)
        } catch is CancellationError {
            // Not a failure: keep what we were showing (nothing above changed it) and try again soon.
            return result(nextPollIn: Self.cancelledRetryInterval)
        } catch let error as ClaudeUsageError {
            if case .unauthorized(let code) = error, let sentTokenHash {
                rejectedToken = RejectedToken(hash: sentTokenHash, statusCode: code,
                                              retryAt: now.addingTimeInterval(Self.rejectedTokenRetry))
            }
            return handle(error, now: now)
        } catch {
            return handle(.network("request failed"), now: now)
        }
    }

    private func handle(_ error: ClaudeUsageError, now: Date) -> UsagePollResult {
        let delay: TimeInterval
        var message = error.userMessage
        switch error {
        case .rateLimited(let retryAfter):
            consecutiveRateLimits += 1
            let exponential = min(Self.maxBackoff, Self.baseInterval * pow(2, Double(consecutiveRateLimits - 1)))
            delay = max(min(retryAfter ?? 0, Self.maxRetryAfter), exponential)
            rateLimit = RateLimit(until: now.addingTimeInterval(delay), delay: delay)
            message = "Rate limited: retrying in \(Self.formatMinutes(delay))"
        case .keychainUnavailable:
            // Possibly a locked keychain: back off instead of spawning `security` every minute.
            consecutiveKeychainFailures += 1
            delay = min(Self.maxBackoff,
                        Self.credentialRecheckInterval * pow(2, Double(consecutiveKeychainFailures - 1)))
        case .notLoggedIn:
            // Whatever we were showing belongs to an account that's no longer logged in.
            snapshot = nil
            status = .unavailable
            return result(nextPollIn: Self.credentialRecheckInterval)
        case .unreadableCredentials, .tokenExpired, .unauthorized:
            // No usable token: re-check credentials soon to recover quickly. The API is only
            // called again once the token changes (see `rejectedToken`).
            delay = Self.credentialRecheckInterval
        case .network:
            // Often transient (e.g. just after wake): retry sooner.
            consecutiveNetworkFailures += 1
            delay = min(Self.baseInterval,
                        Self.networkRetryInterval * pow(2, Double(consecutiveNetworkFailures - 1)))
        case .http, .decoding:
            delay = Self.baseInterval
        }
        status = snapshot == nil ? .error(message) : .stale(message)
        return result(nextPollIn: delay)
    }

    private func result(nextPollIn: TimeInterval) -> UsagePollResult {
        UsagePollResult(usage: AgentUsage(agent: agent, snapshot: snapshot, status: status),
                        nextPollIn: nextPollIn)
    }

    static func formatMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(1, minutes))m"
    }
}
