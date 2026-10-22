import Foundation
import Testing
@testable import ClaudeWatcherCore

// MARK: - Tint color

private func theme(background: UInt32, blue: UInt32? = nil) -> GhosttyTheme {
    var t = GhosttyTheme.ghosttyDefault
    t.background = GhosttyColor(background)
    if let blue { t.palette[4] = GhosttyColor(blue) }
    return t
}

@Test(arguments: [
    // dark backgrounds, incl. one next to a very bright accent
    (UInt32(0x282c34), UInt32?.none), (0x000000, nil), (0x1e1e2e, 0x89b4fa), (0x3a3a3a, 0xffffff),
    (0x6b6b6b, 0xffffff),
    // light backgrounds, incl. ones near the 0.5 boundary and a dark accent
    (0xffffff, nil), (0xfdf6e3, 0x268bd2), (0xbcbcbc, 0x0000ff), (0xc8c8c8, 0x000080), (0xeff1f5, 0x1e66f5),
])
func highlightTintKeepsLuminanceClass(background: UInt32, blue: UInt32?) {
    let t = theme(background: background, blue: blue)
    let tint = t.highlightTint()
    #expect((tint.luminance < 0.5) == (t.background.luminance < 0.5))
    #expect(tint.isLight == t.background.isLight)
    #expect(tint.hexString.count == 7 && tint.hexString.hasPrefix("#"))
    #expect(GhosttyColor(ghostty: tint.hexString) == tint)
}

@Test func highlightTintMovesTowardBlue() {
    let t = GhosttyTheme.ghosttyDefault
    let tint = t.highlightTint()
    #expect(tint != t.background)
    #expect(tint.blue > t.background.blue)
    #expect(tint == t.background.mixed(with: t.palette[4], amount: 0.25).rounded8)
    #expect(t.highlightTint(strength: 0) == t.background)
}

@Test func highlightAccentFallsBackWhenBlueMatchesBackground() {
    var t = GhosttyTheme.ghosttyDefault
    t.palette[4] = t.background
    #expect(t.highlightAccent == t.palette[12])
}

private extension GhosttyColor {
    var rounded8: GhosttyColor { GhosttyColor(ghostty: hexString)! }
}

// MARK: - Escape sequences

@Test func highlightEscapeBytes() {
    #expect(TerminalHighlighter.tintSequence(GhosttyColor(0x1a2b3c))
        == [0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x23, 0x31, 0x61, 0x32, 0x62, 0x33, 0x63, 0x1B, 0x5C])
    #expect(String(decoding: TerminalHighlighter.tintSequence(GhosttyColor(0x1a2b3c)), as: UTF8.self)
        == "\u{1B}]11;#1a2b3c\u{1B}\\")
    #expect(TerminalHighlighter.resetSequence == [0x1B, 0x5D, 0x31, 0x31, 0x31, 0x1B, 0x5C])
}

// MARK: - Highlighter

private enum Op: Equatable, CustomStringConvertible {
    case tint(String, String)  // tty, hex
    case reset(String)
    case other(String, [UInt8])

    var description: String {
        switch self {
        case .tint(let tty, let hex): "tint(\(tty), \(hex))"
        case .reset(let tty): "reset(\(tty))"
        case .other(let tty, let bytes): "other(\(tty), \(bytes))"
        }
    }
}

