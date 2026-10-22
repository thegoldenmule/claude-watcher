import AppKit
import Foundation
import Testing
@testable import ClaudeWatcherCore

private func session(title: String, cwd: String, terminal: TerminalKind = .ghostty,
                     tty: String? = nil, ghosttyID: String? = nil) -> ClaudeSession {
    ClaudeSession(id: "s", pid: 1, cwd: cwd, title: title, tty: tty, terminal: terminal,
                  ghosttyTerminalID: ghosttyID, startedAt: .distantPast, updatedAt: .distantPast)
}

private func term(_ id: String, _ name: String, _ wd: String) -> GhosttyTerminalInfo {
    GhosttyTerminalInfo(id: id, name: name, workingDirectory: wd)
}

// MARK: - Glyph stripping

@Test(arguments: [
    ("✳ Claude Code", "Claude Code"),
    ("◐ Fix the build", "Fix the build"),
    ("◓ Fix the build", "Fix the build"),
    ("◑  Fix the build ", "Fix the build"),
    ("◒ x", "x"),
    ("· Thinking", "Thinking"),
    ("✢ Thinking", "Thinking"),
    ("✶ Thinking", "Thinking"),
    ("✻ Thinking", "Thinking"),
    ("✽ Thinking", "Thinking"),
    ("Plain title", "Plain title"),
    ("[WIP] thing", "[WIP] thing"),        // punctuation not followed by space is kept
    ("(scratch)", "(scratch)"),
    ("…/projects/foo", "…/projects/foo"),
    ("✳", "✳"),                            // glyph alone: nothing to strip to
    ("", ""),
    ("2 tasks", "2 tasks"),
])
func stripsTitleGlyph(input: String, expected: String) {
    #expect(GhosttyMatcher.stripTitleGlyph(input) == expected)
}

@Test func normalizesPaths() {
    #expect(GhosttyMatcher.normalizePath("/Users/me/proj/") == "/Users/me/proj")
    #expect(GhosttyMatcher.normalizePath("/private/tmp/x") == "/tmp/x")
    #expect(GhosttyMatcher.normalizePath("/private/var/folders/a") == "/var/folders/a")
    #expect(GhosttyMatcher.normalizePath("/privateer") == "/privateer")
    #expect(GhosttyMatcher.normalizePath("/") == "/")
    #expect(GhosttyMatcher.normalizePath("file:///Users/me/proj/") == "/Users/me/proj")
    #expect(GhosttyMatcher.normalizePath("") == "")
}

// MARK: - Matcher

@Test func uniqueTitleAndCwdMatch() {
    let terms = [
        term("A", "✳ Fix build", "/p/one"),
        term("B", "◐ Fix build", "/p/two"),
        term("C", "zsh", "/p/one"),
    ]
    #expect(GhosttyMatcher.match(session: session(title: "Fix build", cwd: "/p/one/"), in: terms)
            == .unique(terminalID: "A"))
}

@Test func titleAndCwdAmbiguous() {
    let terms = [
        term("A", "✳ Claude Code", "/p/one"),
        term("B", "✳ Claude Code", "/p/one"),
        term("C", "✳ Claude Code", "/p/two"),
    ]
    guard case .ambiguous(let ids, _) = GhosttyMatcher.match(session: session(title: "Claude Code", cwd: "/p/one"), in: terms)
    else { Issue.record("expected ambiguous"); return }
    #expect(ids == ["A", "B"])
}

@Test func uniqueTitleWithDifferentCwd() {
    let terms = [term("A", "✶ Refactor parser", "/elsewhere"), term("B", "zsh", "/p")]
    #expect(GhosttyMatcher.match(session: session(title: "Refactor parser", cwd: "/p"), in: terms)
            == .unique(terminalID: "A"))
}

@Test func titleOnlyAmbiguous() {
    let terms = [term("A", "✳ Claude Code", "/x"), term("B", "✳ Claude Code", "/y")]
    guard case .ambiguous(let ids, _) = GhosttyMatcher.match(session: session(title: "Claude Code", cwd: "/p"), in: terms)
    else { Issue.record("expected ambiguous"); return }
    #expect(ids == ["A", "B"])
}

@Test func cwdOnlyIsAmbiguousEvenWhenSingle() {
    let terms = [term("A", "zsh", "/p"), term("B", "vim", "/q")]
    guard case .ambiguous(let ids, let reason) = GhosttyMatcher.match(session: session(title: "My task", cwd: "/p"), in: terms)
    else { Issue.record("expected ambiguous"); return }
    #expect(ids == ["A"])
    #expect(reason.contains("directory"))
}

