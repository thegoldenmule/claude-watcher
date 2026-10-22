import AppKit
import ClaudeWatcherCore
import os
import ServiceManagement

/// State behind the menu bar extra: Claude Code hook install status and Launch at Login.
/// Refreshed whenever a menu starts tracking, so it reflects edits made outside the app.
/// Statuses are computed off the main thread (the first `HookInstaller.status` may wait on
/// resolving Claude Code's config dir) and published on main.
@MainActor
@Observable
final class MenuModel {
    /// nil until the first status check completes.
    private(set) var hookStatus: HookInstaller.InstallStatus?
    private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    /// Last hook / login-item error, shown in the menu until the next successful action.
    private(set) var lastError: String?

    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?
    /// Bumped by every `refresh()`; only the newest refresh publishes its result.
    @ObservationIgnored private var refreshGeneration = 0
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
        refreshGeneration += 1
        let generation = refreshGeneration
        let script = bundledHookScript
        Task {
            let (hook, login) = await Task.detached(priority: .userInitiated) {
                (HookInstaller.status(hookScriptSource: script), SMAppService.mainApp.status)
            }.value
            guard generation == refreshGeneration else { return }
            hookStatus = hook
            launchAtLoginStatus = login
        }
    }

    // MARK: Hook

    var hookStatusText: String {
        switch hookStatus {
        case nil: "Claude Code Hook: Checking…"
        case .installed: "Claude Code Hook: Installed"
        case .notInstalled: "Claude Code Hook: Not Installed"
        case .outdated: "Claude Code Hook: Needs Update"
        }
    }

    var hookInstallTitle: String? {
        switch hookStatus {
        case nil, .installed: nil
        case .notInstalled: "Install Hook"
        case .outdated: "Update Hook"
        }
    }

    var canUninstallHook: Bool {
        hookStatus == .installed || hookStatus == .outdated
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
