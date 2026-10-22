import AppKit
import ClaudeWatcherCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let isDemo = DemoMode.isEnabled
    /// nil in demo mode.
    let store: SessionStore?
    let edge: EdgeController

    override init() {
        if DemoMode.isEnabled {
            let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Demo")
            store = nil
            edge = EdgeController(
                sessions: { DemoMode.sessions },
                onSelect: { logger.notice("demo select: \($0.title, privacy: .public)") }
            )
        } else {
            let store = SessionStore()
            self.store = store
            // TODO(integration): replace LoggingFocuser with the real SessionFocuser.
            edge = EdgeController(store: store, focuser: LoggingFocuser())
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
