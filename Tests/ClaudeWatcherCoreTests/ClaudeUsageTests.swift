import Foundation
import Synchronization
import Testing
@testable import ClaudeWatcherCore

// MARK: - Response parsing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func parse(_ json: String) throws -> UsageSnapshot {
    try ClaudeUsageAPI.parse(Data(json.utf8), fetchedAt: t0)
}

@Test func claudeUsageParsesFlatShape() throws {
    let snapshot = try parse("""
    {"five_hour": {"utilization": 42.5, "resets_at": "2026-10-21T20:30:00.412488+00:00"},
     "seven_day": {"utilization": 7, "resets_at": "2026-10-25T08:00:00Z"},
     "seven_day_opus": null, "extra_usage": {"is_enabled": false}}
    """)
    #expect(snapshot.session?.percent == 42.5)
    #expect(snapshot.session?.resetsAt == ClaudeUsageAPI.parseDate("2026-10-21T20:30:00.412488Z"))
    #expect(snapshot.weekly?.percent == 7)
    #expect(snapshot.weekly?.resetsAt == ClaudeUsageAPI.parseDate("2026-10-25T08:00:00Z"))
    #expect(snapshot.asOf == t0)
}

@Test func claudeUsageParsesLimitsShape() throws {
    let snapshot = try parse("""
    {"limits": [
      {"kind": "five_hour_old", "group": "session", "percent": 99, "is_active": false},
      {"kind": "weekly_opus", "group": "weekly", "percent": 80, "resets_at": "2026-10-25T08:00:00Z"},
      {"kind": "session_all", "group": "session", "percent": 12, "resets_at": "2026-10-21T20:00:00Z", "is_active": true},
      {"kind": "weekly_all", "group": "weekly", "percent": 40.25, "resets_at": "2026-10-26T08:00:00.5Z"}
    ]}
    """)
    #expect(snapshot.session == UsageWindow(percent: 12, resetsAt: ClaudeUsageAPI.parseDate("2026-10-21T20:00:00Z")))
    #expect(snapshot.weekly?.percent == 40.25)
    #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1_793_001_600.5))
}

@Test func claudeUsageFlatKeysWinAndBorrowWeeklyReset() throws {
    let snapshot = try parse("""
    {"five_hour": {"utilization": 3},
     "seven_day": {"utilization": 50},
     "limits": [{"kind": "weekly_all", "percent": 51, "resets_at": "2026-10-26T08:00:00Z"},
                {"kind": "session", "percent": 4, "resets_at": "2026-10-21T20:00:00Z"}]}
    """)
    #expect(snapshot.session == UsageWindow(percent: 3, resetsAt: nil))
    #expect(snapshot.weekly == UsageWindow(percent: 50, resetsAt: ClaudeUsageAPI.parseDate("2026-10-26T08:00:00Z")))
}