/// Records writes; OSC 111 writes to a tty in `failResets` send nothing (any tty if
/// `failAllResets`), and to one in `partialResets` only 3 bytes. OSC 11 writes send nothing
/// while `failTints` is set.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _ops: [Op] = []
    private var _failTints = false
    private var _failAllResets = false
    private var _failResets: Set<String> = []
    private var _partialResets: Set<String> = []

    var ops: [Op] { lock.withLock { _ops } }
    var failResets: Bool {
        get { lock.withLock { _failAllResets } }
        set { lock.withLock { _failAllResets = newValue } }
    }

    var failTints: Bool {
        get { lock.withLock { _failTints } }
        set { lock.withLock { _failTints = newValue } }
    }

    func failResets(on ttys: Set<String>, partial: Set<String> = []) {
        lock.withLock { _failResets = ttys; _partialResets = partial }
    }

    func write(_ bytes: [UInt8], _ tty: String) -> Int {
        lock.withLock {
            if bytes == TerminalHighlighter.resetSequence {
                if _failAllResets || _failResets.contains(tty) { return 0 }
                if _partialResets.contains(tty) {
                    _ops.append(.other(tty, Array(bytes.prefix(3))))
                    return 3
                }
                _ops.append(.reset(tty))
            } else if let s = String(bytes: bytes, encoding: .utf8), s.hasPrefix("\u{1B}]11;"), s.hasSuffix("\u{1B}\\") {
                if _failTints { return 0 }
                _ops.append(.tint(tty, String(s.dropFirst(5).dropLast(2))))
            } else {
                _ops.append(.other(tty, bytes))
            }
            return bytes.count
        }
    }

    /// ttys whose last op was a tint.
    var tinted: Set<String> {
        var out = Set<String>()
        for op in ops {
            switch op {
            case .tint(let tty, _): out.insert(tty)
            case .reset(let tty): out.remove(tty)
            case .other: break
            }
        }
        return out
    }
}

private struct Fixture {
    let dir: URL
    let recorder = Recorder()
    let highlighter: TerminalHighlighter
    var recoveryFile: URL { dir.appendingPathComponent("tinted-ttys") }
    var lockDir: URL { dir.appendingPathComponent("hook-state", isDirectory: true) }

    /// `ghosttyTTYs`: ttys with a live Ghostty-hosted process (nil: all of them).
    init(hoverCap: Duration = .seconds(30), pulseDuration: Duration = .milliseconds(60),
         tmuxPIDs: Set<Int32> = [], controlling: Bool = true, ttyDevices: Bool = true,
         ghosttyTTYs: Set<String>? = nil)
    {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-hl-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("hook-state"),
                                                 withIntermediateDirectories: true)
        let recorder = self.recorder
        let io = TerminalHighlighterIO(
            write: { recorder.write($0, $1) },
            isControllingTTY: { _, _ in controlling },
            isInsideTmux: { tmuxPIDs.contains($0) },
            isTTYDevice: { _ in ttyDevices },
            hasGhosttyProcess: { ghosttyTTYs?.contains($0) ?? true })
        highlighter = TerminalHighlighter(
            recoveryFile: dir.appendingPathComponent("tinted-ttys"),
            lockDirectory: dir.appendingPathComponent("hook-state", isDirectory: true),
            io: io, timing: TerminalHighlighterTiming(hoverCap: hoverCap, pulseDuration: pulseDuration))
    }

    func idle() async throws {
        let h = highlighter
        try await onDedicatedThread { h.waitUntilIdle() }
    }

    var recorded: Set<String> {
        TerminalHighlighter.parseRecoveryFile((try? String(contentsOf: recoveryFile, encoding: .utf8)) ?? "")
    }

    var recoveryFileExists: Bool { FileManager.default.fileExists(atPath: recoveryFile.path) }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func session(_ n: Int, pid: Int32 = 4242, terminal: TerminalKind = .ghostty,
                     tty: String? = "", status: SessionStatus = .unknown) -> ClaudeSession {
    ClaudeSession(id: "s\(n)", pid: pid, cwd: "/tmp", title: "t\(n)", status: status,
                  tty: tty == "" ? "/dev/ttys9\(n)" : tty, terminal: terminal,
                  startedAt: .distantPast, updatedAt: .distantPast)
}

private let red = GhosttyColor(0x402020)
private let blue = GhosttyColor(0x202040)

@Test func hoverSequenceTintsAndResetsInOrder() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    #expect(f.recorded == ["/dev/ttys91"])
    f.highlighter.beginHover(session(2), tint: red)
    try await f.idle()
    #expect(f.recorded == ["/dev/ttys92"])
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.ops == [
        .tint("/dev/ttys91", "#402020"), .reset("/dev/ttys91"),
        .tint("/dev/ttys92", "#402020"), .reset("/dev/ttys92"),
    ])
    #expect(!f.recoveryFileExists)
}

