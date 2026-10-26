import Foundation
import Synchronization
import Testing
@testable import ClaudeWatcherCore

// MARK: - SemanticVersion

@Test func semanticVersionParses() throws {
    #expect(SemanticVersion("v0.3.1") == SemanticVersion(major: 0, minor: 3, patch: 1))
    #expect(SemanticVersion("V1") == SemanticVersion(major: 1))
    #expect(SemanticVersion("1.2") == SemanticVersion(major: 1, minor: 2))
    #expect(SemanticVersion(" 2.0.0 ")?.description == "2.0.0")
    let pre = try #require(SemanticVersion("1.0.0-rc.1+abc"))
    #expect(pre.prerelease == ["rc", "1"])
    #expect(pre.build == "abc")
    #expect(pre.isPrerelease)
    #expect(pre.description == "1.0.0-rc.1+abc")
    for bad in ["", "v", "x1.2.3", "1.2.3.4", "1..2", "1.2.a", "1.2.3-", "1.2.3+", "1.2.3-a..b", "-1.2.3", "1.2.3-ü"] {
        #expect(SemanticVersion(bad) == nil, "\(bad)")
    }
}

@Test func semanticVersionOrdersBySemver() throws {
    let ordered = ["0.1.0", "0.3.0", "0.3.1-alpha", "0.3.1-alpha.1", "0.3.1-alpha.beta", "0.3.1-beta",
                   "0.3.1-beta.2", "0.3.1-beta.11", "0.3.1-rc.1", "0.3.1", "0.10.0", "1.0.0"]
    let versions = try ordered.map { try #require(SemanticVersion($0)) }
    for (a, b) in zip(versions, versions.dropFirst()) {
        #expect(a < b, "\(a) < \(b)")
        #expect(!(b < a), "!(\(b) < \(a))")
    }
    #expect(SemanticVersion("1.0.0+a") == SemanticVersion("1.0.0+b"))
    #expect(!(SemanticVersion("1.0.0+a")! < SemanticVersion("1.0.0")!))
}

@Test func semanticVersionCodesAsString() throws {
    let data = try JSONEncoder().encode([SemanticVersion("v1.2.3-rc.1")!])
    #expect(String(decoding: data, as: UTF8.self) == #"["1.2.3-rc.1"]"#)
    #expect(try JSONDecoder().decode([SemanticVersion].self, from: data) == [SemanticVersion("1.2.3-rc.1")!])
}

// MARK: - AppVersionInfo

@Test func appVersionDisplayString() {
    #expect(AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "0.3.1", "CFBundleVersion": "114"])
        .displayString == "ClaudeWatcher 0.3.1 (114)")
    #expect(AppVersionInfo(shortVersion: "0.3.1", build: nil).displayString == "ClaudeWatcher 0.3.1")
    #expect(AppVersionInfo(shortVersion: "1.0", build: "1.0").displayString == "ClaudeWatcher 1.0")
    let none = AppVersionInfo(infoDictionary: nil)
    #expect(none.displayString == "ClaudeWatcher (development build)")
    #expect(none.version == nil)
    #expect(AppVersionInfo(shortVersion: "", build: "").shortVersion == nil)
    #expect(AppVersionInfo(shortVersion: "0.3.1", build: "114").version == SemanticVersion("0.3.1"))
}

// MARK: - Release decoding

private func releaseJSON(tag: String = "v0.4.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [String]? = nil) -> Data {
    let names = assets ?? ["ClaudeWatcher-\(tag.dropFirst()).dmg", "ClaudeWatcher-\(tag.dropFirst()).zip"]
    let assetJSON = names.map {
        #"{"name":"\#($0)","browser_download_url":"https://github.com/thegoldenmule/claude-watcher/releases/download/\#(tag)/\#($0)"}"#
    }.joined(separator: ",")
    return Data("""
    {"tag_name":"\(tag)","name":"ClaudeWatcher","draft":\(draft),"prerelease":\(prerelease),
     "html_url":"https://github.com/thegoldenmule/claude-watcher/releases/tag/\(tag)",
     "published_at":"2026-10-26T16:13:10Z","assets":[\(assetJSON)],"author":{"login":"x"}}
    """.utf8)
}

@Test func decodesGitHubRelease() throws {
    let release = try ReleaseInfo.decodeGitHubRelease(releaseJSON())
    #expect(release.tag == "v0.4.0")
    #expect(release.version == SemanticVersion("0.4.0"))
    #expect(release.pageURL.absoluteString == "https://github.com/thegoldenmule/claude-watcher/releases/tag/v0.4.0")
    #expect(release.dmgURL?.lastPathComponent == "ClaudeWatcher-0.4.0.dmg")
    #expect(release.publishedAt == Date(timeIntervalSince1970: 1_793_031_190))
    #expect(try ReleaseInfo.decodeGitHubRelease(releaseJSON(assets: ["notes.txt"])).dmgURL == nil)
}

