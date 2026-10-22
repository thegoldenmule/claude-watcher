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

/// Records writes; `failResets` makes OSC 111 writes send nothing.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _ops: [Op] = []
    var failResets = false

    var ops: [Op] { lock.withLock { _ops } }

    func write(_ bytes: [UInt8], _ tty: String) -> Int {
        lock.withLock {
            if bytes == TerminalHighlighter.resetSequence {
                if failResets { return 0 }
                _ops.append(.reset(tty))
            } else if let s = String(bytes: bytes, encoding: .utf8), s.hasPrefix("\u{1B}]11;"), s.hasSuffix("\u{1B}\\") {
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

    init(hoverCap: Duration = .seconds(30), pulseStep: Duration = .milliseconds(20),
         tmuxPIDs: Set<Int32> = [], controlling: Bool = true, ttyDevices: Bool = true)
    {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cw-hl-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("hook-state"),
                                                 withIntermediateDirectories: true)
        let recorder = self.recorder
        let io = TerminalHighlighterIO(
            write: { recorder.write($0, $1) },
            isControllingTTY: { _, _ in controlling },
            isInsideTmux: { tmuxPIDs.contains($0) },
            isTTYDevice: { _ in ttyDevices })
        highlighter = TerminalHighlighter(
            recoveryFile: dir.appendingPathComponent("tinted-ttys"),
            lockDirectory: dir.appendingPathComponent("hook-state", isDirectory: true),
            io: io, timing: TerminalHighlighterTiming(hoverCap: hoverCap, pulseStep: pulseStep))
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
                     tty: String? = "") -> ClaudeSession {
    ClaudeSession(id: "s\(n)", pid: pid, cwd: "/tmp", title: "t\(n)",
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
    // Same pane, new tint: rewritten.
    f.highlighter.beginHover(session(2), tint: red)
    try await f.idle()
    #expect(f.recorder.tinted == ["/dev/ttys92"])
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

@Test func pulseBlinksThenResets() async throws {
    let f = Fixture(pulseStep: .milliseconds(20))
    defer { f.cleanup() }
    f.highlighter.pulse(session(1), tint: red)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    let t = Op.tint("/dev/ttys91", "#402020"), r = Op.reset("/dev/ttys91")
    #expect(f.recorder.ops == [t, r, t, r])
    #expect(!f.recoveryFileExists)
}

@Test func pulseOnHoveredPaneSettlesToHoverTint() async throws {
    let f = Fixture(pulseStep: .milliseconds(20))
    defer { f.cleanup() }
    f.highlighter.beginHover(session(1), tint: blue)
    f.highlighter.pulse(session(1), tint: red)
    try await Task.sleep(for: .milliseconds(250))
    try await f.idle()
    #expect(f.recorder.ops.last == .tint("/dev/ttys91", "#202040"))
    #expect(f.recorder.tinted == ["/dev/ttys91"])
    f.highlighter.endHover()
    try await f.idle()
    #expect(f.recorder.tinted.isEmpty)

    // Hover leaving the pane mid-pulse: the pulse's last step resets it.
    let g = Fixture(pulseStep: .milliseconds(30))
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
}
