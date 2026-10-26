import CoreGraphics
import Foundation

/// Pure decision logic for the Dock-style auto-hide: when the pointer has rested on an
/// eligible left screen edge long enough, show; when it has been away from the panel long
/// enough, hide. No AppKit, no timers: the caller feeds pointer samples and acts on the
/// returned `Decision` (including scheduling the requested re-check, because a resting
/// pointer produces no events).
///
/// `suspendedUntil` pauses the reveal: until then a hidden panel is never shown (a visible
/// one still hides as usual). The caller owns it; `reset()` leaves it alone.
///
/// Lives in ClaudeWatcherCore so it can be unit tested; it depends only on
/// Foundation/CoreGraphics. Screen frames use AppKit's global coordinate space (origin at
/// the bottom-left of the primary display, y up), i.e. `NSScreen.frame` / `NSEvent.mouseLocation`.
public struct EdgeRevealPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case none
        /// Show the panel on `screens[screen]`.
        case show(screen: Int)
        case hide
        /// Call `evaluate` again after this many seconds even if the pointer doesn't move.
        case recheck(after: TimeInterval)
    }

    /// How long the pointer must rest on the edge before the panel appears.
    public var showDwell: TimeInterval = 0.15
    /// How long the pointer must stay outside the (inflated) panel before it hides.
    public var hideDelay: TimeInterval = 0.4
    /// Pointer x must be within this distance of the screen's minX.
    public var edgeTolerance: CGFloat = 1
    /// Ignore the edge in the top/bottom strips (menu bar / hot corners / Dock).
    public var cornerExclusion: CGFloat = 10
    /// Hysteresis: the pointer may stray this far outside the panel without hiding it.
    public var exitMargin: CGFloat = 24
    /// Extra slack added to re-check delays so the timer lands after the threshold.
    public var recheckSlack: TimeInterval = 0.01

    /// Edge reveal is paused while `now < suspendedUntil`: no dwell starts and no `.show` (or
    /// `.recheck` for one) is returned. `nil` = not paused; `.distantFuture` = until cleared.
    /// Only affects a hidden panel: a visible one still runs its exit timer and hides.
    public var suspendedUntil: Date?

    public private(set) var dwellStart: Date?
    public private(set) var dwellScreen: Int?
    public private(set) var exitStart: Date?

    public init() {}

    /// Clears the dwell and exit timers. Leaves `suspendedUntil` as is.
    public mutating func reset() {
        dwellStart = nil
        dwellScreen = nil
        exitStart = nil
    }

    /// - Parameters:
    ///   - pointer: current pointer location (global AppKit coordinates).
    ///   - buttonsPressed: any mouse button held (drags never reveal the panel).
    ///   - screens: all screen frames, in a stable order for this call.
    ///   - panelFrame: the panel's on-screen (target) frame when shown, `nil` when hidden.
    public mutating func evaluate(
        pointer p: CGPoint,
        now: Date,
        buttonsPressed: Bool,
        screens: [CGRect],
        panelFrame: CGRect?
    ) -> Decision {
        if let panelFrame {
            dwellStart = nil
            dwellScreen = nil
            if panelFrame.insetBy(dx: -exitMargin, dy: -exitMargin).contains(p) {
                exitStart = nil
                return .none
            }
            guard let start = exitStart else {
                exitStart = now
                return .recheck(after: hideDelay + recheckSlack)
            }
            if now.timeIntervalSince(start) >= hideDelay {
                exitStart = nil
                return .hide
            }
            return .none
        }

        exitStart = nil
        if let until = suspendedUntil, now < until {
            dwellStart = nil
            dwellScreen = nil
            return .none
        }
        guard !buttonsPressed,
              let index = Self.edgeScreenIndex(for: p, screens: screens),
              isAtEdge(p, of: screens[index])
        else {
            dwellStart = nil
            dwellScreen = nil
            return .none
        }
        guard let start = dwellStart, dwellScreen == index else {
            dwellStart = now
            dwellScreen = index
            return .recheck(after: showDwell + recheckSlack)
        }
        if now.timeIntervalSince(start) >= showDwell {
            dwellStart = nil
            dwellScreen = nil
            return .show(screen: index)
        }
        return .none
    }

    private func isAtEdge(_ p: CGPoint, of frame: CGRect) -> Bool {
        p.x <= frame.minX + edgeTolerance
            && p.y >= frame.minY + cornerExclusion
            && p.y <= frame.maxY - cornerExclusion
    }

    /// The screen under the pointer, but only if its left edge is a real edge at the pointer's
    /// height: no other display sits flush against that screen's minX at that y.
    public static func edgeScreenIndex(for p: CGPoint, screens: [CGRect]) -> Int? {
        guard let index = screens.firstIndex(where: { contains($0, p) }) else { return nil }
        let s = screens[index]
        let blocked = screens.indices.contains { i in
            i != index
                && abs(screens[i].maxX - s.minX) < 1
                && p.y >= screens[i].minY && p.y < screens[i].maxY
        }
        return blocked ? nil : index
    }

    /// Like NSMouseInRect for a flipped=false rect, but inclusive of maxY: the pointer can
    /// sit exactly on the top row of a screen.
    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        p.x >= r.minX && p.x < r.maxX && p.y >= r.minY && p.y <= r.maxY
    }
}