@Test func rejectsDraftsPrereleasesAndJunk() {
    #expect(throws: ReleaseInfo.DecodeError.notARelease) { try ReleaseInfo.decodeGitHubRelease(releaseJSON(draft: true)) }
    #expect(throws: ReleaseInfo.DecodeError.notARelease) { try ReleaseInfo.decodeGitHubRelease(releaseJSON(prerelease: true)) }
    #expect(throws: ReleaseInfo.DecodeError.notARelease) { try ReleaseInfo.decodeGitHubRelease(releaseJSON(tag: "v0.5.0-rc.1")) }
    #expect(throws: ReleaseInfo.DecodeError.unrecognizedTag("nightly")) {
        try ReleaseInfo.decodeGitHubRelease(releaseJSON(tag: "nightly"))
    }
    #expect(throws: ReleaseInfo.DecodeError.malformed) { try ReleaseInfo.decodeGitHubRelease(Data("{}".utf8)) }
    #expect(throws: ReleaseInfo.DecodeError.malformed) { try ReleaseInfo.decodeGitHubRelease(Data("<html>".utf8)) }
}

// MARK: - UpdateChecker

/// Serves canned responses in order and records the requests it saw.
private final class FakeGitHub: @unchecked Sendable {
    struct Reply { var status: Int; var headers: [String: String] = [:]; var body = Data() }
    private let lock = NSLock()
    private var replies: [Result<Reply, URLError>]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Result<Reply, URLError>]) { self.replies = replies }

    var fetch: UpdateChecker.Fetch {
        { request in
            let reply: Result<Reply, URLError> = self.lock.withLock {
                self.requests.append(request)
                return self.replies.removeFirst()
            }
            let r = try reply.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1",
                                           headerFields: r.headers)!
            return (r.body, response)
        }
    }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func checkStoresReleaseAndRevalidatesWithETag() async throws {
    let etag = #"W/"bc7b""#
    let github = FakeGitHub([
        .success(.init(status: 200, headers: ["ETag": etag], body: releaseJSON())),
        .success(.init(status: 304, headers: ["ETag": etag])),
    ])
    let first = try await UpdateChecker.check(cache: UpdateCache(), now: { t0 }, fetch: github.fetch).get()
    #expect(first.latest?.version == SemanticVersion("0.4.0"))
    #expect(first.etag == etag)
    #expect(first.checkedAt == t0)

    let later = t0.addingTimeInterval(3600)
    let second = try await UpdateChecker.check(cache: first, userAgent: "ClaudeWatcher/0.3.1",
                                               now: { later }, fetch: github.fetch).get()
    #expect(second.latest == first.latest)
    #expect(second.etag == etag)
    #expect(second.checkedAt == later)

    let (r1, r2) = (github.requests[0], github.requests[1])
    #expect(r1.url == UpdateChecker.latestReleaseURL)
    #expect(r1.value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(r1.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(r2.value(forHTTPHeaderField: "If-None-Match") == etag)
    #expect(r2.value(forHTTPHeaderField: "User-Agent") == "ClaudeWatcher/0.3.1")
}