@Test func noMatch() {
    let terms = [term("A", "zsh", "/q")]
    #expect(GhosttyMatcher.match(session: session(title: "My task", cwd: "/p"), in: terms) == .notFound)
    #expect(GhosttyMatcher.match(session: session(title: "x", cwd: "/p"), in: []) == .notFound)
}

@Test func sessionTitleWithGlyphIsAlsoStripped() {
    let terms = [term("A", "◐ Task", "/p")]
    #expect(GhosttyMatcher.match(session: session(title: "✳ Task", cwd: "/p"), in: terms) == .unique(terminalID: "A"))
}

// MARK: - Listing parser

@Test func parsesListing() {
    let us = "\u{1F}", rs = "\u{1E}"
    let out = "ID1\(us)✳ Claude Code\(us)/p/one\(rs)ID2\(us)name, with comma\(us)\(rs)ID3\(us)x\(us)missing value\(rs)"
    let parsed = GhosttyMatcher.parseListing(out)
    #expect(parsed == [
        term("ID1", "✳ Claude Code", "/p/one"),
        term("ID2", "name, with comma", ""),
        term("ID3", "x", ""),
    ])
}

@Test func parsesListingSkipsMalformed() {
    let us = "\u{1F}", rs = "\u{1E}"
    #expect(GhosttyMatcher.parseListing("") == [])
    #expect(GhosttyMatcher.parseListing("garbage\(rs)\(us)name\(us)/p\(rs)ID\(us)n\(rs)") == [term("ID", "n", "")])
}

// MARK: - Escaping / script generation

@Test func quotesAppleScriptStrings() {
    #expect(AppleScriptSource.quoted("plain") == "\"plain\"")
    #expect(AppleScriptSource.quoted("a\"b") == "\"a\\\"b\"")
    #expect(AppleScriptSource.quoted("a\\b") == "\"a\\\\b\"")
    #expect(AppleScriptSource.quoted("\" & (do shell script \"x\") & \"") == "\"\\\" & (do shell script \\\"x\\\") & \\\"\"")
    #expect(AppleScriptSource.quoted("l1\nl2\tt") == "\"l1\\nl2\\tt\"")
    #expect(AppleScriptSource.quoted("bell\u{07}") == "\"bell\"")
    #expect(AppleScriptSource.quoted("✳ ünï") == "\"✳ ünï\"")
}

/// NSAppleScript isn't thread-safe, so tests that use it directly run serially.
@Suite(.serialized) @MainActor struct AppleScriptCompileTests {
    @Test func quotedStringsRoundTripThroughAppleScript() throws {
        for value in ["a\"b", "back\\slash", "\" & \"injected", "tab\there", "✳ Claude Code"] {
            let script = try #require(NSAppleScript(source: "return \(AppleScriptSource.quoted(value))"))
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            #expect(err == nil)
            #expect(result.stringValue == value)
        }
    }

    @Test func generatedScriptsCompile() throws {
        let scripts = [
            GhosttyScripting.listScript,
            GhosttyScripting.focusScript(terminalID: "0FD9735C-\"evil\\"),
            AppleTerminalFocuser.focusScript(tty: "ttys001"),
            GhosttyScripting.ttyLookupScript(tty: "/dev/ttys001"),
            GhosttyScripting.nonceLookupScript(nonce: "CW-1-a"),
        ]
        for source in scripts {
            let script = try #require(NSAppleScript(source: source))
            var err: NSDictionary?
            let ok = script.compileAndReturnError(&err)
            #expect(ok, "\(String(describing: err))")
        }
    }
}

@Test func normalizesTTY() {
    #expect(AppleTerminalFocuser.normalizeTTY("ttys001") == "/dev/ttys001")
    #expect(AppleTerminalFocuser.normalizeTTY("/dev/ttys001") == "/dev/ttys001")
    #expect(AppleTerminalFocuser.normalizeTTY("") == "")
}

