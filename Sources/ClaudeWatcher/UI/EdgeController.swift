import AppKit
import ClaudeWatcherCore
import os
import SwiftUI

/// Owns the auto-hiding left-edge sidebar panel: watches the pointer (global + local
/// `mouseMoved` monitors, no permissions needed), slides the panel in when the pointer rests
/// on a screen's left edge, and slides it out after the pointer leaves.
///
/// Clicking a row runs `onSelect` (normally a `SessionFocuser`). On `.focused` the panel hides
/// (unless pinned); otherwise the reason is shown in a banner at the bottom of the panel and
/// the panel stays up while it's visible, with an "Open Settings" button when Automation
/// permission is missing.
///
/// The `sessions` closure is evaluated inside SwiftUI's `body`, so reading an `@Observable`
/// property there (like `SessionStore.sessions`) re-renders the list whenever it changes.
/// `isPinned` keeps the panel visible (no auto-hide); bind it to a menu toggle.
@MainActor
@Observable
final class EdgeController {
    static let edgeInset: CGFloat = 6

    /// The user's Ghostty look; the panel's width follows its font.
    let themeStore = ThemeStore()

    /// When true the panel stays visible on the primary screen and never auto-hides.
    var isPinned: Bool {
        get { pinned }
        set {
            guard newValue != pinned else { return }
            pinned = newValue
            pinnedDidChange()
        }
    }

    /// Whether the panel is (or is animating to be) on screen.
    private(set) var isVisible = false

    /// Session whose focus request is in flight (row shows a spinner).
    private(set) var pendingSessionID: String?
    /// Outcome of the last focus attempt that didn't fully succeed; holds the panel open.
    private(set) var notice: FocusNotice?

    private var pinned = false

    @ObservationIgnored private let sessionsSource: @MainActor () -> [ClaudeSession]
    @ObservationIgnored private let selectHandler: @MainActor (ClaudeSession) async -> FocusResult
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var panel: SidebarPanel?
    @ObservationIgnored private var policy = EdgeRevealPolicy()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var targetFrame: NSRect?
    @ObservationIgnored private var transitionGeneration = 0

    @ObservationIgnored private let logger = Logger(
        subsystem: "com.thegoldenmule.ClaudeWatcher", category: "EdgeController")

    init(
        sessions: @escaping @MainActor () -> [ClaudeSession],
        onSelect: @escaping @MainActor (ClaudeSession) async -> FocusResult
    ) {
        self.sessionsSource = sessions
        self.selectHandler = onSelect
    }

    /// Convenience: list `store.sessions`, focus the clicked session's terminal via `focuser`.
    /// Keep `focuser` a single long-lived instance (it caches terminal ids).
    convenience init(store: SessionStore, focuser: any SessionFocuser) {
        let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Focus")
        self.init(
            sessions: { store.sessions },
            onSelect: { session in
                let started = ContinuousClock.now
                let result = await focuser.focus(session)
                let elapsed = ContinuousClock.now - started
                logger.notice("""
                    focus \(session.title, privacy: .public) pid=\(session.pid) \
                    terminal=\(String(describing: session.terminal), privacy: .public) \
                    hookID=\(session.ghosttyTerminalID ?? "-", privacy: .public): \
                    \(String(describing: result), privacy: .public) in \(elapsed, privacy: .public)
                    """)
                return result
            }
        )
    }

    // MARK: - Lifecycle