@Test func claudeUsageParsingIsLenient() throws {
    // Malformed fields become nil instead of failing the response.
    let snapshot = try parse("""
    {"five_hour": "nope", "seven_day": {"utilization": "high", "resets_at": 5},
     "limits": [42, {"kind": "weekly_all", "percent": "x"}, {"kind": "weekly_all", "percent": 9, "resets_at": "garbage"}]}
    """)
    #expect(snapshot.session == nil)
    #expect(snapshot.weekly == UsageWindow(percent: 9, resetsAt: nil))

    let nulls = try parse(#"{"five_hour": null, "seven_day": {"utilization": 1, "resets_at": null}, "limits": "x"}"#)
    #expect(nulls.session == nil)
    #expect(nulls.weekly == UsageWindow(percent: 1, resetsAt: nil))

    let empty = try parse("{}")
    #expect(empty.session == nil && empty.weekly == nil)

    #expect(throws: ClaudeUsageError.decoding) { try parse("not json") }
    #expect(throws: ClaudeUsageError.decoding) { try parse("[1, 2]") }
}

@Test func claudeUsageParsesDates() {
    let base = Date(timeIntervalSince1970: 1_792_614_600) // 2026-10-21T20:30:00Z
    #expect(ClaudeUsageAPI.parseDate("2026-10-21T20:30:00Z") == base)
    #expect(ClaudeUsageAPI.parseDate("2026-10-21T22:30:00+02:00") == base)
    #expect(ClaudeUsageAPI.parseDate("2026-10-21T20:30:00.5Z") == base.addingTimeInterval(0.5))
    let micro = ClaudeUsageAPI.parseDate("2026-10-21T20:30:00.412488+00:00")
    #expect(micro.map { abs($0.timeIntervalSince(base) - 0.412488) < 1e-6 } == true)
    let nano = ClaudeUsageAPI.parseDate("2026-10-21T20:30:00.123456789Z")
    #expect(nano.map { abs($0.timeIntervalSince(base) - 0.123456789) < 1e-6 } == true)
    #expect(ClaudeUsageAPI.parseDate("yesterday") == nil)
    #expect(ClaudeUsageAPI.parseDate("") == nil)
}

@Test func claudeUsageParsesRetryAfter() {
    let now = Date(timeIntervalSince1970: 1_792_614_600) // Wed, 21 Oct 2026 20:30:00 GMT
    #expect(ClaudeUsageAPI.parseRetryAfter("120", now: now) == 120)
    #expect(ClaudeUsageAPI.parseRetryAfter(" 30 ", now: now) == 30)
    #expect(ClaudeUsageAPI.parseRetryAfter("-5", now: now) == 0)
    #expect(ClaudeUsageAPI.parseRetryAfter("Wed, 21 Oct 2026 20:32:00 GMT", now: now) == 120)
    #expect(ClaudeUsageAPI.parseRetryAfter("Wed, 21 Oct 2026 20:00:00 GMT", now: now) == 0)
    #expect(ClaudeUsageAPI.parseRetryAfter("soon", now: now) == nil)
    #expect(ClaudeUsageAPI.parseRetryAfter("", now: now) == nil)
    #expect(ClaudeUsageAPI.parseRetryAfter(nil, now: now) == nil)
}

@Test func claudeUsageRequestHeaders() {
    let request = ClaudeUsageAPI.request(token: "tok-123", userAgent: "ClaudeWatcher/1.2.3")
    #expect(request.url == URL(string: "https://api.anthropic.com/api/oauth/usage"))
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeWatcher/1.2.3")
}

// MARK: - Credentials

private let credentialsJSON = #"{"claudeAiOauth":{"accessToken":"sk-test","refreshToken":"rt-secret","expiresAt":1800000000000,"scopes":["user:inference"]},"mcpOAuth":{}}"#

@Test func claudeUsageDecodesCredentials() throws {
    let plain = try ClaudeCredentialStore.decode(Data((credentialsJSON + "\n").utf8))
    #expect(plain.accessToken == "sk-test")
    #expect(plain.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    #expect(!plain.description.contains("sk-test"))
    #expect(!"\(plain)".contains("sk-test"))
    #expect(!String(reflecting: plain).contains("sk-test"))

    // `security -w` prints hex when the value has non-printable bytes.
    let hex = Data(credentialsJSON.utf8).map { String(format: "%02x", $0) }.joined()
    #expect(try ClaudeCredentialStore.decode(Data((hex + "\n").utf8)) == plain)
    #expect(try ClaudeCredentialStore.decode(Data(hex.uppercased().utf8)) == plain)

    let noExpiry = try ClaudeCredentialStore.decode(Data(#"{"claudeAiOauth":{"accessToken":"a"}}"#.utf8))
    #expect(noExpiry.expiresAt == nil)
    #expect(!noExpiry.isExpired(now: .distantFuture))
}

@Test func claudeUsageCredentialFailures() {
    #expect(throws: ClaudeUsageError.notLoggedIn) { try ClaudeCredentialStore.decode(Data()) }
    #expect(throws: ClaudeUsageError.notLoggedIn) { try ClaudeCredentialStore.decode(Data("\n".utf8)) }
    #expect(throws: ClaudeUsageError.notLoggedIn) { try ClaudeCredentialStore.decode(Data(#"{"mcpOAuth":{}}"#.utf8)) }
    #expect(throws: ClaudeUsageError.notLoggedIn) {
        try ClaudeCredentialStore.decode(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8))
    }
    #expect(throws: ClaudeUsageError.notLoggedIn) {
        try ClaudeCredentialStore.decode(Data(#"{"claudeAiOauth":null}"#.utf8))
    }
    #expect(throws: ClaudeUsageError.unreadableCredentials) { try ClaudeCredentialStore.decode(Data("garbage".utf8)) }
    #expect(throws: ClaudeUsageError.unreadableCredentials) { try ClaudeCredentialStore.decode(Data("abc".utf8)) }
}

@Test func claudeUsageCredentialExpiry() {
    let credentials = ClaudeCredentials(accessToken: "a", expiresAt: t0)
    #expect(!credentials.isExpired(now: t0.addingTimeInterval(-61)))
    #expect(credentials.isExpired(now: t0.addingTimeInterval(-59)))   // 60 s skew
    #expect(credentials.isExpired(now: t0.addingTimeInterval(10)))
}

@Test func claudeUsageServiceNames() {
    let defaultHome = URL(fileURLWithPath: "/Users/test/.claude", isDirectory: true)
    // sha256("/Users/test/claude-work") = ba8216bd…, sha256("/Users/test/claude-work/") = 403814fd…
    #expect(ClaudeCredentialStore.suffixedService(configDir: "/Users/test/claude-work")
            == "Claude Code-credentials-ba8216bd")
    #expect(ClaudeCredentialStore.serviceNames(
        claudeHome: URL(fileURLWithPath: "/Users/test/claude-work", isDirectory: true), defaultHome: defaultHome)
        == ["Claude Code-credentials-ba8216bd", "Claude Code-credentials-403814fd", "Claude Code-credentials"])
    let forDefault = ClaudeCredentialStore.serviceNames(claudeHome: defaultHome, defaultHome: defaultHome)
    #expect(forDefault.first == "Claude Code-credentials")
    #expect(forDefault.count == 3)
    #expect(forDefault[1] == ClaudeCredentialStore.suffixedService(configDir: "/Users/test/.claude"))
    // NFC: a decomposed é hashes like the precomposed one, as Claude Code's `normalize("NFC")`.
    #expect(ClaudeCredentialStore.suffixedService(configDir: "/Users/te\u{0301}st")
            == ClaudeCredentialStore.suffixedService(configDir: "/Users/t\u{00E9}st"))
}

