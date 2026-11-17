import AppKit
import ClaudeWatcherCore
import os
import ServiceManagement

/// State behind the menu bar extra: Claude Code and Codex hook install status and Launch at Login.
/// Refreshed whenever a menu starts tracking, so it reflects edits made outside the app.
/// The hook status is computed off the main thread once Claude Code's config dir is resolved,
/// and published on main; the login-item status is read synchronously (it's cheap).
@MainActor
@Observable
final class MenuModel {
    /// nil until the first status check completes.
    private(set) var hookStatus: HookInstaller.InstallStatus?
    /// nil until the first Codex status check completes.
    private(set) var codexHookStatus: CodexHookInstaller.Status?
    /// Whether Codex's home directory (`$CODEX_HOME`, default `~/.codex`) exists.
    private(set) var codexPresent = false
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

    /// The Codex hook script shipped in the app bundle; nil outside the .app.
    var bundledCodexHookScript: URL? {
        Bundle.main.url(forResource: "codex-watcher-hook", withExtension: "sh")
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
        // Cheap, and not worth delaying behind the Claude home resolution.
        launchAtLoginStatus = SMAppService.mainApp.status
        let script = bundledHookScript
        Task {
            // Suspends (no thread blocked) until the config dir is resolved; the status read
            // is then just file IO, off main.
            _ = await SessionDiscovery.resolvedClaudeHome()
            let hook = await Task.detached(priority: .userInitiated) {
                HookInstaller.status(hookScriptSource: script)
            }.value
            guard generation == refreshGeneration else { return }
            hookStatus = hook
        }
        let codexScript = bundledCodexHookScript
        // Separate task: CODEX_HOME's resolution must not delay the Claude status.
        Task {
            let codexHome = await CodexPaths.resolvedHome()
            let (present, status) = await Task.detached(priority: .userInitiated) {
                (CodexHookInstaller.isCodexPresent(codexHome: codexHome),
                 CodexHookInstaller.status(hookScriptSource: codexScript, codexHome: codexHome))
            }.value
            guard generation == refreshGeneration else { return }
            codexPresent = present
            codexHookStatus = status
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

    // MARK: Codex hook

    var codexHookStatusText: String {
        switch codexHookStatus {
        case nil: "Codex Hook: Checking…"
        case let status? where status.install == .installed && status.needsTrust: "Codex Hook: Approve in Codex"
        case let status?:
            switch status.install {
            case .installed: "Codex Hook: Installed"
            case .notInstalled: "Codex Hook: Not Installed"
            case .outdated: "Codex Hook: Needs Update"
            }
        }
    }

    /// "Install Hook" / "Update Hook" when the Codex hook needs (re)installing, else nil.
    var codexHookInstallTitle: String? {
        switch codexHookStatus?.install {
        case nil, .installed?: nil
        case .notInstalled?: "Install Hook"
        case .outdated?: "Update Hook"
        }
    }

    /// Top-level attention item only when Codex is present and the hook is missing or outdated.
    var codexHookNeedsAttention: Bool {
        codexPresent && codexHookInstallTitle != nil
    }

    var canUninstallCodexHook: Bool {
        codexHookStatus?.install == .installed || codexHookStatus?.install == .outdated
    }

    func installCodexHook() {
        guard let source = bundledCodexHookScript else {
            lastError = "Codex hook script not found in the app bundle (build with `make app`)."
            return
        }
        do {
            let backup = try CodexHookInstaller.install(hookScriptSource: source)
            logger.notice("codex hook installed; hooks.json backup: \(backup?.path ?? "none", privacy: .public)")
            lastError = nil
        } catch {
            lastError = "Codex hook install failed: \(error)"
            logger.error("codex hook install failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func uninstallCodexHook() {
        do {
            let backup = try CodexHookInstaller.uninstall()
            logger.notice("codex hook uninstalled; hooks.json backup: \(backup?.path ?? "none", privacy: .public)")
            lastError = nil
        } catch {
            lastError = "Codex hook uninstall failed: \(error)"
            logger.error("codex hook uninstall failed: \(String(describing: error), privacy: .public)")
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