@Test func hoverBurstCoalescesAndEndsUntinted() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    for _ in 0..<20 {
        f.highlighter.beginHover(session(1), tint: red)
        f.highlighter.beginHover(session(2), tint: blue)
        f.highlighter.endHover()
    }
    try await f.idle()
    #expect(f.recorder.tinted.isEmpty)
    #expect(f.recorder.ops.count <= 4)  // stale tints aren't queued up
    #expect(!f.recoveryFileExists)
}

@Test func hoverBurstLeavesOnlyTheLastPaneTinted() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: red)
    f.highlighter.beginHover(session(2), tint: blue)
    try await f.idle()
    #expect(f.recorder.tinted == ["/dev/ttys92"])
    #expect(f.recorder.ops.last == .tint("/dev/ttys92", "#202040"))
    // Re-hovering the same pane with the same tint writes nothing new.
    let count = f.recorder.ops.count
    f.highlighter.beginHover(session(2), tint: blue)
    try await f.idle()
    #expect(f.recorder.ops.count == count)
    // Same pane, new tint: one tint write, no reset first.
    f.highlighter.beginHover(session(2), tint: red)
    try await f.idle()
    #expect(f.recorder.tinted == ["/dev/ttys92"])
    #expect(f.recorder.ops.count == count + 1)
    #expect(f.recorder.ops.last == .tint("/dev/ttys92", "#402020"))
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.tinted.isEmpty)
}

@Test func hoverAutoResetsAfterCap() async throws {
    let f = Fixture(hoverCap: .milliseconds(150))
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys91", "#402020")])
    try await Task.sleep(for: .milliseconds(500))
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys91", "#402020"), .reset("/dev/ttys91")])
    // endHover after the cap fired writes nothing more.
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.ops.count == 2)
}

@Test func reHoverRestartsTheCap() async throws {
    let cap = Duration.milliseconds(400)
    let f = Fixture(hoverCap: cap)
    defer { f.cleanup() }
    let clock = ContinuousClock()
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    try await Task.sleep(for: .milliseconds(250))
    let rehover = clock.now
    f.highlighter.beginHover(session(1), tint: red)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    // Past the first hover's cap; still tinted if the re-hover's cap hasn't run out yet (only
    // checkable when the run wasn't delayed past it).
    if clock.now - rehover < cap - .milliseconds(50) {
        #expect(f.recorder.ops == [.tint("/dev/ttys91", "#402020")])
    }
    try await Task.sleep(for: .milliseconds(600))
    try await f.idle()
    #expect(f.recorder.tinted.isEmpty)
    #expect(f.recorder.ops.last == .reset("/dev/ttys91"))
}

@Test func hoverSkipsIneligibleSessions() async throws {
    let f = Fixture(tmuxPIDs: [7])
    defer { f.cleanup() }
    let h = f.highlighter
    h.beginHover(session(1, terminal: .appleTerminal), tint: red); try await f.idle()
    h.beginHover(session(2, terminal: .other("iTerm2")), tint: red); try await f.idle()
    h.beginHover(session(3, pid: 7), tint: red); try await f.idle()                  // tmux
    h.beginHover(session(4, tty: nil), tint: red); try await f.idle()
    h.beginHover(session(5, tty: "/dev/tty.usbserial"), tint: red); try await f.idle()
    h.beginHover(session(6, tty: "/dev/ttys"), tint: red); try await f.idle()
    h.pulse(session(1, terminal: .appleTerminal), tint: red)
    h.pulse(session(3, pid: 7), tint: red)
    try await f.idle()
    #expect(f.recorder.ops.isEmpty)
    #expect(!f.recoveryFileExists)

    let notControlling = Fixture(controlling: false)
    defer { notControlling.cleanup() }
    notControlling.highlighter.beginHover(session(1), tint: red)
    try await notControlling.idle()
    #expect(notControlling.recorder.ops.isEmpty)
}