private final class KeychainFake: Sendable {
    let items: [String: ClaudeCredentialStore.KeychainRead]
    let files: [String: Data]
    let asked = Mutex<[String]>([])
    init(items: [String: ClaudeCredentialStore.KeychainRead], files: [String: Data] = [:]) {
        self.items = items
        self.files = files
    }
    func load(home: String) async throws -> ClaudeCredentials {
        try await ClaudeCredentialStore.load(
            claudeHome: URL(fileURLWithPath: home, isDirectory: true),
            defaultHome: URL(fileURLWithPath: "/Users/test/.claude", isDirectory: true),
            readKeychain: { service in
                self.asked.withLock { $0.append(service) }
                return self.items[service] ?? .notFound
            },
            readFile: { url in self.files[url.path] })
    }
}

@Test func claudeUsageLoadsCredentialsInOrder() async throws {
    let other = #"{"claudeAiOauth":{"accessToken":"other"}}"#
    // Custom home: suffixed item first.
    let custom = KeychainFake(items: [
        "Claude Code-credentials-ba8216bd": .found(Data(credentialsJSON.utf8)),
        "Claude Code-credentials": .found(Data(other.utf8)),
    ])
    #expect(try await custom.load(home: "/Users/test/claude-work").accessToken == "sk-test")
    #expect(custom.asked.withLock { $0 } == ["Claude Code-credentials-ba8216bd"])

    // Custom home without a suffixed item: the plain one.
    let plainOnly = KeychainFake(items: ["Claude Code-credentials": .found(Data(other.utf8))])
    #expect(try await plainOnly.load(home: "/Users/test/claude-work").accessToken == "other")
    #expect(plainOnly.asked.withLock { $0.count } == 3)

    // Default home: plain first.
    let defaultFake = KeychainFake(items: ["Claude Code-credentials": .found(Data(other.utf8))])
    #expect(try await defaultFake.load(home: "/Users/test/.claude").accessToken == "other")
    #expect(defaultFake.asked.withLock { $0 } == ["Claude Code-credentials"])

    // No Keychain item: the credentials file.
    let file = KeychainFake(items: [:], files: ["/Users/test/claude-work/.credentials.json": Data(credentialsJSON.utf8)])
    #expect(try await file.load(home: "/Users/test/claude-work").accessToken == "sk-test")

    // Nothing at all: not logged in.
    await #expect(throws: ClaudeUsageError.notLoggedIn) { try await KeychainFake(items: [:]).load(home: "/x") }

    // `security` failing stops the search (never falls through to another account's item).
    let failing = KeychainFake(items: ["Claude Code-credentials-ba8216bd": .failed,
                                       "Claude Code-credentials": .found(Data(other.utf8))])
    await #expect(throws: ClaudeUsageError.keychainUnavailable) { try await failing.load(home: "/Users/test/claude-work") }
}

