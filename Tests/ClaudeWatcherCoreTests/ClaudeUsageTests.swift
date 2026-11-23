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

    // A present-but-null `five_hour` alone is a valid (empty) reading: no session limit.
    let noSession = try parse(#"{"five_hour": null}"#)
    #expect(noSession.session == nil && noSession.weekly == nil)

    #expect(throws: ClaudeUsageError.decoding) { try parse("not json") }
    #expect(throws: ClaudeUsageError.decoding) { try parse("[1, 2]") }
}

@Test func claudeUsageBodyWithoutUsageKeysIsADecodingError() throws {
    // An error body or a renamed schema must not replace a good snapshot with an empty one.
    #expect(throws: ClaudeUsageError.decoding) { try parse("{}") }
    #expect(throws: ClaudeUsageError.decoding) {
        try parse(#"{"error": {"type": "invalid_request_error", "message": "nope"}}"#)
    }
    #expect(throws: ClaudeUsageError.decoding) { try parse(#"{"fiveHour": {"utilization": 3}}"#) }
    // Any one of the keys, even null or malformed, is a reading.
    #expect(try parse(#"{"seven_day": null}"#).weekly == nil)
    #expect(try parse(#"{"limits": []}"#).session == nil)
    #expect(try parse(#"{"seven_day": "x"}"#).weekly == nil)
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
    var dumped = ""
    dump(plain, to: &dumped)
    #expect(!dumped.contains("sk-test"))
    #expect(dumped.contains("expiresAt"))
    #expect(Mirror(reflecting: plain).children.allSatisfy { "\($0.value)" != "sk-test" })
    #expect(Mirror(reflecting: plain).children.map(\.label) == ["expiresAt"])

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

@Test func claudeUsageLocationTiers() {
    let defaultHome = URL(fileURLWithPath: "/Users/test/.claude", isDirectory: true)
    // sha256("/Users/test/claude-work") = ba8216bd…, sha256("/Users/test/claude-work/") = 403814fd…
    #expect(ClaudeCredentialStore.suffixedService(configDir: "/Users/test/claude-work")
            == "Claude Code-credentials-ba8216bd")
    typealias L = ClaudeCredentialStore.Location
    let custom = URL(fileURLWithPath: "/Users/test/claude-work", isDirectory: true)
    #expect(ClaudeCredentialStore.locationTiers(claudeHome: custom, defaultHome: defaultHome) == [
        [L.keychain(service: "Claude Code-credentials-ba8216bd"), .keychain(service: "Claude Code-credentials-403814fd"),
         .file(URL(fileURLWithPath: "/Users/test/claude-work/.credentials.json"))],
        [.keychain(service: "Claude Code-credentials")],
    ])
    let forDefault = ClaudeCredentialStore.locationTiers(claudeHome: defaultHome, defaultHome: defaultHome)
    #expect(forDefault.count == 1)
    #expect(forDefault.first?.count == 4)
    #expect(forDefault.first?.first == .keychain(service: "Claude Code-credentials"))
    #expect(forDefault.first?[1] == .keychain(service: ClaudeCredentialStore.suffixedService(configDir: "/Users/test/.claude")))
    #expect(forDefault.first?.last == .file(URL(fileURLWithPath: "/Users/test/.claude/.credentials.json")))
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
    func load(home: String, now: Date = t0) async throws -> ClaudeCredentials {
        try await ClaudeCredentialStore.load(
            claudeHome: URL(fileURLWithPath: home, isDirectory: true),
            defaultHome: URL(fileURLWithPath: "/Users/test/.claude", isDirectory: true), now: now,
            readKeychain: { service in
                self.asked.withLock { $0.append(service) }
                return self.items[service] ?? .notFound
            },
            readFile: { url in self.files[url.path] })
    }
}

