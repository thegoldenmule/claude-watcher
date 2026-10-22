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
@Suite(.serialized) struct AppleScriptCompileTests {
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
    #expect(OSC7Probe.makeNonce(pid: 42, random: 0xBEEF) == "CW-42-beef")
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
