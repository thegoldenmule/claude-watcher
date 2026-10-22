import SwiftUI

@main
struct ClaudeWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ClaudeWatcher", systemImage: "sidebar.left") {
            Toggle("Pin Sidebar", isOn: Binding(
                get: { appDelegate.edge.isPinned },
                set: { appDelegate.edge.isPinned = $0 }
            ))
            if appDelegate.isDemo {
                Text("Demo mode")
            }
            Divider()
            Button("Quit ClaudeWatcher") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
