import AppKit
import ClaudeWatcherCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let isDemo = DemoMode.isEnabled
    /// nil in demo mode.
    let store: SessionStore?
    /// The one focuser for the app's lifetime: it holds the Ghostty pid cache and probe locks.
    let focuser = RoutingFocuser()
    let edge: EdgeController

    override init() {
        if DemoMode.isEnabled {
            let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Demo")
            store = nil
            edge = EdgeController(
                sessions: { DemoMode.sessions },
                onSelect: { session in
                    logger.notice("demo select: \(session.title, privacy: .public)")
                    return await DemoMode.focusResult(for: session)
                }
            )
        } else {
            let store = SessionStore()
            self.store = store
            edge = EdgeController(store: store, focuser: focuser)
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let appearance = DemoMode.forcedAppearance { NSApp.appearance = appearance }
        store?.start()
        if isDemo { edge.isPinned = true }
        edge.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        edge.stop()
        store?.stop()
    }
}