@Test func mapsAppleScriptErrors() {
    #expect(AppleScriptError.from(code: -1743, message: "", app: "Ghostty") == .notPermitted(app: "Ghostty"))
    #expect(AppleScriptError.from(code: -1712, message: "", app: "Ghostty") == .timedOut)
    #expect(AppleScriptError.from(code: -600, message: "", app: "Ghostty") == .appNotRunning)
    #expect(AppleScriptError.notPermitted(app: "Ghostty").userMessage(app: "Ghostty").contains("Automation"))
    #expect(OsascriptRunner.errorCode(in: "51:55: execution error: Not authorized. (-1743)\n") == -1743)
}

// MARK: - Focuser flow with a fake script runner

private final class FakeRunner: AppleScriptExecuting, @unchecked Sendable {
    let lock = NSLock()
    var scripts: [String] = []
    let respond: @Sendable (String) -> Result<String, AppleScriptError>
    init(_ respond: @escaping @Sendable (String) -> Result<String, AppleScriptError>) { self.respond = respond }
    func run(_ source: String, app: String, timeout: Duration) async -> Result<String, AppleScriptError> {
        lock.withLock { scripts.append(source) }
        return respond(source)
    }
}

@Test func ghosttyScriptingParsesAndFocuses() async throws {
    let fake = FakeRunner { src in
        if src.contains("every terminal") { return .success("A\u{1F}✳ T\u{1F}/p\u{1E}") }
        return .success(src.contains("\"A\"") ? "ok" : "notfound")
    }
    let g = GhosttyScripting(runner: fake)
    #expect(try await g.listTerminals() == [term("A", "✳ T", "/p")])
    #expect(try await g.focus(terminalID: "A") == .focused)
    #expect(try await g.focus(terminalID: "B") == .notFound)
}

@Test func resolverChainFallsThroughStaleID() async throws {
    let fake = FakeRunner { src in
        if src.contains("every terminal") { return .success("A\u{1F}✳ T\u{1F}/p\u{1E}") }
        return .success("notfound")
    }
    let g = GhosttyScripting(runner: fake)
    let s = session(title: "T", cwd: "/p", ghosttyID: "STALE")
    #expect(try await KnownTerminalIDResolver().resolve(s, ghostty: g) == .unique(terminalID: "STALE"))
    #expect(try await TitleCwdResolver().resolve(s, ghostty: g) == .unique(terminalID: "A"))
}

@Test func permissionErrorPropagates() async {
    let fake = FakeRunner { _ in .failure(.notPermitted(app: "Ghostty")) }
    do {
        _ = try await GhosttyScripting(runner: fake).listTerminals()
        Issue.record("expected throw")
    } catch {
        #expect(error == .notPermitted(app: "Ghostty"))
    }
}

@Test func focusMapsStaleZombie() async throws {
    let g = GhosttyScripting(runner: FakeRunner { _ in .success("stale") })
    #expect(try await g.focus(terminalID: "Z") == .stale)
}

@Test func ttyLookupUnsupportedReturnsNil() async throws {
    let unsupported = GhosttyScripting(runner: FakeRunner { _ in .failure(.scriptError(code: -2753, message: "The variable tty is not defined.")) })
    #expect(try await unsupported.terminalIDs(forTTY: "/dev/ttys001") == nil)
    let supported = GhosttyScripting(runner: FakeRunner { _ in .success("X\u{1E}") })
    #expect(try await supported.terminalIDs(forTTY: "/dev/ttys001") == ["X"])
    let denied = GhosttyScripting(runner: FakeRunner { _ in .failure(.notPermitted(app: "Ghostty")) })
    await #expect(throws: AppleScriptError.notPermitted(app: "Ghostty")) {
        _ = try await denied.terminalIDs(forTTY: "/dev/ttys001")
    }
}

private struct FixedResolver: GhosttyTerminalResolver {
    let name: String
    let resolution: GhosttyResolution
    var cachesResult: Bool = false
    func resolve(_ session: ClaudeSession, ghostty: GhosttyScripting) async throws(AppleScriptError) -> GhosttyResolution {
        resolution
    }
}

