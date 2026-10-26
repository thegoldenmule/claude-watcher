import Foundation

/// What the last successful update check learned, persisted between launches (the app stores
/// it as JSON in UserDefaults) so the menu has a state right away, and so the next request can
/// be conditional (`If-None-Match`: an unchanged release costs GitHub a body-less 304).
public struct UpdateCache: Sendable, Equatable, Codable {
    /// GitHub's ETag for `latest` (sent back verbatim; GitHub's are weak, `W/"…"`).
    public var etag: String?
    /// The latest published release; nil if none was published (or never checked).
    public var latest: ReleaseInfo?
    /// When GitHub last answered successfully (200, 304, or 404 "no release yet").
    public var checkedAt: Date?

    public init(etag: String? = nil, latest: ReleaseInfo? = nil, checkedAt: Date? = nil) {
        self.etag = etag
        self.latest = latest
        self.checkedAt = checkedAt
    }
}

/// A failed check: why, and (when GitHub's rate limit was hit) not to retry before when.
public struct UpdateCheckFailure: Error, Sendable, Equatable {
    public var reason: String
    public var at: Date
    public var retryNotBefore: Date?

    public init(reason: String, at: Date, retryNotBefore: Date? = nil) {
        self.reason = reason
        self.at = at
        self.retryNotBefore = retryNotBefore
    }
}

/// Asks GitHub for the latest ClaudeWatcher release. Unauthenticated (no `gh`, no token):
/// the public REST endpoint allows 60 requests an hour per IP, far above our cadence. Only
/// reads; never downloads or installs anything.
public enum UpdateChecker {
    public static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/thegoldenmule/claude-watcher/releases/latest")!

    /// Performs one HTTP request. Injected in tests.
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// No URLCache, so a 304 reaches us instead of being turned into a cached 200.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public static let defaultFetch: Fetch = { request in try await session.data(for: request) }

    /// The request for `latest`, conditional only when there's a cached release to fall back on.
    public static func request(cache: UpdateCache, userAgent: String) -> URLRequest {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = cache.etag, cache.latest != nil {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    /// One check. Returns the updated cache on success, or the failure (the cache is then
    /// returned unchanged, so a known release survives a failed check).
    public static func check(
        cache: UpdateCache, userAgent: String = "ClaudeWatcher", now: @Sendable () -> Date = Date.init,
        fetch: Fetch = defaultFetch
    ) async -> Result<UpdateCache, UpdateCheckFailure> {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await fetch(request(cache: cache, userAgent: userAgent))
        } catch {
            return .failure(UpdateCheckFailure(reason: describe(error), at: now()))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(UpdateCheckFailure(reason: "unexpected response", at: now()))
        }
        let checkedAt = now()
        switch http.statusCode {
        case 200:
            do {
                let release = try ReleaseInfo.decodeGitHubRelease(data)
                return .success(UpdateCache(
                    etag: http.value(forHTTPHeaderField: "ETag"), latest: release, checkedAt: checkedAt))
            } catch {
                return .failure(UpdateCheckFailure(reason: error.description, at: checkedAt))
            }
        case 304 where cache.latest != nil:
            var updated = cache
            updated.checkedAt = checkedAt
            return .success(updated)
        case 404:
            // No (non-draft, non-prerelease) release published yet.
            return .success(UpdateCache(etag: nil, latest: nil, checkedAt: checkedAt))
        case 429, 403 where http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            return .failure(UpdateCheckFailure(
                reason: "GitHub rate limit reached", at: checkedAt,
                retryNotBefore: rateLimitReset(http, now: checkedAt)))
        default:
            return .failure(UpdateCheckFailure(reason: "GitHub returned HTTP \(http.statusCode)", at: checkedAt))
        }
    }

    /// `retry-after` (seconds) if present, else `x-ratelimit-reset` (epoch seconds).
    static func rateLimitReset(_ http: HTTPURLResponse, now: Date) -> Date? {
        if let s = http.value(forHTTPHeaderField: "retry-after"), let seconds = TimeInterval(s) {
            return now.addingTimeInterval(seconds)
        }
        if let s = http.value(forHTTPHeaderField: "x-ratelimit-reset"), let epoch = TimeInterval(s) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    private static func describe(_ error: any Error) -> String {
        (error as? URLError)?.localizedDescription ?? String(describing: error)
    }
}

/// When to check: 12 h after a success; after a failure, 30 min later (or once GitHub's rate
/// limit resets, if that's later). Wall-clock based, so a Mac that slept through the due time
/// checks on its next tick.
public enum UpdateSchedule {
    public static let interval: TimeInterval = 12 * 60 * 60
    public static let failureRetry: TimeInterval = 30 * 60

    public static func nextCheck(cache: UpdateCache, lastFailure: UpdateCheckFailure?) -> Date {
        if let failure = lastFailure, cache.checkedAt.map({ failure.at >= $0 }) ?? true {
            let retry = failure.at.addingTimeInterval(failureRetry)
            return max(retry, failure.retryNotBefore ?? retry)
        }
        guard let checkedAt = cache.checkedAt else { return .distantPast }
        return checkedAt.addingTimeInterval(interval)
    }

    public static func isDue(cache: UpdateCache, lastFailure: UpdateCheckFailure?, now: Date) -> Bool {
        now >= nextCheck(cache: cache, lastFailure: lastFailure)
    }

    /// At launch, check (after a short delay) unless the cached answer is under an
    /// hour old, so frequent relaunches (`make run`) don't each hit GitHub.
    public static let launchMinimumAge: TimeInterval = 60 * 60

    public static func isDueAtLaunch(cache: UpdateCache, now: Date) -> Bool {
        guard let checkedAt = cache.checkedAt else { return true }
        // A check "in the future" means the clock moved back: don't trust it.
        return checkedAt > now || now.timeIntervalSince(checkedAt) >= launchMinimumAge
    }
}

/// What the menu shows about updates. Derived at display time from the running version and the
/// cached release (never persisted as a verdict, so updating the app clears "available").
public enum UpdateMenuState: Sendable, Equatable {
    /// The running build has no semantic version (`swift run`): nothing to compare.
    case unversioned
    /// Nothing known yet, no check running.
    case notChecked
    case checking
    case upToDate
    case available(ReleaseInfo)
    case failed(reason: String)

    /// A known newer release wins over everything (it stays useful even if a later check
    /// failed); then a running check, then the last attempt's failure, then up to date.
    /// Pre-releases are never offered, and a build at or above the latest release (a dev
    /// build after a release, a dry-run `X.Y.Z-suffix`) is up to date.
    public static func resolve(
        current: SemanticVersion?, cache: UpdateCache, isChecking: Bool, lastFailure: UpdateCheckFailure?
    ) -> UpdateMenuState {
        guard let current else { return .unversioned }
        if let latest = cache.latest, !latest.version.isPrerelease, latest.version > current {
            return .available(latest)
        }
        if isChecking { return .checking }
        if let failure = lastFailure, cache.checkedAt.map({ failure.at >= $0 }) ?? true {
            return .failed(reason: failure.reason)
        }
        return cache.checkedAt == nil ? .notChecked : .upToDate
    }
}
