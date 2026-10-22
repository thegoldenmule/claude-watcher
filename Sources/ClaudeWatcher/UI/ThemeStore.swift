import AppKit
import ClaudeWatcherCore
import os

/// Keeps the sidebar's look in sync with the user's Ghostty config: loads it at start, reloads
/// when any config/theme file changes (a cheap stat of a handful of paths every 2 s, which also
/// notices a config file being created or replaced atomically by an editor), and, for
/// `theme = light:X,dark:Y`, when the system appearance flips.
@MainActor
@Observable
final class ThemeStore {
    private(set) var style: TerminalStyle
    /// Called after `style` changes (the panel resizes and updates its appearance).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let loader: GhosttyThemeLoader
    @ObservationIgnored private var followsAppearance = false
    @ObservationIgnored private var watchedPaths: [String] = []
    @ObservationIgnored private var signature: [String] = []
    @ObservationIgnored private var lastPrefersDark: Bool?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.thegoldenmule.ClaudeWatcher", category: "Theme")

    init(loader: GhosttyThemeLoader = .standard(resourcesDirectory: ThemeStore.ghosttyResourcesDirectory())) {
        self.loader = loader
        self.style = .default
        reload()
    }

    func start() {
        guard pollTask == nil else { return }
        // The app appearance may have been forced (CW_APPEARANCE) since init.
        reload()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.reloadIfFilesChanged()
            }
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceChanged() }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        appearanceObservation = nil
    }

    private var prefersDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func appearanceChanged() {
        guard followsAppearance, prefersDark != lastPrefersDark else { return }
        reload()
    }

    private func reloadIfFilesChanged() {
        if Self.signature(of: watchedPaths) != signature { reload() }
    }

    private func reload() {
        let dark = prefersDark
        let load = loader.load(prefersDark: dark)
        lastPrefersDark = dark
        followsAppearance = load.followsAppearance
        watchedPaths = load.watchedPaths
        signature = Self.signature(of: watchedPaths)
        guard load.theme != style.theme else { return }
        style = TerminalStyle(theme: load.theme)
        logger.notice("""
            ghostty theme: \(load.theme.themeName ?? "(default)", privacy: .public) \
            bg=\(load.theme.background.hexString, privacy: .public) \
            fg=\(load.theme.foreground.hexString, privacy: .public) \
            font=\(self.style.fontDescription, privacy: .public) \(load.theme.fontSize)pt \
            opacity=\(load.theme.backgroundOpacity) adaptive=\(load.followsAppearance)
            """)
        onChange?()
    }

    /// mtime + size per path ("-" when missing).
    private static func signature(of paths: [String]) -> [String] {
        paths.map { path in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return "\(mtime):\(size)"
        }
    }

    nonisolated static func ghosttyResourcesDirectory() -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")?
            .appendingPathComponent("Contents/Resources/ghostty").path
    }
}
