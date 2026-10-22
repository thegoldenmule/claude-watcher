import SwiftUI

@main
struct ClaudeWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ClaudeWatcher", systemImage: "sidebar.left") {
            Button("Quit ClaudeWatcher") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