/// Only runs the `.focused` paths, so it never activates the real Ghostty. Needs Ghostty running
/// (the focuser checks NSRunningApplication first, and never launches it).
@Test(.enabled(if: !NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").isEmpty))
func focuserFallsThroughStaleAndCaches() async {
    let fake = FakeRunner { src in
        if src.contains("\"ZOMBIE\"") { return .success("stale") }
        if src.contains("\"GONE\"") { return .success("notfound") }
        return .success("ok")
    }
    let cache = GhosttyTerminalCache()
    let focuser = GhosttyFocuser(
        resolvers: [
            FixedResolver(name: "hook", resolution: .unique(terminalID: "GONE")),
            CachedTerminalResolver(cache: cache),
            FixedResolver(name: "zombie", resolution: .unique(terminalID: "ZOMBIE")),
            FixedResolver(name: "probe", resolution: .unique(terminalID: "LIVE"), cachesResult: true),
        ],
        ghostty: GhosttyScripting(runner: fake), cache: cache)
    let s = session(title: "T", cwd: "/p", tty: "/dev/ttys999")
    let first = await focuser.focusWithReport(s)
    #expect(first == GhosttyFocusReport(result: .focused, resolver: "probe", terminalID: "LIVE"))
    #expect(await cache.terminalID(pid: s.pid, tty: s.tty) == "LIVE")
    let second = await focuser.focusWithReport(s)
    #expect(second.resolver == "cache")
    #expect(await cache.terminalID(pid: s.pid, tty: "/dev/ttys000") == nil)  // tty changed → evicted
}

// MARK: - OSC 7 probe (pure parts)

@Test func osc7Nonce() {
    #expect(OSC7Probe.makeNonce(pid: 42, random: 0xBEEF) == "CW-42-000000000000beef")
    #expect(OSC7Probe.makeNonce(pid: 42, random: .max) == "CW-42-ffffffffffffffff")
    let a = OSC7Probe.makeNonce(pid: 42), b = OSC7Probe.makeNonce(pid: 42)
    #expect(a != b)
    #expect(a.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
}

@Test func osc7Sequences() {
    #expect(OSC7Probe.probeSequence(host: "mac.local", nonce: "CW-1-a")
            == "\u{1B}]7;file://mac.local/tmp/CW-1-a\u{07}")
    #expect(OSC7Probe.restoreSequence(host: "mac.local", cwd: "/Users/me/My Project")
            == "\u{1B}]7;file://mac.local/Users/me/My%20Project\u{07}")
    #expect(OSC7Probe.percentEncodePath("/a/b%c#d?e;f") == "/a/b%25c%23d%3Fe%3Bf")
    #expect(OSC7Probe.percentEncodePath("/x\u{07}\u{1B}y") == "/x%07%1By")
    #expect(OSC7Probe.percentEncodePath("/ünï/✳") == "/%C3%BCn%C3%AF/%E2%9C%B3")
}

@Test func osc7TTYValidation() {
    #expect(OSC7Probe.isWritableTTYPath("/dev/ttys001"))
    #expect(!OSC7Probe.isWritableTTYPath("/dev/ttys"))
    #expect(!OSC7Probe.isWritableTTYPath("/dev/ttys001/../disk0"))
    #expect(!OSC7Probe.isWritableTTYPath("/dev/console"))
    #expect(!OSC7Probe.isWritableTTYPath("ttys001"))
    #expect(!OSC7Probe.isWritableTTYPath("/tmp/ttys001"))
}

@Test func osc7HostName() {
    #expect(!OSC7Probe.hostName().isEmpty)
}

// MARK: - OSC 7 probe writes and restore

/// Records every write; `accept` decides how many bytes of each call "go out".
private final class FakeTTY: @unchecked Sendable {
    let lock = NSLock()
    var calls: [[UInt8]] = []
    var accept: ([UInt8], Int) -> Int  // (bytes, call index) -> written
    init(accept: @escaping ([UInt8], Int) -> Int = { bytes, _ in bytes.count }) { self.accept = accept }

    var strings: [String] { lock.withLock { calls.map { String(decoding: $0, as: UTF8.self) } } }