@Test func hoverSkipsWhileProbeLockIsFresh() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    let lock = f.lockDir.appendingPathComponent(".probe-ttys91.lock", isDirectory: true)
    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    f.highlighter.pulse(session(1), tint: red)
    try await f.idle()
    #expect(f.recorder.ops.isEmpty)
    // Another tty isn't affected.
    f.highlighter.beginHover(session(2), tint: red)
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys92", "#402020")])

    // A stale lock (mtime well past the freshness window) doesn't block.
    let old = Date().addingTimeInterval(-60)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lock.path)
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    #expect(f.recorder.ops.suffix(2) == [.reset("/dev/ttys92"), .tint("/dev/ttys91", "#402020")])
}

@Test func pulseTintsThenResets() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.pulse(session(1), tint: red)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys91", "#402020"), .reset("/dev/ttys91")])
    #expect(!f.recoveryFileExists)
}

@Test func busySessionGetsNoHoverTintButPulses() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1, status: .busy), tint: red)
    try await f.idle()
    #expect(f.recorder.ops.isEmpty)
    #expect(!f.recoveryFileExists)
    // A hovered pane whose session turns busy (seen on a keep-alive beginHover) is reset.
    f.highlighter.beginHover(session(2, status: .waiting), tint: red)
    try await f.idle()
    f.highlighter.beginHover(session(2, status: .busy), tint: red)
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys92", "#402020"), .reset("/dev/ttys92")])
    // The pulse (two writes) still runs on a busy session.
    f.highlighter.pulse(session(1, status: .busy), tint: red)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    #expect(f.recorder.ops.suffix(2) == [.tint("/dev/ttys91", "#402020"), .reset("/dev/ttys91")])
}

@Test func pulseOnHoveredPaneSettlesToHoverTint() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: blue)
    f.highlighter.pulse(session(1), tint: red)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys91", "#202040"), .tint("/dev/ttys91", "#402020"),
                               .tint("/dev/ttys91", "#202040")])
    #expect(f.recorder.tinted == ["/dev/ttys91"])
    // Pulsing the hovered pane in the hover's own color: one write, nothing to settle.
    f.highlighter.pulse(session(1), tint: blue)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    #expect(f.recorder.ops.count == 4)
    #expect(f.recorder.ops.last == .tint("/dev/ttys91", "#202040"))
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.tinted.isEmpty)

    // Hover leaving the pane mid-pulse: the pulse's last step resets it.
    let g = Fixture(pulseDuration: .milliseconds(100))
    defer { g.cleanup() }
    g.highlighter.pulse(session(1), tint: red)
    g.highlighter.beginHover(session(1), tint: blue)
    try await g.idle()
    g.highlighter.endHover()
    try await Task.sleep(for: .milliseconds(300))
    try await g.idle()
    #expect(g.recorder.tinted.isEmpty)
    #expect(!g.recoveryFileExists)
}

@Test func failedRecolorKeepsTrackingTheOldTint() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    // A keep-alive recolor (e.g. after an appearance switch) gets nothing out: the pane still
    // shows red, so it stays recorded and tracked.
    f.recorder.failTints = true
    f.highlighter.beginHover(session(1), tint: blue)
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys91", "#402020")])
    #expect(f.recorded == ["/dev/ttys91"])
    // The next keep-alive retries the recolor.
    f.recorder.failTints = false
    f.highlighter.beginHover(session(1), tint: blue)
    try await f.idle()
    #expect(f.recorder.ops.last == .tint("/dev/ttys91", "#202040"))
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.tinted.isEmpty)
    #expect(!f.recoveryFileExists)

    // Pointer leaves right after the failed recolor: the old tint is still reset.
    let g = Fixture()
    defer { g.cleanup() }
    g.highlighter.beginHover(session(1), tint: red)
    try await g.idle()
    g.recorder.failTints = true
    g.highlighter.beginHover(session(1), tint: blue)
    try await g.idle()
    g.highlighter.endHover()
    try await g.idle()
    #expect(g.recorder.ops == [.tint("/dev/ttys91", "#402020"), .reset("/dev/ttys91")])
    #expect(!g.recoveryFileExists)

    // A failed tint on a pane that wasn't tinted isn't tracked or recorded.
    let k = Fixture()
    defer { k.cleanup() }
    k.recorder.failTints = true
    k.highlighter.beginHover(session(1), tint: red)
    try await k.idle()
    k.highlighter.endHover()
    try await k.idle()
    #expect(k.recorder.ops.isEmpty)
    #expect(!k.recoveryFileExists)
}