    /// Creates the panel and starts watching the pointer. Call once after app launch.
    func start() {
        guard panel == nil else { return }
        let panel = SidebarPanel()
        panel.appearance = themeStore.style.nsAppearance
        let host = FirstMouseHostingView(rootView: SidebarRoot(controller: self))
        host.sizingOptions = []  // the controller owns the frame
        panel.contentView = host
        self.panel = panel

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.tick() }
            return event
        }
        monitors = [global, local].compactMap { $0 }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }

        themeStore.onChange = { [weak self] in self?.themeDidChange() }
        themeStore.start()

        if let session = DemoMode.previewNoticeSession {
            notice = FocusNotice(session: session, result: DemoMode.cannedResult(for: session))
        }
        pendingSessionID = DemoMode.previewPendingID

        if pinned { showPinned() }
    }

    /// Removes monitors and hides the panel.
    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        themeStore.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        hide(animated: false)
        panel = nil
    }

    // MARK: - Used by the hosted view

    fileprivate func currentSessions() -> [ClaudeSession] { sessionsSource() }

    fileprivate func select(_ session: ClaudeSession) {
        guard pendingSessionID == nil else { return }  // one focus at a time
        clearNotice()
        pendingSessionID = session.id
        Task {
            let result = await selectHandler(session)
            pendingSessionID = nil
            if result == .focused {
                if !pinned { hide(animated: true) }
            } else {
                post(FocusNotice(session: session, result: result))
            }
        }
    }

    fileprivate func dismissNotice() {
        clearNotice()
        tick()
    }

    fileprivate func openAutomationSettings() {
        if let url = URL(string: FocusResult.automationSettingsURL) { NSWorkspace.shared.open(url) }
        dismissNotice()
    }

    private func post(_ notice: FocusNotice) {
        noticeTask?.cancel()
        self.notice = notice
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: notice.duration)
            guard !Task.isCancelled, let self, self.notice?.id == notice.id else { return }
            self.dismissNotice()
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    // MARK: - Pointer tracking

    private func tick() {
        // A visible notice holds the panel open until it expires or is dismissed.
        guard panel != nil, !pinned, notice == nil, pendingSessionID == nil else { return }
        let screens = NSScreen.screens
        let decision = policy.evaluate(
            pointer: NSEvent.mouseLocation,
            now: Date(),
            buttonsPressed: NSEvent.pressedMouseButtons != 0,
            screens: screens.map(\.frame),
            panelFrame: isVisible ? targetFrame : nil
        )
        switch decision {
        case .none:
            break
        case .recheck(let delay):
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.tick()
            }
        case .show(let index):
            show(on: screens[index], animated: true)
        case .hide:
            hide(animated: true)
        }
    }

    private func pinnedDidChange() {
        policy.reset()
        guard panel != nil else { return }
        if pinned {
            showPinned()
        } else {
            tick()  // starts the exit timer if the pointer is already away
        }
    }

    /// New font/colors: re-theme the window and resize it in place if it's showing.
    private func themeDidChange() {
        guard let panel else { return }
        panel.appearance = themeStore.style.nsAppearance
        guard isVisible, let current = targetFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) })
        else { return }
        let target = frame(on: screen)
        targetFrame = target
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    private func screensDidChange() {
        // Frames (and visibleFrame) may all have changed; never reuse a cached frame.
        policy.reset()
        hide(animated: false)
        if pinned { showPinned() }
    }

    // MARK: - Showing / hiding

    private func showPinned() {
        guard let screen = NSScreen.screens.first else { return }
        show(on: screen, animated: !isVisible)
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let edgeInset = Self.edgeInset
        return NSRect(
            x: vf.minX + edgeInset,
            y: vf.minY + edgeInset,
            width: themeStore.style.panelWidth,
            height: vf.height - 2 * edgeInset
        )
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func show(on screen: NSScreen, animated: Bool) {
        guard let panel else { return }
        let target = frame(on: screen)
        let offscreen = target.offsetBy(dx: -(target.maxX - screen.frame.minX) - 2, dy: 0)
        targetFrame = target
        isVisible = true
        transitionGeneration += 1

        guard animated else {
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            panel.invalidateShadow()
            return
        }
        if reduceMotion {
            panel.setFrame(target, display: true)
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            if !panel.isVisible { panel.setFrame(offscreen, display: false) }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    private func hide(animated: Bool) {
        policy.reset()
        guard let panel, isVisible || panel.isVisible else { return }
        isVisible = false
        transitionGeneration += 1
        let generation = transitionGeneration
        let screenMinX = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })?.frame.minX
            ?? panel.frame.minX
        let offscreen = panel.frame.offsetBy(dx: -(panel.frame.maxX - screenMinX) - 2, dy: 0)

        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let fade = reduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fade ? 0.15 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if fade {
                panel.animator().alphaValue = 0
            } else {
                panel.animator().setFrame(offscreen, display: true)
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() that started mid-animation owns the panel now.
                guard let self, self.transitionGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }
}

/// A focus attempt that didn't fully succeed, shown as a banner at the bottom of the panel.
struct FocusNotice: Identifiable, Equatable {
    let id = UUID()
    let sessionTitle: String
    let message: String
    /// `.failed` (vs. `.appActivatedOnly`, which is informational).
    let isError: Bool
    let needsAutomationPermission: Bool

    init(session: ClaudeSession, result: FocusResult) {
        sessionTitle = session.title
        message = result.reason ?? ""
        if case .failed = result { isError = true } else { isError = false }
        needsAutomationPermission = result.needsAutomationPermission
    }

    /// Long enough to read; longer when there's a button to reach.
    var duration: Duration { needsAutomationPermission ? .seconds(10) : .seconds(4) }
}

/// Root of the hosted SwiftUI tree. Reading `controller.currentSessions()` inside `body` lets
/// Observation track whatever the source closure reads.
private struct SidebarRoot: View {
    let controller: EdgeController

    var body: some View {
        SidebarView(
            sessions: controller.currentSessions(),
            isPinned: controller.isPinned,
            pendingSessionID: controller.pendingSessionID,
            notice: controller.notice,
            onSelect: { controller.select($0) },
            onDismissNotice: { controller.dismissNotice() },
            onOpenAutomationSettings: { controller.openAutomationSettings() }
        )
        .environment(\.terminalStyle, controller.themeStore.style)
    }
}
