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
///
/// With a `TerminalHighlighter` (nil in demo mode), resting the pointer on a row for
/// `hoverDwell` tints that session's Ghostty pane, and a successful focus pulses it. Hiding the
/// panel resets every tint.
@MainActor
@Observable
final class EdgeController {
    static let edgeInset: CGFloat = 6

    /// The user's Ghostty look; the panel's width follows its font.
    let themeStore = ThemeStore()

    /// When true the panel stays visible and never auto-hides (shown on the screen it's already
    /// on, else the primary one). Toggled from the menu or the panel's header.
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

    /// Tint the hovered row's Ghostty pane (persisted; default on).
    var highlightOnHover: Bool = EdgeController.storedFlag(Keys.highlightOnHover) {
        didSet {
            UserDefaults.standard.set(highlightOnHover, forKey: Keys.highlightOnHover)
            if highlightOnHover { rearmHover() } else { cancelHoverTint() }
        }
    }

    /// Briefly pulse a pane after it's focused from the panel (persisted; default on).
    var pulseOnFocus: Bool = EdgeController.storedFlag(Keys.pulseOnFocus) {
        didSet { UserDefaults.standard.set(pulseOnFocus, forKey: Keys.pulseOnFocus) }
    }

    /// Edge auto-reveal is paused until this date (persisted; `.distantFuture` = until resumed).
    private(set) var revealPausedUntil: Date? = EdgeController.storedPauseDate()

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

    /// How long the pointer must rest on one row before its pane is tinted.
    static let hoverDwell: Duration = .milliseconds(150)
    /// The Core drops a hover tint 3 s after the last `beginHover` (a safety cap against a stalled
    /// UI), so a row that stays hovered re-sends it this often; a repeat writes nothing.
    static let hoverKeepAlive: Duration = .seconds(2)
    @ObservationIgnored private let highlighter: TerminalHighlighter?
    /// Row under the pointer, per the rows' `onHover` or a hit-test (ids only: data updates
    /// don't re-tint).
    @ObservationIgnored private var hoveredID: String?
    /// Rendered rows' frames in the pane (top-left origin), as last laid out, for hit-testing.
    @ObservationIgnored private var rowFrames: [String: CGRect] = [:]
    /// The session list's visible area in the pane; rows outside it are scrolled away.
    @ObservationIgnored private var listViewport: CGRect = .null
    /// Row whose pane `beginHover` was called for (so `endHover` is only sent when needed).
    @ObservationIgnored private var tintedID: String?
    /// Dwell, then keep-alive, for the hovered row's tint.
    @ObservationIgnored private var dwellTask: Task<Void, Never>?

    @ObservationIgnored private let logger = Logger(
        subsystem: "com.thegoldenmule.ClaudeWatcher", category: "EdgeController")

    init(
        sessions: @escaping @MainActor () -> [ClaudeSession],
        onSelect: @escaping @MainActor (ClaudeSession) async -> FocusResult,
        highlighter: TerminalHighlighter? = nil
    ) {
        self.sessionsSource = sessions
        self.selectHandler = onSelect
        self.highlighter = highlighter
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

        scheduleResume()  // a pause persisted across relaunch
        if pinned { showPinned() }
    }