@Test func failedPulseOnHoveredPaneKeepsItRecorded() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: blue)
    try await f.idle()
    f.recorder.failTints = true
    f.highlighter.pulse(session(1), tint: red)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys91", "#202040")])
    #expect(f.recorded == ["/dev/ttys91"])
    f.recorder.failTints = false
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.ops.last == .reset("/dev/ttys91"))
    #expect(!f.recoveryFileExists)

    // The pulse's settle back to the hover tint fails: the pane keeps the pulse tint, stays
    // recorded, and a keep-alive beginHover retries the hover tint.
    let pulse = Duration.milliseconds(400)
    let g = Fixture(pulseDuration: pulse)
    defer { g.cleanup() }
    let clock = ContinuousClock()
    g.highlighter.beginHover(session(1), tint: blue)
    let start = clock.now
    g.highlighter.pulse(session(1), tint: red)
    try await g.idle()
    g.recorder.failTints = true
    guard clock.now - start < pulse - .milliseconds(100) else { return }  // run delayed past the settle
    try await Task.sleep(for: pulse + .milliseconds(200))
    try await g.idle()
    #expect(g.recorder.ops == [.tint("/dev/ttys91", "#202040"), .tint("/dev/ttys91", "#402020")])
    #expect(g.recorded == ["/dev/ttys91"])
    g.recorder.failTints = false
    g.highlighter.beginHover(session(1), tint: blue)
    try await g.idle()
    #expect(g.recorder.ops.last == .tint("/dev/ttys91", "#202040"))
    g.highlighter.endHover()
    try await g.idle()
    #expect(g.recorder.tinted.isEmpty)
    #expect(!g.recoveryFileExists)
}

@Test func recoveryFileKeepsTTYWhenResetFails() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    #expect(try String(contentsOf: f.recoveryFile, encoding: .utf8) == "/dev/ttys91\n")
    f.recorder.failResets = true
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorded == ["/dev/ttys91"])
    f.recorder.failResets = false
    f.highlighter.resetAll()
    try await f.idle()
    #expect(f.recorder.ops.last == .reset("/dev/ttys91"))
    #expect(!f.recoveryFileExists)
}

@Test func resetAllResetsRecordedTTYsAndClearsFile() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    try "/dev/ttys901\n/dev/ttys902\n/etc/passwd\n/dev/ttys\n\n".write(to: f.recoveryFile, atomically: true, encoding: .utf8)
    f.highlighter.resetAll()
    try await f.idle()
    #expect(f.recorder.ops == [.reset("/dev/ttys901"), .reset("/dev/ttys902")])
    #expect(!f.recoveryFileExists)

    // Recorded paths that aren't tty devices (anymore) are skipped, and the file still cleared.
    let g = Fixture(ttyDevices: false)
    defer { g.cleanup() }
    try "/dev/ttys901\n".write(to: g.recoveryFile, atomically: true, encoding: .utf8)
    let h = g.highlighter
    try await onDedicatedThread { h.resetAllSync(timeout: .seconds(2)) }
    #expect(g.recorder.ops.isEmpty)
    #expect(!g.recoveryFileExists)
}

