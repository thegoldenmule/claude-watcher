import AppKit
import ClaudeWatcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // TODO(integration): wire SessionStore, EdgeController, focuser
    }
}