// MARK: - Poll state machine

/// Scripted credentials and HTTP responses; records every token actually sent.
private final class UsageFakes: Sendable {
    enum Reply: Sendable {
        case status(Int, body: String = "", headers: [String: String] = [:])
        case failure(URLError.Code)
        case cancelled
    }

    let credentials = Mutex<Result<ClaudeCredentials, ClaudeUsageError>>(.failure(.notLoggedIn))
    let replies = Mutex<[Reply]>([])
    let sentTokens = Mutex<[String]>([])

    func setToken(_ token: String, expiresAt: Date? = nil) {
        credentials.withLock { $0 = .success(ClaudeCredentials(accessToken: token, expiresAt: expiresAt)) }
    }
    func setCredentialError(_ error: ClaudeUsageError) {
        credentials.withLock { $0 = .failure(error) }
    }
    func enqueue(_ reply: Reply) { replies.withLock { $0.append(reply) } }
    var sent: [String] { sentTokens.withLock { $0 } }

    func makeSource() -> ClaudeUsageSource {
        ClaudeUsageSource(
            loadCredentials: { try self.credentials.withLock { try $0.get() } },
            fetch: { request in
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
                self.sentTokens.withLock { $0.append(String(auth.dropFirst("Bearer ".count))) }
                let reply = self.replies.withLock { $0.isEmpty ? .status(500) : $0.removeFirst() }
                switch reply {
                case .status(let code, let body, let headers):
                    let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                                   headerFields: headers)!
                    return (Data(body.utf8), response)
                case .failure(let code):
                    throw URLError(code)
                case .cancelled:
                    throw CancellationError()
                }
            },
            userAgent: "ClaudeWatcher/test")
    }
}

private let okBody = #"{"five_hour":{"utilization":10,"resets_at":"2026-10-21T20:30:00Z"},"seven_day":{"utilization":20}}"#

@Test func claudeUsagePollSuccess() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    fakes.enqueue(.status(200, body: okBody))
    let source = fakes.makeSource()
    #expect(source.agent == .claude)
    let result = await source.poll(now: t0)
    #expect(result.usage.agent == .claude)
    #expect(result.usage.status == .ok)
    #expect(result.usage.snapshot?.session?.percent == 10)
    #expect(result.usage.snapshot?.weekly?.percent == 20)
    #expect(result.usage.snapshot?.asOf == t0)
    #expect(result.nextPollIn == 300)
    #expect(fakes.sent == ["tok-a"])
}

@Test func claudeUsageRejectedTokenIsNotResent() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    fakes.enqueue(.status(200, body: okBody))
    fakes.enqueue(.status(401))
    let source = fakes.makeSource()
    _ = await source.poll(now: t0)

    let rejected = await source.poll(now: t0.addingTimeInterval(300))
    #expect(rejected.usage.status == .stale("Token expired: open Claude Code to refresh"))
    #expect(rejected.usage.snapshot != nil)
    #expect(rejected.nextPollIn == 60)
    #expect(fakes.sent == ["tok-a", "tok-a"])

    // Same token a minute later: not sent again.
    let again = await source.poll(now: t0.addingTimeInterval(360))
    #expect(again.usage.status == .stale("Token expired: open Claude Code to refresh"))
    #expect(again.nextPollIn == 60)
    #expect(fakes.sent.count == 2)

    // Claude Code refreshed it: the new token is sent.
    fakes.setToken("tok-b")
    fakes.enqueue(.status(200, body: okBody))
    let refreshed = await source.poll(now: t0.addingTimeInterval(420))
    #expect(refreshed.usage.status == .ok)
    #expect(fakes.sent == ["tok-a", "tok-a", "tok-b"])
}