    func io(controlling: Bool = true, lockDirectory: URL) -> OSC7ProbeIO {
        OSC7ProbeIO(
            isControllingTTY: { _, _ in controlling },
            write: { bytes, _ in
                self.lock.withLock {
                    let n = self.accept(bytes, self.calls.count)
                    self.calls.append(bytes)
                    return n
                }
            },
            hostName: { "mac.local" },
            lock: OSC7ProbeLock(directory: lockDirectory, maxWait: .milliseconds(100)))
    }
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-probe-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let probeTTY = "/dev/ttys999"
private let restoreSeq = "\u{1B}]7;file://mac.local/Users/me/p\u{07}"

private func nonceRunner(_ id: String) -> FakeRunner {
    FakeRunner { src in
        let nonce = src.components(separatedBy: "\"").first { $0.hasPrefix("CW-") } ?? "?"
        return .success("\(id)\u{1F}\u{1F}/tmp/\(nonce)\u{1E}")
    }
}

@Test func osc7ProbeWritesNonceThenRestoresAndReleasesLock() async throws {
    let dir = tempDir(), tty = FakeTTY()
    let id = await OSC7ProbeCoordinator.runProbe(tty: probeTTY, pid: 42, restoreCwd: "/Users/me/p",
                                                 ghostty: GhosttyScripting(runner: nonceRunner("T1")),
                                                 io: tty.io(lockDirectory: dir))
    #expect(try id.get() == "T1")
    #expect(tty.strings.count == 2)
    #expect(tty.strings.first?.hasPrefix("\u{1B}]7;file://mac.local/tmp/CW-42-") == true)
    #expect(tty.strings.last == restoreSeq)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)  // lock released
}

@Test func osc7ProbeSkipsWhenNotControllingTTY() async throws {
    let dir = tempDir(), tty = FakeTTY(), fake = nonceRunner("T1")
    let id = await OSC7ProbeCoordinator.runProbe(tty: probeTTY, pid: 42, restoreCwd: "/Users/me/p",
                                                 ghostty: GhosttyScripting(runner: fake),
                                                 io: tty.io(controlling: false, lockDirectory: dir))
    #expect(try id.get() == nil)
    #expect(tty.calls.isEmpty)  // neither nonce nor restore written
    #expect(fake.scripts.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func osc7ProbeWritesNothingMoreWhenNonceWriteFails() async throws {
    let tty = FakeTTY { _, _ in 0 }, fake = nonceRunner("T1")
    let id = await OSC7ProbeCoordinator.runProbe(tty: probeTTY, pid: 42, restoreCwd: "/Users/me/p",
                                                 ghostty: GhosttyScripting(runner: fake), io: tty.io(lockDirectory: tempDir()))
    #expect(try id.get() == nil)
    #expect(tty.calls.count == 1)  // nothing went out, so nothing to terminate or restore
    #expect(fake.scripts.isEmpty)
}

@Test func osc7ProbeTerminatesPartialNonceAndRestores() async throws {
    let tty = FakeTTY { bytes, call in call == 0 ? 5 : bytes.count }, fake = nonceRunner("T1")
    let id = await OSC7ProbeCoordinator.runProbe(tty: probeTTY, pid: 42, restoreCwd: "/Users/me/p",
                                                 ghostty: GhosttyScripting(runner: fake), io: tty.io(lockDirectory: tempDir()))
    #expect(try id.get() == nil)
    #expect(Array(tty.strings.dropFirst()) == ["\u{07}", restoreSeq])
    #expect(fake.scripts.isEmpty)  // no lookup for an incomplete nonce
}

@Test func osc7ProbeRestoreFailureIsReportedAndTerminated() async throws {
    // Full nonce, lookup succeeds, restore only partly written: BEL terminates it.
    let tty = FakeTTY { bytes, call in call == 1 ? 3 : bytes.count }
    let id = await OSC7ProbeCoordinator.runProbe(tty: probeTTY, pid: 42, restoreCwd: "/Users/me/p",
                                                 ghostty: GhosttyScripting(runner: nonceRunner("T1")),
                                                 io: tty.io(lockDirectory: tempDir()))
    #expect(try id.get() == "T1")
    #expect(Array(tty.strings.dropFirst()) == [restoreSeq, "\u{07}"])

    let failing = FakeTTY { _, _ in 0 }
    #expect(!OSC7ProbeCoordinator.restore(tty: probeTTY, host: "mac.local", cwd: "/Users/me/p",
                                          nonceTerminated: true, io: failing.io(lockDirectory: tempDir())))
    #expect(failing.strings == [restoreSeq])  // nothing went out: no stray BEL
}

@Test func osc7ProbeRestoresAfterLookupError() async throws {
    let tty = FakeTTY()
    let id = await OSC7ProbeCoordinator.runProbe(tty: probeTTY, pid: 42, restoreCwd: "/Users/me/p",
                                                 ghostty: GhosttyScripting(runner: FakeRunner { _ in .failure(.timedOut) }),
                                                 io: tty.io(lockDirectory: tempDir()))
    #expect(throws: AppleScriptError.self) { try id.get() }
    #expect(tty.strings.last == restoreSeq)
}