@Test func etagIsNotSentWithoutACachedRelease() {
    let request = UpdateChecker.request(cache: UpdateCache(etag: #""x""#, latest: nil), userAgent: "u")
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
}

@Test func checkFailuresKeepTheCache() async throws {
    let release = try ReleaseInfo.decodeGitHubRelease(releaseJSON())
    let cache = UpdateCache(etag: #""e""#, latest: release, checkedAt: t0)
    let reset = 1_800_003_600.0
    let github = FakeGitHub([
        .failure(URLError(.notConnectedToInternet)),
        .success(.init(status: 500)),
        .success(.init(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(Int(reset))"])),
        .success(.init(status: 429, headers: ["retry-after": "120"])),
        .success(.init(status: 403)),
        .success(.init(status: 200, body: releaseJSON(tag: "garbage"))),
        // A 304 without a cached release can't be answered.
        .success(.init(status: 304)),
    ])
    var failures: [UpdateCheckFailure] = []
    for i in 0..<7 {
        let base = i == 6 ? UpdateCache() : cache
        switch await UpdateChecker.check(cache: base, now: { t0 }, fetch: github.fetch) {
        case .success(let c): Issue.record("check \(i) succeeded: \(c)")
        case .failure(let f): failures.append(f)
        }
    }
    #expect(failures.allSatisfy { $0.at == t0 })
    #expect(failures[0].retryNotBefore == nil)
    #expect(failures[1].reason == "GitHub returned HTTP 500")
    #expect(failures[2].reason == "GitHub rate limit reached")
    #expect(failures[2].retryNotBefore == Date(timeIntervalSince1970: reset))
    #expect(failures[3].retryNotBefore == t0.addingTimeInterval(120))
    #expect(failures[4].reason == "GitHub returned HTTP 403")
    #expect(failures[4].retryNotBefore == nil)
    #expect(failures[5].reason == "unrecognized release tag garbage")
    #expect(failures[6].reason == "GitHub returned HTTP 304")
}

@Test func noPublishedReleaseIsASuccess() async throws {
    let github = FakeGitHub([.success(.init(status: 404))])
    let cache = try await UpdateChecker.check(cache: UpdateCache(), now: { t0 }, fetch: github.fetch).get()
    #expect(cache == UpdateCache(etag: nil, latest: nil, checkedAt: t0))
    #expect(UpdateMenuState.resolve(current: SemanticVersion("0.3.1"), cache: cache, isChecking: false,
                                    lastFailure: nil) == .upToDate)
}

@Test func cacheRoundTripsThroughJSON() throws {
    let cache = UpdateCache(etag: #"W/"e""#, latest: try ReleaseInfo.decodeGitHubRelease(releaseJSON()), checkedAt: t0)
    let data = try JSONEncoder().encode(cache)
    #expect(try JSONDecoder().decode(UpdateCache.self, from: data) == cache)
}

// MARK: - Schedule

@Test func scheduleChecksEvery12HoursAndRetriesFailuresSooner() {
    let checked = UpdateCache(checkedAt: t0)
    #expect(UpdateSchedule.isDue(cache: UpdateCache(), lastFailure: nil, now: t0))
    #expect(UpdateSchedule.nextCheck(cache: checked, lastFailure: nil) == t0.addingTimeInterval(12 * 3600))
    #expect(!UpdateSchedule.isDue(cache: checked, lastFailure: nil, now: t0.addingTimeInterval(11 * 3600)))
    #expect(UpdateSchedule.isDue(cache: checked, lastFailure: nil, now: t0.addingTimeInterval(13 * 3600)))

    let failedLater = UpdateCheckFailure(reason: "x", at: t0.addingTimeInterval(100))
    #expect(UpdateSchedule.nextCheck(cache: checked, lastFailure: failedLater) == t0.addingTimeInterval(100 + 1800))
    #expect(UpdateSchedule.nextCheck(cache: UpdateCache(), lastFailure: failedLater) == t0.addingTimeInterval(100 + 1800))
    // A failure older than the last success no longer matters.
    let failedEarlier = UpdateCheckFailure(reason: "x", at: t0.addingTimeInterval(-100))
    #expect(UpdateSchedule.nextCheck(cache: checked, lastFailure: failedEarlier) == t0.addingTimeInterval(12 * 3600))
    // A rate-limit reset later than the retry delay wins; an earlier one doesn't.
    let limited = UpdateCheckFailure(reason: "x", at: t0, retryNotBefore: t0.addingTimeInterval(3600))
    #expect(UpdateSchedule.nextCheck(cache: UpdateCache(), lastFailure: limited) == t0.addingTimeInterval(3600))
    let soon = UpdateCheckFailure(reason: "x", at: t0, retryNotBefore: t0.addingTimeInterval(60))
    #expect(UpdateSchedule.nextCheck(cache: UpdateCache(), lastFailure: soon) == t0.addingTimeInterval(1800))
}

@Test func launchChecksUnlessTheCacheIsFresh() {
    #expect(UpdateSchedule.isDueAtLaunch(cache: UpdateCache(), now: t0))
    let checked = UpdateCache(checkedAt: t0)
    #expect(!UpdateSchedule.isDueAtLaunch(cache: checked, now: t0.addingTimeInterval(59 * 60)))
    #expect(UpdateSchedule.isDueAtLaunch(cache: checked, now: t0.addingTimeInterval(61 * 60)))
    #expect(UpdateSchedule.isDueAtLaunch(cache: checked, now: t0.addingTimeInterval(-60)))
}

// MARK: - Menu state

@Test func menuStateComparesRunningVersionWithLatestRelease() throws {
    let latest = try ReleaseInfo.decodeGitHubRelease(releaseJSON(tag: "v0.3.1"))
    let cache = UpdateCache(latest: latest, checkedAt: t0)
    func state(_ current: String?, checking: Bool = false, failure: UpdateCheckFailure? = nil,
               cache: UpdateCache = cache) -> UpdateMenuState {
        UpdateMenuState.resolve(current: current.flatMap(SemanticVersion.init), cache: cache,
                                isChecking: checking, lastFailure: failure)
    }
    #expect(state("0.3.0") == .available(latest))
    #expect(state("0.3.1-rc.1") == .available(latest))
    #expect(state("0.3.1") == .upToDate)
    #expect(state("0.3.1", checking: true) == .checking)
    // A dev build after a release, or a dry run's suffixed version, is never told to "update".
    #expect(state("0.4.0") == .upToDate)
    #expect(state("0.4.0-rc1") == .upToDate)
    #expect(state(nil) == .unversioned)
    #expect(state("not-a-version") == .unversioned)
    #expect(state("0.3.1", cache: UpdateCache()) == .notChecked)
    #expect(state("0.3.1", checking: true, cache: UpdateCache()) == .checking)
}

@Test func knownUpdateSurvivesLaterFailures() throws {
    let latest = try ReleaseInfo.decodeGitHubRelease(releaseJSON(tag: "v0.4.0"))
    let cache = UpdateCache(latest: latest, checkedAt: t0)
    let failure = UpdateCheckFailure(reason: "offline", at: t0.addingTimeInterval(60))
    let current = SemanticVersion("0.3.1")
    #expect(UpdateMenuState.resolve(current: current, cache: cache, isChecking: true, lastFailure: failure)
        == .available(latest))
    #expect(UpdateMenuState.resolve(current: current, cache: cache, isChecking: false, lastFailure: failure)
        == .available(latest))
    // Without a known update, the newest failure shows, unless a later success superseded it.
    let current040 = SemanticVersion("0.4.0")
    #expect(UpdateMenuState.resolve(current: current040, cache: cache, isChecking: false, lastFailure: failure)
        == .failed(reason: "offline"))
    let old = UpdateCheckFailure(reason: "offline", at: t0.addingTimeInterval(-60))
    #expect(UpdateMenuState.resolve(current: current040, cache: cache, isChecking: false, lastFailure: old)
        == .upToDate)
    // A cached pre-release (shouldn't come from `latest`) is never offered.
    var pre = latest
    pre.version = SemanticVersion("0.5.0-rc.1")!
    #expect(UpdateMenuState.resolve(current: current040, cache: UpdateCache(latest: pre, checkedAt: t0),
                                    isChecking: false, lastFailure: nil) == .upToDate)
}