/// Credentials JSON for `token`, expiring at `expiresAt` (nil: no `expiresAt` field).
private func credentials(_ token: String, expiresAt: Date?) -> ClaudeCredentialStore.KeychainRead {
    .found(credentialsData(token, expiresAt: expiresAt))
}
private func credentialsData(_ token: String, expiresAt: Date?) -> Data {
    let expiry = expiresAt.map { #","expiresAt":\#(Int64($0.timeIntervalSince1970 * 1000))"# } ?? ""
    return Data(#"{"claudeAiOauth":{"accessToken":"\#(token)"\#(expiry)}}"#.utf8)
}

private let plainService = "Claude Code-credentials"
private let workService = "Claude Code-credentials-ba8216bd"         // /Users/test/claude-work
private let workSlashService = "Claude Code-credentials-403814fd"    // /Users/test/claude-work/
private let defaultSuffixed = ClaudeCredentialStore.suffixedService(configDir: "/Users/test/.claude")
private let workFile = "/Users/test/claude-work/.credentials.json"
private let defaultFile = "/Users/test/.claude/.credentials.json"

@Test func claudeUsageLoadsCredentialsFromTheHomeFirst() async throws {
    let later = t0.addingTimeInterval(3600)
    // Custom home: its own item, never the plain one (which may be another account), even if
    // the plain one expires later.
    let custom = KeychainFake(items: [
        workService: credentials("work", expiresAt: later),
        plainService: credentials("other", expiresAt: later.addingTimeInterval(3600)),
    ])
    #expect(try await custom.load(home: "/Users/test/claude-work").accessToken == "work")
    #expect(custom.asked.withLock { $0 } == [workService, workSlashService])

    // Custom home with only the file: the file, still before the plain item.
    let file = KeychainFake(items: [plainService: credentials("other", expiresAt: later)],
                            files: [workFile: credentialsData("file", expiresAt: later)])
    #expect(try await file.load(home: "/Users/test/claude-work").accessToken == "file")
    #expect(!file.asked.withLock { $0 }.contains(plainService))

    // Custom home with nothing of its own: the plain item.
    let plainOnly = KeychainFake(items: [plainService: credentials("other", expiresAt: nil)])
    #expect(try await plainOnly.load(home: "/Users/test/claude-work").accessToken == "other")
    #expect(plainOnly.asked.withLock { $0 } == [workService, workSlashService, plainService])

    // Custom home whose own token expired: that (-> "token expired"), not the plain item.
    let expiredOwn = KeychainFake(items: [workService: credentials("work", expiresAt: t0),
                                          plainService: credentials("other", expiresAt: later)])
    let expired = try await expiredOwn.load(home: "/Users/test/claude-work")
    #expect(expired.accessToken == "work" && expired.isExpired(now: t0))

    // Nothing at all: not logged in.
    await #expect(throws: ClaudeUsageError.notLoggedIn) { try await KeychainFake(items: [:]).load(home: "/x") }
}

@Test func claudeUsagePrefersTheFreshestCredentials() async throws {
    let later = t0.addingTimeInterval(3600)
    // Default home: a stale plain item (Claude Code once run without CLAUDE_CONFIG_DIR) loses to
    // the suffixed item Claude Code now refreshes (CLAUDE_CONFIG_DIR=~/.claude).
    let stalePlain = KeychainFake(items: [plainService: credentials("old", expiresAt: t0.addingTimeInterval(-86400)),
                                          defaultSuffixed: credentials("new", expiresAt: later)])
    #expect(try await stalePlain.load(home: "/Users/test/.claude").accessToken == "new")

    // Both valid: the later expiry wins, wherever it is (the file too).
    let both = KeychainFake(items: [plainService: credentials("a", expiresAt: later),
                                    defaultSuffixed: credentials("b", expiresAt: later.addingTimeInterval(60))],
                            files: [defaultFile: credentialsData("c", expiresAt: later.addingTimeInterval(30))])
    #expect(try await both.load(home: "/Users/test/.claude").accessToken == "b")

    // No expiry ranks below a known future one, but above an expired one.
    let noExpiry = KeychainFake(items: [plainService: credentials("none", expiresAt: nil),
                                        defaultSuffixed: credentials("known", expiresAt: later)])
    #expect(try await noExpiry.load(home: "/Users/test/.claude").accessToken == "known")
    let noExpiryVsExpired = KeychainFake(items: [plainService: credentials("expired", expiresAt: t0),
                                                 defaultSuffixed: credentials("none", expiresAt: nil)])
    #expect(try await noExpiryVsExpired.load(home: "/Users/test/.claude").accessToken == "none")

    // A tie goes to the earlier location.
    let tie = KeychainFake(items: [plainService: credentials("plain", expiresAt: later),
                                   defaultSuffixed: credentials("suffixed", expiresAt: later)])
    #expect(try await tie.load(home: "/Users/test/.claude").accessToken == "plain")

    // All expired: the latest one comes back (the source reports "token expired").
    let allExpired = KeychainFake(items: [plainService: credentials("a", expiresAt: t0.addingTimeInterval(-10)),
                                          defaultSuffixed: credentials("b", expiresAt: t0)])
    #expect(try await allExpired.load(home: "/Users/test/.claude").accessToken == "b")
}

@Test func claudeUsageCredentialReadFailures() async throws {
    let later = t0.addingTimeInterval(3600)
    // A failed read doesn't hide a usable token elsewhere in the tier.
    let usable = KeychainFake(items: [plainService: .failed, defaultSuffixed: credentials("b", expiresAt: later)])
    #expect(try await usable.load(home: "/Users/test/.claude").accessToken == "b")

    // No usable token: the failed item may hold it, so the keychain is "unavailable", not
    // "expired", and the search never falls through to another tier's item.
    let expiredAndFailed = KeychainFake(items: [plainService: credentials("a", expiresAt: t0), defaultSuffixed: .failed])
    await #expect(throws: ClaudeUsageError.keychainUnavailable) { try await expiredAndFailed.load(home: "/Users/test/.claude") }
    let failing = KeychainFake(items: [workService: .failed, plainService: credentials("other", expiresAt: later)])
    await #expect(throws: ClaudeUsageError.keychainUnavailable) { try await failing.load(home: "/Users/test/claude-work") }

    // Unparseable or token-less items in the home stop the search too.
    let garbage = KeychainFake(items: [workService: .found(Data("garbage".utf8)),
                                       workSlashService: .found(Data(#"{"mcpOAuth":{}}"#.utf8)),
                                       plainService: credentials("other", expiresAt: later)])
    await #expect(throws: ClaudeUsageError.unreadableCredentials) { try await garbage.load(home: "/Users/test/claude-work") }
    let tokenless = KeychainFake(items: [workService: .found(Data(#"{"mcpOAuth":{}}"#.utf8)),
                                         plainService: credentials("other", expiresAt: later)])
    await #expect(throws: ClaudeUsageError.notLoggedIn) { try await tokenless.load(home: "/Users/test/claude-work") }
    // ... but a usable token next to them wins.
    let mixed = KeychainFake(items: [workService: .found(Data("garbage".utf8))],
                             files: [workFile: credentialsData("file", expiresAt: nil)])
    #expect(try await mixed.load(home: "/Users/test/claude-work").accessToken == "file")
}

private final class Recorder: Sendable {
    let values = Mutex<[String]>([])
    func record(_ value: String) { values.withLock { $0.append(value) } }
    var recorded: [String] { values.withLock { $0 } }
}

@Test func claudeUsageLockedKeychainIsNotAsked() async {
    let spawned = Recorder()
    let spawn: SecurityTool.Spawn = { service in
        spawned.record(service)
        return .notFound
    }
    let locked = SecurityTool.makeRead(isKeychainLocked: { true }, spawn: spawn)
    #expect(await locked("svc") == .failed)
    #expect(spawned.recorded.isEmpty)
    let unlocked = SecurityTool.makeRead(isKeychainLocked: { false }, spawn: spawn)
    #expect(await unlocked("svc") == .notFound)
    #expect(spawned.recorded == ["svc"])
}

@Test func claudeUsageKeychainAccount() {
    #expect(SecurityTool.account(userName: "jdoe") == "jdoe")
    #expect(SecurityTool.account(userName: "j.doe_2-x") == "j.doe_2-x")
    #expect(SecurityTool.account(userName: "j doe") == "claude-code-user")
    #expect(SecurityTool.account(userName: "jöe") == "claude-code-user")
    #expect(SecurityTool.account(userName: "") == "claude-code-user")
}

@Test func claudeUsageSecurityToolEscalatesToKill() async throws {
    let start = Date()
    // Ignores SIGTERM (a builtin busy loop: no child holds the pipe open).
    let stubborn = try await onDedicatedThread {
        SecurityTool.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; while :; do :; done"],
                         timeout: 0.2, killGrace: 0.3)
    }
    #expect(stubborn != nil)
    #expect(stubborn?.exitStatus == nil)
    #expect(Date().timeIntervalSince(start) < 10)

    let echo = try await onDedicatedThread {
        SecurityTool.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"], timeout: 10, killGrace: 1)
    }
    #expect(echo?.exitStatus == 0)
    #expect(echo?.stdout == Data("hi\n".utf8))
    let missing = try await onDedicatedThread {
        SecurityTool.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 1, killGrace: 1)
    }
    #expect(missing == nil)
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
            loadCredentials: { _ in try self.credentials.withLock { try $0.get() } },
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
    fakes.enqueue(.cancelled)
    let cancelled = await source.poll(now: t0.addingTimeInterval(330))
    #expect(cancelled.usage.status == .ok)
    #expect(cancelled.usage.snapshot != nil)
    #expect(cancelled.nextPollIn == 30)
}

@Test func claudeUsageURLCancelledIsANetworkError() async {
    // Nothing cancels polls, so URLError.cancelled (e.g. an invalidated session) backs off.
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    let source = fakes.makeSource()
    fakes.enqueue(.status(200, body: okBody))
    _ = await source.poll(now: t0)
    fakes.enqueue(.failure(.cancelled))
    let first = await source.poll(now: t0.addingTimeInterval(300))
    #expect(first.usage.status == .stale("Network error"))
    #expect(first.nextPollIn == 30)
    fakes.enqueue(.failure(.cancelled))
    #expect(await source.poll(now: t0.addingTimeInterval(330)).nextPollIn == 60)
}

@Test func claudeUsageClockGoingBackwards() async {
    let fakes = UsageFakes()
    fakes.setToken("tok-a")
    let source = fakes.makeSource()

    // A 5 min rate-limit wait, then the clock jumps back a day: still at most 5 min.
    fakes.enqueue(.status(429))
    #expect(await source.poll(now: t0).nextPollIn == 300)
    let back = t0.addingTimeInterval(-86400)
    #expect(await source.poll(now: back).nextPollIn == 300)
    #expect(await source.poll(now: back.addingTimeInterval(100)).nextPollIn == 200)
    #expect(fakes.sent.count == 1)
    fakes.enqueue(.status(403))
    _ = await source.poll(now: back.addingTimeInterval(300))
    #expect(fakes.sent.count == 2)

    // A rejected token, then the clock jumps back a day: resent 5 min later, not a day later.
    let earlier = back.addingTimeInterval(-86400)
    _ = await source.poll(now: earlier)
    #expect(fakes.sent.count == 2)
    _ = await source.poll(now: earlier.addingTimeInterval(299))
    #expect(fakes.sent.count == 2)
    fakes.enqueue(.status(200, body: okBody))
    #expect(await source.poll(now: earlier.addingTimeInterval(300)).usage.status == .ok)
    #expect(fakes.sent.count == 3)
}

// MARK: - Redirects

/// Answers every request to `api.anthropic.com` with a 302 to `elsewhere.invalid`, which
/// answers 200; records the hosts it was asked for.
private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let hosts = Recorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        Self.hosts.record(url.host ?? "")
        if url.host == "elsewhere.invalid" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(okBody.utf8))
            client.urlProtocolDidFinishLoading(self)
            return
        }
        let target = URL(string: "https://elsewhere.invalid/steal")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": target.absoluteString])!
        var redirected = request
        redirected.url = target
        client.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        // Not followed: the redirect response is the final one.
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test func claudeUsageNeverFollowsRedirects() async throws {
    let config = ClaudeUsageAPI.sessionConfiguration()
    config.protocolClasses = [RedirectingProtocol.self]
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let request = ClaudeUsageAPI.request(token: "tok-redirect", userAgent: "ClaudeWatcher/test")

    // The stub really redirects: a plain session follows it.
    let (_, followed) = try await session.data(for: request)
    #expect((followed as? HTTPURLResponse)?.statusCode == 200)
    #expect(RedirectingProtocol.hosts.recorded == ["api.anthropic.com", "elsewhere.invalid"])

    // Ours doesn't, and the 302 is an HTTP error.
    await #expect(throws: ClaudeUsageError.http(302)) {
        try await ClaudeUsageAPI.fetch(token: "tok-redirect", userAgent: "ClaudeWatcher/test", now: t0,
                                       fetch: ClaudeUsageAPI.fetch(using: session))
    }
    #expect(RedirectingProtocol.hosts.recorded == ["api.anthropic.com", "elsewhere.invalid", "api.anthropic.com"])
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
