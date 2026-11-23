import SwiftUI

@main
struct ClaudeWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            let menu = appDelegate.menu
            if appDelegate.isDemo {
                Text("Demo mode")
            }
            // Plan usage, one disabled line per agent (plus an error line when a poll failed).
            let usageLines = appDelegate.usage.menuLines
            if !usageLines.isEmpty {
                ForEach(Array(usageLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
                Divider()
            }
            Toggle("Pin Sidebar", isOn: Binding(
                get: { appDelegate.edge.isPinned },
                set: { appDelegate.edge.isPinned = $0 }
            ))
            if !appDelegate.isDemo {
                revealPauseMenu
            }

            // Only what needs the user's attention; everything else lives under Settings.
            if needsAttention {
                Divider()
                if let title = menu.hookInstallTitle {
                    Button("\(title == "Install Hook" ? "Install" : "Update") Claude Code Hook") { menu.installHook() }
                }
                if menu.codexHookNeedsAttention, let title = menu.codexHookInstallTitle {
                    Button("\(title == "Install Hook" ? "Install" : "Update") Codex Hook") { menu.installCodexHook() }
                }
                if menu.launchAtLoginStatus == .requiresApproval {
                    Button("Approve Launch at Login…") { menu.openLoginItemsSettings() }
                }
                if let error = menu.lastError {
                    Text(error)
                }
                if case .available(let release) = appDelegate.updates.state {
                    Button("Update Available: \(release.tag)…") { appDelegate.updates.openReleasePage(release) }
                }
            }

            Divider()
            settingsMenu
            Button("Quit ClaudeWatcher") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            statusItemLabel
        }
    }

    /// The app's symbol, followed by the usage meters unless there are none (or they're turned
    /// off): then exactly the plain symbol.
    @ViewBuilder private var statusItemLabel: some View {
        let paused = appDelegate.edge.isRevealPaused
        let symbol = paused ? "moon.zzz" : "sidebar.left"
        let meters = appDelegate.usage.menuBarMeters
        if meters.isEmpty {
            Image(systemName: symbol)
                .accessibilityLabel("ClaudeWatcher")
        } else {
            Image(nsImage: StatusItemRenderer.image(symbol: symbol, meters: meters))
                .accessibilityLabel(StatusItemRenderer.accessibilityLabel(meters: meters, paused: paused))
        }
    }

    /// True when the top level should show a hook, login item, error or update item.
    private var needsAttention: Bool {
        let menu = appDelegate.menu
        if case .available = appDelegate.updates.state { return true }
        return menu.hookInstallTitle != nil || menu.codexHookNeedsAttention
            || menu.launchAtLoginStatus == .requiresApproval || menu.lastError != nil
    }

    /// One item either way: "Pause Edge Reveal" to pause for a while, or, while paused, its
    /// status ("Edge Reveal Paused Until 3:00 PM") with "Resume Now" and the same durations.
    @ViewBuilder private var revealPauseMenu: some View {
        let edge = appDelegate.edge
        let paused = edge.isRevealPaused
        Menu(paused ? Self.pauseStatus(edge.revealPausedUntil ?? .distantFuture) : "Pause Edge Reveal") {
            if paused {
                Button("Resume Now") { edge.resumeReveal() }
                Divider()
            }
            Button("15 Minutes") { edge.pauseReveal(until: .now.addingTimeInterval(15 * 60)) }
            Button("1 Hour") { edge.pauseReveal(until: .now.addingTimeInterval(60 * 60)) }
            Button("4 Hours") { edge.pauseReveal(until: .now.addingTimeInterval(4 * 60 * 60)) }
            Divider()
            Button("Until Resumed") { edge.pauseReveal(until: .distantFuture) }
        }
    }

    /// Everything that's set once and rarely touched: terminal effects, sidebar width, usage
    /// meters, login item, the Claude Code and Codex hooks, and the version with its update check.
    private var settingsMenu: some View {
        let menu = appDelegate.menu
        return Menu("Settings") {
            if !appDelegate.isDemo {
                // Demo mode never tints terminals; don't expose (or write) the real prefs.
                Toggle("Highlight Terminal on Hover", isOn: Binding(
                    get: { appDelegate.edge.highlightOnHover },
                    set: { appDelegate.edge.highlightOnHover = $0 }
                ))
                Toggle("Pulse Terminal on Focus", isOn: Binding(
                    get: { appDelegate.edge.pulseOnFocus },
                    set: { appDelegate.edge.pulseOnFocus = $0 }
                ))
                Button("Reset Sidebar Width") { appDelegate.edge.resetPanelWidth() }
                    .disabled(!appDelegate.edge.hasCustomPanelWidth)
                Divider()
            }
            Toggle("Show Usage in Menu Bar", isOn: Binding(
                get: { appDelegate.usage.showInMenuBar },
                set: { appDelegate.usage.showInMenuBar = $0 }
            ))
            Toggle("Launch at Login", isOn: Binding(
                get: { menu.launchAtLogin },
                set: { menu.setLaunchAtLogin($0) }
            ))

            Divider()
            Text(menu.hookStatusText)
            if let title = menu.hookInstallTitle {
                Button(title) { menu.installHook() }
            }
            if menu.canUninstallHook {
                Button("Uninstall Hook") { menu.uninstallHook() }
            }

            if menu.codexPresent || menu.canUninstallCodexHook {
                Divider()
                Text(menu.codexHookStatusText)
                if let title = menu.codexHookInstallTitle {
                    Button(title) { menu.installCodexHook() }
                }
                if menu.canUninstallCodexHook {
                    Button("Uninstall Codex Hook") { menu.uninstallCodexHook() }
                }
            }

            Divider()
            updateItems
        }
    }

    /// The running version, what the last update check found, and "Check for Updates".
    @ViewBuilder private var updateItems: some View {
        let updates = appDelegate.updates
        let state = updates.state
        Text(updates.app.displayString)
        switch state {
        case .unversioned, .notChecked: EmptyView()
        case .checking: Text("Checking for Updates…")
        case .upToDate: Text("Up to Date")
        case .available(let release):
            Button("Update Available: \(release.tag)…") { updates.openReleasePage(release) }
        case .failed: Text("Couldn't Check for Updates")
        }
        if state != .unversioned, state != .checking {
            Button("Check for Updates") { updates.checkNow() }
                .disabled(updates.isChecking)
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
