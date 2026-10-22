import AppKit
import ClaudeWatcherCore
import os
import ServiceManagement

/// State behind the menu bar extra: Claude Code hook install status and Launch at Login.
/// Refreshed whenever a menu starts tracking, so it reflects edits made outside the app.
@MainActor
@Observable
final class MenuModel {
    private(set) var hookStatus: HookInstaller.InstallStatus = .notInstalled
    private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    /// Last hook / login-item error, shown in the menu until the next successful action.
    private(set) var lastError: String?

    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Menu")

    /// The hook script shipped in the app bundle (`scripts/build-app.sh` copies it there).
    /// nil when running outside the .app (e.g. `swift run`).
    var bundledHookScript: URL? {
        Bundle.main.url(forResource: "claude-watcher-hook", withExtension: "sh")
    }

    init() {
        refresh()
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        hookStatus = HookInstaller.status(hookScriptSource: bundledHookScript)
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    // MARK: Hook

    var hookStatusText: String {
        switch hookStatus {
        case .installed: "Claude Code Hook: Installed"
        case .notInstalled: "Claude Code Hook: Not Installed"
        case .outdated: "Claude Code Hook: Needs Update"
        }
    }

    var hookInstallTitle: String? {
        switch hookStatus {
        case .installed: nil
        case .notInstalled: "Install Hook"
        case .outdated: "Update Hook"
        }
    }

    func installHook() {
        guard let source = bundledHookScript else {
            lastError = "Hook script not found in the app bundle (build with `make app`)."
            return
        }
        do {
            let backup = try HookInstaller.install(hookScriptSource: source)
            logger.notice("hook installed; settings backup: \(backup?.path ?? "none", privacy: .public)")
            lastError = nil
        } catch {
            lastError = "Hook install failed: \(error)"
            logger.error("hook install failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func uninstallHook() {
        do {
            let backup = try HookInstaller.uninstall()
            logger.notice("hook uninstalled; settings backup: \(backup?.path ?? "none", privacy: .public)")
            lastError = nil
        } catch {
            lastError = "Hook uninstall failed: \(error)"
            logger.error("hook uninstall failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    // MARK: Launch at Login

    var launchAtLogin: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "Launch at Login: \(error.localizedDescription)"
            logger.error("launch at login \(enabled): \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