@Test func osc7ProbeSkipsWhileAnotherProcessHoldsTheLock() async throws {
    let dir = tempDir(), tty = FakeTTY(), fake = nonceRunner("T1")
    let other = try #require(await OSC7ProbeLock(directory: dir).acquire(tty: probeTTY))
    defer { other.release() }
    let id = await OSC7ProbeCoordinator.runProbe(tty: probeTTY, pid: 42, restoreCwd: "/Users/me/p",
                                                 ghostty: GhosttyScripting(runner: fake), io: tty.io(lockDirectory: dir))
    #expect(try id.get() == nil)
    #expect(tty.calls.isEmpty)
    #expect(fake.scripts.isEmpty)
}

/// A FIFO whose buffer is full stands in for a flow-controlled (XOFF) tty.
@Test func osc7WriteAllRetriesUntilDrainedAndIsBounded() async throws {
    let path = tempDir().appendingPathComponent("fifo").path
    #expect(mkfifo(path, 0o600) == 0)
    let rfd = open(path, O_RDONLY | O_NONBLOCK)
    let wfd = open(path, O_WRONLY | O_NONBLOCK)
    #expect(rfd >= 0 && wfd >= 0)
    defer { close(rfd); close(wfd) }
    let chunk = [UInt8](repeating: 0x41, count: 4096)
    while chunk.withUnsafeBytes({ Darwin.write(wfd, $0.baseAddress, $0.count) }) > 0 {}

    // Full and nobody reading: gives up after the timeout instead of hanging.
    let start = ContinuousClock.now
    #expect(OSC7Probe.writeAll(Array("hello".utf8), to: wfd, timeout: .milliseconds(50)) == 0)
    let elapsed = ContinuousClock.now - start
    #expect(elapsed >= .milliseconds(40) && elapsed < .milliseconds(500))

    // A reader drains it shortly after: the whole payload goes out.
    let drainFD = rfd
    let drainer = Task.detached {
        try? await Task.sleep(for: .milliseconds(30))
        var buf = [UInt8](repeating: 0, count: 65536)
        _ = buf.withUnsafeMutableBytes { read(drainFD, $0.baseAddress, $0.count) }
    }
    let payload = Array(OSC7Probe.restoreSequence(host: "mac.local", cwd: "/Users/me/p").utf8)
    #expect(OSC7Probe.writeAll(payload, to: wfd, timeout: .milliseconds(200)) == payload.count)
    await drainer.value
}

@Test func osc7WriteRejectsNonTTYPaths() {
    #expect(OSC7Probe.write(Array("x".utf8), toTTY: "/tmp/ttys001") == 0)
    #expect(!OSC7Probe.write("x", toTTY: "/dev/console"))
}

// MARK: - Cross-process probe lock

@Test func probeLockAcquireRelease() async throws {
    let dir = tempDir().appendingPathComponent("hook-state")  // created on demand
    let lock = OSC7ProbeLock(directory: dir)
    #expect(lock.lockPath(forTTY: "/dev/ttys001") == dir.appendingPathComponent(".probe-ttys001.lock").path)
    #expect(lock.lockPath(forTTY: "/dev/tty s;x") == nil)

    let held = try #require(await lock.acquire(tty: "/dev/ttys001"))
    let owner = try String(contentsOfFile: held.path + "/owner", encoding: .utf8)
    #expect(owner == "\(getpid()) \(held.token)\n")
    guard case .busy = lock.tryAcquire(tty: "/dev/ttys001") else { Issue.record("expected busy"); return }
    guard case .acquired(let other) = lock.tryAcquire(tty: "/dev/ttys002") else { Issue.record("per-tty"); return }
    other.release()

    #expect(held.release())
    #expect(!FileManager.default.fileExists(atPath: held.path))
    let again = try #require(await lock.acquire(tty: "/dev/ttys001"))
    #expect(again.token != held.token)
    again.release()
}

@Test func probeLockWaitsBoundedThenSkips() async throws {
    let dir = tempDir()
    let lock = OSC7ProbeLock(directory: dir, maxWait: .milliseconds(150), pollInterval: .milliseconds(25))
    let held = try #require(await lock.acquire(tty: "/dev/ttys001"))

    let start = ContinuousClock.now
    #expect(await lock.acquire(tty: "/dev/ttys001") == nil)
    let elapsed = ContinuousClock.now - start
    #expect(elapsed >= .milliseconds(150) && elapsed < .seconds(1))

    // Released mid-wait: the waiter gets it.
    let releaser = Task.detached { try? await Task.sleep(for: .milliseconds(50)); held.release() }
    let waited = await lock.acquire(tty: "/dev/ttys001")
    #expect(waited != nil)
    waited?.release()
    await releaser.value
}