@Test func claudeUsageRejectedTokenRetriedAfterFiveMinutes() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    fakes.enqueue(.status(403))
    let source = fakes.makeSource()
    let first = await source.poll(now: t0)
    #expect(first.usage.status == .error("Token expired: open Claude Code to refresh"))
    _ = await source.poll(now: t0.addingTimeInterval(299))
    #expect(fakes.sent.count == 1)
    fakes.enqueue(.status(200, body: okBody))
    let retried = await source.poll(now: t0.addingTimeInterval(300))
    #expect(retried.usage.status == .ok)
    #expect(fakes.sent.count == 2)
}

@Test func claudeUsageExpiredTokenIsNotSent() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a", expiresAt: t0.addingTimeInterval(30))
    let source = fakes.makeSource()
    let result = await source.poll(now: t0)
    #expect(result.usage.status == .error("Token expired: open Claude Code to refresh"))
    #expect(result.nextPollIn == 60)
    #expect(fakes.sent.isEmpty)
}

@Test func claudeUsageRateLimitBackoff() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    let source = fakes.makeSource()

    // No retry-after: 5 min, then 10 min (exponential).
    fakes.enqueue(.status(429))
    let first = await source.poll(now: t0)
    #expect(first.nextPollIn == 300)
    #expect(first.usage.status == .error("Rate limited: retrying in 5m"))

    // Polled early: no request, the remaining wait.
    let early = await source.poll(now: t0.addingTimeInterval(100))
    #expect(early.nextPollIn == 200)
    #expect(fakes.sent.count == 1)

    fakes.enqueue(.status(429))
    let second = await source.poll(now: t0.addingTimeInterval(300))
    #expect(second.nextPollIn == 600)

    // A longer retry-after wins, capped at 1 h.
    fakes.enqueue(.status(429, headers: ["Retry-After": "7200"]))
    let third = await source.poll(now: t0.addingTimeInterval(900))
    #expect(third.nextPollIn == 3600)
    #expect(third.usage.status == .error("Rate limited: retrying in 1h 0m"))

    // Exponential caps at 30 min, and a shorter retry-after doesn't shorten it.
    fakes.enqueue(.status(429, headers: ["Retry-After": "10"]))
    let fourth = await source.poll(now: t0.addingTimeInterval(4500))
    #expect(fourth.nextPollIn == 1800)

    // Success resets the backoff.
    fakes.enqueue(.status(200, body: okBody))
    let ok = await source.poll(now: t0.addingTimeInterval(6300))
    #expect(ok.usage.status == .ok)
    fakes.enqueue(.status(429))
    let again = await source.poll(now: t0.addingTimeInterval(6600))
    #expect(again.nextPollIn == 300)
    #expect(again.usage.status == .stale("Rate limited: retrying in 5m"))
}

@Test func claudeUsageNetworkBackoff() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    let source = fakes.makeSource()
    var delays: [TimeInterval] = []
    for i in 0..<6 {
        fakes.enqueue(.failure(.notConnectedToInternet))
        delays.append(await source.poll(now: t0.addingTimeInterval(Double(i) * 1000)).nextPollIn)
    }
    #expect(delays == [30, 60, 120, 240, 300, 300])
    let last = await source.poll(now: t0.addingTimeInterval(9000)) // default reply: 500
    #expect(last.usage.status == .error("Server error (500)"))
    #expect(last.nextPollIn == 300)
    fakes.enqueue(.status(200, body: okBody))
    _ = await source.poll(now: t0.addingTimeInterval(9300))
    fakes.enqueue(.failure(.timedOut))
    let afterOK = await source.poll(now: t0.addingTimeInterval(9600))
    #expect(afterOK.nextPollIn == 30)
    #expect(afterOK.usage.status == .stale("Network error"))
}

