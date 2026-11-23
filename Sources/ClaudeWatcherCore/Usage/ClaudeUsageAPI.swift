import Foundation

/// Claude's plan usage endpoint (the one Claude Code's `/usage` uses), authenticated with Claude
/// Code's OAuth access token.
enum ClaudeUsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Performs one HTTP request. Injected in tests (same shape as `UpdateChecker.Fetch`).
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Ephemeral: no cookies, no disk cache, nothing persisted.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        // After wake the network can take a few seconds to return: wait for it (bounded by the
        // resource timeout) instead of failing immediately.
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    static let defaultFetch: Fetch = { request in try await session.data(for: request) }

    static func request(token: String, userAgent: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Fetches current usage. Throws `ClaudeUsageError`, or `CancellationError` if the calling
    /// task was cancelled.
    static func fetch(token: String, userAgent: String, now: Date, fetch: Fetch) async throws -> UsageSnapshot {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await fetch(request(token: token, userAgent: userAgent))
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            // Never interpolate the request (it carries the token); URLError's text doesn't.
            throw ClaudeUsageError.network((error as? URLError)?.localizedDescription ?? "request failed")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeUsageError.network("Invalid response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ClaudeUsageError.unauthorized(http.statusCode)
        case 429:
            throw ClaudeUsageError.rateLimited(
                retryAfter: parseRetryAfter(http.value(forHTTPHeaderField: "retry-after"), now: now))
        default:
            throw ClaudeUsageError.http(http.statusCode)
        }
        return try parse(data, fetchedAt: now)
    }

    // MARK: - Parsing

    /// Both response shapes: the flat `five_hour`/`seven_day` objects (`utilization`,
    /// `resets_at`), and the newer `limits` array (`kind`, `group`, `percent`, `resets_at`,
    /// `is_active`), which some accounts get instead. Flat keys win; malformed fields are nil.
    static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw ClaudeUsageError.decoding
        }
        // Only entries with a usable percentage count (a malformed one never hides a good one).
        let limits = (body.limits ?? []).filter { $0.window != nil }
        let weeklyLimit = limits.first { $0.kind == "weekly_all" }
        var weekly = body.sevenDay?.window ?? weeklyLimit?.window
        if weekly != nil, weekly?.resetsAt == nil {
            weekly?.resetsAt = weeklyLimit?.resetsAt.flatMap(parseDate)
        }
        // `five_hour` is null on accounts without a session limit.
        let sessionLimit = limits.first { limit in
            limit.isActive != false && [limit.kind, limit.group].contains { name in
                name.map { $0.contains("session") || $0.contains("five_hour") } ?? false
            }
        }
        return UsageSnapshot(session: body.fiveHour?.window ?? sessionLimit?.window,
                             weekly: weekly,
                             asOf: fetchedAt)
    }

    /// `retry-after` is either delta-seconds or an HTTP-date. nil if absent or unparseable.
    static func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return seconds.isFinite ? max(0, seconds) : nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        return nil
    }

    /// ISO-8601 with any number of fractional-second digits (the API sends microseconds, e.g.
    /// `2026-10-21T20:30:00.412488+00:00`), with `Z` or `±hh:mm`.
    static func parseDate(_ string: String) -> Date? {
        var base = string
        var fraction: TimeInterval = 0
        if let dot = string.firstIndex(of: ".") {
            let afterDot = string.index(after: dot)
            let digitsEnd = string[afterDot...].firstIndex { !$0.isASCII || !$0.isNumber } ?? string.endIndex
            let digits = string[afterDot..<digitsEnd]
            fraction = TimeInterval("0." + digits) ?? 0
            base = String(string[..<dot] + string[digitsEnd...])
        }
        guard let date = try? Date(base, strategy: .iso8601) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    private struct ResponseBody: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }

        // Lenient: a malformed field becomes nil instead of failing the whole response.
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try? c.decodeIfPresent(Window.self, forKey: .sevenDay)
            limits = (try? c.decodeIfPresent([LossyLimit].self, forKey: .limits))?.compactMap(\.value)
        }
    }

    /// One `limits` entry that can't fail the array: a malformed one becomes nil.
    private struct LossyLimit: Decodable {
        let value: Limit?
        init(from decoder: any Decoder) throws { value = try? Limit(from: decoder) }
    }

    private struct Limit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: String?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            group = try? c.decodeIfPresent(String.self, forKey: .group)
            percent = try? c.decodeIfPresent(Double.self, forKey: .percent)
            resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
            isActive = try? c.decodeIfPresent(Bool.self, forKey: .isActive)
        }

        var window: UsageWindow? {
            guard let percent, percent.isFinite else { return nil }
            return UsageWindow(percent: percent, resetsAt: resetsAt.flatMap(ClaudeUsageAPI.parseDate))
        }
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try? c.decodeIfPresent(Double.self, forKey: .utilization)
            resetsAt = try? c.decodeIfPresent(String.self, forKey: .resetsAt)
        }

        var window: UsageWindow? {
            guard let utilization, utilization.isFinite else { return nil }
            return UsageWindow(percent: utilization, resetsAt: resetsAt.flatMap(ClaudeUsageAPI.parseDate))
        }
    }
}
