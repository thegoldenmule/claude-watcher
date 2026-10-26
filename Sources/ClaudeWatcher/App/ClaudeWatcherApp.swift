import SwiftUI

@main
struct ClaudeWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            let menu = appDelegate.menu
            Toggle("Pin Sidebar", isOn: Binding(
                get: { appDelegate.edge.isPinned },
                set: { appDelegate.edge.isPinned = $0 }
            ))
            if !appDelegate.isDemo {
                Button("Reset Sidebar Width") { appDelegate.edge.resetPanelWidth() }
                    .disabled(!appDelegate.edge.hasCustomPanelWidth)
            }
            if appDelegate.isDemo {
                // Demo mode never tints terminals; don't expose (or write) the real prefs.
                Text("Demo mode")
            } else {
                Toggle("Highlight Terminal on Hover", isOn: Binding(
                    get: { appDelegate.edge.highlightOnHover },
                    set: { appDelegate.edge.highlightOnHover = $0 }
                ))
                Toggle("Pulse Terminal on Focus", isOn: Binding(
                    get: { appDelegate.edge.pulseOnFocus },
                    set: { appDelegate.edge.pulseOnFocus = $0 }
                ))
            }
            if !appDelegate.isDemo {
                revealPauseItems
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
        } label: {
            Image(systemName: appDelegate.edge.isRevealPaused ? "moon.zzz" : "sidebar.left")
                .accessibilityLabel("ClaudeWatcher")
        }
    }

    /// Pause the edge reveal for a while, or show until when it's paused and offer to resume.
    @ViewBuilder private var revealPauseItems: some View {
        let edge = appDelegate.edge
        if edge.isRevealPaused, let until = edge.revealPausedUntil {
            Text(Self.pauseStatus(until))
            Button("Resume Edge Reveal") { edge.resumeReveal() }
        } else {
            Menu("Pause Edge Reveal") {
                Button("15 Minutes") { edge.pauseReveal(until: .now.addingTimeInterval(15 * 60)) }
                Button("1 Hour") { edge.pauseReveal(until: .now.addingTimeInterval(60 * 60)) }
                Button("4 Hours") { edge.pauseReveal(until: .now.addingTimeInterval(4 * 60 * 60)) }
                Divider()
                Button("Until Resumed") { edge.pauseReveal(until: .distantFuture) }
            }
        }
    }

    private static func pauseStatus(_ until: Date) -> String {
        guard until != .distantFuture else { return "Edge Reveal Paused" }
        let time = Calendar.current.isDateInToday(until)
            ? until.formatted(date: .omitted, time: .shortened)
            : until.formatted(date: .abbreviated, time: .shortened)
        return "Edge Reveal Paused Until \(time)"
    }
}