@Test func claudeUsageKeychainBackoff() async {
    let fakes = UsageFakes()
    fakes.setCredentialError(.keychainUnavailable)
    let source = fakes.makeSource()
    var delays: [TimeInterval] = []
    for i in 0..<7 {
        let result = await source.poll(now: t0.addingTimeInterval(Double(i) * 2000))
        #expect(result.usage.status == .error("Couldn't read Claude Code credentials"))
        delays.append(result.nextPollIn)
    }
    #expect(delays == [60, 120, 240, 480, 960, 1800, 1800])
    #expect(fakes.sent.isEmpty)
}

@Test func claudeUsageNotLoggedInClearsSnapshot() async {
    let fakes = UsageFakes()
    let source = fakes.makeSource()
    let none = await source.poll(now: t0)
    #expect(none.usage.status == .unavailable)
    #expect(none.usage.snapshot == nil)
    #expect(none.nextPollIn == 60)

    fakes.setToken("tok-a")
    fakes.enqueue(.status(200, body: okBody))
    #expect(await source.poll(now: t0.addingTimeInterval(60)).usage.snapshot != nil)

    fakes.setCredentialError(.notLoggedIn)
    let loggedOut = await source.poll(now: t0.addingTimeInterval(360))
    #expect(loggedOut.usage.status == .unavailable)
    #expect(loggedOut.usage.snapshot == nil)

    // Logging back in with a failing request: an error, not the old account's snapshot.
    fakes.setToken("tok-b")
    fakes.enqueue(.status(502))
    let back = await source.poll(now: t0.addingTimeInterval(420))
    #expect(back.usage.status == .error("Server error (502)"))
    #expect(back.usage.snapshot == nil)
}

@Test func claudeUsageStaleVersusError() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    let source = fakes.makeSource()
    fakes.enqueue(.status(200, body: "<html>"))
    let first = await source.poll(now: t0)
    #expect(first.usage.status == .error("Unexpected response from server"))
    #expect(first.usage.snapshot == nil)
    #expect(first.nextPollIn == 300)

    fakes.enqueue(.status(200, body: okBody))
    _ = await source.poll(now: t0.addingTimeInterval(300))
    fakes.setCredentialError(.unreadableCredentials)
    let stale = await source.poll(now: t0.addingTimeInterval(600))
    #expect(stale.usage.status == .stale("Couldn't parse Claude Code credentials"))
    #expect(stale.usage.snapshot?.asOf == t0.addingTimeInterval(300))
    #expect(stale.nextPollIn == 60)
}

@Test func claudeUsageCancellationKeepsState() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    let source = fakes.makeSource()
    fakes.enqueue(.cancelled)
    let first = await source.poll(now: t0)
    #expect(first.usage.status == .loading)
    #expect(first.nextPollIn == 30)

    fakes.enqueue(.status(200, body: okBody))
    _ = await source.poll(now: t0.addingTimeInterval(30))
    fakes.enqueue(.failure(.cancelled))
    let cancelled = await source.poll(now: t0.addingTimeInterval(330))
    #expect(cancelled.usage.status == .ok)
    #expect(cancelled.usage.snapshot != nil)
    #expect(cancelled.nextPollIn == 30)
}

// MARK: - Live poll (CW_LIVE=1 swift test --filter liveClaudeUsage)

@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE"] == "1"))
func liveClaudeUsage() async {
    let result = await ClaudeUsageSource().poll(now: Date())
    let usage = result.usage
    func describe(_ window: UsageWindow?) -> String {
        guard let window else { return "none" }
        return "\(window.percent)% resets \(window.resetsAt.map { "\($0)" } ?? "-")"
    }
    print("LIVE: status=\(usage.status) nextPollIn=\(result.nextPollIn)s")
    print("LIVE: session=\(describe(usage.snapshot?.session)) weekly=\(describe(usage.snapshot?.weekly))")
    print("LIVE: asOf=\(usage.snapshot.map { "\($0.asOf)" } ?? "-")")
}