@Test func probeLockBreaksStaleLockByRename() async throws {
    let dir = tempDir()
    let lock = OSC7ProbeLock(directory: dir, maxWait: .zero)
    let path = try #require(lock.lockPath(forTTY: "/dev/ttys001"))
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try "999 deadbeef\n".write(toFile: path + "/owner", atomically: false, encoding: .utf8)

    // Fresh lock held by someone else: busy.
    #expect(await lock.acquire(tty: "/dev/ttys001") == nil)

    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -20)], ofItemAtPath: path)
    let held = try #require(await lock.acquire(tty: "/dev/ttys001"))
    #expect(held.path == path)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names == [".probe-ttys001.lock"])  // the renamed-aside stale lock was removed
    #expect(held.release())
}

@Test func probeLockReleaseRequiresOurToken() async throws {
    let dir = tempDir()
    let lock = OSC7ProbeLock(directory: dir)
    let held = try #require(await lock.acquire(tty: "/dev/ttys001"))
    // Broken as stale and re-taken by another process meanwhile.
    try "123 0123456789abcdef\n".write(toFile: held.path + "/owner", atomically: false, encoding: .utf8)
    #expect(!held.release())
    #expect(FileManager.default.fileExists(atPath: held.path + "/owner"))
    #expect(OSC7ProbeLock.ownerToken("123 0123456789abcdef\n") == "0123456789abcdef")
    #expect(OSC7ProbeLock.ownerToken("") == nil)
}

// MARK: - Nonce lookup polling

/// A nonce-lookup reply: `id US US wd RS` per terminal.
private func nonceReply(_ pairs: [(String, String)]) -> String {
    pairs.map { "\($0.0)\u{1F}\u{1F}\($0.1)\u{1E}" }.joined()
}

@Test func noGeneratedScriptDelays() {
    let scripts = [
        GhosttyScripting.listScript,
        GhosttyScripting.focusScript(terminalID: "X"),
        GhosttyScripting.ttyLookupScript(tty: "/dev/ttys001"),
        GhosttyScripting.nonceLookupScript(nonce: "CW-1-a"),
        AppleTerminalFocuser.focusScript(tty: "ttys001"),
    ]
    for source in scripts {
        #expect(!source.contains("delay"))
        #expect(source.contains("with timeout of 3 seconds"))
    }
}

@Test func noncePollingRunsShortScriptsUntilFirstUniqueHit() async throws {
    let nonce = "CW-7-00000000000000ab"
    let calls = Counter()
    let fake = FakeRunner { _ in
        calls.next() < 3 ? .success("") : .success(nonceReply([("T1", "/tmp/\(nonce)")]))
    }
    let g = GhosttyScripting(runner: fake)
    let ids = try await g.terminalIDs(withNonceWorkingDirectory: nonce, interval: .milliseconds(1))
    #expect(ids == ["T1"])
    let scripts = fake.lock.withLock { fake.scripts }
    #expect(scripts.count == 4)  // stopped at the first hit, not all 6 attempts
    #expect(scripts.allSatisfy { !$0.contains("delay") && !$0.contains(" times") })
    #expect(scripts.allSatisfy { $0.contains("\"\(nonce)\"") })
}

@Test func noncePollingStopsImmediatelyOnHitAndGivesUpAfterBudget() async throws {
    let nonce = "CW-7-00000000000000ab"
    let hit = FakeRunner { _ in .success(nonceReply([("T1", "/private/tmp/\(nonce)/")])) }
    #expect(try await GhosttyScripting(runner: hit).terminalIDs(withNonceWorkingDirectory: nonce) == ["T1"])
    #expect(hit.lock.withLock { hit.scripts.count } == 1)

    let miss = FakeRunner { _ in .success("") }
    #expect(try await GhosttyScripting(runner: miss).terminalIDs(withNonceWorkingDirectory: nonce,
                                                                   interval: .milliseconds(1)) == [])
    #expect(miss.lock.withLock { miss.scripts.count } == 6)  // same budget as the old in-script loop

    let denied = FakeRunner { _ in .failure(.notPermitted(app: "Ghostty")) }
    await #expect(throws: AppleScriptError.notPermitted(app: "Ghostty")) {
        _ = try await GhosttyScripting(runner: denied).terminalIDs(withNonceWorkingDirectory: nonce)
    }
    #expect(denied.lock.withLock { denied.scripts.count } == 1)
}