// MARK: - Live check (CW_LIVE=1 swift test --filter liveUpdateCheck)

@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE"] == "1"))
func liveUpdateCheck() async throws {
    // `Bundle.main` is the test runner: read the app's version from the repo's Info.plist.
    let plist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Info.plist")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    let app = AppVersionInfo(infoDictionary: info)
    let result = await UpdateChecker.check(cache: UpdateCache(), userAgent: "ClaudeWatcher/\(app.shortVersion ?? "dev")")
    switch result {
    case .failure(let failure):
        print("LIVE: update check failed: \(failure.reason) retryNotBefore=\(failure.retryNotBefore.map { "\($0)" } ?? "nil")")
        Issue.record("live update check failed: \(failure.reason)")
    case .success(let cache):
        let latest = cache.latest
        print("LIVE: running \(app.displayString); latest=\(latest?.tag ?? "none") version=\(latest.map { "\($0.version)" } ?? "-")")
        print("LIVE: page=\(latest?.pageURL.absoluteString ?? "-") dmg=\(latest?.dmgURL?.absoluteString ?? "-")")
        print("LIVE: published=\(latest?.publishedAt.map { "\($0)" } ?? "-") etag=\(cache.etag ?? "nil")")
        // Revalidate: GitHub should answer 304 to our ETag.
        let statuses = Mutex<[Int]>([])
        let again = await UpdateChecker.check(cache: cache, fetch: { request in
            let (data, response) = try await UpdateChecker.defaultFetch(request)
            statuses.withLock { $0.append((response as? HTTPURLResponse)?.statusCode ?? -1) }
            return (data, response)
        })
        let revalidated = (try? again.get()).map { $0.latest == latest ? "same release" : "changed" } ?? "failed"
        print("LIVE: revalidation HTTP \(statuses.withLock { $0 }), \(revalidated)")
        let state = UpdateMenuState.resolve(current: app.version, cache: cache, isChecking: false, lastFailure: nil)
        print("LIVE: menu state \(state)")
    }
}
