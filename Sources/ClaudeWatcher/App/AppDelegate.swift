import AppKit
import ClaudeWatcherCore
import os

/// Holds the session store once it exists, so the sidebar's `sessions` closure (read inside
/// SwiftUI's `body`) re-renders when the store appears.
@MainActor
@Observable
private final class StoreSlot {
    var store: SessionStore?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let isDemo = DemoMode.isEnabled
    /// The one focuser for the app's lifetime: it holds the Ghostty pid cache and probe locks.
    let focuser = RoutingFocuser()
    private let slot = StoreSlot()
    let edge: EdgeController
    let menu: MenuModel
    let updates: UpdateModel
    let usage: UsageModel
    private var terminating = false

    /// nil in demo mode, and until `SessionDiscovery.defaultClaudeHome` has been resolved.
    var store: SessionStore? { slot.store }

    override init() {
        // Resolving Claude Code's config dir may spawn launchctl and a login shell (up to ~4 s
        // worst case): start it now, off the main thread, and never wait for it on main.
        SessionDiscovery.prewarmDefaultClaudeHome()
        CodexPaths.prewarm()
        menu = MenuModel()
        updates = UpdateModel(isDemo: DemoMode.isEnabled)
        // The sources' inits are trivial; all their IO happens in `poll`, on their own actors.
        let usage = UsageModel(sources: DemoMode.isEnabled
            ? DemoMode.usageSources : [ClaudeUsageSource(), CodexUsageSource()])
        self.usage = usage
        if DemoMode.isEnabled {
            let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Demo")
            edge = EdgeController(
                sessions: { DemoMode.sessions },
                usage: { usage.lines },
                onSelect: { session in
                    logger.notice("demo select: \(session.title, privacy: .public)")
                    return await DemoMode.focusResult(for: session)
                },
                onShow: { usage.tick() }
            )
        } else {
            edge = EdgeController(
                sessions: { [slot] in slot.store?.sessions ?? [] },
                usage: { usage.lines },
                onSelect: Self.focusHandler(focuser),
                onShow: { usage.tick() },
                // Never in demo mode: demo sessions have fake ttys.
                highlighter: .shared)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let appearance = DemoMode.forcedAppearance { NSApp.appearance = appearance }
        if isDemo {
            edge.isPinned = true
        } else {
            // Recover a pane left tinted by a crash.
            TerminalHighlighter.shared.resetAll()
            Task { await startStore() }
            updates.start()
        }
        edge.start()
        usage.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        edge.stop()
        updates.stop()
        usage.stop()
        store?.stop()
        if !isDemo { TerminalHighlighter.shared.resetAllSync() }
    }

    /// Creates and starts the store once the config dirs are resolved (off the main thread).
    private func startStore() async {
        let claudeHome = await SessionDiscovery.resolvedClaudeHome()
        let codexHome = await CodexPaths.resolvedHome()
        guard !terminating, slot.store == nil else { return }
        let codex = CodexDiscovery(codexHome: codexHome, hookStateDirectory: CodexHookStateStore.defaultDirectory)
        let store = SessionStore(
            claudeHome: claudeHome, hookStateDirectory: HookStateStore.defaultDirectory, codex: codex)
        slot.store = store
        store.start()
    }

    /// Focuses the clicked session's terminal via `focuser`, logging the outcome.
    private static func focusHandler(
        _ focuser: some SessionFocuser
    ) -> @MainActor (ClaudeSession) async -> FocusResult {
        let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Focus")
        return { session in
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
    }
}