@Test func resetAllKeepsTTYsWhoseResetDidNotGoOut() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    try "/dev/ttys901\n/dev/ttys902\n/dev/ttys903\n".write(to: f.recoveryFile, atomically: true, encoding: .utf8)
    f.recorder.failResets(on: ["/dev/ttys901"], partial: ["/dev/ttys902"])
    f.highlighter.resetAll()
    try await f.idle()
    // A partial reset is closed with ST; both failed ones stay recorded for the next resetAll.
    #expect(f.recorder.ops == [.other("/dev/ttys902", [0x1B, 0x5D, 0x31]), .other("/dev/ttys902", [0x1B, 0x5C]),
                               .reset("/dev/ttys903")])
    #expect(f.recorded == ["/dev/ttys901", "/dev/ttys902"])
    f.recorder.failResets(on: [])
    f.highlighter.resetAll()
    try await f.idle()
    #expect(f.recorder.ops.suffix(2) == [.reset("/dev/ttys901"), .reset("/dev/ttys902")])
    #expect(!f.recoveryFileExists)

    // A failed reset whose device is gone is dropped.
    let g = Fixture(ttyDevices: false)
    defer { g.cleanup() }
    try "/dev/ttys901\n".write(to: g.recoveryFile, atomically: true, encoding: .utf8)
    g.recorder.failResets = true
    g.highlighter.resetAll()
    try await g.idle()
    #expect(!g.recoveryFileExists)
}

@Test func resetAllSkipsTTYsWithoutAGhosttyProcess() async throws {
    let f = Fixture(ghosttyTTYs: ["/dev/ttys902"])
    defer { f.cleanup() }
    try "/dev/ttys901\n/dev/ttys902\n".write(to: f.recoveryFile, atomically: true, encoding: .utf8)
    f.highlighter.resetAll()
    try await f.idle()
    #expect(f.recorder.ops == [.reset("/dev/ttys902")])
    #expect(!f.recoveryFileExists)
}

@Test func resetAllWithNothingRecordedTouchesNoFiles() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.resetAll()
    try await f.idle()
    // A file appearing now (not written by this instance) is left alone by a no-op resetAll.
    try "/dev/ttys901\n".write(to: f.recoveryFile, atomically: true, encoding: .utf8)
    f.highlighter.resetAll()
    try await f.idle()
    #expect(f.recoveryFileExists)
    #expect(f.recorder.ops.isEmpty)

    // A file holding only junk lines is cleaned up.
    let g = Fixture()
    defer { g.cleanup() }
    try "/etc/passwd\n".write(to: g.recoveryFile, atomically: true, encoding: .utf8)
    g.highlighter.resetAll()
    try await g.idle()
    #expect(!g.recoveryFileExists)
}

@Test func resetAllDropsHover() async throws {
    let f = Fixture()
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: red)
    try await f.idle()
    f.highlighter.resetAll()
    try await f.idle()
    #expect(f.recorder.ops == [.tint("/dev/ttys91", "#402020"), .reset("/dev/ttys91")])
    // A later endHover has nothing left to reset.
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.ops.count == 2)
}

@Test func ttyDeviceCheck() {
    #expect(!TerminalHighlighter.isTTYDevice("/dev/null"))
    #expect(!TerminalHighlighter.isTTYDevice("/dev/ttys99999999"))
    #expect(!TerminalHighlighter.isTTYDevice("/tmp/ttys1"))
    #expect(!TerminalHighlighter.hasGhosttyProcess(onTTY: "/dev/null"))
    #expect(!TerminalHighlighter.hasGhosttyProcess(onTTY: "/dev/ttys99999999"))
    #expect(TerminalHighlighter.isGhosttyExecutable("/Applications/Ghostty.app/Contents/MacOS/ghostty"))
    #expect(!TerminalHighlighter.isGhosttyExecutable("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"))
    #expect(!TerminalHighlighter.isGhosttyExecutable(nil))
}

@Test func controllingTTYScanFindsTheTTYsProcesses() throws {
    // Our own tty, when the test run has one (not in CI): this process or an ancestor is on it.
    var st = stat()
    guard fstat(STDIN_FILENO, &st) == 0, isatty(STDIN_FILENO) == 1 else { return }
    let pids = TerminalHighlighter.pids(withControllingTTY: st.st_rdev)
    let mine = Set([getpid()] + ProcessTree.ancestors(of: getpid()))
    #expect(!Set(pids).isDisjoint(with: mine))
}
