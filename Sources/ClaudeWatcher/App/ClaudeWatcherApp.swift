import SwiftUI

@main
struct ClaudeWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ClaudeWatcher", systemImage: "sidebar.left") {
            let menu = appDelegate.menu
            Toggle("Pin Sidebar", isOn: Binding(
                get: { appDelegate.edge.isPinned },
                set: { appDelegate.edge.isPinned = $0 }
            ))
            if appDelegate.isDemo {
                Text("Demo mode")
            }

            Divider()
            Text(menu.hookStatusText)
            if let title = menu.hookInstallTitle {
                Button(title) { menu.installHook() }
            }
            if menu.canUninstallHook {
                Button("Uninstall Hook") { menu.uninstallHook() }
            }

            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { menu.launchAtLogin },
                set: { menu.setLaunchAtLogin($0) }
            ))
            if menu.launchAtLoginStatus == .requiresApproval {
                Button("Approve in Login Items Settings…") { menu.openLoginItemsSettings() }
            }

            if let error = menu.lastError {
                Divider()
                Text(error)
            }

            Divider()
            Button("Quit ClaudeWatcher") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