@Test func nonceMatchIsDelimitedAgainstPrefixCollisions() {
    let nonce = "CW-7-00000000000000ab"
    // A longer nonce containing ours, a deeper path, and a sibling suffix never match.
    let out = nonceReply([
        ("LONGER", "/tmp/\(nonce)0"),
        ("DEEPER", "/tmp/\(nonce)/sub"),
        ("SUFFIX", "/tmp/x\(nonce)"),
        ("EXACT", "/tmp/\(nonce)"),
        ("URL", "file://host/tmp/\(nonce)"),
    ])
    #expect(GhosttyScripting.nonceMatches(out, nonce: nonce) == ["EXACT", "URL"])
    #expect(GhosttyScripting.nonceMatches(out, nonce: "") == [])
    #expect(GhosttyScripting.nonceMatches("", nonce: nonce) == [])
}

@Test func nonceCollisionOnlyIsTreatedAsNoHit() async throws {
    let nonce = "CW-7-00000000000000ab"
    let fake = FakeRunner { _ in .success(nonceReply([("OTHER", "/tmp/\(nonce)ff")])) }
    let ids = try await GhosttyScripting(runner: fake).terminalIDs(withNonceWorkingDirectory: nonce,
                                                                     interval: .milliseconds(1))
    #expect(ids == [])
    #expect(fake.lock.withLock { fake.scripts.count } == 6)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

@Test func parsesIDs() {
    #expect(GhosttyScripting.parseIDs("A\u{1E}B\u{1E}") == ["A", "B"])
    #expect(GhosttyScripting.parseIDs("") == [])
}

@Test func processTreeBasics() {
    let me = getpid()
    #expect(ProcessTree.parentPID(of: me) == getppid())
    #expect(ProcessTree.name(of: me)?.isEmpty == false)
    #expect(!ProcessTree.ancestors(of: me).isEmpty)
}

// MARK: - Live (CW_LIVE_FOCUS=1)

@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE_FOCUS"] == "1"))
func liveListsGhosttyTerminals() async throws {
    let terms = try await GhosttyScripting().listTerminals()
    #expect(!terms.isEmpty)
    #expect(terms.allSatisfy { UUID(uuidString: $0.id) != nil })
}

@Test func focusResultFlagsAutomationPermissionFailures() {
    let denied = FocusResult.failed(reason: AppleScriptError.notPermitted(app: "Ghostty").userMessage(app: "Ghostty"))
    #expect(denied.needsAutomationPermission)
    #expect(denied.reason?.contains("Automation") == true)
    #expect(!FocusResult.failed(reason: AppleScriptError.timedOut.userMessage(app: "Ghostty")).needsAutomationPermission)
    #expect(!FocusResult.appActivatedOnly(reason: "x").needsAutomationPermission)
    #expect(FocusResult.focused.reason == nil)
    #expect(!FocusResult.focused.needsAutomationPermission)
}

/// Probes a Ghostty terminal you created yourself: `CW_LIVE_NONCE_TTY=/dev/ttysNNN
/// CW_LIVE_NONCE_ID=<its terminal id> swift test --filter liveNonceLookup`. Writes OSC 7 only to
/// that tty and restores the cwd to $HOME afterwards.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CW_LIVE_NONCE_TTY"] != nil))
func liveNonceLookup() async throws {
    let env = ProcessInfo.processInfo.environment
    let tty = try #require(env["CW_LIVE_NONCE_TTY"]), want = try #require(env["CW_LIVE_NONCE_ID"])
    let host = OSC7Probe.hostName(), nonce = OSC7Probe.makeNonce(pid: getpid())
    #expect(OSC7Probe.write(OSC7Probe.probeSequence(host: host, nonce: nonce), toTTY: tty))
    defer { _ = OSC7Probe.write(OSC7Probe.restoreSequence(host: host, cwd: NSHomeDirectory()), toTTY: tty) }
    let start = ContinuousClock.now
    let ids = try await GhosttyScripting().terminalIDs(withNonceWorkingDirectory: nonce)
    print("liveNonceLookup: \(ids) in \(ContinuousClock.now - start)")
    #expect(ids == [want])
}
