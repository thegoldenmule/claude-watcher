import CoreGraphics
import Foundation
import Testing
@testable import ClaudeWatcherCore

private typealias Decision = EdgeRevealPolicy.Decision

private let mainScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let t0 = Date(timeIntervalSince1970: 1000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

/// True when `d` is `.recheck` with a delay within floating-point noise of `expected`.
private func isRecheck(_ d: Decision, _ expected: TimeInterval) -> Bool {
    if case .recheck(let after) = d { return abs(after - expected) < 1e-9 }
    return false
}

private extension EdgeRevealPolicy {
    mutating func sample(
        _ x: CGFloat, _ y: CGFloat, at t: TimeInterval,
        buttons: Bool = false,
        screens: [CGRect] = [mainScreen],
        panel: CGRect? = nil
    ) -> Decision {
        evaluate(pointer: CGPoint(x: x, y: y), now: at(t), buttonsPressed: buttons,
                 screens: screens, panelFrame: panel)
    }
}

@Suite struct EdgeRevealPolicyShowTests {
    @Test func dwellThenShow() {
        var p = EdgeRevealPolicy()
        #expect(isRecheck(p.sample(0, 500, at: 0), 0.16), "first edge sample -> recheck")
        #expect(p.sample(0, 500, at: 0.1) == .none, "before dwell -> none")
        #expect(p.sample(0, 500, at: 0.16) == .show(screen: 0), "after dwell -> show")
    }

    @Test func leavingEdgeResetsDwell() {
        var p = EdgeRevealPolicy()
        _ = p.sample(0, 500, at: 0)
        #expect(p.sample(5, 500, at: 0.1) == .none, "off edge")
        #expect(isRecheck(p.sample(0, 500, at: 0.2), 0.16), "dwell restarts")
        #expect(p.sample(1, 500, at: 0.36) == .show(screen: 0), "x=1 within tolerance")
    }

    @Test func buttonsAndCorners() {
        var p = EdgeRevealPolicy()
        #expect(p.sample(0, 500, at: 0, buttons: true) == .none, "drag ignored")
        #expect(p.sample(0, 5, at: 0) == .none, "bottom corner ignored")
        #expect(p.sample(0, 980, at: 0) == .none, "top corner ignored")
        #expect(isRecheck(p.sample(0, 11, at: 0), 0.16), "just above corner ok")
        #expect(p.sample(0, 11, at: 0.1, buttons: true) == .none, "press cancels dwell")
        #expect(isRecheck(p.sample(0, 11, at: 0.2), 0.16), "restarts after release")
    }
}

@Suite struct EdgeRevealPolicyMultiDisplayTests {
    @Test func flushLeftDisplayBlocksMainEdge() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let screens = [mainScreen, left]
        #expect(EdgeRevealPolicy.edgeScreenIndex(for: CGPoint(x: 0, y: 500), screens: screens) == nil,
                "main left edge blocked by flush display")
        #expect(EdgeRevealPolicy.edgeScreenIndex(for: CGPoint(x: -1920, y: 500), screens: screens) == 1,
                "outer display edge eligible")
    }

    @Test func shorterNeighborBlocksOnlyBesideIt() {
        let shortLeft = CGRect(x: -1920, y: 0, width: 1920, height: 400)
        let screens = [mainScreen, shortLeft]
        #expect(EdgeRevealPolicy.edgeScreenIndex(for: CGPoint(x: 0, y: 500), screens: screens) == 0,
                "edge free above shorter neighbor")
        #expect(EdgeRevealPolicy.edgeScreenIndex(for: CGPoint(x: 0, y: 300), screens: screens) == nil,
                "edge blocked beside neighbor")
    }

    @Test func rightDisplay() {
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let screens = [mainScreen, right]
        #expect(EdgeRevealPolicy.edgeScreenIndex(for: CGPoint(x: 1512, y: 500), screens: screens) == nil,
                "right display's left edge blocked by main")
        #expect(EdgeRevealPolicy.edgeScreenIndex(for: CGPoint(x: 0, y: 500), screens: screens) == 0,
                "main left edge free")
    }

    @Test func switchingScreensRestartsDwell() {
        var p = EdgeRevealPolicy()
        let above = CGRect(x: 0, y: 982, width: 1512, height: 900)
        let screens = [mainScreen, above]
        _ = p.sample(0, 500, at: 0, screens: screens)
        #expect(isRecheck(p.sample(0, 1500, at: 0.2, screens: screens), 0.16), "screen switch restarts dwell")
    }
}

@Suite struct EdgeRevealPolicyHideTests {
    let panel = CGRect(x: 6, y: 6, width: 280, height: 900)

    @Test func hideTimingWithHysteresis() {
        var p = EdgeRevealPolicy()
        #expect(p.sample(100, 500, at: 0, panel: panel) == .none, "inside")
        #expect(p.sample(6 + 280 + 20, 500, at: 0, panel: panel) == .none, "within margin")
        #expect(isRecheck(p.sample(6 + 280 + 30, 500, at: 1, panel: panel), 0.41), "exit starts")
        #expect(p.sample(600, 500, at: 1.2, panel: panel) == .none, "exit pending")
        #expect(p.sample(600, 500, at: 1.41, panel: panel) == .hide, "hide after delay")
    }

    @Test func reentryCancelsExit() {
        var p = EdgeRevealPolicy()
        _ = p.sample(600, 500, at: 2, panel: panel)
        #expect(p.sample(200, 500, at: 2.2, panel: panel) == .none, "re-entered")
        #expect(isRecheck(p.sample(600, 500, at: 2.5, panel: panel), 0.41), "exit restarts after re-entry")
        #expect(p.sample(600, 500, at: 2.8, panel: panel) == .none, "not yet")
    }
}