    /// Removes monitors and hides the panel.
    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        themeStore.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        hide(animated: false, resetHighlights: false)  // the app resets synchronously at exit
        panel = nil
    }

    // MARK: - Used by the hosted view

    fileprivate func currentSessions() -> [ClaudeSession] { sessionsSource() }

    fileprivate func select(_ session: ClaudeSession) {
        guard pendingSessionID == nil else { return }  // one focus at a time
        clearNotice()
        pendingSessionID = session.id
        // No tint starting mid-focus, and no keep-alive: the result ends the tint.
        dwellTask?.cancel()
        dwellTask = nil
        Task {
            let result = await selectHandler(session)
            pendingSessionID = nil
            // Only end this row's tint: another row hovered mid-focus keeps its tint and keep-alive.
            if tintedID == session.id { endHoverTint() }
            if result == .focused {
                if pulseOnFocus { highlighter?.pulse(session, tint: highlightTint) }
                // Keep the pulse: this hide must not reset it.
                if !pinned { hide(animated: true, resetHighlights: false) }
            } else {
                post(FocusNotice(session: session, result: result))
            }
            // Still up (pinned, or a notice): the clicked row's dwell was cancelled, so re-arm the
            // row under the pointer. A hover landing on a pulsing pane doesn't cut the pulse short:
            // the Core leaves that pane to the pulse, whose end settles it to the hover tint.
            rearmHover()
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

    fileprivate func rowHoverChanged(_ sessionID: String, inside: Bool) {
        // Enter/exit of adjacent rows may arrive in either order: an exit only clears its own row.
        if inside {
            setHovered(sessionID)
        } else if hoveredID == sessionID {
            setHovered(nil)
        }
    }

    fileprivate func rowFramesChanged(_ frames: [String: CGRect]) { rowFrames = frames }
    fileprivate func listViewportChanged(_ viewport: CGRect) { listViewport = viewport }

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

    // MARK: - Panel width

    /// Whether the panel's right edge can be dragged (while pinned). Off in demo mode, which
    /// neither reads nor writes the stored width.
    @ObservationIgnored let isResizable = !DemoMode.isEnabled
    /// The user's width (persisted), applied in pinned and auto-hide modes alike; nil follows the
    /// theme. `frame(on:)` clamps it per screen without writing the clamp back, so a width that
    /// didn't fit a small screen comes back on a bigger one.
    @ObservationIgnored private var panelWidthOverride: CGFloat? =
        DemoMode.isEnabled ? nil : EdgeController.storedWidth()
    /// A width is stored (enables "Reset Sidebar Width"); updated at drag end and reset only.
    private(set) var hasCustomPanelWidth = !DemoMode.isEnabled && EdgeController.storedWidth() != nil
    /// Screen-x distance from the pointer to the panel's right edge when the drag began.
    @ObservationIgnored private var dragGrabOffset: CGFloat = 0
    @ObservationIgnored private var isResizing = false
    @ObservationIgnored private var didResize = false

    private static func storedWidth() -> CGFloat? {
        guard let value = UserDefaults.standard.object(forKey: Keys.panelWidth) as? Double,
              value.isFinite, value > 0
        else { return nil }
        return CGFloat(value)
    }

    fileprivate func panelResizeBegan(at screenX: CGFloat) {
        guard isResizable, pinned, isVisible, let frame = targetFrame else { return }
        dragGrabOffset = frame.maxX - screenX
        isResizing = true
        didResize = false
    }

    fileprivate func panelResizeChanged(to screenX: CGFloat) {
        // The screen the panel is on, not the one under the pointer (which may be past its edge).
        guard isResizing, let panel, let current = targetFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) })
        else { return }
        let width = PanelWidth.clamped(
            screenX + dragGrabOffset - current.minX, visibleWidth: screen.visibleFrame.width)
        guard width != current.width else { return }
        panelWidthOverride = width
        didResize = true
        // Keep targetFrame current: `rowID(at:)` hit-tests against it.
        let target = frame(on: screen)
        targetFrame = target
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    fileprivate func panelResizeEnded() {
        guard isResizing else { return }
        isResizing = false
        guard didResize, let width = panelWidthOverride else { return }
        didResize = false
        UserDefaults.standard.set(Double(width), forKey: Keys.panelWidth)
        hasCustomPanelWidth = true
    }

    /// Forgets the user's width and goes back to the theme's.
    func resetPanelWidth() {
        guard isResizable else { return }
        isResizing = false
        didResize = false
        UserDefaults.standard.removeObject(forKey: Keys.panelWidth)
        panelWidthOverride = nil
        hasCustomPanelWidth = false
        guard let panel, isVisible, let current = targetFrame,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(current) })
        else { return }
        let target = frame(on: screen)
        targetFrame = target
        panel.setFrame(target, display: true)
        panel.invalidateShadow()
    }

    // MARK: - Reveal pause

    /// Ends the pause when its date comes.
    @ObservationIgnored private var resumeTask: Task<Void, Never>?

    var isRevealPaused: Bool {
        guard let until = revealPausedUntil else { return false }
        return Date() < until
    }

    /// Stops the left edge from revealing the panel until `until` (`.distantFuture`: until
    /// `resumeReveal()`). An auto-shown panel still hides as usual; pinning is unaffected.
    func pauseReveal(until: Date) {
        revealPausedUntil = until
        UserDefaults.standard.set(until, forKey: Keys.revealPausedUntil)
        scheduleResume()
        tick()  // drops a pending dwell; a visible auto-shown panel keeps its exit timer
    }

    /// Lets the edge reveal the panel again. No tick: it takes a pointer move to show it.
    func resumeReveal() {
        resumeTask?.cancel()
        resumeTask = nil
        revealPausedUntil = nil
        UserDefaults.standard.removeObject(forKey: Keys.revealPausedUntil)
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = nil
        guard let until = revealPausedUntil, until != .distantFuture else { return }
        let delay = until.timeIntervalSinceNow
        guard delay > 0 else {
            resumeReveal()
            return
        }
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // Never tick here: a pointer resting on the edge mustn't pop the panel unprompted.
            guard !Task.isCancelled, let self, self.revealPausedUntil == until else { return }
            self.resumeReveal()
        }
    }

    /// The persisted pause, if still in force (demo mode ignores it).
    private static func storedPauseDate() -> Date? {
        guard !DemoMode.isEnabled,
              let date = UserDefaults.standard.object(forKey: Keys.revealPausedUntil) as? Date,
              date > Date()
        else { return nil }
        return date
    }

    // MARK: - Terminal highlight

    private var highlightTint: GhosttyColor { themeStore.style.theme.highlightTint() }

    /// A new row (or none) is under the pointer: drop the current tint at once, then start the
    /// new row's dwell.
    private func setHovered(_ id: String?, dwell: Duration = hoverDwell) {
        guard id != hoveredID else { return }
        hoveredID = id
        cancelHoverTint()
        guard let id, highlighter != nil, highlightOnHover, isVisible, pendingSessionID != id else { return }
        dwellTask = Task { [weak self] in
            var delay = dwell
            while true {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self?.beginHoverTint(id) == true else { return }
                delay = Self.hoverKeepAlive
            }
        }
    }

    /// After a re-show, a click, or the hover pref coming back on (and no dwell running),
    /// re-arms the dwell for the row actually under the pointer, if any. Rows don't re-report a
    /// pointer that never left them, and their last report goes stale across a hide (hidden rows
    /// see no exit), so this hit-tests instead. It does so after `hoverDwell`, once a re-shown
    /// panel has laid out at its new frame; a row's `onHover` in the meantime takes over.
    private func rearmHover() {
        guard dwellTask == nil, highlighter != nil, highlightOnHover, isVisible else { return }
        hoveredID = nil
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDwell)
            guard !Task.isCancelled, let self else { return }
            self.dwellTask = nil
            if let id = self.rowID(at: NSEvent.mouseLocation) { self.setHovered(id, dwell: .zero) }
        }
    }

    /// The row under `point` (screen coordinates), per the rows' last laid-out frames.
    private func rowID(at point: NSPoint) -> String? {
        // The content view fills the borderless panel; mid-slide, hit-test where it's headed.
        guard isVisible, let frame = targetFrame else { return nil }
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        guard listViewport.contains(local) else { return nil }
        return rowFrames.first { $0.value.contains(local) }?.key
    }

    /// Tints (or keeps tinting) `id`'s pane if it's still the hovered row; false stops the loop.
    private func beginHoverTint(_ id: String) -> Bool {
        guard let highlighter, highlightOnHover, isVisible, hoveredID == id, pendingSessionID != id,
              let session = currentSessions().first(where: { $0.id == id })
        else { return false }
        // A row the pointer left unreported (e.g. one picked by `rearmHover` that never saw an
        // enter, so sees no exit either) must not stay tinted by the keep-alive.
        guard rowID(at: NSEvent.mouseLocation) == id else {
            hoveredID = nil
            endHoverTint()
            return false
        }
        highlighter.beginHover(session, tint: highlightTint)
        tintedID = id
        return true
    }

    /// Stops any pending dwell and clears the current hover tint (the row stays hovered).
    private func cancelHoverTint() {
        dwellTask?.cancel()
        dwellTask = nil
        endHoverTint()
    }

    private func endHoverTint() {
        guard tintedID != nil else { return }
        tintedID = nil
        highlighter?.endHover()
    }

    // MARK: - Pointer tracking

    private func tick() {
        // A visible notice holds the panel open until it expires or is dismissed.
        guard panel != nil, !pinned, notice == nil, pendingSessionID == nil else { return }
        let screens = NSScreen.screens
        policy.suspendedUntil = revealPausedUntil
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
            // Starts the exit timer if the pointer is already away; unpinned from the header, the
            // pointer is inside the panel, so it stays up until the pointer leaves.
            tick()
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

    /// Stays on the screen an auto-shown panel is on (pinning from its header must not jump it
    /// to the primary screen); a hidden panel goes to the primary screen.
    private func showPinned() {
        let screens = NSScreen.screens
        let current = isVisible
            ? targetFrame.flatMap { frame in screens.first { $0.frame.intersects(frame) } } : nil
        guard let screen = current ?? screens.first else { return }
        show(on: screen, animated: !isVisible)
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let edgeInset = Self.edgeInset
        return NSRect(
            x: vf.minX + edgeInset,
            y: vf.minY + edgeInset,
            width: PanelWidth.resolved(
                stored: panelWidthOverride, themeDefault: themeStore.style.panelWidth, visibleWidth: vf.width),
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
        rearmHover()

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
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }, completionHandler: {
                MainActor.assumeIsolated { panel.invalidateShadow() }
            })
        } else {
            panel.alphaValue = 1
            if !panel.isVisible { panel.setFrame(offscreen, display: false) }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: {
                // The shadow follows the pane's rounded alpha, which only exists once drawn.
                MainActor.assumeIsolated { panel.invalidateShadow() }
            })
        }
    }

    /// `resetHighlights` also resets every terminal tint (auto-hide, screen change, unpin); a
    /// hide after a successful focus passes false so the focus pulse plays out.
    private func hide(animated: Bool, resetHighlights: Bool = true) {
        policy.reset()
        hoveredID = nil  // rows may not see a hover exit once the panel is ordered out
        cancelHoverTint()
        guard let panel, isVisible || panel.isVisible else { return }
        if resetHighlights { highlighter?.resetAll() }
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

    private enum Keys {
        static let highlightOnHover = "highlightTerminalOnHover"
        static let pulseOnFocus = "pulseTerminalOnFocus"
        static let panelWidth = "sidebarPanelWidth"  // Double, points
        static let revealPausedUntil = "edgeRevealPausedUntil"  // Date
    }

    private static func storedFlag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
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
            onTogglePin: { controller.isPinned.toggle() },
            onDismissNotice: { controller.dismissNotice() },
            onOpenAutomationSettings: { controller.openAutomationSettings() },
            onHoverChange: { controller.rowHoverChanged($0, inside: $1) },
            onRowFrames: { controller.rowFramesChanged($0) },
            onListViewport: { controller.listViewportChanged($0) }
        )
        .overlay(alignment: .trailing) {
            // The pane fills the panel, so its visible edge is the panel's: the strip sits just
            // inside it, clear of the rounded corners.
            if controller.isPinned && controller.isResizable {
                PanelResizeHandle(
                    onBegan: { controller.panelResizeBegan(at: $0) },
                    onChanged: { controller.panelResizeChanged(to: $0) },
                    onEnded: { controller.panelResizeEnded() },
                    onReset: { controller.resetPanelWidth() }
                )
                .frame(width: 6)
                .padding(.vertical, TerminalStyle.cornerRadius)
            }
        }
        .environment(\.terminalStyle, controller.themeStore.style)
        .environment(\.panelVisible, controller.isVisible)
    }
}
